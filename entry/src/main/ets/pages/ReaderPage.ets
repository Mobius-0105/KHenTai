import { image } from '@kit.ImageKit';
import { window } from '@kit.ArkUI';
import { EhApi } from '../core/EhApi';
import { Gallery, GalleryDetail, ImagePage, ThumbTile } from '../core/Models';
import { ImageLoader, ThumbPipeline, ThumbRef } from '../net/ImageLoader';
import { ImageDiskCache } from '../net/ImageDiskCache';
import { ThumbCropper } from '../net/ThumbCropper';
import { Prefs } from '../core/Prefs';
import { Theme } from '../core/Theme';
import { FloatingTabs } from '../components/FloatingTabs';
import { MaterialPlane } from '../components/MaterialPlane';

/** 宽高比超过这个值就算「横幅」：双栏模式下独占一行，不再硬拼两页 */
/**
 * 宽图阈值：宽 > 高（比例 > 1.0）。
 *
 * 之前取 1.2 是"看起来像横图"的经验值，但 JHenTai 用的是严格 `width > height`
 * （`horizontal_double_column_layout.dart:122`）。差别在 1.0~1.2 这一段：
 * 那批"接近正方"的页拼成两页也放不下，独占一屏反而更清楚。
 */
const WIDE_RATIO: number = 1.0;
/** 底部缩略图条：单格尺寸（参考 JHenTai 的 80×120，按手机屏宽等比收一点） */
const STRIP_CELL_W: number = 76;
const STRIP_CELL_H: number = 114;
/**
 * 底部条的两条闸门（详见 ImageLoader.ThumbPipeline）。
 *
 * 底部条是 `List + ForEach`（非懒加载）：300 页的画廊一打开就是 300 格全部挂载、
 * 300 个 onAppear，每格要「拉一次 /s/ 页 + 拉一次图片」。不限流的话站点配额页
 * （509）立刻就到，正文页也会被这些请求挤慢。
 * 两条闸门分开：HTML 打主站（3，保守）；图片打 CDN/H@H（6，可以宽）。
 */
const STRIP_HTML_PARALLEL: number = 3;
const STRIP_IMG_PARALLEL: number = 6;
/** 一格从进队到出图的容忍上限（毫秒）：超过就记死，不再无限重试 */
const STRIP_STUCK_MS: number = 8000;

/**
 * 条漫（连续滚动）单页最大宽度，单位 vp。
 * 手机竖屏（360~430vp）永远碰不到这条上限，只有平板/折叠屏展开后才会把长条图收窄居中，
 * 避免一张 1280vp 宽的长条图被拉伸到糊。
 */
const READER_SINGLE_PAGE_MAX_WIDTH: number = 780;

/**
 * 阅读器底色：恒为深色，不跟主题。
 *
 * 看图时四周任何色相都会和图片本身的颜色打架，只有近黑的中性底能把注意力完全留给画面；
 * 所以这里的文字/图标一律走白色系，**不能**用 Theme.text()（浅色主题下它是深色，
 * 压在这层黑底上读不出来）。设置面板是浮起来的卡片，内部才用 Theme.xxx()。
 */
const READER_BG: string = '#0B0D10';
/** 压在玻璃胶囊上的主信息（标题、页码、上一页/下一页） */
const ON_GLASS: string = '#FFFFFF';
/** 压在玻璃胶囊上的次级信息（页码后缀、滑条刻度数字） */
const ON_GLASS_SOFT: string = '#D9FFFFFF';
/** 玻璃胶囊自带的白色细边：黑底上只有比底色亮的线才读得出来 */
const ON_GLASS_EDGE: string = '#24FFFFFF';
/** 滑条轨道：底色的 30% 白，拖动时才能同时看清轨道与滑块 */
const SLIDER_TRACK: string = '#4DFFFFFF';
/** 滑条已选段的颜色：主题蓝（与全局 accent 同色系，但在深底上要更亮一档） */
const SLIDER_ON: string = '#5AA9FF';
/** 不可用（第一页的上一页 / 最后一页的下一页）的不透明度 */
const DISABLED_OPACITY: number = 0.4;

/** 底栏页码切成滑条后，停止操作多久自动退回页码（毫秒） */
const PAGE_CONTROL_IDLE_MS: number = 2000;
/** 设置面板上滑/淡入时长 */
const SHEET_ANIM_MS: number = 220;
/** 设置面板单行高度 */
const SETTING_ROW_H: number = 52;
/** 顶/底两条胶囊的高度与圆角：半高即全圆，和 Bika 那套胶囊同档 */
const CAPSULE_H: number = 52;
const CAPSULE_R: number = 26;

/**
 * 阅读器里的一页。
 *
 * 两种来源：
 *  - 远程：/s/ 单图页 → 图片地址 → 带 Referer 下载（h@h 会校验）
 *  - 本地：下载器落盘的 jpg，直接解码，不联网
 *
 * 每页自己持有一张 PixelMap，滚出屏幕就释放 —— 比全局缓存更容易保证
 * “不释放正在显示的那张”。
 */
@Component
struct ReaderImage {
  url: string = '';
  index: number = 0;
  /** true 表示 url 是本地文件路径 */
  local: boolean = false;
  onTap: () => void = (): void => {};
  /** 解码完成后把宽高比回传给父层：双栏要按比例判断横图 */
  onLoaded: (index: number, ratio: number) => void = (index: number, ratio: number): void => {};
  /**
   * true = 按父容器 contain（宽高都 100%），而不是用自身比例撑高。
   *
   * 双页模式下两页各自的比例不同，如果都按"自身比例"撑开，两张图高度不齐、上下错位。
   * JHenTai 的做法是两张都 contain 到「半宽 × 全屏高」这个**同一个框**
   * （`getImageFittedSizeIncludeSpread`），于是视觉上等高、留白各自在框内。
   */
  fitBox: boolean = false;
  /**
   * 显隐工具栏所需的连击次数：1 = 单击，2 = 双击。由 ReaderPage 按设置下发。
   *
   * 必须是 @Prop 而不是普通成员：普通成员只在**创建时**接受父组件初始化，
   * 父层切了设置之后已挂载的图片不会收到新值（手势还是旧的），
   * 这正是「切换后要立即生效」这条需求踩不得的坑。
   * 默认 1 保证其它调用点（不改这一项时）行为完全不变。
   */
  @Prop tapCount: number = 1;

  @State private pm: image.PixelMap | null = null;
  @State private ratio: number = 0.7;
  @State private err: string = '';
  @State private loading: boolean = true;
  /** 重试进度文案（"重试中 4/9"）：重试有间隔，不给反馈就像卡死 */
  @State private retryNote: string = '';

  aboutToAppear(): void {
    // 每一页**自己解码、自己持有、自己释放**（见 aboutToDisappear）。
    //
    // 为什么不再共享 ImageCache 里的 PixelMap：那是上一版黑图的来源。
    // 共享一个解码结果意味着「谁在用」需要引用计数来追踪，而 ArkTS 这边没有现成的
    // 图片库替我们做这件事 —— 预取、重试、缓存淘汰任何一处 release 早一步，
    // 屏幕上正在画的那一帧就变成全黑。
    // 现在采用与 JHenTai「预取只落盘、显示各自解码」等价的模型：字节层共享，像素层独占。
    this.load();
  }

  aboutToDisappear(): void {
    // 这一页的像素归本组件所有，滚出屏幕就释放 —— 所有权单一，没有共享就没有竞态。
    //
    // **但必须延迟一帧**：组件从树上摘下来的那一帧，系统可能还在用它做上屏/转场合成；
    // 当场 release 就可能出现"闪一下黑"（甚至整页黑）。延迟 32ms（约两帧）再释放，
    // 这与 Flutter 那边 `addPostFrameCallback(oldImageInfo.dispose)` 是同一个思路。
    const old: image.PixelMap | null = this.pm;
    this.pm = null;
    if (old !== null) {
      setTimeout(() => {
        try {
          old.release();
        } catch (e) {
        }
      }, 32);
    }
  }

  /**
   * 加载这一页。
   *
   * 失败重试分**三组**，组内密集、组间拉长：
   *
   * ```
   * 组1: 立刻 / +0.35s / +0.9s
   * 组2: 隔 2.5s 后再来一组
   * 组3: 隔 6s 后再来一组
   * ```
   *
   * 为什么不是「连试三次」：E-Hentai 的图床是 H@H 节点，失败大多是节点短时拥塞或
   * 连接排队 —— 几百毫秒内连试三次，三次会撞在同一段拥塞里，等于只试了一次。
   * 组间拉到 2.5s / 6s，才真正覆盖「节点缓过来」的时间尺度。
   *
   * 两种失败**不重试**（重试必然再撞，还拖慢整页）：
   *   - 本地文件读不到：离线页面被删了；
   *   - 509 浏览上限：要换账号或等配额。
   */
  async load(): Promise<void> {
    this.loading = true;
    this.err = '';
    this.retryNote = '';
    const insideGroup: number[] = [0, 350, 900];
    const groupGap: number[] = [0, 2500, 6000];
    let attempt: number = 0;
    const total: number = insideGroup.length * groupGap.length;
    let lastErr: string = '';

    for (let g = 0; g < groupGap.length; g++) {
      if (groupGap[g] > 0) {
        // 组间等待也给个提示，否则用户看到转圈停在那里会以为卡死
        this.retryNote = '重试中 ' + (attempt + 1).toString() + '/' + total.toString();
        await this.sleep(groupGap[g]);
      }
      for (let k = 0; k < insideGroup.length; k++) {
        if (insideGroup[k] > 0) {
          await this.sleep(insideGroup[k]);
        }
        attempt++;
        if (attempt > 1) {
          this.retryNote = '重试中 ' + attempt.toString() + '/' + total.toString();
        }
        try {
          let pm: image.PixelMap | null = null;
          if (this.local) {
            pm = await ImageLoader.loadFile(this.url);
            if (pm === null) {
              this.err = '本地文件读取失败';
              this.retryNote = '';
              this.loading = false;
              return;
            }
          } else {
            const page = await EhApi.loadImagePage(this.url);
            if (page.limited) {
              this.err = '该图达到浏览上限（509），登录后可继续';
              this.retryNote = '';
              this.loading = false;
              return;
            }
            pm = await ImageLoader.load(page.imageUrl, this.url);
            if (pm === null) {
              throw new Error('图片下载失败');
            }
          }
          const info: image.ImageInfo = pm.getImageInfoSync();
          if (info.size.height > 0) {
            this.ratio = info.size.width / info.size.height;
          }
          this.onLoaded(this.index, this.ratio);
          this.pm = pm;
          this.retryNote = '';
          this.loading = false;
          return;
        } catch (e) {
          lastErr = (e as Error).message;
        }
      }
    }
    // 全部重试都失败：这份字节大概率是坏的（截断/全 0），删掉，别让它一直毒化缓存
    ImageDiskCache.remove(this.url);
    this.err = (lastErr.length > 0 ? lastErr : '加载失败')
      + '（已重试 ' + (total - 1).toString() + ' 次）';
    this.retryNote = '';
    this.loading = false;
  }

