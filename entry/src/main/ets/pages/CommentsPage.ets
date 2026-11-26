import { ApiCred, Comment, parseApiCred, parseComments, postComment, voteComment } from '../core/Comments';
import { Theme } from '../core/Theme';
import { Tokens } from '../core/Tokens';
import { Gallery, GalleryDetail } from '../core/Models';
import { PageHeader, HEADER_BOTTOM_GAP } from '../components/PageHeader';
import { MaterialPlane, MATERIAL_EDGE_WIDTH } from '../components/MaterialPlane';

// ------------------------------------------------------------ 悬浮输入胶囊尺寸
/** 胶囊高 46（与详情页工具条同高） */
const INPUT_BAR_HEIGHT: number = 46;
/** 胶囊与屏幕左右/底部边距 */
const INPUT_BAR_INSET: number = 16;
/** 发送按钮「有内容 / 没内容」两态配色的过渡时长：只换颜色，短一点才不显得按钮在犹豫 */
const SEND_TONE_MS: number = 160;

// ------------------------------------------------------------ 顶栏让位

/**
 * PageHeader 的玻璃下沿比 headerHeight() 多铺出来的那一段。
 *
 * PageHeader 内部材质高度 = statusBar + TITLE_BAR_HEIGHT + HEADER_BOTTOM_GAP(6)，
 * 而本页 headerHeight() 只算到 TITLE_BAR_HEIGHT —— 那 6 是组件给自己的下沿留白，
 * 没有导出成公共常量，也不允许改组件（别的页在用），所以只能在本页按同一个数补回来。
 * 漏掉它，本页算出的让位就比玻璃实际下沿少 6，首卡会贴在玻璃上（只剩半个间距）。
 */
// 直接用 PageHeader 导出的那条：它就是这个 6 的唯一来源，见该常量的注释
const HEADER_MATERIAL_GAP: number = HEADER_BOTTOM_GAP;

/** 顶栏玻璃下沿 → 首卡的视觉间距：与卡片自身 16 内边距同一档（约 3/4），首卡才和顶栏分出层次 */
const CONTENT_TOP_GAP: number = 12;

/**
 * 评论区。
 *
 * 评论数据直接从详情页的原始 HTML 里解析（`detail.rawHtml`），所以不需要额外请求；
 * 发评论后站点不会立即回显，重新进一次详情页即可看到，这里不做假乐观更新。
 *
 * 投票需要 apikey/apiuid（登录后详情页里才有），拿不到就只读。
 */
@Component
export struct CommentsPage {
  gallery: Gallery = new Gallery();
  detail: GalleryDetail = new GalleryDetail();
  onBack: () => void = (): void => {};

  @State private comments: Comment[] = [];
  @State private cred: ApiCred = new ApiCred();
  @State private text: string = '';
  @State private posting: boolean = false;
  @State private toast: string = '';
  private toastTimer: number = -1;

  /**
   * 主题订阅位。
   *
   * sendBg() 现在按深浅两套 alpha 取值（见该方法注释），这个分支读的是 Prefs 里不可观测的主题态，
   * 只写 Theme.xxx() 的节点在切主题时不会被标记重绘 —— 不订阅 themeDark，切完主题按钮会停在旧底色。
   * 顺带把本页其余 Theme.xxx() 节点一起带进重绘（左右分支同值只为建立依赖，不改取色规则）。
   */
  @StorageProp('themeDark') private themeDark: boolean = false;

  aboutToAppear(): void {
    this.cred = parseApiCred(this.detail.rawHtml);
    this.comments = parseComments(this.detail.rawHtml);
  }