  /** setTimeout 的 Promise 包装：组间/组内等待都用它，避免回调套回调 */
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.pm !== null) {
        if (this.fitBox) {
          Image(this.pm as image.PixelMap)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        } else {
          Image(this.pm as image.PixelMap)
            .width('100%')
            .aspectRatio(this.ratio)
            .objectFit(ImageFit.Contain)
        }
      } else {
        Column({ space: 8 }) {
          if (this.loading) {
            LoadingProgress().width(26).height(26).color('#6C727C')
            Text(this.retryNote.length > 0
              ? '第 ' + (this.index + 1).toString() + ' 页 · ' + this.retryNote
              : '第 ' + (this.index + 1).toString() + ' 页')
              .fontSize(11)
              .fontColor('#6C727C')
          } else {
            Text(this.err.length > 0 ? this.err : '加载失败')
              .fontSize(12)
              .fontColor('#9AA0AA')
              .textAlign(TextAlign.Center)
              .padding({ left: 24, right: 24 })

            // 重试按钮做成 44 高的胶囊：原来只有 12 号字那么大一块，
            // 手指按下去要瞄准 —— 触控目标最小 44×44 是这类场景的通行值。
            Text('点击重试')
              .fontSize(14)
              .fontColor('#FFFFFF')
              .height(44)
              .padding({ left: 28, right: 28 })
              .borderRadius(22)
              .backgroundColor('#2A313A')
              .border({ width: 0.7, color: '#3A424C' })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                // 手动重试前先删掉磁盘上这份字节：上一次失败有可能是它本身损坏，
                // 不清掉就会反复拿到同一份坏数据（JHenTai 的重试也是先删缓存再重解析）。
                ImageDiskCache.remove(this.url);
                this.load();
              })
          }
        }
        .width('100%')
        .aspectRatio(0.7)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(READER_BG)
      }
    }
    .width('100%')
    /**
     * 显隐工具栏的手势。
     *
     * 不用 `onClick`：onClick 的语义是「一次点按立即触发」，做不出「单击无响应」；
     * `TapGesture({ count: 2 })` 由 ArkUI 自己判断连击 —— 只点一下时它会等到双击时窗
     * 结束才判失败，**不会先闪一下工具栏**，正好就是要的行为。
     *
     * 为什么不自己用定时器判双击：定时器方案必须在单击后延迟 N ms 才切换，
     * count=1 时平白多出一段延迟；而且两套判定会跟系统的双击时窗打架。
     *
     * 与翻页/滚动的共存：TapGesture 只识别「按下-抬起且几乎不位移」，
     * 与 Swiper 的横滑、List 的纵滑是不同recognizer，不会互相吞掉（这里也不改用
     * parallelGesture —— tap 本身不与 pan 竞争，parallel 反而会降低命中优先级）。
     */
    .gesture(TapGesture({ count: this.tapCount })
      .onAction(() => this.onTap()))
  }
}

/**
 * 设置面板里的一行「标题 + 分段选择」。
 *
 * 单独做成组件而不是写成 @Builder：一行里要循环出 2~4 个可选项，用组件才能把
 * 「选中态用 @Prop 回灌、回调用普通成员」这套本工程的既有写法完整照搬过来。
 */
@Component
struct ReaderSegRow {
  label: string = '';
  options: string[] = [];
  /** 当前选中下标；必须是 @Prop，否则在面板里切模式时高亮不会跟着动 */
  @Prop selected: number = 0;
  onPick: (index: number) => void = (index: number): void => {};

  build() {
    Row() {
      Text(this.label)
        .fontSize(13)
        .fontColor(Theme.text())
        .maxLines(1)
      Blank()
      Row({ space: 4 }) {
        ForEach(this.options, (item: string, i: number) => {
          Text(item)
            .fontSize(12)
            .fontColor(this.selected === i ? '#FFFFFF' : Theme.subText())
            .textAlign(TextAlign.Center)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(13)
            // 选中态用 accent 实底 + 白字：面板里没有玻璃，纯描边在小尺寸上读不出「选中」
            .backgroundColor(this.selected === i ? Theme.accent() : '#00000000')
            .onClick(() => {
              if (this.selected !== i) {
                this.onPick(i);
              }
            })
        }, (item: string, i: number) => 'seg-' + i.toString())
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(SETTING_ROW_H)
    .alignItems(VerticalAlign.Center)
  }
}

/** 设置面板里的一行「标题 + 开关」 */
@Component
struct ReaderToggleRow {
  label: string = '';
  @Prop checked: boolean = false;
  onChange: (value: boolean) => void = (value: boolean): void => {};

  build() {
    Row() {
      Text(this.label)
        .fontSize(13)
        .fontColor(Theme.text())
        .maxLines(1)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: this.checked })
        .selectedColor(Theme.accent())
        .onChange((on: boolean) => {
          // 父层回灌 checked 时也会触发一次回调，值相同就吞掉，不然会来回打架
          if (on !== this.checked) {
            this.onChange(on);
          }
        })
    }
    .width('100%')
    .height(SETTING_ROW_H)
    .alignItems(VerticalAlign.Center)
  }
}

/**
 * 阅读器。
 *
 * 三种阅读形态（对应设置面板里的「阅读模式 / 页面布局」两项）：
 *   0 连续滚动（条漫）
 *   1 横向翻页 · 单页
 *   2 横向翻页 · 双页
 *
 * 页面列表**边读边补**：详情页只给前 20 个缩略图链接，其余按 `?p=20/40…` 追加，
 * 所以上千页的画廊也能立刻开始读。离线阅读时直接读下载目录，不联网。
 *
 * 界面分三层：内容层（条漫列表 / 翻页 Swiper）、浮在内容上的两条玻璃胶囊、从底部弹出的设置面板。
 * 中间那一大片刻意留空，点击落到图片上就是「显隐工具栏」。
 */
@Component
export struct ReaderPage {
  gallery: Gallery = new Gallery();
  detail: GalleryDetail = new GalleryDetail();
  /** 非空表示离线阅读：这些是本地 jpg 的绝对路径 */
  localPages: string[] = [];
  /** 从第几页开始（0 基）；详情页缩略图点击时传入 */
  @Prop startPage: number = 0;
  onBack: () => void = (): void => {};

  @State private urls: string[] = [];
  @State private current: number = 0;
  @State private chrome: boolean = true;
  @State private collecting: boolean = false;
  @State private jump: number = 1;
  @State private totalEstimate: number = 0;
  @State private mode: number = 0;
  @State private pairStarts: number[] = [];
  @State private offline: boolean = false;
  /** 按 Prefs `read_dir` 解析：true = 日漫/港台版式，从右往左翻 */
  @State private rtl: boolean = false;
  /** 按 Prefs `tap_zone` 解析：true = 左右 1/3 点击翻页，中间 1/3 显隐控件 */
  @State private tapPaging: boolean = false;

  /** 屏幕方向 system / portrait / landscape。Prefs `read_orientation`，默认 system */
  @State private orientation: string = 'system';
  /** 双页模式首图单独占一屏。Prefs `read_first_alone`，默认 true */
  @State private firstAlone: boolean = true;
  /**
   * 条漫单页最大宽度（vp）。
   *
   * 已经**不是**用户项：设置面板里的「条漫宽度」滑条已删除，`read_strip_width` 键也不再读写。
   * 仍然保留这个字段，是因为 stripCap() 还要按它把长条图在平板/折叠屏上收窄居中 ——
   * 直接写常量会让「取宽」这件事散落在 build 里，留一个字段便于以后统一口径。
   */
  private stripWidth: number = READER_SINGLE_PAGE_MAX_WIDTH;
  /**
   * 条漫相邻两页之间的留缝（vp）。Prefs `read_page_gap`，默认 0（无缝，与旧版一致）。
   *
   * 必须是 @State：条漫 List 里每一项的 margin 直接读它，拖滑条时才能立刻生效。
   */
  @State private pageGap: number = 0;
  /**
   * 显隐工具栏的点按方式：'single' 单击 / 'double' 双击。Prefs `read_toolbar_tap`。
   *
   * 必须是 @State：切换后本页所有 ReaderImage 的 TapGesture count 要立刻跟着变，
   * 否则得退出重进阅读器才生效（需求要求「切换后立即生效」）。
   */
  @State private tapMode: string = 'single';

  /** 设置面板是否展开（展开时盖一层遮罩，点遮罩关闭） */
  @State private settingsOpen: boolean = false;
  /**
   * 「正在关闭」：退场动画播放期间为 true。
   *
   * 上一版把面板改成**常驻挂载**来拿退场动画，结果整页都点不动 —— 常驻的全屏遮罩即使
   * hitTest 设为 None，仍然会在某些路径上吞掉触摸（尤其手势/滚动的命中链）。
   * 现在回到「if 增删」，用这个标记在关闭时先播 220ms 再真正移除：
   * 动画有了、节点也不会留在树上挡点击。
   */
  @State private sheetClosing: boolean = false;
  private sheetCloseTimer: number = -1;
  /**
   * 设置面板被手指**往下**拖的距离（vp）。
   *
   * 只做「跟手 + 松手复位」两件事：拖动时面板跟着走、遮罩同步变淡；
   * 松手后要么回弹到 0，要么直接关闭。用 offset 而不是 translate，
   * 是为了不干扰入场动画那个 translate(y:100%)。
   *
   * 只往正方向取值：面板贴底挂，向上位移会在下沿留缝、露出底下的页面。
   */
  @State private sheetDy: number = 0;
  /**
   * 本次拖动中手指的**原始**纵向位移（vp，向上为负）。
   *
   * 面板本身只跟「向下」走（sheetDy 恒 >= 0），所以「上滑展开全屏」这个判断
   * 只能靠手指位移本身，不能读 sheetDy。普通字段即可：它不进 build。
   */
  private lastPanDy: number = 0;
  /**
   * 面板是否被「往上滑」展开成全屏。
   *
   * 45% 高度适合调设置，但用户常想边看画面边调，全屏更方便对比。
   * 交互：按住顶部抓手往上滑超过 60 → 全屏；往下滑超过 60 → 回 45%；再往下 80 → 关闭。
   */
  @State private sheetFull: boolean = false;
  /** 设置面板当前 tab：0 阅读 / 1 显示 */
  @State private settingsTab: number = 0;
  /** 底栏页码是否已经切成滑条（点页码进入，闲置 2s 自动退回） */
  @State private pageControl: boolean = false;

  /**
   * 上一次用的「翻页」布局（1 单页 / 2 双页）。
   * 切到条漫再切回来时用它恢复，而不是一律退回单页 —— 双页是平板用户主动选的，不该被清掉。
   */
  private lastPaged: number = 1;

  /** 每页宽高比（未知为 0）：只做分组判断用，不进 @State，免得每加载一页就整页重建 */
  private ratios: number[] = [];

  private scroller: Scroller = new Scroller();
  private swiper: SwiperController = new SwiperController();
  /** 底部缩略图条的滚动控制器（自动跟随当前页） */
  private stripScroller: Scroller = new Scroller();
  /** 底部条的缩略图（两条路共用：裁剪出来的 / 逐页真图） */
  private stripPms: Map<number, image.PixelMap> = new Map<number, image.PixelMap>();
  /**
   * 裁剪路线失败过的页。
   *
   * 裁不出来（sheet 403 / 容器坏 / 该格越界）就换路走逐页真图，重裁大概率同一个结果。
   * 与详情页同口径，见 DetailPage.cropFailed 的说明。
   */
  private stripCropFailed: Set<number> = new Set<number>();
  /**
   * 底部条的两段式调度器（HTML 3 / 图片 6 / 离当前页最近优先）。
   *
   * 优先级每次取任务都现算，所以翻到第 200 页之后补的是眼前那几格，
   * 而不是排队最久的第 1 页（原来按入队顺序补，就是「翻远了横条上还是空的」）。
   */
  private stripPipe: ThumbPipeline | null = null;
  /** 已受理但还没出结果的页号 → 受理时刻（去重 + 超时判定） */
  private stripStarts: Map<number, number> = new Map<number, number>();
  /** 每页连续失败次数：第一次失败重来一趟，第二次就记死 */
  private stripFails: Map<number, number> = new Map<number, number>();
  /**
   * 已经解好的页号。
   *
   * 为什么不用 stripPms 直接判断：Map 不是可观察对象，往里 set 不会触发 build。
   * 所以另开一个 @State 数组记「哪些页已经有图了」，由 build 读取它来触发重绘；
   * 真正的 PixelMap 仍放在 stripPms 里（不进 @State，避免状态代理包一层原生对象）。
   */
  @State private stripLoaded: number[] = [];
  /** 加载次数用尽的页：每页最多 2 次，失败两次就不再打（避免滚动时无限重试） */
  private stripDead: Set<number> = new Set<number>();
  /**
   * 被缓存策略摘下来的 PixelMap，暂不释放。
   *
   * 为什么不能立即 release：大幅跳页时被淘汰的那张可能**还在屏幕上**，
   * 释放后组件拿到的是已回收的句柄 —— 表现就是黑格。先挂到这里，
   * 组件重建/滚出屏幕后再统一释放。
   */
  private retired: image.PixelMap[] = [];
  /** 加载完一张就 +1，触发列表重绘（Map 本身不是可观察的） */
  @State private stripVer: number = 0;
  /** 起始页是否已经落位；false 期间滚动回调不能改写 current */
  private startApplied: boolean = false;

  /** 缓存的窗口：方向锁定作用在它上面，销毁时用它还原 */
  private win: window.Window | null = null;
  /**
   * 组件是否还活着。
   * `getLastWindow()` 是异步的：如果窗口回调晚于 aboutToDisappear 到达，
   * 再去 setPreferredOrientation 就会把设置作用到「已经离开的页面」上，
   * 或者把还原动作覆盖掉 —— 所以回调里必须先看这个标记。
   */
  private alive: boolean = true;
  /** 正在预取的页（按 url 去重），避免同一页被连续两次翻页各触发一次 */
  private inflight: Set<string> = new Set<string>();
  /** 页码滑条自动回退的定时器句柄；-1 表示没在计时 */
  private pageTimer: number = -1;

  aboutToAppear(): void {
    this.rtl = Prefs.str('read_dir', 'ltr') === 'rtl';
    this.tapPaging = Prefs.str('tap_zone', 'off') === 'paging';
    // read_mode 只存三个值（scroll / single / double）而不是「模式 + 布局」两个键：
    // 条漫、单页、双页本来就是三选一，一个键写完不会留下「模式是条漫、布局还记着双页」
    // 这种自相矛盾的组合，读回来也不用做一致性校验。
    const rawMode: string = Prefs.str('read_mode', 'scroll');
    if (rawMode === 'single') {
      this.mode = 1;
      this.lastPaged = 1;
    } else if (rawMode === 'double') {
      this.mode = 2;
      this.lastPaged = 2;
    } else {
      this.mode = 0;
    }
    // read_first_alone 默认 true —— 首页通常是封面式跨页大图，和下一页硬拼会被压扁。
    this.firstAlone = Prefs.bool('read_first_alone', true);
    // 条漫宽度：**不再读 read_strip_width**（设置面板那一栏已删掉，用户值不再生效）。
    // 固定用常量，保证老用户存过的 640/900 不会让长条图突然变窄/变宽。
    this.stripWidth = READER_SINGLE_PAGE_MAX_WIDTH;
    // read_page_gap 默认 0：老用户升级后条漫观感不变；夹到 0~24 防止旧库里存过大值。
    const gap: number = Prefs.num('read_page_gap', 0);
    this.pageGap = gap > 0 ? (gap > 24 ? 24 : gap) : 0;
    // read_orientation 默认 'system' —— 不干预系统的旋转锁定，避免一进阅读器就强制横屏。
    this.orientation = Prefs.str('read_orientation', 'system');
    // read_toolbar_tap 默认 'single'：老用户升级后手感不变，单击仍然切换工具栏。
    this.tapMode = Prefs.str('read_toolbar_tap', 'single') === 'double' ? 'double' : 'single';

    if (this.localPages.length > 0) {
      const local: string[] = [];
      for (let i = 0; i < this.localPages.length; i++) {
        local.push(this.localPages[i]);
      }
      this.urls = local;
      this.offline = true;
      this.totalEstimate = local.length;
    } else {
      const first: string[] = [];
      for (let i = 0; i < this.detail.pageUrls.length; i++) {
        first.push(this.detail.pageUrls[i]);
      }
      this.urls = first;
      this.totalEstimate = this.detail.gallery.pages > 0 ? this.detail.gallery.pages : first.length;
      this.collect(first.length);
    }
    // 前 20 页的裁切矩形随 detail 一起带进来了，这里不用做任何预处理：
    // 底部条 onAppear 时由 ensureStripThumb 分流（有 tile → ThumbCropper 裁像素）。
    this.pairStarts = this.pairsFor(this.urls.length);
    const begin: number = Math.max(0, this.startPage);
    this.current = begin;
    this.jump = begin + 1;
    if (begin <= 0) {
      this.startApplied = true;
    } else {
      this.tryApplyStart();
    }
    // 方向锁定是「进来才生效、出去必须还原」的资源，不放在 build 里：
    // build 每次重绘都会跑，会反复向系统下发 setPreferredOrientation。
    this.applyOrientationWindow();
    // 底部条的初始偏移永远在左端，而起始页可能在中间（从详情页点第 200 格进来的），
    // 所以先让条子居中到 current 一次。等首帧挂载完再滚，太早会被忽略。
    setTimeout(() => {
      this.followStrip();
    }, 0);
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.stopPageTimer();
    // 磁盘缓存不清：那是「下次进来不用重新下」的本钱，由容量策略自己管
    this.inflight.clear();
    // 底部条按需解出来的小图要释放（它们不归任何组件所有）
    this.stripPms.forEach((pm: image.PixelMap) => {
      try {
        pm.release();
      } catch (e) {
      }
    });
    this.stripPms.clear();
    // 被淘汰但还没到延迟释放时间的那些：页面已经销毁，可以立刻还回去
    for (let i = 0; i < this.retired.length; i++) {
      try {
        this.retired[i].release();
      } catch (e) {
      }
    }
    this.retired = [];
    // 等闸门的队列也清掉：页面都销毁了，谁排着都没意义（在途结果由管道丢弃并释放）
    this.stripStarts.clear();
    this.stripFails.clear();
    this.stripCropFailed.clear();
    const p: ThumbPipeline | null = this.stripPipe;
    if (p !== null) {
      p.stop();
      this.stripPipe = null;
    }
    const memo: window.Window | null = this.win;
    this.win = null;
    if (memo === null) {
      // 从没拿到窗口，也就从没改过方向，不需要还原
      return;
    }
    try {
      memo.setPreferredOrientation(window.Orientation.UNSPECIFIED);
    } catch (e) {
      console.warn('[ReaderPage] restore orientation failed');
    }
  }

  /**
   * 把方向锁下发给当前窗口。
   *
   * 拿到过的窗口缓存到 this.win，销毁时复用同一引用还原；没拿到就再取一次
   * （不是并发保护问题，而是用户可能刚进页面就去切方向）。
   */
  private applyOrientationWindow(): void {
    const memo: window.Window | null = this.win;
    if (memo !== null) {
      this.applyOrientationTo(memo);
      return;
    }
    window.getLastWindow(getContext(this)).then((w: window.Window) => {
      if (!this.alive) {
        // 页面已经销毁：绝不能再往这个窗口上下发设置，否则会把 aboutToDisappear 的还原覆盖掉
        return;
      }
      this.win = w;
      this.applyOrientationTo(w);
    }).catch((e: Error) => {
      console.warn('[ReaderPage] getLastWindow failed: ' + e.message);
    });
  }

  private applyOrientationTo(w: window.Window): void {
    try {
      if (this.orientation === 'portrait') {
        w.setPreferredOrientation(window.Orientation.PORTRAIT);
      } else if (this.orientation === 'landscape') {
        w.setPreferredOrientation(window.Orientation.LANDSCAPE);
      } else {
        w.setPreferredOrientation(window.Orientation.UNSPECIFIED);
      }
    } catch (e) {
      console.warn('[ReaderPage] setPreferredOrientation failed');
    }
  }

  // ------------------------------------------------------------ 设置项

  /**
   * 切换阅读形态。
   *
   * 三个形态共用同一份 urls，所以切的时候要把「当前看到第几页」换算到新形态的位置上：
   * 条漫用绝对页号直接定位，翻页用 Swiper 的槽位（双页一屏两页，还要按首图规则对齐）。
   * 翻页这边**只改 current**：`.index(this.slotOfPage(this.current))` 是声明式属性，
   * 重绘后 Swiper 自己落到新槽位（switchMode 会把 Swiper 整个换掉，创建时就带对 index）。
   */
  private switchMode(next: number): void {
    if (next === this.mode) {
      return;
    }
    const page: number = this.current;
    this.mode = next;
    if (next !== 0) {
      this.lastPaged = next;
    }
    // 双页要落到目标页所在那一屏的左页，否则会停在「下一页的开头」，看起来像跳过去了
    this.current = next === 2 ? this.pairStartOf(page) : page;
    this.jump = this.current + 1;
    Prefs.put('read_mode', next === 0 ? 'scroll' : (next === 2 ? 'double' : 'single'));
    if (next === 0) {
      setTimeout(() => {
        this.scroller.scrollToIndex(this.current, false, ScrollAlign.START);
      }, 0);
    }
  }

  /** 阅读模式分段：true = 条漫，false = 翻页（翻页沿用上次的单页/双页） */
  private setReadingMode(strip: boolean): void {
    this.switchMode(strip ? 0 : this.lastPaged);
  }

  /** 页面布局分段：0 单页 / 1 双页 */
  private setLayout(index: number): void {
    this.switchMode(index === 1 ? 2 : 1);
  }

  /**
   * 翻页方向（参考 JHenTai 的 `cached_page_view.dart`：`PagedPageView.builder(reverse: ...)`）。
   *
   * JHenTai 的模型只有一句话：**索引永远是「第几页」，不镜像；只让滚动容器反向。**
   * `pageIndex == page 号`，RTL 只是 `reverse: true` 把滚动轴翻过来，所有页码数学
   * （跳页、进度、缩略图）仍然用页号。
   *
   * ArkUI 的 Swiper 没有 `reverse`，所以「反向」只能模拟，而**模拟只允许存在于一处**：
   * slotOfPage / pageOfSlot。换向时因此只需要：
   *   1. 写 rtl；
   *   2. 写 Prefs；
   *   3. current 原样保留（页号不变）。
   * 因为 `.index(this.slotOfPage(this.current))` 是声明式属性，重绘后 Swiper 会自己落到
   * 新的槽位 n-1-current —— **绝不能再补一次 changeIndex**：那会和声明式 index 抢同一个
   * 属性，上一版就是 `changeIndex(mirror(slot))` + `.index()` 打架，最终停在末页。
   */
  private setRtl(rtl: boolean): void {
    if (rtl === this.rtl) {
      return;
    }
    const page: number = this.current;
    this.rtl = rtl;
    Prefs.put('read_dir', rtl ? 'rtl' : 'ltr');
    // 页号不变：这是「切完还在第 10 页」的唯一依据
    this.current = page;
    // 条子与方向无关（位置 = 页号），本来不需要重排；这里补一次居中是因为
    // Swiper 换向重绘后不一定回调 onDidChange，而条子该停在 current 上。
    setTimeout(() => {
      this.followStrip();
    }, 0);
  }

  /** 双页模式的「首图单独」：改完必须重算分组，`.index()` 会按新分组重新求值 */
  private setFirstAlone(on: boolean): void {
    if (on === this.firstAlone) {
      return;
    }
    this.firstAlone = on;
    Prefs.put('read_first_alone', on);
    this.pairStarts = this.pairsFor(this.urls.length);
  }

  private orientationIndex(): number {
    if (this.orientation === 'portrait') {
      return 1;
    }
    return this.orientation === 'landscape' ? 2 : 0;
  }

  private setOrientation(index: number): void {
    const v: string = index === 1 ? 'portrait' : (index === 2 ? 'landscape' : 'system');
    if (v === this.orientation) {
      return;
    }
    this.orientation = v;
    Prefs.put('read_orientation', v);
    this.applyOrientationWindow();
  }

  // ------------------------------------------------------------ 底栏页码 / 滑条