  aboutToDisappear(): void {
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  private showToast(text: string): void {
    this.toast = text;
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout(() => {
      this.toast = '';
      this.toastTimer = -1;
    }, 2600);
  }

  private async send(): Promise<void> {
    const t: string = this.text.trim();
    if (t.length === 0 || this.posting) {
      return;
    }
    this.posting = true;
    try {
      const err: string = await postComment(this.gallery, t);
      if (err.length === 0) {
        this.text = '';
        this.showToast('已发布（重新进入详情页可看到）');
      } else {
        this.showToast(err);
      }
    } catch (e) {
      this.showToast((e as Error).message);
    }
    this.posting = false;
  }

  /**
   * 给一条评论投票。
   *
   * 卡片里的「赞成 / 反对」入口已经下线，本方法目前**没有调用方**。仍然原样保留（不改一行逻辑、
   * 不删 voteComment 的 import）：一是本轮只允许删 UI，接口调用链（voteComment 的签名、错误分支）
   * 是以后恢复入口或做批量操作的唯一实现，删了就得重写；二是它只是普通私有方法，ArkTS 不会因为
   * 「未被调用」报错，保留对构建产物零影响（不会被摇进任何代码路径）。
   * 若确认永久不要投票，再连同 import 一起清掉即可。
   */
  private async vote(c: Comment, up: boolean): Promise<void> {
    if (!this.cred.ok()) {
      this.showToast('投票需要登录（缺少 apikey）');
      return;
    }
    if (!c.canVote) {
      this.showToast('这条评论已投过票');
      return;
    }
    const delta: number = up ? 1 : -1;
    const ok: boolean = await voteComment(this.cred, this.gallery, c.id, up);
    if (ok) {
      c.score = c.score + delta;
      c.canVote = false;
      // 重新赋一次数组才触发刷新（元素是同一批对象）
      this.comments = this.comments.slice();
    } else {
      this.showToast('投票失败');
    }
  }

  /** 输入胶囊占位高度（含导航条避让与与屏边距），列表留白与提示位都用它 */
  private inputBarHeight(): number {
    return (AppStorage.get<number>('navBarHeight') ?? 0) + INPUT_BAR_INSET + INPUT_BAR_HEIGHT;
  }

  /** 状态栏高度：顶栏自己要吃这一段，列表让位也要算它 */
  private statusBar(): number {
    const v: number | undefined = AppStorage.get<number>('statusBarHeight');
    return v === undefined ? 0 : v;
  }

  /**
   * 顶栏「栏」本身的高度（含状态栏）= 状态栏 + 56，与首页/详情页同一个算法。
   * 注意：这只是栏，不是玻璃。PageHeader 的材质还多铺 HEADER_MATERIAL_GAP(6)，
   * 任何要贴合玻璃下沿的地方都用 contentTop()，不要再直接拿这个值当让位。
   */
  private headerHeight(): number {
    return this.statusBar() + Tokens.TITLE_BAR_HEIGHT;
  }

  /**
   * 内容起点（从屏幕顶算），列表与空态共用这一个算式。
   *
   * 三段相加，缺一段视觉间距就会错位：
   *   headerHeight()                 —— 状态栏 + 56，顶栏「栏」本身；
   *   + HEADER_MATERIAL_GAP(6)       —— PageHeader 的玻璃比栏多铺的 6，必须让掉；
   *   + CONTENT_TOP_GAP(12)          —— 想要的「玻璃下沿 → 首卡」视觉间距。
   * 即 headerHeight + 6 + 12 = headerHeight + 18：玻璃下沿到首卡正好 12，
   * 而不是之前只加 12 时被那 6 吃掉、只剩 6 的结果。
   * 空态与列表都调这个方法，保证「没评论」和「有评论」的让位完全一致。
   */
  private contentTop(): number {
    return this.headerHeight() + HEADER_MATERIAL_GAP + CONTENT_TOP_GAP;
  }

  /** 顶栏副标题：条数，未登录时补一句只读提示 */
  private headerSubtitle(): string {
    return this.comments.length.toString() + ' 条' + (this.cred.ok() ? '' : ' · 未登录，只能查看');
  }

  // ------------------------------------------------------------ 发送按钮的两态配色

  /**
   * 「有没有可发的内容」。
   *
   * 判定必须和 send() 里的 `this.text.trim().length === 0` 完全同源：同一个 @State text、
   * 同样先 trim。若另立一份 boolean 或第二份文本状态，中文输入法组词、粘贴带首尾空格这类
   * 场景下两边会错开，出现「按钮已经亮了，点下去却静默 return」——用户只会以为点击被吞了。
   */
  private hasInput(): boolean {
    return this.text.trim().length > 0;
  }

  /**
   * 发送按钮底色：有内容 = accent 实色；没内容 = accent 叠低 alpha（深浅两档）。
   *
   * 为什么空态用「半透明蓝」而不是「灰掉」：
   *  1. 灰色是「不可用」的语义，而这个按钮**始终可点**（send() 自己 guard 空内容），
   *     涂灰会让人以为还得先满足什么条件，比没提示更迷惑；
   *  2. 半透明只是把这块主色压暗一档，仍读得出「这是主操作，只是还没到时候」，
   *     同时和胶囊里的其他内容保持同一色相，不会在深色玻璃上糊出一块脏灰。
   *
   * 为什么透明度写在颜色里（#AARRGGBB）而不是整节点 .opacity(0.4)：
   *  .opacity() 作用于节点和它的全部子绘制，文字会一起淡到 40%，白字压在 40% 的蓝底上
   *  对比度只剩 1.x，整块看起来就是一坨糊掉的灰片 —— 底要半透明，字不能。
   *  只给 backgroundColor 加 alpha 通道，字保持不透明，两件事才拆得开。
   *
   * 为什么空态 alpha 要分深浅两套（本次改动）：
   *  字色统一成白色后，「40% accent 叠底 + 白字」在两种主题下的对比度差了一个量级 ——
   *    - 深色（底 #0B0D10）：40% 的 #5AA9FF 混出来是深蓝，白字对比度约 9:1，很好；
   *      这里若也提到 80%，按钮会被提亮到中蓝，白字反降到约 3.6:1，还抢走视觉焦点，所以维持 #66。
   *    - 浅色（底 #F5F6F8）：40% 的 #2F6BD8 混出来是 rgb(166,190,235) 的**浅蓝**，白字只有约 1.9:1；
   *      50%（#80）也才约 2.2:1，都低于 WCAG 对正文 4.5:1、大字 3:1 的下限，13vp 白字实际糊进底里。
   *      提到 80%（#CC）后是 rgb(87,135,222)、约 3.6:1 —— 白字读得清，又仍明显比实色「轻」，
   *      与「有内容」态（约 5:1）保留可感知的差别。再往上到 90% 才勉强 4.2:1，那时两态几乎同色，
   *      这套 alpha 想表达的「还没到时候」就没了，所以停在 80%。
   *  一句话：同一个 alpha 不可能同时适合两种主题（浅色嫌太淡、深色嫌太浓），只能按主题分开取。
   */
  private sendBg(): string {
    if (this.hasInput()) {
      return Theme.accent();
    }
    const c: string = Theme.accent();
    const hex: string = c.startsWith('#') ? c.substring(1) : c;
    // 只取后 6 位：万一 Theme 以后给出带 alpha 的 8 位写法，也不会拼出 10 位的非法色值
    const rgb: string = hex.length > 6 ? hex.substring(hex.length - 6) : hex;
    return (this.themeDark ? '#66' : '#CC') + rgb;
  }

  /**
   * 发送按钮字色：两态统一白色。
   *
   * 之前空态用 Theme.text()（浅色近黑 / 深色近白），换来了可读性，但一颗按钮在两态之间「黑白跳」
   * 会被误读成换了一颗控件；而主按钮配白字是本项目既有的观感，两态同字色才读得出「同一颗按钮、
   * 只是强度不同」。空态的可读性交给 sendBg() 的 alpha 提升来解决（浅色 80% / 深色 40%），
   * 而不是靠换字色 —— 职责拆开：字负责「看得清」，底负责「还没到时候」。
   */
  private sendTextColor(): ResourceColor {
    return Color.White;
  }

  build() {
    // 顶栏与输入胶囊都是**压在内容上**的浮层（与首页/详情页同一套）：
    // 评论列表从顶栏下面滚过去，材质才有东西可模糊；输入条同理，不占布局流。
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.comments.length === 0) {
        Column({ space: 8 }) {
          Text(this.detail.rawHtml.length === 0 ? '没有页面数据，请返回重新进入详情' : '还没有评论')
            .fontSize(13)
            .fontColor(Theme.subText())
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        // 居中要在顶栏下面居中，否则提示会被玻璃顶栏挡住。
        // 让位与列表同源（contentTop()），空态和有评论时不会出现一个 6 一个 18。
        .padding({ top: this.contentTop(), left: 32, right: 32 })
      } else {
        List({ space: 8 }) {
          ForEach(this.comments, (c: Comment) => {
            ListItem() {
              this.commentCard(c)
            }
          }, (c: Comment) => c.id + c.score.toString())
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16 })
        // 上下避让交给 contentStartOffset / contentEndOffset，而不是 padding：
        // padding 会把内容裁在边界里，卡片永远滚不到顶栏/胶囊下面，材质背后没东西可模糊；
        // offset 只挪内容起点，卡片能从顶栏下面穿过去，玻璃才「透」得出来。
        // 起点 = headerHeight + 6 + 12（见 contentTop()）：6 是 PageHeader 玻璃比栏多铺的下沿，
        // 12 才是想要的「玻璃 → 首卡」视觉间距。以前只写 headerHeight + 12，那 12 里被玻璃吃掉 6，
        // 首卡实际只离玻璃 6，卡顶和顶栏下沿挤成一条，读起来像粘在一起。
        // 只加在这里：没有同时给 List 加 top padding，否则两者叠加会让首卡白白多让一道。
        .contentStartOffset(this.contentTop())
        .contentEndOffset(this.inputBarHeight() + 8)
        .scrollBar(BarState.Off)
      }

      // ---- 贴底浮层：toast 在胶囊上方，胶囊贴底
      Stack({ alignContent: Alignment.Bottom }) {
        if (this.toast.length > 0) {
          Text(this.toast)
            .fontSize(12)
            .fontColor(Color.White)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .borderRadius(999)
            .backgroundColor('#33383F')
            .margin({ bottom: this.inputBarHeight() + 10 })
            // 提示只是提示，不能吃掉列表的点击
            .hitTestBehavior(HitTestMode.None)
        }

        // 悬浮输入胶囊：材质走 MaterialPlane，不可用时它自己回退成实底 + 厚模糊
        Stack({ alignContent: Alignment.Center }) {
          MaterialPlane({ kind: 'panel', radius: 999, planeHeight: INPUT_BAR_HEIGHT })

          Row({ space: 8 }) {
            TextInput({ text: this.text, placeholder: '写下你的评论…' })
              .layoutWeight(1)
              .height(INPUT_BAR_HEIGHT)
              .fontSize(13)
              .fontColor(Theme.text())
              .placeholderColor(Theme.subText())
              .backgroundColor(Color.Transparent)
              .padding({ left: 16, right: 4 })
              .borderRadius(999)
              .onChange((v: string) => {
                // 动画必须包住这次赋值：属性是跟着 text 重算的，先把值写完再 animateTo
                // 已经没有「旧值 → 新值」可插值，只会直接跳变。160ms 只作用于发送按钮的
                // 底色 / 字色，文字本身与输入框不受影响。
                animateTo({ duration: SEND_TONE_MS, curve: Curve.Smooth }, () => {
                  this.text = v;
                });
              })
            Text(this.posting ? '…' : '发送')
              .height(34)
              .padding({ left: 14, right: 14 })
              .fontSize(13)
              .fontColor(this.sendTextColor())
              .textAlign(TextAlign.Center)
              .borderRadius(999)
              .backgroundColor(this.sendBg())
              .margin({ right: 6 })
              .onClick(() => {
                // 空内容也不禁用：send() 自己会 guard（trim 后为空直接 return），
                // 按钮只是观感上「还没到时候」，不承担拦截职责。
                this.send();
              })
          }
          .width('100%')
          .height(INPUT_BAR_HEIGHT)
          .padding({ left: 6, right: 6 })
        }
        .width('calc(100% - 32vp)')
        .height(INPUT_BAR_HEIGHT)
        .borderRadius(999)
        // 描边画在这一层、且这一层**不再 clip**：.clip(true) 裁的是节点自身绘制，
        // 0.7 的外圈边会被圆角路径削掉一半，看起来像「某些角度有边、某些角度没有」。
        // 圆角裁剪本来就由 MaterialPlane 内部完成（材质层按 radius 裁），外层不需要再裁一次。
        // 为什么统一走 Theme.btnEdge() / Theme.floatShadow()：这个输入胶囊与详情页工具条、页头返回键
        // 是同一批浮起控件，白边（白 20%）+ 同一档接触阴影必须同源，否则页面之间来回跳会看出差异。
        // 宽度仍取 MATERIAL_EDGE_WIDTH（0.7），与搜索页那批悬浮按钮同口径。
        .border({ width: MATERIAL_EDGE_WIDTH, color: Theme.btnEdge() })
        // 阴影与描边同层：这一层没有 clip，阴影不会被圆角路径切掉
        .shadow(Theme.floatShadow())
        // 距屏底 = 导航条 + 16：到屏幕底部留一条，不贴着条
        .margin({ bottom: this.inputBarHeight() - INPUT_BAR_HEIGHT })
      }
      .width('100%')
      .height('100%')
      // 自身和子节点都响应，但不挡住下面列表的滚动手势
      .hitTestBehavior(HitTestMode.Transparent)

      // ---- 顶栏：首页同款（沉浸材质 + 22 中黑大标题 + 11 次要色副标题 + 右侧 32 高动作槽）
      // 放在最上层的最后一位：贴底浮层是满屏的，顶栏必须压在它上面才不会被抢点击。
      PageHeader({
        title: '评论',
        subtitle: this.headerSubtitle(),
        prominent: true,
        onBack: () => this.onBack()
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg())
  }

  @Builder
  private commentCard(c: Comment) {
    Column({ space: 6 }) {
      // 头一行只放「谁 + 什么时候」，评分单独贴在右侧：
      // 原来三样（名字/分数/时间）挤在一行，中间还夹一个 Blank，
      // 视线要在三个落点之间来回跳，读起来就是「乱」。
      Row({ space: 8 }) {
        Text(c.userName.length > 0 ? c.userName : '匿名')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .copyOption(CopyOptions.LocalDevice)
        Text(c.time)
          .fontSize(10)
          .fontColor(Theme.subText())
          .layoutWeight(1)
        // 评分只在对这条评论有意义时出现（未评分时站点给的是 0/负值）
        if (c.score !== 0) {
          Text((c.score > 0 ? '+' : '') + c.score.toString())
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(c.score > 0 ? '#7FD4A0' : '#FF8A8A')
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 正文：字号 13 / 行高 21（13×1.6），长评论靠行高撑开可读性，
      // 不靠卡片内边距 —— 那只会让短评论看起来空、长评论看起来挤。
      Text(c.content.length > 0 ? c.content : '（这条评论的内容没有解析出来）')
        .fontSize(13)
        .fontColor(Theme.text())
        .lineHeight(21)
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)

      // 卡片底部的「赞成 / 已投票 / 反对」一行已整行移除（投票入口下线）：
      // 这一行原本只承载投票两件事，没有混放「回复 / 举报」等其它动作，所以删掉整行即可，
      // 不需要在行内保留任何按钮；它下面的 Column 只剩「姓名行 + 正文」，间距由 Column 的
      // space: 8 统一给，不需要再为这一行补任何 margin / Divider（原本也没有 Divider）。
    }
    .width('100%')
    .padding(14)
    .borderRadius(12)
    .backgroundColor(Theme.card())
    .alignItems(HorizontalAlign.Start)
  }
}