  /**
   * 点页码进入滑条。
   *
   * 只有一页时不进入：滑条没有可拖的区间，切过去只会看到一条拖不动的轨道。
   */
  private openPageControl(): void {
    if (this.urls.length <= 1) {
      return;
    }
    this.jump = this.current + 1;
    this.pageControl = true;
    this.keepPageControl();
  }

  /** 每次操作都重置 2s 计时：滑条要「停止操作」才回退，不是「打开后 2s」 */
  private keepPageControl(): void {
    this.stopPageTimer();
    this.pageTimer = setTimeout(() => {
      this.pageTimer = -1;
      this.pageControl = false;
    }, PAGE_CONTROL_IDLE_MS);
  }

  private stopPageTimer(): void {
    if (this.pageTimer >= 0) {
      clearTimeout(this.pageTimer);
      this.pageTimer = -1;
    }
  }

  private onJumpChange(v: number, m: SliderChangeMode): void {
    this.jump = v;
    this.keepPageControl();
    // Click 是「点在轨道上直接跳」，也必须落位，否则松手后页码显示的和画面对不上。
    // 滑条是 1 基（1..n），jumpTo 收的是 0 基页号，所以这里减 1。
    if (m === SliderChangeMode.End || m === SliderChangeMode.Click) {
      this.jumpTo(v - 1);
    }
  }

  // ------------------------------------------------------------ 起始页 / 分组 / 分页换算

  /**
   * 落到起始页。
   *
   * 缩略图网格点的是「第 N 页」，但详情页首屏只有前 20 条链接，
   * 点子靠后的格子时 urls 还不够长 —— 这时先不跳，等 collect() 补到再重试
   * （见 appendUrls）。滚动放到 setTimeout 里是因为首帧 List 还没完成布局，
   * 立刻 scrollToIndex 会被直接忽略。
   */
  private tryApplyStart(): void {
    if (this.startApplied) {
      return;
    }
    const target: number = Math.max(0, this.startPage);
    if (this.urls.length === 0 || target >= this.urls.length) {
      return;
    }
    let idx: number = target;
    if (this.mode === 2) {
      // 双栏要落到该页所在的那一屏的左页（横幅页自己一屏，所以不能简单取偶数对齐）
      idx = this.pairStarts.length > 0 ? this.pairStartOf(target) : target;
    }
    this.current = idx;
    this.jump = idx + 1;
    this.startApplied = true;
    if (this.mode === 0) {
      // 条漫是 List，没有「声明式首索引」这种东西，只能显式滚；等首帧布局完再滚
      setTimeout(() => {
        this.scroller.scrollToIndex(idx, false, ScrollAlign.START);
      }, 0);
    }
  }

  /** 目标页始终拿不到（图被删/请求失败）时放开守卫，回到从头读的正常状态 */
  private releaseStartGuard(): void {
    if (this.startApplied) {
      return;
    }
    this.startApplied = true;
    this.current = 0;
    this.jump = 1;
  }

  /**
   * 双栏分组。
   *
   * 横幅页（宽 > 高 * 1.2）在双栏里并排只会被压成一条缝，所以让它独占一屏。
   * 比例未知（还没解码，ratio 为 0）时一律当竖图处理，避免刚开始读就跳动。
   * 在此基础上叠加「首图单独成组」：第 0 页永远单独一屏，之后才两页一组。
   *
   * 单页/拼页的判定收敛到 `isSingleSpread()`：分组（这里）和渲染必须用
   * 同一个谓词，否则会出现「分组里这一屏只有一页、渲染时却拼了下一页」的错位。
   */
  private pairsFor(count: number): number[] {
    const out: number[] = [];
    let i: number = 0;
    while (i < count) {
      out.push(i);
      i += this.isSingleSpread(i, count) ? 1 : 2;
    }
    return out;
  }

  /**
   * 从第 i 页开始的一组是不是「单独一页」。
   *
   * 三种情况：
   *  - 本页是横幅（原规则）；
   *  - 下一页是横幅（这一屏仍会把横幅页硬拼进来、而且下一页还会再显示一次 —— 一并修掉）；
   *  - 首图单独，且就是第 0 页。
   */
  private isSingleSpread(i: number, count: number): boolean {
    if (this.isWide(i)) {
      return true;
    }
    if (i + 1 < count && this.isWide(i + 1)) {
      return true;
    }
    return this.firstAlone && i === 0;
  }

  private isWide(i: number): boolean {
    if (i < 0 || i >= this.ratios.length) {
      return false;
    }
    const r: number = this.ratios[i];
    return r > WIDE_RATIO;
  }

  /** 第 page 页落在双栏的哪一屏（pairStarts 的下标） */
  private pairSlotOf(page: number): number {
    const starts: number[] = this.pairStarts;
    for (let k = starts.length - 1; k >= 0; k--) {
      if (starts[k] <= page) {
        return k;
      }
    }
    return 0;
  }

  /** 第 page 页所在那一屏的起始页（绝对页号） */
  private pairStartOf(page: number): number {
    if (this.pairStarts.length === 0) {
      return page;
    }
    return this.pairStarts[this.pairSlotOf(page)];
  }

  /** 当前模式下 Swiper 的一屏到底显示几页：双栏一屏 = 一组 */
  private slotCount(): number {
    return this.mode === 2 ? this.pairStarts.length : this.urls.length;
  }

  /**
   * Swiper 子项的**槽位序页号**：第 s 个槽位该画哪一页。
   *
   * 这是「镜像 index」能成立的另一半，也是上一版落到末页的真正原因：
   * Swiper 的 index 是**槽位下标**，不是页号。只把 index 镜像成 n-1-page、
   * 子项却仍按页号顺序排，index=90 的槽里躺的就是第 91 页 —— 换向当然「跳到别的页」。
   * 正确的模拟（等价于 JHenTai 的 `reverse: true`，`cached_page_view.dart`）必须
   * **子项一起倒序**：槽位 0 画最后一页，第 1 页因此落在最右；往右滑（槽位减小）= 下一页。
   */
  private slotPages(): number[] {
    const out: number[] = [];
    const n: number = this.slotCount();
    for (let s = 0; s < n; s++) {
      out.push(this.pageOfSlot(s));
    }
    return out;
  }

  /**
   * 本模式下的「有效方向」。
   *
   * 条漫是竖向 List，整条长图从上往下读，**没有左右之分** —— 任何镜像都只会让
   * 「点击左侧翻到下一页」这类判断莫名其妙地反掉。所以条漫（mode 0）一律按 LTR 处理，
   * 只有翻页模式才认用户在设置里选的方向。
   *
   * 为什么要有这一层而不是到处写 `this.mode === 0 ? false : this.rtl`：
   * flip / slotOfPage / pageOfSlot / tapThird 四处必须用**同一个**方向，
   * 任何一处漏改就是「画面顺序对、点击方向反」这种极难查的错位。
   */
  private effRtl(): boolean {
    return this.mode === 0 ? false : this.rtl;
  }

  /**
   * 唯一的镜像公式：阅读序位置 → 显示位置。有效方向为 rtl 时整段倒序，否则恒等。
   *
   * 对应 JHenTai 的 `reverse: true`（`cached_page_view.dart`）。判据是 effRtl() 而不是 rtl：
   * 条漫根本不参与镜像（见 effRtl），条子的页序已经是左→右，这里只服务于翻页模式。
   * 全文件只允许存在这一处 `n - 1 - i`：Swiper 槽位和底部缩略图条都从它派生，
   * 各写一套的话，两处一旦不一致就是「画面在左、条子跳右」。
   */
  private flip(i: number, n: number): number {
    if (n <= 0) {
      return 0;
    }
    return this.effRtl() ? n - 1 - i : i;
  }

  /**
   * 页号 → Swiper 槽位（声明式 `.index()` 唯一的数据源）。
   *
   * 单页模式：槽位就是页号，所以这就是 `effRtl ? n-1-page : page`。
   * 双页模式：Swiper 的一「槽」是一屏两页，槽位是分组下标 —— 页号先经 pairSlotOf
   * 落到分组，再按**分组数**整段倒序（用页数会越界，Swiper 会被夹到最后一屏）。
   *
   * 条漫不调用它（没有 Swiper），但公式里读的是 effRtl()，所以即使在条漫下被误调用，
   * 也只会拿到恒等值，不会突然把页序翻过来。
   */
  private slotOfPage(page: number): number {
    const ord: number = this.mode === 2 ? this.pairSlotOf(page) : page;
    return this.flip(ord, this.slotCount());
  }

  /** Swiper 槽位 → 页号（与 slotOfPage 互逆；双页模式回的是该屏的起始页） */
  private pageOfSlot(slot: number): number {
    const n: number = this.slotCount();
    const ord: number = this.flip(slot, n);
    if (n <= 0) {
      return 0;
    }
    if (this.mode === 2) {
      return ord >= 0 && ord < this.pairStarts.length ? this.pairStarts[ord] : 0;
    }
    return ord >= 0 && ord < this.urls.length ? ord : 0;
  }

  private samePairs(a: number[], b: number[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }

  /** 子图解码完把比例交上来；只有「分组真的变了」才动 pairStarts，避免读到一半乱跳 */
  private onRatio(index: number, ratio: number): void {
    if (index < 0 || ratio <= 0) {
      return;
    }
    const next: number[] = this.ratios.slice();
    while (next.length <= index) {
      next.push(0);
    }
    if (next[index] === ratio) {
      return;
    }
    next[index] = ratio;
    this.ratios = next;
    const pairs: number[] = this.pairsFor(this.urls.length);
    if (this.samePairs(pairs, this.pairStarts)) {
      return;
    }
    this.pairStarts = pairs;
  }

  private appendUrls(more: string[]): void {
    const merged: string[] = this.urls.slice();
    for (let i = 0; i < more.length; i++) {
      merged.push(more[i]);
    }
    this.urls = merged;
    this.pairStarts = this.pairsFor(merged.length);
    // 起始页可能正落在刚补到的这一段里
    this.tryApplyStart();
  }

  /** 后台把剩余缩略图页的链接补齐 */
  async collect(started: number): Promise<void> {
    const totalPages: number = this.detail.thumbPageCount;
    if (totalPages <= 1) {
      // 只有一屏：目标页若在这 20 条里就能跳，跳不了才算彻底没戏
      this.tryApplyStart();
      this.releaseStartGuard();
      return;
    }
    this.collecting = true;
    let got: number = started;
    for (let p = 1; p < totalPages; p++) {
      try {
        // p 是页索引（不是图片偏移）：乘 20 会跳过大量页面，读到的页序就乱了
        const more: string[] = await EhApi.loadThumbPageUrls(this.gallery.url, p);
        if (more.length === 0) {
          break;
        }
        got += more.length;
        this.appendUrls(more);
        this.totalEstimate = Math.max(this.totalEstimate, this.urls.length);
      } catch (e) {
        break;
      }
    }
    this.collecting = false;
    this.tryApplyStart();
    this.releaseStartGuard();
  }

  /**
   * 跳到第 page 页（**0 基页号**，与 current / urls 下标同口径）。
   *
   * 页号是唯一的跳转口径：rtl 下的镜像只发生在 `.index()` 的求值里（slotOfPage），
   * 这里不参与任何方向运算 —— 与 JHenTai「pageIndex 永远是页号」一致。
   */
  jumpTo(page: number): void {
    // 用户显式跳页，起始页的守卫就作废了
    this.startApplied = true;
    let idx: number = Math.max(0, Math.min(this.urls.length - 1, page));
    if (this.mode === 2) {
      idx = this.pairStartOf(idx);
    }
    this.current = idx;
    this.jump = idx + 1;
    if (this.mode === 0) {
      this.scroller.scrollToIndex(idx, true, ScrollAlign.START);
    }
  }

  /**
   * 是不是已经在第一页。
   *
   * 全部按**页号**（双页按分组下标）判断，不看 slotOfPage：后者在 rtl 下是镜像值，
   * 拿它判两端会把「上一页 / 下一页」的禁用整体反过来。
   */
  private atFirst(): boolean {
    if (this.urls.length === 0) {
      return true;
    }
    if (this.mode === 2) {
      return this.pairSlotOf(this.current) <= 0;
    }
    return this.current <= 0;
  }

  /** 是不是已经在最后一页（双页是最后一屏），口径同 atFirst */
  private atLast(): boolean {
    if (this.urls.length === 0) {
      return true;
    }
    if (this.mode === 2) {
      return this.pairStarts.length === 0 ||
        this.pairSlotOf(this.current) >= this.pairStarts.length - 1;
    }
    return this.current >= this.urls.length - 1;
  }

  /**
   * 上一页 / 下一页。
   *
   * 条漫没有「页」的概念但有滚动位置，所以走 scrollToIndex 滚一整屏；
   * 翻页直接复用 turn()：它按页号前后走一屏，方向交给 Swiper 自己处理。
   */
  private stepPage(delta: number): void {
    if (delta < 0 && this.atFirst()) {
      return;
    }
    if (delta > 0 && this.atLast()) {
      return;
    }
    if (this.mode === 0) {
      this.scroller.scrollToIndex(this.current + delta, true, ScrollAlign.START);
      return;
    }
    this.turn(delta > 0);
  }

  /**
   * 前后翻一屏（点击分区 / 底栏按钮共用）。
   *
   * forward 是**阅读顺序**上的前后，不是槽位增量：页号直接 +1 / -1，再交给声明式
   * `.index(slotOfPage(current))` 换算成槽位。rtl 下「下一页」的槽位比当前小，
   * 这个换算由 slotOfPage 一处完成 —— 这里再加一次取反就会二次镜像、翻回原页。
   */
  private turn(forward: boolean): void {
    if (this.mode === 0 || this.urls.length === 0) {
      return;
    }
    const step: number = forward ? 1 : -1;
    const ord: number = this.mode === 2 ? this.pairSlotOf(this.current) : this.current;
    const to: number = ord + step;
    if (to < 0 || to >= this.slotCount()) {
      return;
    }
    this.current = this.mode === 2 ? this.pairStarts[to] : to;
    this.jump = this.current + 1;
    this.followStrip();
  }

  /**
   * 左/中/右三块，各占整宽 1/3。
   *
   * 方向只在这里换一次：左边那块在 rtl 下是「下一页」。判据用 effRtl() 而不是 rtl ——
   * 条漫的左右没有语义（上下才代表前后），点击分区因此按 LTR 处理，和翻页模式的 LTR 一致。
   */
  private tapThird(isLeft: boolean): void {
    const forward: boolean = isLeft === this.effRtl();
    this.turn(forward);
  }

  /**
   * 顶栏/底栏共用的页号文案。
   *
   * 双页一屏可能是 2 页（也可能是 1 页横幅 + 1 页竖图），所以这里给的是「这一屏的页范围」；
   * 索引还在补齐时用 ~ 标出总数是估算值（补页会继续往里追加链接）。
   */
  private pageLabel(): string {
    let total: string = this.urls.length.toString();
    if (this.collecting && this.totalEstimate > this.urls.length) {
      total = '~' + this.totalEstimate.toString();
    }
    if (this.mode === 2 && this.pairStarts.length > 0) {
      const slot: number = this.pairSlotOf(this.current);
      const start: number = this.pairStarts[slot];
      const limit: number = slot + 1 < this.pairStarts.length ? this.pairStarts[slot + 1] : this.urls.length;
      const end: number = Math.min(this.urls.length, limit);
      return '第 ' + (start + 1).toString() + '-' + end.toString() + ' / ' + total + ' 页';
    }
    return '第 ' + (this.current + 1).toString() + ' / ' + total + ' 页';
  }

  /**
   * 条漫的单页宽度上限。
   *
   * 为什么返回 '100%' 而不是 undefined：ArkTS 的 Length 不接受 undefined，
   * 用 '100%' 表达「不限制」等价且类型干净。
   */
  private stripCap(): Length {
    return this.stripWidth > 0 ? this.stripWidth : '100%';
  }

  // ------------------------------------------------------------ 顶栏

  /**
   * 顶栏：左边一条宽胶囊（返回 + 标题 + 页码），右边一颗方胶囊（设置齿轮）。
   *
   * 两条都是 52 高的全圆玻璃，和 Bika 那套「标题一条、动作一条」的分法一致：
   * 阅读时顶栏只承担定位（我在哪、这是哪部作品）和唯一一个入口，把画面让出来。
   */
  @Builder
  private topBar() {
    Row({ space: 12 }) {
      this.infoCapsule()
      this.actionCapsule()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: 12,
      right: 12,
      top: (AppStorage.get<number>('statusBarHeight') ?? 0) + 8,
      bottom: 8
    })
  }

  /** 左侧信息胶囊：返回箭头 + 作品标题（单行省略）+ 页码 */
  @Builder
  private infoCapsule() {
    Stack() {
      MaterialPlane({ kind: 'header', radius: CAPSULE_R, planeHeight: CAPSULE_H, dark: true })
      Row()
        .width('100%')
        .height(CAPSULE_H)
        .borderRadius(CAPSULE_R)
        .border({ width: 0.7, color: ON_GLASS_EDGE })
        .hitTestBehavior(HitTestMode.None)
      Row({ space: 2 }) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([ON_GLASS])
        }
        .width(40)
        .height(48)
        .onClick(() => {
          this.onBack();
        })

        Row({ space: 6 }) {
          // 标题不设固定宽度而用 layoutWeight(1)：文字长了它自己截断，
          // 后面的页码永远是完整的一份，不会被省略号吃掉
          Text(this.gallery.title)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(ON_GLASS)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          // 页码**不放在顶栏**：底栏已经有「第 N / M 页」，同一屏里出现两次是重复信息，
          // 还挤占标题宽度（长标题要省略）。补页进度用小转圈表达就够。
          if (this.collecting) {
            LoadingProgress().width(14).height(14).color(ON_GLASS_SOFT)
          }
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(CAPSULE_H)
      .padding({ left: 6, right: 14 })
      .alignItems(VerticalAlign.Center)
    }
    .layoutWeight(1)
    .height(CAPSULE_H)
    .borderRadius(CAPSULE_R)
  }

  /** 右侧动作胶囊：只有一个齿轮，点开设置面板 */
  @Builder
  private actionCapsule() {
    Stack() {
      MaterialPlane({ kind: 'header', radius: CAPSULE_R, planeHeight: CAPSULE_H, dark: true })
      Row()
        .width('100%')
        .height(CAPSULE_H)
        .borderRadius(CAPSULE_R)
        .border({ width: 0.7, color: ON_GLASS_EDGE })
        .hitTestBehavior(HitTestMode.None)
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(22)
          .fontColor([ON_GLASS])
      }
      .width(48)
      .height(48)
      .onClick(() => {
        this.settingsTab = 0;
        this.openSettings();
        // 面板一开就把页码滑条的计时停掉：否则 2s 后底栏会在遮罩后面自己变回页码
        this.stopPageTimer();
        this.pageControl = false;
      })
    }
    .width(CAPSULE_H)
    .height(CAPSULE_H)
    .borderRadius(CAPSULE_R)
  }

  // ------------------------------------------------------------ 底栏

  /**
   * 底栏：中央一条 52 高胶囊，最宽 360（再宽读数就要横着扫，反而不如短一点）。
   *
   * 常态是「上一页 | 页码 | 下一页」，点页码整条换成滑条 —— 同一个位置、同一个尺寸，
   * 只切换内容，视觉上不会跳。两种状态都带淡入 + 0.96 缩放的 transition，
   * 切换读起来是「一条胶囊原地换了内容」而不是「两条东西交叉出现」。
   */
  // ------------------------------------------------------------ 裁切（前 20 页）
  //
  // 底部条前 20 页有 detail.pageTiles（详情页 HTML 自带的那一屏子矩形），
  // 走 ThumbCropper 按**像素**裁一块，比例天然等于原图；其余页（以及裁剪失败的页）
  // 仍然走逐页真图 —— 这是预期行为，不是缺功能。
  // 出处：Ehviewer_OHOS 的 `PreviewThumbnailCache.ensureCropped`（`ptc.ets:23-128`）。

  /** 这一页可用的裁切矩形（没有 tiles / 越界 / 宽高无效都返回 null） */
  private stripTileOf(i: number): ThumbTile | null {
    if (i < 0 || i >= this.detail.pageTiles.length) {
      return null;
    }
    const t: ThumbTile = this.detail.pageTiles[i];
    if (t.sheet.length === 0 || t.w <= 0 || t.h <= 0) {
      return null;
    }
    return t;
  }

  /** 第 i 页的按需缩略图（没有就 null） */
  private stripPmOf(i: number): image.PixelMap | null {
    const pm: image.PixelMap | undefined = this.stripPms.get(i);
    return pm === undefined ? null : pm;
  }

  /**
   * 为某一页补一张底部条缩略图（页挂到树上时调用）。
   *
   * 分工：
   *  - 前 20 页有 tile → ThumbCropper 裁像素（一格 76×114 的显示框里用 Contain 放）；
   *  - 其余页 / 裁剪失败过 → 取 `/s/` 页解析出真实图片地址，再按长边 240 解码
   *    （比例天然正确，代价是每格 1~2 次往返）。
   *
   * 节奏：**按需 + 去重 + 上限**。裁剪路线的并发在 ThumbCropper 里（4 个槽位），
   * 逐页路线交给 ThumbPipeline（HTML 3 / 图片 6 / 离当前页最近优先），
   * 这里只做格子级去重和超时登记。
   * 命中 `page_map` 映射时阶段一不发请求 —— 翻同一本画廊时横条几乎立刻就有图。
   */
  private ensureStripThumb(i: number): void {
    if (i < 0 || i >= this.urls.length || this.offline) {
      return;
    }
    // 去重：排队中 / 在跑 / 已有图 / 已判死 都不再受理
    if (this.stripPms.has(i) || this.stripDead.has(i) || this.stripStarts.has(i)) {
      return;
    }
    const at: number = Date.now();
    this.stripStarts.set(i, at);
    const t: ThumbTile | null = this.stripCropFailed.has(i) ? null : this.stripTileOf(i);
    if (t !== null) {
      this.cropStrip(i, t);
    } else {
      this.stripPipeOf().request(i);
    }
    this.armStripTimeout(i, at, 1);
  }

  /**
   * 裁剪路线：从 sheet 里裁出第 i 页。
   *
   * 失败换路（与 DetailPage.cropPage 同口径）：记进 stripCropFailed，此后这一页走逐页真图；
   * 重裁大概率还是同一个结果，而逐页那条路是已经验证过的兜底。
   */
  private async cropStrip(i: number, t: ThumbTile): Promise<void> {
    let pm: image.PixelMap | null = null;
    try {
      const referer: string = t.page.length > 0 ? t.page : '';
      pm = await ThumbCropper.crop(t.sheet, t.x, t.y, t.w, t.h, referer);
    } catch (e) {
      pm = null;
    }
    if (pm !== null) {
      this.acceptStrip(i, pm);
      return;
    }
    if (!this.alive) {
      return;
    }
    this.stripCropFailed.add(i);
    this.stripStarts.delete(i);
    this.ensureStripThumb(i);
  }

  /** 调度器懒建（回调要绑实例，字段初始化阶段不适合 new） */
  private stripPipeOf(): ThumbPipeline {
    const cur: ThumbPipeline | null = this.stripPipe;
    if (cur !== null) {
      return cur;
    }
    const p: ThumbPipeline = new ThumbPipeline(STRIP_HTML_PARALLEL, STRIP_IMG_PARALLEL,
      (i: number): number => Math.abs(i - this.current),
      (i: number): Promise<ThumbRef> => this.resolveStripRef(i),
      (i: number, url: string): Promise<image.PixelMap | null> => this.decodeStrip(i, url),
      (i: number, pm: image.PixelMap): void => {
        this.acceptStrip(i, pm);
      },
      (i: number, reason: string): void => {
        this.failStrip(i, reason);
      });
    this.stripPipe = p;
    return p;
  }

  /** 阶段一：取直链。命中映射（Db.page_map）时零请求 */
  private async resolveStripRef(i: number): Promise<ThumbRef> {
    const out: ThumbRef = new ThumbRef();
    const pageUrl: string = this.urls[i];
    if (pageUrl === undefined) {
      return out;
    }
    try {
      const page: ImagePage = await EhApi.imagePageCached(pageUrl);
      out.url = page.imageUrl;
      out.limited = page.limited;
      out.ok = !page.limited && page.imageUrl.length > 0;
    } catch (e) {
      out.ok = false;
    }
    return out;
  }

  /** 阶段二：取字节 + 解码（命中字节缓存就不发请求） */
  private async decodeStrip(i: number, url: string): Promise<image.PixelMap | null> {
    const pageUrl: string = this.urls[i];
    if (pageUrl === undefined) {
      return null;
    }
    return await ImageLoader.loadThumb(pageUrl, url);
  }

  private acceptStrip(i: number, pm: image.PixelMap): void {
    this.stripStarts.delete(i);
    if (!this.alive) {
      // 页面已经退出：刚解出来的图没人用了，直接还回去
      try {
        pm.release();
      } catch (e) {
      }
      return;
    }
    if (this.stripPms.has(i)) {
      try {
        pm.release();
      } catch (e) {
      }
      return;
    }
    this.stripPms.set(i, pm);
    this.stripFails.delete(i);
    // 只做「从 Map 里摘掉 + 挂进 retired」，**不立刻 release**：
    // 大幅跳页时这张图可能还在屏幕上，释放后就是黑格。
    if (this.stripPms.size > 40) {
      const oldest: number | undefined = this.stripPms.keys().next().value;
      if (oldest !== undefined && oldest !== i) {
        const old: image.PixelMap | undefined = this.stripPms.get(oldest);
        this.stripPms.delete(oldest);
        if (old !== undefined) {
          this.retired.push(old);
        }
      }
    }
    // retired 超过 20 张才动手：延迟 1500ms（足够一帧以上）再释放最早的那批，
    // 既不无限增长，也不会踩到「刚被换下去但还在渲染」的那一张。
    if (this.retired.length > 20) {
      const dropCount: number = this.retired.length - 20;
      const batch: image.PixelMap[] = this.retired.slice(0, dropCount);
      this.retired = this.retired.slice(dropCount);
      setTimeout(() => {
        for (let k = 0; k < batch.length; k++) {
          try {
            batch[k].release();
          } catch (e) {
          }
        }
      }, 1500);
    }
    // 让 build 真的看到「这一页有图了」：stripLoaded 是 @State，Map 不是
    if (this.stripLoaded.indexOf(i) < 0) {
      this.stripLoaded = this.stripLoaded.concat([i]);
    }
    this.stripVer = this.stripVer + 1;
  }

  /**
   * 失败：第一次清缓存重来一趟（自愈），第二次记死。
   *
   * 配额页不重试：再打一次只会把额度用光，正文页也会跟着变慢。横条是辅助功能，
   * 少一格缩略图不影响阅读（格子里还有页码）。
   */
  private failStrip(i: number, reason: string): void {
    this.stripStarts.delete(i);
    let n: number = 0;
    const old: number | undefined = this.stripFails.get(i);
    if (old !== undefined) {
      n = old;
    }
    n = n + 1;
    this.stripFails.set(i, n);
    if (reason === 'quota' || n >= 2 || !this.alive) {
      this.stripDead.add(i);
      return;
    }
    this.healStrip(i);
  }

  /**
   * 自愈：清掉这一页的映射与字节缓存再重排。
   *
   * 直链过期（403）和坏字节在这条路上分不出来，两处一起清最省事；
   * 代价只是多一次 HTML 往返，而失败本来就少见。
   */
  private async healStrip(i: number): Promise<void> {
    const pageUrl: string = this.urls[i];
    if (pageUrl === undefined) {
      return;
    }
    EhApi.dropImagePage(pageUrl);
    await ImageDiskCache.remove(pageUrl);
    if (!this.alive) {
      return;
    }
    this.ensureStripThumb(i);
  }

  /**
   * 8 秒兜底：到点没出图就记死，别再让它在队列里反复重排队。
   *
   * 还在队列里排着的（一次网络都没发出去）先再给一窗 —— 300 格同时挂载时，
   * 排在后面的格子本来就要等，那不是「失败」。时刻不一致说明中间重试过，直接忽略。
   */
  private armStripTimeout(i: number, at: number, extra: number): void {
    setTimeout(() => {
      if (!this.alive || this.stripStarts.get(i) !== at) {
        return;
      }
      // 裁剪路线也要这一窗：它排在 ThumbCropper 的 4 个槽位后面，看起来和「图床慢」一样
      const cropping: boolean = this.stripTileOf(i) !== null && !this.stripCropFailed.has(i);
      if (extra > 0 && (cropping || this.stripPipeOf().isQueued(i))) {
        this.armStripTimeout(i, at, extra - 1);
        return;
      }
      this.stripPipeOf().cancel(i);
      this.stripDead.add(i);
    }, STRIP_STUCK_MS);
  }

  /**
   * 底部缩略图条：**位置 → 页号**。
   *
   * 条子跟着条漫走，不做镜像：位置 0 永远显示第 1 页，左→右就是页号递增，与 rtl 无关。
   *
   * 为什么和 Swiper 不同：Swiper 的镜像（flip）是**翻页手势**的物理方向决定的 ——
   * 日漫从右往左翻，滚动轴必须反向；而底部条是一个「定位器」，用户扫它的时候读的是
   * 「第几页在第几个格子」这件绝对的事。把它跟着反向，会出现「点第 3 格跳到第 298 页」
   * 这种反直觉操作，切一次方向条子还要整条重新排一遍。
   * 所以这里恒等返回：pos 就是页号，高亮 `pos === current`、点击 `jumpTo(pos)`。
   */
  private stripPageAt(pos: number): number {
    return pos;
  }

  /**
   * 当前页变化后把缩略图条滚到该页（居中），避免用户翻到后面才发现条还停在开头。
   *
   * 索引直接就是 current：条子不镜像（见 stripPageAt），页号和位置是同一个数。
   */
  private followStrip(): void {
    try {
      this.stripScroller.scrollToIndex(this.current, true, ScrollAlign.CENTER);
    } catch (e) {
      // 列表还没挂载/索引越界：忽略即可，下次翻页会再对一次
    }
  }

  /**
   * 底部缩略图条（做法参考 JHenTai 的 `read_page.dart:_buildThumbnails`）。
   *
   * 结构：横向列表，每项 = 缩略图（76×114，圆角 8）+ 页号（9 号字，当前页高亮底），
   * 项间距 6，点一下跳页；横向距离够宽，一屏能看到 4~5 页，方便定位。
   *
   * 图有两个来源（优先级同详情页网格）：
   *  1) 前 20 页有 `detail.pageTiles` → ThumbCropper 按像素裁一格（一屏只下一次 sheet）；
   *  2) 其余页（或裁剪失败过）：逐页取 `/s/` 页 → 真图 → 按长边 240 解码。
   * 两条路都写进 stripPms，所以这里只有「有图 / 没图」两态。
   * 没图时显示页号 —— 不做假图，页号至少还能当「跳到这里」的按钮用。
   */
  @Builder
  private thumbStrip() {
    Stack({ alignContent: Alignment.TopStart }) {
      List({ scroller: this.stripScroller, space: 6 }) {
        // 遍历页号本身：pos 既是 List 的位置，也是页号（条子不镜像，见 stripPageAt）。
        // 所以换向（rtl 开/关）时子项集合、位置、页号三者都不变，条子原地不动 ——
        // 这正是「条子跟着条漫走」的含义。
        // key 只带页号：复用同一批子组件，已经解好的缩略图不会因为换方向被丢掉。
        ForEach(this.urls, (u: string, pos: number) => {
          ListItem() {
            Column({ space: 4 }) {
              Stack({ alignContent: Alignment.Center }) {
                if (this.stripLoaded.indexOf(this.stripPageAt(pos)) >= 0 &&
                  this.stripPmOf(this.stripPageAt(pos)) !== null) {
                  // 条件里必须读 stripLoaded（@State）：只查 stripPms 的话，
                  // 图虽然出来了但 build 不知道，格子会一直停在页码上。
                  // contain：裁剪图的比例就是原图比例、逐页图按长边 240 等比解码，
                  // 两者都不会被 76×114 的格子拉伸变形。
                  Image(this.stripPmOf(this.stripPageAt(pos)) as image.PixelMap)
                    .width('100%')
                    .height('100%')
                    .objectFit(ImageFit.Contain)
                } else {
                  // 没图（排队 / 加载中 / 失败）：显示页号，不留空白格。
                  // 空白会让整条缩略图条看起来是坏的，而页号本身也是「点这里跳页」的标签。
                  Text((this.stripPageAt(pos) + 1).toString())
                    .fontSize(11)
                    .fontColor('#8A8F98')
                }
              }
              .width(STRIP_CELL_W)
              .height(STRIP_CELL_H)
              .borderRadius(8)
              .clip(true)
              .backgroundColor('#1A1D22')
              .border({ width: this.current === this.stripPageAt(pos) ? 1.5 : 0, color: '#5AA9FF' })

              Text((this.stripPageAt(pos) + 1).toString())
                .fontSize(9)
                .fontColor(this.current === this.stripPageAt(pos) ? '#FFFFFF' : '#8A8F98')
                .padding({ left: 4, right: 4 })
                .borderRadius(4)
                .backgroundColor(this.current === this.stripPageAt(pos) ? '#2F6FB5' : '#00000000')
            }
            .width(STRIP_CELL_W)
            .onAppear(() => {
              // 格子挂到树上就登记这一页。注意 ForEach 不是懒加载：300 页的画廊这里会
              // 一次性收到 300 个 onAppear —— 前 20 页走裁剪（4 个槽位 + 一屏一张 sheet），
              // 其余页由 ThumbPipeline 的两条闸门（HTML 3 / 图片 6）和「离当前页最近优先」兜住。
              this.ensureStripThumb(this.stripPageAt(pos));
            })
          .onClick(() => {
            // 位置就是页号（条子不镜像），所以直接跳 pos
            this.jumpTo(this.stripPageAt(pos));
          })
        }
      }, (u: string, pos: number) => 'strip-' + this.stripPageAt(pos).toString())
    }
    .listDirection(Axis.Horizontal)
    .width('100%')
    .height(STRIP_CELL_H + 24)
    .scrollBar(BarState.Off)
    .cachedCount(4)
    .padding({ left: 12, right: 12, bottom: 6 })
    }
    .width('100%')
    .height(STRIP_CELL_H + 24)
  }

  @Builder
  private bottomBar() {
    Stack() {
      Stack({ alignContent: Alignment.Center }) {
        MaterialPlane({ kind: 'header', radius: CAPSULE_R, planeHeight: CAPSULE_H, dark: true })
        Row()
          .width('100%')
          .height(CAPSULE_H)
          .borderRadius(CAPSULE_R)
          .border({ width: 0.7, color: ON_GLASS_EDGE })
          .hitTestBehavior(HitTestMode.None)

        if (this.pageControl) {
          Row({ space: 4 }) {
            Slider({
              value: this.jump,
              min: 1,
              max: Math.max(2, this.urls.length),
              step: 1
            })
              .layoutWeight(1)
              .trackThickness(4)
              .blockSize({ width: 18, height: 18 })
              .trackColor(SLIDER_TRACK)
              // 已滑过的一段用主题蓝：白色在深色玻璃上分不出「已选/未选」
              .selectedColor(SLIDER_ON)
              .blockColor(ON_GLASS)
              // 拖动时在滑块上方浮出目标页号（就是「拖动显示目标页」这条要求）
              .showTips(true)
              .enabled(this.urls.length > 1)
              .onChange((v: number, m: SliderChangeMode) => {
                this.onJumpChange(v, m);
              })
            Text(this.jump.toString() + ' / ' + this.urls.length.toString())
              .fontSize(12)
              .fontColor(ON_GLASS_SOFT)
              .maxLines(1)
              // 不给固定宽度：右对齐的定宽盒子会让「文字右缘 = 盒子右缘」，
              // 改容器 padding 只动盒子、文字位置纹丝不动（上一版"页码没动"的原因）。
              // 左边 2 让文字贴近滑条，右边 8 是和胶囊边缘的呼吸 ——
              // 只留左边距会让「12 / 304」最后一个数字顶到玻璃边线上（8 仍偏贴，实机看着像压在边上）。
              .margin({ left: 2, right: 14 })
          }
          .width('100%')
          .height(CAPSULE_H)
          // 右侧收到 2：滑条自身的滑块在轨道内还有一圈内缩，视觉上已经自带几 vp 的留白，
          // 容器再给 6 会变成两条缝叠在一起，页码看起来离得很远
          .padding({ left: 12, right: 2 })
          .alignItems(VerticalAlign.Center)
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
            .animation({ duration: 180, curve: Curve.Friction }))
        } else {
          Row() {
            Text('上一页')
              .fontSize(14)
              .fontColor(ON_GLASS)
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(44)
              .opacity(this.atFirst() ? DISABLED_OPACITY : 1)
              .onClick(() => {
                this.stepPage(-1);
              })
            Text(this.pageLabel())
              .fontSize(14)
              .fontColor(ON_GLASS)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(44)
              .onClick(() => {
                this.openPageControl();
              })
            Text('下一页')
              .fontSize(14)
              .fontColor(ON_GLASS)
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(44)
              .opacity(this.atLast() ? DISABLED_OPACITY : 1)
              .onClick(() => {
                this.stepPage(1);
              })
          }
          .width('100%')
          .height(CAPSULE_H)
          .padding({ left: 8, right: 8 })
          .alignItems(VerticalAlign.Center)
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
            .animation({ duration: 180, curve: Curve.Friction }))
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 360 })
      .height(CAPSULE_H)
      .borderRadius(CAPSULE_R)
    }
    .width('100%')
    .padding({
      left: 12,
      right: 12,
      bottom: (AppStorage.get<number>('navBarHeight') ?? 0) + 10
    })
  }

  /** 打开设置面板：每次都从 45% 正常态开始 */
  private openSettings(): void {
    if (this.sheetCloseTimer >= 0) {
      clearTimeout(this.sheetCloseTimer);
      this.sheetCloseTimer = -1;
    }
    this.sheetClosing = false;
    this.sheetFull = false;
    this.sheetDy = 0;
    this.stopPageTimer();
    this.settingsOpen = true;
  }

  /** 关闭设置面板：先播退场动画，再移除节点 */
  private closeSettings(): void {
    if (!this.settingsOpen || this.sheetClosing) {
      return;
    }
    this.sheetClosing = true;
    this.sheetCloseTimer = setTimeout(() => {
      this.sheetCloseTimer = -1;
      this.settingsOpen = false;
      this.sheetClosing = false;
      this.sheetFull = false;
      this.sheetDy = 0;
    }, SHEET_ANIM_MS);
  }

  // ------------------------------------------------------------ 设置面板

  /**
   * 设置面板外壳：遮罩 + 从底部上滑的卡片。
   *
   * 不用 bindSheet：那个 API 自带系统圆角/阴影和手势层，和阅读器的纯黑底、无边框气质不搭，
   * 而且它自己会吃掉背景点击；这里手写一层遮罩反而只需十几行，还能精确控制 45% 高度与 220ms。
   */
  @Builder
  private settingsOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Row()
        .width('100%')
        .height('100%')
        // 遮罩随面板下拖同步变淡：面板走了一半、背景还全黑，会显得"卡住"。
        // 显隐由 settingsOpen 驱动而不是 if 增删：if 收起来是**瞬间消失**，
        // 只有常驻节点 + opacity 过渡才有退场动画。
        .backgroundColor('#73000000')
        .opacity(this.sheetClosing ? 0 : 1 - Math.min(0.7, Math.max(0, this.sheetDy) / 260))
        .animation({ duration: SHEET_ANIM_MS, curve: Curve.Friction })
        .hitTestBehavior(this.sheetClosing ? HitTestMode.None : HitTestMode.Default)
        .onClick(() => {
          this.closeSettings();
        })

      Column() {
        // 顶部抓手：告诉用户这块可以往下拖（虽然关闭只靠点遮罩，但形状上它是一张 sheet）
        Row()
          .width(36)
          .height(4)
          .borderRadius(2)
          .backgroundColor(Theme.line())
          .margin({ top: 8, bottom: 8 })

        // 分段栏套一层带内边距的 Row：FloatingTabs 自己 width('100%')，
        // 直接给它 margin 会让 100% 与左右边距叠在一起、横向溢出
        Row() {
          FloatingTabs({
            items: ['阅读', '显示'],
            selected: this.settingsTab,
            onSelect: (i: number): void => {
              this.settingsTab = i;
            }
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })

        Scroll() {
          Column() {
            if (this.settingsTab === 0) {
              this.readingRows()
            } else {
              this.displayRows()
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 16 })
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        // 不能用 Spring：回弹会把内容拽出滚动视口，松手再弹回来 —— 观感上就是
        // 「按住面板顶部上滑，里面的内容被拖着走」。面板是一张固定的卡片，越界一律不接。
        .edgeEffect(EdgeEffect.None)
      }
      .width('100%')
      .constraintSize({ maxWidth: 560 })
      .height(this.sheetFull ? '92%' : '45%')
      // 面板必须是一块**不透光**的卡片：底色 Theme.card() 是实色，再配 clip(true)，
      // 圆角处、内容滚出边界处都不会漏出下面正在阅读的页面。
      .backgroundColor(Theme.card())
      .borderRadius({ topLeft: 20, topRight: 20 })
      .clip(true)
      // 跟手位移：只跟随**向下**的拖动（向上不跟手，否则面板会离开屏幕下沿、露出底页）
      .offset({ y: this.sheetDy })
      // 入场/退场：整体从屏幕下沿滑入滑出 + 淡入淡出。
      // 与 transform 无关，避免和 offset 抢同一个属性
      .translate({ y: this.sheetClosing ? 400 : 0 })
      .opacity(this.sheetClosing ? 0 : 1)
      // 松手：超过 80 或快速下甩就关闭，否则弹回。
      //
      // 跟手量只取**向下**：面板是贴底挂的，整块往上挪 N vp 就等于在屏幕下沿留出
      // N vp 的缺口，底下正在读的那一页就从缺口里露出来 —— 这就是「按住页头上滑露底」。
      // 上滑展开全屏仍然保留，但判断用的是手指位移（lastPanDy），不是面板位移。
      .gesture(
        PanGesture({ direction: PanDirection.Vertical, distance: 6 })
          .onActionUpdate((e: GestureEvent) => {
            const dy: number = e.offsetY;
            // 记原始位移：面板本身不跟手上移，但松手时要靠它判断「是不是在上滑」
            this.lastPanDy = dy;
            this.sheetDy = dy > 0 ? dy : 0;
          })
          .onActionEnd(() => {
            // 读手势自己的位移而不是 sheetDy：后者已被上式夹成 >= 0，判不出往上滑了多少
            const dy: number = this.lastPanDy;
            this.lastPanDy = 0;
            this.sheetDy = 0;
            if (dy <= -60) {
              this.sheetFull = true;
              return;
            }
            if (dy > 80) {
              if (this.sheetFull) {
                // 全屏态下先收回 45%，再滑一次才关 —— 一步跨到关闭太容易误触
                this.sheetFull = false;
                return;
              }
              this.closeSettings();
            }
          })
      )
      .animation({ duration: 180, curve: Curve.Friction })
      // 位移取自身高度的 100%：面板整块从屏幕下沿外面滑进来，淡入同时做
      .transition(TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: '100%' }))
        .animation({ duration: SHEET_ANIM_MS, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  /** 行间细线：0.5 的发丝，只有「上面还有一行」时才画（首行不画） */
  @Builder
  private rowDivider() {
    Row()
      .width('100%')
      .height(0.5)
      .backgroundColor(Theme.line())
  }

  /** 条漫页间留缝（vp）：0~24、步长 2。落在条漫分组里，只影响连续滚动 */
  @Builder
  private pageGapRow() {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text('页间留缝')
          .fontSize(13)
          .fontColor(Theme.text())
        Blank()
        Text(this.pageGap.toString() + ' vp')
          .fontSize(12)
          .fontColor(Theme.subText())
      }
      .width('100%')
      .height(SETTING_ROW_H)
      .alignItems(VerticalAlign.Center)

      Slider({ value: this.pageGap, min: 0, max: 24, step: 2 })
        .width('100%')
        .trackThickness(4)
        .blockSize({ width: 16, height: 16 })
        .selectedColor(Theme.accent())
        .showTips(false)
        .onChange((v: number) => {
          this.setPageGap(v);
        })
        .padding({ bottom: 8 })
    }
    .width('100%')
  }

  /**
   * 留缝滑条落点。
   *
   * 取整：Slider 按 step 落点，但仍可能出现 5.999，写进 Prefs 会出现小数。
   * 先改 @State：条漫每一项的 margin 都读它，松手即生效（不必重进页面）。
   */
  private setPageGap(v: number): void {
    const g: number = Math.round(v);
    if (g !== this.pageGap) {
      this.pageGap = g;
      Prefs.put('read_page_gap', g);
    }
  }

  /**
   * 当前设置下显隐工具栏所需要的连击次数。
   *
   * 单独抽成方法而不是在 build 里三处写三元：ReaderImage 与 tapLayer 的中间区
   * 必须永远用同一个值，否则开启「点击翻页」后中间 1/3 与图片上的点按方式会不一致。
   */
  private tapCount(): number {
    return this.tapMode === 'double' ? 2 : 1;
  }

  /** 「显示」页里「显示工具栏」的落点：写 Prefs + 立刻改 @State，切完即生效 */
  private setTapMode(i: number): void {
    const v: string = i === 1 ? 'double' : 'single';
    if (v !== this.tapMode) {
      this.tapMode = v;
      Prefs.put('read_toolbar_tap', v);
    }
  }

  /** 「阅读」页：模式 / 方向 / 布局 / 首图，后三项只在翻页形态下才有意义 */
  @Builder
  private readingRows() {
    Column() {
      ReaderSegRow({
        label: '阅读模式',
        options: ['翻页', '条漫'],
        selected: this.mode === 0 ? 1 : 0,
        onPick: (i: number): void => {
          this.setReadingMode(i === 1);
        }
      })
      // 条漫分组：页间留缝只对连续滚动有意义（翻页模式没有「相邻两页」这个概念），
      // 所以紧跟「阅读模式」这一行、并且只在条漫下出现 —— 和原来的「条漫宽度」同一栏。
      if (this.mode === 0) {
        this.rowDivider()
        this.pageGapRow()
      }
      if (this.mode !== 0) {
        this.rowDivider()
        ReaderSegRow({
          label: '翻页方向',
          options: ['从左到右', '从右到左'],
          selected: this.rtl ? 1 : 0,
          onPick: (i: number): void => {
            this.setRtl(i === 1);
          }
        })
        this.rowDivider()
        ReaderSegRow({
          label: '页面布局',
          options: ['单页', '双页'],
          selected: this.mode === 2 ? 1 : 0,
          onPick: (i: number): void => {
            this.setLayout(i);
          }
        })
        if (this.mode === 2) {
          this.rowDivider()
          ReaderToggleRow({
            label: '首图单独占一屏',
            checked: this.firstAlone,
            onChange: (on: boolean): void => {
              this.setFirstAlone(on);
            }
          })
        }
      }
    }
    .width('100%')
  }

  /**
   * 「显示」页：屏幕方向。
   *
   * 条漫的页间留缝已经移回「阅读」页的条漫分组（它只对连续滚动有意义，
   * 属于「怎么读」而不是「怎么显示」）。
   */
  @Builder
  private displayRows() {
    Column() {
      // 屏幕方向不是纯视觉项，但它和「怎么显示」是一类（都是整块画面的取景），
      // 所以留在「显示」页。
      ReaderSegRow({
        label: '屏幕方向',
        options: ['系统', '竖屏', '横屏'],
        selected: this.orientationIndex(),
        onPick: (i: number): void => {
          this.setOrientation(i);
        }
      })

      // 工具栏的点按方式紧跟屏幕方向：两者都是「整块画面的操作手感」，
      // 和设置面板里其它 swipe / paging 项分开，用户找它时不会翻到「阅读」页去。
      this.rowDivider()
      ReaderSegRow({
        label: '显示工具栏',
        options: ['单击', '双击'],
        selected: this.tapMode === 'double' ? 1 : 0,
        onPick: (i: number): void => {
          this.setTapMode(i);
        }
      })
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 内容层

  build() {
    Stack() {
      if (this.mode === 0) {
        this.continuousView()
      } else {
        this.pageView()
      }

      // 工具栏层：整层 hitTest(Transparent) 只负责定位，中间那一大片必须继续把点击
      // 交给下面的图片（点画面中央 = 显隐工具栏），所以不能给这层加底色或点击区。
      //
      // 显隐**不用 if**：if 是增删节点，没有过渡，工具栏会「啪」地出现。
      // 改成常驻 + opacity/位移：上栏往上收 12、下栏往下沉 12，200ms Friction，
      // 与阅读器里其它浮层（页码滑条、设置面板）同一套时长与曲线。
      // 隐藏时必须关掉命中测试：透明但吃点击 = 那一片永远点不到图片。
      Column() {
        Column() {
          this.topBar()
        }
        .width('100%')
        .opacity(this.chrome ? 1 : 0)
        .translate({ y: this.chrome ? 0 : -12 })
        .animation({ duration: 200, curve: Curve.Friction })
        .hitTestBehavior(this.chrome ? HitTestMode.Transparent : HitTestMode.None)

        Blank()

        Column({ space: 6 }) {
          // 缩略图条只在工具栏展开时出现：它比页码条占地方，收起时不该留白
          this.thumbStrip()
          this.bottomBar()
        }
        .width('100%')
        .opacity(this.chrome ? 1 : 0)
        .translate({ y: this.chrome ? 0 : 12 })
        .animation({ duration: 200, curve: Curve.Friction })
        .hitTestBehavior(this.chrome ? HitTestMode.Transparent : HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)

      // 用 if 挂载：关掉之后节点必须离开树，不能靠 opacity 常驻（那会挡住整页点击）
      if (this.settingsOpen) {
        this.settingsOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(READER_BG)
  }

  @Builder
  private continuousView() {
    List({ scroller: this.scroller, space: 0 }) {
      ForEach(this.urls, (u: string, i: number) => {
        ListItem() {
          ReaderImage({
            url: u,
            index: i,
            local: this.offline,
            tapCount: this.tapCount(),
            onTap: () => {
              this.chrome = !this.chrome;
            }
          })
        }
        // 页间留缝落在这里而不是 List 的 space 上：margin 加在项的外面，
        // 图片仍然按 aspectRatio 撑自己的高度，宽度一点没少（不会被缝隙挤窄）。
        // 第一项不加（i === 0），否则整条长图会凭空多出一段顶部留白。
        // 只有条漫走这个 builder，翻页模式天然不受影响。
        .margin({ top: i === 0 ? 0 : this.pageGap })
      }, (u: string) => u)
    }
    .width('100%')
    .height('100%')
    // 整条长图收窄到 stripWidth 后由外层 Stack 居中。
    // 外层 Stack 默认 alignContent Center，所以这里不需要再包一层 Row 居中。
    .constraintSize({ maxWidth: this.stripCap() })
    .cachedCount(2)
    .scrollBar(BarState.Off)
    .onScrollIndex((start: number) => {
      if (!this.startApplied) {
        // 起始页还没落位，别让首帧的 0 把 current 冲回第一页
        return;
      }
      this.current = start;
      if (this.jump !== start + 1) {
        this.jump = start + 1;
      }
      this.prefetchAround(start);
      this.followStrip();
    })
  }

  @Builder
  private pageView() {
    Swiper(this.swiper) {
      if (this.mode === 2) {
        // 同单页：数据源是「槽位序的屏起始页」，rtl 下整段倒序；一屏内部的两页左右
        // 由下面 Row 的 .reverse(this.rtl) 负责（JHenTai 的 spread 顺序也是这么处理的）。
        ForEach(this.slotPages(), (start: number) => {
          Stack({ alignContent: Alignment.Center }) {
            if (this.isSingleSpread(start, this.urls.length)) {
              // 单独一屏：横幅页不跟邻页硬拼；首图单独时第 0 页也走这里
              ReaderImage({
                url: this.urls[start],
                index: start,
                local: this.offline,
                tapCount: this.tapCount(),
                onTap: () => {
                  this.chrome = !this.chrome;
                },
                onLoaded: (i: number, r: number): void => {
                  this.onRatio(i, r);
                }
              })
            } else {
              Row({ space: 2 }) {
                ReaderImage({
                  url: this.urls[start],
                  index: start,
                  local: this.offline,
                  tapCount: this.tapCount(),
                  fitBox: true,
                  onTap: () => {
                    this.chrome = !this.chrome;
                  },
                  onLoaded: (i: number, r: number): void => {
                    this.onRatio(i, r);
                  }
                })
                  .layoutWeight(1)
                if (start + 1 < this.urls.length) {
                  ReaderImage({
                    url: this.urls[start + 1],
                    index: start + 1,
                    local: this.offline,
                    tapCount: this.tapCount(),
                    fitBox: true,
                    onTap: () => {
                      this.chrome = !this.chrome;
                    },
                    onLoaded: (i: number, r: number): void => {
                      this.onRatio(i, r);
                    }
                  })
                    .layoutWeight(1)
                }
              }
              .width('100%')
              .height('100%')
              // rtl 的一屏里，后一页在左、前一页在右（Row 有 reverse，Swiper 没有）
              .reverse(this.rtl)
            }
            if (this.tapPaging) {
              this.tapLayer()
            }
          }
          .width('100%')
          .height('100%')
          // key 里必须带 firstAlone：切开/合上首图时 pairStarts 会整体平移，但第 0 组的下标
          // 恒为 0、key 不变，ForEach 会复用旧一屏（首图仍是拼页）。带上开关状态才能强制重建。
          // 注意 key 里**不能**再带方向：换向只改 index 映射（slotOfPage），子项顺序始终是
          // 页号顺序；把方向写进 key 会整组重建，重建时 Swiper 回落到 0 → rtl 下就是末页
          // （「切方向跳末页」的根因，详见 setRtl）。
        }, (start: number) => 'pair-' + start.toString() +
          (this.firstAlone ? '-fs' : '-fp'))
      } else {
        // 数据源用「槽位序页号」而不是 urls：rtl 下槽位 0 放最后一页，index 才能当页号用。
        // key 仍然只带页号（不含方向位）：换向时同一批 key 只是换了位置，
        // 复用同一批子组件，不重新解码。
        ForEach(this.slotPages(), (page: number) => {
          Stack({ alignContent: Alignment.Center }) {
            ReaderImage({
              url: this.urls[page],
              index: page,
              local: this.offline,
              tapCount: this.tapCount(),
              onTap: () => {
                this.chrome = !this.chrome;
              },
              onLoaded: (idx: number, r: number): void => {
                this.onRatio(idx, r);
              }
            })
            if (this.tapPaging) {
              this.tapLayer()
            }
          }
          .width('100%')
          .height('100%')
        }, (page: number) => 'page-' + page.toString())
      }
    }
    .index(this.slotOfPage(this.current))
    .loop(false)
    .indicator(false)
    .cachedCount(1)
    .width('100%')
    .height('100%')
    .onChange((idx: number) => {
      // 只翻译，不回写：把槽位换回页号即可。
      // 这里**绝不能**再动 index / changeIndex —— 声明式的 `.index(slotOfPage(current))`
      // 读的就是 current，回写同类值只会和用户手势抢方向（上一版落到末页的一半原因）。
      this.current = this.pageOfSlot(idx);
      this.jump = this.current + 1;
      this.prefetchAround(this.current);
      this.followStrip();
    })
  }

  /**
   * 预取：把当前页之后的 3 页、之前的 1 页的**字节**提前落到磁盘缓存。
   *
   * 之前完全没有预取 —— 只有 `cachedCount` 让相邻节点提前挂载，而那两个缓存槽
   * 在快速翻页时根本追不上。JHenTai 的做法是给 PageView 开 `cacheExtent`
   * （Flutter 默认不构建相邻页），EhViewer 系是「按预加载页数并行请求」；
   * 这里取后者：显式请求，不依赖框架的缓存窗口。
   *
   * 规则：
   *   - 后 3 前 1（往前翻的等待感比往后翻更明显 —— 往回翻通常是"回看刚看过的"，最忌讳转圈）；
   *   - 已在缓存或正在请求的直接跳过（`inflight`），避免同一页被连点触发多次；
   *   - 失败静默：预取失败不影响当前阅读，真正翻到那一页时组件会自己走完整重试流程。
   */
  private prefetchAround(from: number): void {
    const targets: number[] = [from + 1, from + 2, from + 3, from - 1];
    for (let k = 0; k < targets.length; k++) {
      const i: number = targets[k];
      if (i < 0 || i >= this.urls.length) {
        continue;
      }
      const url: string = this.urls[i];
      if (url.length === 0 || ImageDiskCache.has(url) || this.inflight.has(url)) {
        continue;
      }
      this.inflight.add(url);
      this.prefetchOne(i, url);
    }
  }

  private async prefetchOne(index: number, url: string): Promise<void> {
    try {
      // 离线阅读本来就是本地文件，没有「预取」这回事
      if (this.offline) {
        return;
      }
      const page = await EhApi.loadImagePage(url);
      if (page.limited) {
        return;
      }
      // 只落盘字节：不 decode、不进内存 —— 这正是与 JHenTai 对齐的那一点
      await ImageLoader.prefetchToDisk(url, page.imageUrl);
    } catch (e) {
      // 预取失败是常态（节点抖动），不打扰用户
    } finally {
      this.inflight.delete(url);
    }
  }

  /**
   * 点击分区层：整宽横切三块，各 1/3。
   *
   * 用三个等宽子块而不是读 event.x 算百分比，省掉一次宽度测量（onAreaChange），
   * 双栏一屏同样按整屏三等分，行为一致。底色给一个几乎全透明的值，
   * 保证空容器也有渲染节点、能吃到点击（同时盖住下层 ReaderImage 的 onClick，
   * 否则中间那 1/3 会被切两次 chrome）。
   */
  @Builder
  private tapLayer() {
    Row() {
      Text('')
        .layoutWeight(1)
        .height('100%')
        .backgroundColor('#01000000')
        .onClick(() => this.tapThird(true))
      Text('')
        .layoutWeight(1)
        .height('100%')
        .backgroundColor('#01000000')
        // 中间区与图片上的点按方式保持一致（见 tapCount 的注释）：
        // 双击模式下这里也只能靠双击切换，单击不响应。
        .gesture(TapGesture({ count: this.tapCount() })
          .onAction(() => {
            this.chrome = !this.chrome;
          }))
      Text('')
        .layoutWeight(1)
        .height('100%')
        .backgroundColor('#01000000')
        .onClick(() => this.tapThird(false))
    }
    .width('100%')
    .height('100%')
  }
}
