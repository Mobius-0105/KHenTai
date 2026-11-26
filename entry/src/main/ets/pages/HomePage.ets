import { EhApi } from '../core/EhApi';
import { Theme } from '../core/Theme';
import { EhConsts } from '../core/Consts';
import { Gallery } from '../core/Models';
import { GalleryListView } from '../ui/GalleryListView';
import { MaterialSurface } from '../components/MaterialSurface';
import { MaterialPlane } from '../components/MaterialPlane';
import { FloatingTabs, FLOATING_TABS_GAP, FLOATING_TABS_HEIGHT } from '../components/FloatingTabs';

/**
 * 尺寸/字号/圆角常量。
 *
 * 工程内没有 core/Tokens.ets（core/ 下只有业务模块），所以数值取自
 * docs/V2-UI-SPEC.md §3.6 关键尺寸、§3.2 间距、§3.3 字号、§3.5 圆角，
 * 逐条在注释里标了令牌名，将来补 Tokens.ets 时可直接替换。
 */
/**
 * 标题行 48（TITLE_BAR_HEIGHT）。
 *
 * 为什么从 56 收到 48：原来那 56 是给「标题 22 + 副标题 11」两行字留的（中间还有 1 的行距），
 * 副标题删掉后只剩一行 22 号字，再留 56 就是标题上下各空 17，顶栏看着发虚；
 * 48 让标题仍然垂直居中（22 号字上下各留 13 左右），既贴住状态栏又不顶边。
 * 排行 chip（28 / 材质 32）放进 48 后上下也仍各余 10 / 8，不会把标题挤扁。
 */
const BAR_ROW_HEIGHT: number = 48;        // TITLE_BAR_HEIGHT
/**
 * 排行时间 chip 的尺寸（顶栏标题行右侧那一小排）。
 *
 * 高 28 / 字号 12 / 左右各 16 的内边距：单字 chip 的宽 ≈ 12 + 32 = 44，
 * 4 颗加 3 条 4vp 的缝 = 176 + 12 = 188。
 * 左右 16 而不是 10：10 的时候单字 chip 只有 32，字几乎顶到胶囊弧线上，
 * 加上后面那块滑动色块，选中项左右没有留白，读起来像色块压着字。
 * 28 高仍塞得进 48 的标题行（上下各余 10），不会把 22 号的标题挤成一小截。
 */
const RANK_CHIP_HEIGHT: number = 28;
const RANK_CHIP_FONT: number = 12;
const RANK_CHIP_PAD_X: number = 16;
const RANK_CHIP_GAP: number = 4;
/**
 * 排行 chip 这一排在胶囊内部左右各留的呼吸（6vp）。
 *
 * 为什么需要：chip 贴到胶囊边上时，第一颗/最后一颗的字正好落在 999 圆弧的切线处，
 * 看起来像被弧线切掉一块；选中第一颗时色块（圆角 12）的左上角更是直接顶在外层
 * 胶囊的圆弧内壁上。6 正好让色块的角与胶囊弧之间留出一道可见的缝。
 * **为什么必须与色块的 x 共用这一份常量**：上一轮的病根就是「chip 行有自己的起点、
 * 色块自己又算一套起点」—— 两套几何一旦不同步，第 i 颗就累计多走 i × 偏差，
 * 最后那颗（「总」）的色块右缘就跑到胶囊外面去了。所以 chip 行的 padding、
 * 色块的 x、这一排的自然宽三者全部从这里换算（rankChipX / rankContentW），
 * 只此一处，改一个数三者同步。
 */
const RANK_BAR_PAD: number = 6;
/**
 * 排行 chip 那一条材质的工作高度（32 = chip 28 + 上下各 2）。
 *
 * 为什么必须是**定值**：材质来自 MaterialPlane 里的 Navigation title 作用域，
 * 只有给到确定的 planeHeight 才建得起来 —— 靠子节点撑开高度在这条路径上不成立
 * （搜索页语言胶囊的 LANG_GROUP_H 是同一个理由）。
 * 为什么 32 而不是 28：材质要包住 28 高的 chip，上下各留 2 才有「一块玻璃上摆着几个选项」
 * 的层次；塞进 48 的标题行后上下仍各余 8，不会把标题行读厚。
 */
const RANK_PLANE_H: number = 32;
/**
 * 滑动色块的高度 24：材质 32 内上下各留 4。
 *
 * 为什么不跟 chip 一样 28：色块要整块落在材质里面（chip 可以贴边，因为它没有底），
 * 24 + 上下各 4 时色块的弧线整圈都在材质的胶囊内 —— 圆角 999 的两端是半圆，
 * 等高叠放会让色块的角正好压在材质的裁切弧上，看起来像被削掉一块。
 */
const RANK_PILL_H: number = 24;
/**
 * 色块在材质里的纵向偏移（(32 - 24) / 2 = 4）。
 *
 * 写成公式而不是再写一个 4：以后动材质或色块高度时，色块仍然落在 chip 正后方，
 * 不会偏出半个像素（搜索页 LANG_PILL_Y 是同一个来源）。
 */
const RANK_PILL_Y: number = (RANK_PLANE_H - RANK_PILL_H) / 2;
/**
 * 色块横滑 / 字色淡入的时长（160 / Smooth）。
 *
 * 与搜索页语言组、首页 FloatingTabs 的点按滑动块同档：同一个 App 里
 * 「一个块滑到新选项」必须同参数，否则来回切页会觉得一边更快（那边也给的是 160）。
 */
const RANK_PILL_ANIM: number = 160;
/**
 * 排行 chip 整组显隐的时长：160 / Smooth（进入与离开同长）。
 *
 * 为什么和 RANK_PILL_ANIM 分开写：那个 160 是「一颗色块滑到另一颗」的手感，
 * 这个是「整组从标题行右侧淡入/淡出」。目前同值只是巧合，语义不同，
 * 将来调其中一个不该把另一个带歪。
 * 为什么 160 而不是 220/260：显隐是由切 tab 触发的，内容页已经在滑动；
 * 附属控件比页面慢一拍就会被读成「卡了一下」。
 */
const RANK_VIS_ANIM: number = 160;
/** 排行 chip 不可见时的下落量（进入从 +4 升到 0，离开反向）：只做一点点位移，别抢标题的注意力 */
const RANK_VIS_SHIFT: number = 4;
/**
 * 排行 chip 的宽度上限：标题行实测宽的 57%。
 *
 * 这一排现在需要 200vp = 左右各 6 的内边距（12）+ 4×44（176）+ 3×4 的缝（12）。
 * 360 屏的 55.6% 才是 200，所以取 57 留一点余量：
 *   57% × 360 = 205.2（比 200 多 5.2，足够吸收字体/取整误差）
 *   56% × 360 = 201.6 —— 只多 1.6，一旦字号缩放到 12.5 就会重新溢出，不留这一档。
 * 再往上（59%）标题就开始被省略号吃掉最后一个字母，所以 57 是「标题优先、chip 让位」的分界。
 * 到了上限还放不下（≤340 的窄屏、分屏、大字体）就横向滚动，绝不吃标题。
 */
const RANK_CHIP_MAX_RATIO: number = 0.57;
/** 首帧还没量到标题行宽度时的兜底上限（= 320 屏的 57% ≈ 182.4）：宁可先窄一点，也不抢标题 */
const RANK_CHIP_MAX_FALLBACK: number = 320 * RANK_CHIP_MAX_RATIO;
const PAGE_PADDING: number = 16;          // SPACE_LG
const FONT_TITLE: number = 22;            // FONT_SIZE_H2（大标题层级）
/**
 * 标题行与 tab 行、tab 行与顶栏下沿之间的纵向间距：6。
 *
 * 为什么不复用 FloatingTabs 导出的 FLOATING_TABS_GAP(8)：那个 8 是**分段组件自己**的口径，
 * 别的页（媒体库等）还在用，本页改它会把别处一起带歪；而且副标题删掉之后顶栏本来就矮了一截，
 * 间距再留 8，「标题 / 分段 / 内容」三段之间的空隙会比字本身还沉。
 * 这个 6 只服务本页顶栏：headerHeight() 与 tab 行的上下 margin 共用它，改一处三处同步。
 */
const BAR_GAP: number = 6;
/**
 * 分段胶囊**下方**的呼吸。
 *
 * 与上方分开取值（6 vs 10）：上面紧接标题，大了会把标题与分段推散；下面接内容，
 * 太小会让胶囊看着贴在列表第一行上 —— 同一组数字管两端，总有一端不合适。
 * headerHeight() 与胶囊的 margin 必须都引这一个常量，否则顶栏高度的账会对不上。
 */
const BAR_GAP_BOTTOM: number = 10;
/**
 * 卡片列表与顶栏之间的呼吸（SPACE_SM 附近）。
 *
 * 为什么需要：顶栏高度只覆盖到 tab 胶囊的下边缘，列表若从 headerHeight() 原样起排，
 * 第一排卡片的上沿会紧贴胶囊外圈 —— 两者都是圆角，贴在一起时圆和圆几乎相切，
 * 看起来像卡片被胶囊「压住」了一角。加 8~10vp 后，胶囊下沿和卡片上沿之间
 * 出现一条和左右 16 边距同量级的负空间，视觉上才分得开「一层 chrome」和「内容」。
 */
const CARD_TOP_GAP: number = 10;

/**
 * 顶栏「回到顶部」圆钮的尺寸：32×32。
 *
 * 与标题行里另外两颗小控件同一档：排行 chip 的材质高 32、搜索页「清空 / 筛选」高 32。
 * 48 的标题行里上下各余 8，读起来是「标题行里的一颗按钮」而不是一块压住标题的板。
 */
const TOP_BTN_SIZE: number = 32;
/**
 * 滚动过这个距离才出现（480）。
 *
 * 与详情页那颗回顶钮同一个阈值（DetailPage 的 TOP_BTN_THRESHOLD）：同一个手势在两个
 * 页面里越过同一条线才浮出按钮，用户不用重新适应「滑多远它才来」。
 * 480 大约是两三张卡的高度 —— 短列表（一屏就看完）不该出现回顶钮。
 */
const TOP_BTN_THRESHOLD: number = 480;
/**
 * 顶栏发丝线的判定容差（vp）：列表偏移大于这个数才算「内容已经顶到顶栏下沿」。
 *
 * 不能写 `> 0`：滚动到底后轻微回弹、或列表首帧报出一个 0.2 之类的亚像素位移，
 * 都会让线在一像素之间反复翻转（每次翻转都是一次整页 build）。0.5vp 是视觉上
 * 等于「完全在顶部」的一档，同时把这些噪声全吃掉。
 */
const HAIRLINE_EPS: number = 0.5;
/** 显隐时长 160 / Smooth：与顶栏其它轻量反馈（排行 chip 淡入、搜索钮换色）同档 */
/**
 * 回顶钮的进出动画时长（ms）。
 *
 * 从 160 提到 200：160 与「顶栏其它小控件」同一档，但这颗钮做的事是「从上方滑入」，
 * 位移 8，速度一样时会显得急；200 + Friction 才像「贴上来」而不是「弹出来」。
 */
const TOP_BTN_ANIM: number = 200;
/** 不可见时的下沉量（进入从 +4 抬到 0，离开反向）：只做一点点位移，别抢标题注意 */
/**
 * 隐藏时向下偏移的位移（vp）。
 *
 * 4 太轻，160ms 内几乎看不出是「滑下来」还是「淡下去」；8 才读得出方向。
 * 注意方向是**从上往下沉**（隐藏时 y>0），符合「往上滑出、露出来」的直觉。
 */
const TOP_BTN_SHIFT: number = 8;

/** 四种模式的文案：顺序与 TabContent 一一对应（本组件不决定顺序，只复用） */
const MODE_LABELS: string[] = ['最新', '热门', '排行', '观看'];

/**
 * 排行时间范围：文案与 tl 值成对定义。
 *
 * 分成两个等长数组而不是 Map：chip 只认「items + 下标」，
 * 文案必须按顺序单独给它一份；tl 值只在下标↔tl 换算时用到。
 */
const RANK_LABELS: string[] = ['日', '月', '年', '总'];
const RANK_TLS: number[] = [15, 13, 12, 11];

/** 首页：默认列表 + 热门 */
@Component
export struct HomePage {
  onOpen: (g: Gallery) => void = (g: Gallery): void => {};

  /**
   * 主题订阅位。
   *
   * 为什么需要：Theme.bg()/card() 内部读的是 Prefs（同步内存表，不可观测），
   * 属性表达式里只出现 Theme.xxx() 时，主题变化不会有任何节点被标记重绘。
   * Theme.refresh() 会把当前深浅写进 AppStorage 的 'themeDark'，这里订阅它，
   * 本页才能在设置页切主题后整体换色（材质层 MaterialSurface 另有自己的订阅）。
   */
  @StorageProp('themeDark') private themeDark: boolean = false;

  @State @Watch('onModeChanged') private mode: number = 0;
  @State private url: string = EhApi.homeUrl(0);
  /** 首页模式的内层 Tabs：点 chip 或左右滑动都走它 */
  private modeCtrl: TabsController = new TabsController();
  /** 排行页的时间范围：15 日 / 13 月 / 12 年 / 11 总 */
  @State private rankTl: number = 15;

  /**
   * 标题行实测宽度（onAreaChange 写入），只用来给排行 chip 算 53% 的上限。
   *
   * 不写死：屏幕 320~800vp、还能分屏/旋转，上限必须由实测宽度算；
   * 写死一个数在窄屏会挤掉标题、宽屏又白留一块空。
   */
  @State private titleRowW: number = 0;
  /**
   * 单个排行 chip 的实测宽度（4 个单字 chip 等宽，量到一颗就够）。
   *
   * 这是这一整排**唯一**的实测几何：色块的宽、色块的 x、这一排的自然宽，
   * 全部由它经 rankChipW()/rankChipX()/rankContentW() 换算（见 rankChipW 的注释）。
   * 为什么不在 build 里现算：宽由字号 + 左右内边距撑开，字体缩放 / 分屏都会变，
   * 只有实测值才跟得上。
   */
  @State private rankChipWMeasured: number = 0;
  /**
   * 滑动色块当前的 x（相对内层 Stack 左缘，**已含 RANK_BAR_PAD**，见 rankChipX）。
   *
   * 单独存状态而不是在 build 里按 rankIndex() 现算：只有「写状态被 animateTo 包住」时
   * 位置才会插值，现算等于每帧直接跳到新位置，看不到滑动（搜索页 langPillX 同一结论）。
   * 初值也取 RANK_BAR_PAD：首帧量到宽之后才会被 recordRankChipW 覆盖，
   * 但万一哪次重绘抢在测量前用上它，落点也在第一颗 chip 上而不是贴死左边缘。
   */
  @State private rankPillX: number = RANK_BAR_PAD;
  /**
   * 排行 chip 整组的显隐进度（0 = 完全隐藏，1 = 完全显示）。
   *
   * 为什么不继续用 `if (this.mode === 2)` 增删节点：`if` 分支在同一帧里就把节点
   * 抽走/插回来，没有任何中间态 —— 切到排行时 chip 是「啪」地出现，切走时「啪」地消失，
   * 和旁边 160ms 的分段滑块、字色渐变完全不是一个节奏。改成**始终挂载**、
   * 只动 opacity / translate，过渡才有落点。
   */
  @State private rankFade: number = 0;
  /** 与 rankFade 同一条曲线驱动的纵向位移：进入 4 → 0（从下方轻轻浮上来），离开反向 */
  @State private rankSlideY: number = RANK_VIS_SHIFT;
  /**
   * chip 是否参与布局（Visibility.Visible / None），与 rankFade 不是一回事。
   *
   * 为什么不直接拿 rankFade > 0 当可见性：opacity 为 0 的节点**仍然占宽度**，
   * 那 200 宽会一直把标题行右侧吃掉（标题在窄屏会被它挤成省略号），它还会继续吃点击。
   * 所以两段式：显隐过渡期间可见（才有得淡），过渡结束后 Visibility.None
   * —— Visibility.None 既不占宽也不吃点击，标题随即拿回整行宽度。
   */
  @State private rankMounted: boolean = false;

  /**
   * 四个模式各自的列表滚动位置（vp，「离顶部多远」）。
   *
   * 为什么是一组而不是一个数：四个 TabContent 各自保留滚动位置（这是「切模式不重载」
   * 的前提），共用一个数的话，在「最新」里滑下去再切到「热门」，热门明明还在顶部，
   * 回顶钮却已经亮着 —— 那颗按钮会显得完全没道理。
   */
  @State private listScrollY: number[] = [0, 0, 0, 0];
  /**
   * 四个模式各自的回顶信号（理由见 GalleryListView.scrollToTopTick 的注释：
   * 父组件拿不到子组件实例，只能靠属性下发，而 @Prop 的 @Watch 只认值变化）。
   *
   * 同样分开存：点「最新」里的回顶只该动「最新」这一个列表，
   * 一个共用的 tick 会把另外三个 tab 的位置也一起归零 —— 用户切回去时位置就没了。
   */
  @State private topTick: number[] = [0, 0, 0, 0];

  aboutToAppear(): void {
    this.url = EhApi.homeUrl(0);
  }

  private statusBar(): number {
    const v: number | undefined = AppStorage.get<number>('statusBarHeight');
    return v === undefined ? 0 : v;
  }

  /**
   * 顶栏实际高度（含状态栏）：
   *   状态栏 + 标题行 48 + 6 + tab 行 40 + 6
   *
   * tab 行从「浮在内容上的独立胶囊」改回顶栏内部的第二行，顶栏就必须把它算进高度。
   * 本方法只回答「顶栏画多高」，材质层（MaterialSurface.surfaceHeight）直接取它；
   * 列表让位走 listTopInset() = 本方法 + CARD_TOP_GAP，两者刻意不是同一个数（见那边的注释）。
   * 这样顶栏不会因为内容要呼吸而变厚，也不会出现「让位比顶栏少」而露出黑缝。
   *
   * 数值沿革（不含状态栏）：**旧 = 56 + 8 + 40 + 8 = 112 → 新 = 48 + 6 + 40 + 6 = 100**，
   * 少了 12：标题行 56→48 收 8（副标题那 11 + 1 行距原本就吃在这 8 里，剩下的 48 仍够一行
   * 22 号字垂直居中），两段间距 8→6 各收 2。三处都改，加起来正好 12，不是凑数。
   * 状态栏那一段仍是 this.statusBar()（AppStorage 'statusBarHeight'，拿不到取 0），
   * 没有动：它由系统给，改它会和别的页（LibraryPage/SearchPage…）对不齐。
   *
   * 排行时间 chip 从「tab 行下面的第三行」搬到了标题行右侧，所以这里**不再有**
   * 「8 + 40」那段排行专用高度：顶栏在排行模式下不再长高，内容区也不会平白多让 48。
   */
  private headerHeight(): number {
    return this.statusBar() + BAR_ROW_HEIGHT
      + BAR_GAP + FLOATING_TABS_HEIGHT + BAR_GAP_BOTTOM;
  }

  /**
   * 列表内容起点 = 顶栏高度 + 一段呼吸。
   *
   * 只在这里加 CARD_TOP_GAP，不去动 headerHeight()：顶栏材质（MaterialSurface 的
   * surfaceHeight）和列表让位必须是两个数 —— 让位比顶栏高一点，是内容退让，不是顶栏变高。
   * 反过来把 gap 塞进 headerHeight() 会把材质也一起垫厚 10vp，胶囊下面多出一条空玻璃带。
   *
   * 数值：**旧 112 + 10 = 122 → 新 100 + 10 = 110**（不含状态栏），与 headerHeight() 同步。
   * 全工程的顶部让位只有这一个来源：四个 GalleryListView 的 topInset 传的都是本方法，
   * 它们内部就是 .contentStartOffset(this.topInset)，所以顶栏一收，内容起点自动跟着收，
   * 不存在「改了 headerHeight 忘了 contentStartOffset」的第二处要同步。
   */
  private listTopInset(): number {
    return this.headerHeight() + CARD_TOP_GAP;
  }

  /** 排行时间范围当前下标：tl 值 → chip 下标（顺序与 RANK_LABELS 一致） */
  private rankIndex(): number {
    for (let i: number = 0; i < RANK_TLS.length; i++) {
      if (RANK_TLS[i] === this.rankTl) {
        return i;
      }
    }
    return 0;
  }

  /**
   * 模式切换：驱动排行 chip 的显隐过渡（进入 opacity 0→1 且 y 4→0，离开反向）。
   *
   * 为什么放在 @Watch 里而不是在 build 里按 mode 算现值：只有「状态写入被 animateTo 包住」
   * 时属性变化才有插值，直接按 mode 现算 opacity/translate 等于两帧硬切。
   *
   * 为什么进入要先写 rankMounted：Visibility.None 的节点不在布局里，opacity 动画没有起点；
   * 先让它可见（此时 rankFade 仍是 0，第一帧画出来就是全透明），紧随其后的 animateTo 才有得淡。
   *
   * 为什么离开的收尾要再判断一次 mode：这 160ms 里用户可能又滑回排行，
   * 那时 onFinish 若照旧把 rankMounted 关掉，刚淡入的 chip 会被半个动画打断。
   */
  private onModeChanged(): void {
    const show: boolean = this.mode === 2;
    if (show === this.rankMounted) {
      return;
    }
    if (show) {
      this.rankMounted = true;
      animateTo({ duration: RANK_VIS_ANIM, curve: Curve.Smooth }, () => {
        this.rankFade = 1;
        this.rankSlideY = 0;
      });
    } else {
      animateTo({
        duration: RANK_VIS_ANIM,
        curve: Curve.Smooth,
        onFinish: () => {
          if (this.mode !== 2) {
            this.rankMounted = false;
            this.rankFade = 0;
            this.rankSlideY = RANK_VIS_SHIFT;
          }
        }
      }, () => {
        this.rankFade = 0;
        this.rankSlideY = RANK_VIS_SHIFT;
      });
    }
  }

  /**
   * 页面底色（含 TabContent 空白帧的底色）。
   *
   * 两个分支返回同一个色值：这里读 themeDark 不是为了算出不同颜色，
   * 而是让 build() 与 AppStorage 的 'themeDark' 建立依赖 —— 只写 Theme.bg()
   * 的话，切主题后本页不会被标记重绘（取色规则仍统一由 Theme 决定）。
   */
  private pageBg(): string {
    if (this.themeDark) {
      return Theme.bg();
    }
    return Theme.bg();
  }

  /**
   * 顶栏「回到顶部」圆钮：标题行右侧，紧挨排行 chip 的左边。
   *
   * 顺序为什么是「标题 … 回顶 · chip」而不是反过来：这一行是右对齐的固定尾巴，
   * 排行 chip 是**偶发**出现的附属信息（只在排行模式可见），回顶钮是**常驻**的动作位，
   * 常驻件贴着标题、偶发件贴最右，切模式时标题的可用宽度不会因为 chip 进出来回跳。
   * 行本身是 `Row({ space: FLOATING_TABS_GAP })`，所以两颗之间自然有 8，不用再写 margin。
   *
   * 显隐不用 if 增删节点：`if` 在同一帧就把节点抽走/插回，没有中间态，切 scroll 时是「啪」
   * 地出现；这里始终挂载，只改 opacity / translate，160ms 才有落点（与排行 chip 同一套）。
   * 代价是它常占 32 宽 —— 标题是单行左对齐文字，收回这 32 只会让它更早省略，不会让标题跳动。
   */
  @Builder
  private backToTopBtn() {
    Stack({ alignContent: Alignment.Center }) {
      MaterialPlane({ kind: 'header', radius: 999, planeHeight: TOP_BTN_SIZE })
      SymbolGlyph($r('sys.symbol.arrow_up'))
        .fontSize(16)
        .fontColor([Theme.text()])
    }
    .width(TOP_BTN_SIZE)
    .height(TOP_BTN_SIZE)
    .borderRadius(999)
    // 白边与投影画在这层不裁切的 Stack 上：材质自己按 radius 裁圆，边画在裁切路径上
    // 会被削掉外侧半条（0.7 的发丝线剩 0.35 等于没画）。与顶栏其它浮起控件同一份 Theme 取值。
    .border({ width: 0.7, color: Theme.btnEdge() })
    .shadow(Theme.floatShadow())
    .opacity(this.topBtnShown() ? 1 : 0)
    .translate({ y: this.topBtnShown() ? 0 : TOP_BTN_SHIFT })
    .animation({ duration: TOP_BTN_ANIM, curve: Curve.Friction })
    // **不可见时必须关掉命中测试**：opacity 0 的节点照样在布局里、照样吃点击，
    // 顶栏右上角就会留一块「看不见但点得到」的死区，点下去还会把列表弹回顶部 ——
    // 透明鬼按钮是最难自己发现的一类 bug。Transparent 而不是 None 的另一半意思是：
    // 可见时手势要能穿透这一颗（贴边的横滑/下拉不该被它挡住）。
    .hitTestBehavior(this.topBtnShown() ? HitTestMode.Transparent : HitTestMode.None)
    .onClick(() => this.backToTop())
  }

  /** 当前模式的列表是否已滑过阈值（决定回顶钮显隐） */
  /**
   * 切页/切段期间**抑制**回顶钮的显隐。
   *
   * 跳动的成因不是动画缺失，而是两次状态翻转撞在一起：切段的那一帧旧段的偏移还是
   * 大于 480（按钮亮），新段的首帧报 0（按钮灭），紧接着新段可能又报 481 —— 160ms 的
   * 动画被连续打断，看起来就是「闪一下/跳一下」。
   * 做法：切换开始的 240ms 内一律按「不显示」处理，等布局稳定后再按真实值出现。
   */
  @State private btnSuppressed: boolean = false;
  private btnTimer: number = -1;

  private suppressBtn(): void {
    this.btnSuppressed = true;
    if (this.btnTimer >= 0) {
      clearTimeout(this.btnTimer);
    }
    this.btnTimer = setTimeout(() => {
      this.btnSuppressed = false;
      this.btnTimer = -1;
    }, 240);
  }

  private topBtnShown(): boolean {
    if (this.btnSuppressed) {
      return false;
    }
    return this.listScrollY[this.mode] > TOP_BTN_THRESHOLD;
  }

  /**
   * 子列表回报滚动位置。
   *
   * **只在「是否过阈值」翻转时才写状态**：onDidScroll 是每帧回调，逐帧写 @State 会把整页
   * build()（四个 TabContent + 顶栏材质）拖进 60/120fps 的重建里，而回顶钮其实只依赖
   * 「过没过 480」这一个布尔量 —— 越线之外的所有变化都可以安全丢掉（按钮的 opacity
   * 只认这一个判断，不需要连续的滚动距离）。
   */
  private setListScrollY(idx: number, y: number): void {
    const now: boolean = y > TOP_BTN_THRESHOLD;
    const was: boolean = this.listScrollY[idx] > TOP_BTN_THRESHOLD;
    if (now === was) {
      return;
    }
    const next: number[] = this.listScrollY.slice();
    next[idx] = y;
    // 整组换成新数组：@State 观察的是「数组被整体替换」，比逐项写入可靠
    this.listScrollY = next;
  }

  /** 点回顶：只给当前模式 +1（理由见 topTick 的注释） */
  private backToTop(): void {
    const next: number[] = this.topTick.slice();
    next[this.mode] = next[this.mode] + 1;
    this.topTick = next;
  }

  /**
   * 四个模式各自「内容是否已顶到顶栏下沿」（顶栏发丝线的唯一依据）。
   *
   * 与 listScrollY 分开存，因为两者的阈值完全不同（480 vs 0.5），不能共用一次量化：
   * listScrollY 只在跨 480 时更新，中间的 300 / 100 / 1 全被丢掉，拿它判发丝线会永远
   * 读到 0；而这个数组只在一像素级的边界上翻转，数据量同样很小。
   * 按模式分开存（和 listScrollY 同理）：在「最新」里滑下去，切到还停在顶部的「热门」时
   * 线必须消失，共用一个布尔就会带着上一个 tab 的状态过去。
   */
  @State private hairOn: boolean[] = [false, false, false, false];

  /**
   * 子列表回报「是否顶到顶栏下沿」。
   *
   * 只在布尔翻转时写 @State：onScrollOffset 是每帧回调，逐帧写会让整页 build()
   * （四个 TabContent + 顶栏材质）跟着滚动帧率重建，而发丝线只认这一个布尔量。
   */
  private setListHairline(idx: number, y: number): void {
    const now: boolean = y > HAIRLINE_EPS;
    if (this.hairOn[idx] === now) {
      return;
    }
    const next: boolean[] = this.hairOn.slice();
    next[idx] = now;
    // 整组换新数组：@State 观察的是「数组被整体替换」，与 setListScrollY 同一套写法
    this.hairOn = next;
  }

  build() {
    // 顶栏是一层**压在列表上**的沉浸材质：列表内容从它下面滚过，
    // 才有东西可以被模糊/被材质透出 —— 这也是参考项目里材质顶栏能看见的前提。
    Stack({ alignContent: Alignment.TopStart }) {
      // 四种模式各用一个 TabContent：滑动切换时各自保留自己的列表与滚动位置，
      // 不像原来那样切模式要重建 url 再从头加载。
      Tabs({ barPosition: BarPosition.Start, index: this.mode, controller: this.modeCtrl }) {
        // 每个 TabContent 的直接子节点都先铺一层页面底色：
        // 切换过程中目标页的第一帧可能还没画出列表，没有底色就会露出窗口的白/黑底，
        // 那才是「闪白」的真正来源（不是过渡动画本身）。
        TabContent() {
          Column() {
            GalleryListView({
              requestUrl: EhApi.homeUrl(0),
              emptyHint: '这里没有内容，可能需要登录或更换站点',
              onOpen: (g: Gallery) => this.onOpen(g),
              topInset: this.listTopInset(),
              // 回顶三件套：开通道 → 回报偏移（下标就是这个 tab 的序号）→ 接当前模式的回顶 tick
              showTopHint: true,
              onScrollOffset: (y: number) => {
                this.setListScrollY(0, y);
                // 同一个偏移喂两处：回顶钮（480 阈值）与顶栏发丝线（0.5 阈值）
                this.setListHairline(0, y);
              },
              scrollToTopTick: this.topTick[0]
            })
          }
          .width('100%')
          .height('100%')
          .backgroundColor(this.pageBg())
        }

        TabContent() {
          Column() {
            GalleryListView({
              requestUrl: EhApi.popularUrl(0),
              emptyHint: '这里没有内容，可能需要登录或更换站点',
              onOpen: (g: Gallery) => this.onOpen(g),
              topInset: this.listTopInset(),
              showTopHint: true,
              onScrollOffset: (y: number) => {
                this.setListScrollY(1, y);
                this.setListHairline(1, y);
              },
              scrollToTopTick: this.topTick[1]
            })
          }
          .width('100%')
          .height('100%')
          .backgroundColor(this.pageBg())
        }

        TabContent() {
          Column() {
            GalleryListView({
              requestUrl: this.url,
              emptyHint: '这里没有内容，可能需要登录或更换站点',
              onOpen: (g: Gallery) => this.onOpen(g),
              topInset: this.listTopInset(),
              showTopHint: true,
              onScrollOffset: (y: number) => {
                this.setListScrollY(2, y);
                this.setListHairline(2, y);
              },
              scrollToTopTick: this.topTick[2]
            })
          }
          .width('100%')
          .height('100%')
          .backgroundColor(this.pageBg())
        }

        TabContent() {
          Column() {
            GalleryListView({
              requestUrl: EhApi.watchedUrl(0),
              emptyHint: '观看列表为空（需要登录）',
              onOpen: (g: Gallery) => this.onOpen(g),
              topInset: this.listTopInset(),
              showTopHint: true,
              onScrollOffset: (y: number) => {
                this.setListScrollY(3, y);
                this.setListHairline(3, y);
              },
              scrollToTopTick: this.topTick[3]
            })
          }
          .width('100%')
          .height('100%')
          .backgroundColor(this.pageBg())
        }
      }
      .barHeight(0)
      .scrollable(true)
      // 260ms：比底栏高亮的 220ms 略长，滑过去的尾巴更完整，不会「到点被截断」。
      // 恢复过渡动画的前提是上面每个 TabContent 都有底色 —— 否则新页首帧仍然露白。
      .animationDuration(260)
      // Tabs 自身也铺底色：内容区以外的空白帧（动画中间态）同样不会露出窗口底色
      .backgroundColor(this.pageBg())
      // bar 高度为 0 也一并把 bar 背景设透明，避免某些版本给隐藏的 bar 画一条实色带
      .barBackgroundColor(Color.Transparent)
      // 裁掉滑动中溢出的页内容，避免相邻页在动画边界处露头
      .clip(true)
      .onChange((index: number) => {
        this.mode = index;
        // 切 tab 期间抑制：四个 tab 各自的偏移不同，同一帧里按钮会被判亮又判灭
        this.suppressBtn();
        // 排行页切回来时按当前时间范围重新取一次，其余模式各自的 url 已经写在 TabContent 里
        if (index === 2) {
          this.url = EhApi.rankUrl(this.rankTl, 0);
        }
        // 排行时间 chip 现在挂在标题行右侧：mode 一变，@Watch('onModeChanged') 就驱动它
        // 淡入/淡出（160ms），这里不再需要任何显隐代码
      })
      .width('100%')
      .layoutWeight(1)

      MaterialSurface({
        surfaceHeight: this.headerHeight()
      }) {
        Column() {
          Row({ space: FLOATING_TABS_GAP }) {
            // 大标题：22 号中黑。
            // 副标题（站点名 E-Hentai / ExHentai）已删除 —— 它只重复了「当前连的是哪个站」，
            // 而这个信息在设置页与本页卡片里的域名已经出现过；删掉后标题行从两行字收回一行，
            // 顶栏也跟着矮一截（见 BAR_ROW_HEIGHT / headerHeight 的注释）。
            // layoutWeight(1)：标题是这一行的主角，先吃掉「行宽 - chip 宽」的全部余量；
            // 右侧 chip 自己有 57% 的硬上限，不会反过来把标题挤到只剩省略号。
            Text('KHenTai')
              .layoutWeight(1)
              .fontSize(FONT_TITLE)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            // 回到顶部：标题行右侧、排行 chip 的左边（顺序理由见 backToTopBtn 的注释）
            this.backToTopBtn()

            // 排行时间范围（日/月/年/总）：从「tab 行下面的第三行」搬进标题行右侧。
            // 只在排行模式出现 —— chip 是这一行的附属信息，切到「最新/热门/观看」后
            // 它没有意义，留在标题右边只会白占宽度。
            // 注意这里**没有 if**：节点始终挂载，显隐由 rankChips() 内部的
            // visibility / opacity / translate 过渡承担（见 onModeChanged 的注释）；
            // 不可见时是 Visibility.None，不占宽也不吃点击。
            this.rankChips()
          }
          .width('100%')
          .height(BAR_ROW_HEIGHT)
          .padding({ left: PAGE_PADDING, right: PAGE_PADDING })
          .alignItems(VerticalAlign.Center)
          // 标题行的实测宽度：chip 的 57% 上限从这里算（不写死，见 RANK_CHIP_MAX_RATIO）
          .onAreaChange((oldArea: Area, newArea: Area) => {
            const w: number = parseFloat(newArea.width.toString());
            if (!isNaN(w) && w > 0 && Math.abs(w - this.titleRowW) > 0.5) {
              this.titleRowW = w;
            }
          })

          // 分段胶囊：顶栏内部的第二行（不再是压在内容上的浮层）。
          // 左右 16 由这一行给足，胶囊自己 width('100%') —— 胶囊两边与标题、与卡片是同一条竖线；
          // 上下各 6（BAR_GAP）与 headerHeight() 里的两段 BAR_GAP 一一对应。
          Row() {
            // 只在本页套这一层 Stack，目的是给分段胶囊挂「白边 + 阴影」——
            // FloatingTabs 组件本身别的页也在用，不能为首页这一处的外观去改组件。
            // 宽高与胶囊完全一致（行内容宽 × 40），所以描边正好压在胶囊外圈，不多不少。
            Stack({ alignContent: Alignment.Center }) {
              FloatingTabs({
                items: MODE_LABELS,
                // 外面这层已经加了 Theme.btnEdge() 白边，组件自带的那圈 edge() 必须关掉：
                // 两条边同界，半透明白压在 15% 黑上会混成偏灰的一圈。
                edgeRing: false,
                selected: this.mode,
                onSelect: (i: number) => {
                  this.mode = i;
                  this.switchUrl();
                  this.modeCtrl.changeIndex(i);
                }
              })
              // 白边层：必须声明在 FloatingTabs **之后**（Stack 里后声明的画在上面）。
              // 为什么不给外层 Stack 自己写 .border：容器的边框先于子节点绘制，
              // 会被整块不透明的胶囊玻璃 + 它自带的 edgeRing 盖住，白边根本露不出来。
              // 这一层只有一圈边、没有底、不吃点击；也**绝不能**加 clip ——
              // 0.7 的发丝线外侧正好压在圆角裁切路径上，一裁就削掉半条（剩 0.35 等于没画）。
              Row()
                .width('100%')
                .height(FLOATING_TABS_HEIGHT)
                .borderRadius(999)
                .border({ width: 0.7, color: Theme.btnEdge() })
                .hitTestBehavior(HitTestMode.None)
                .accessibilityLevel('no-hide-descendants')
            }
            .width('100%')
            .height(FLOATING_TABS_HEIGHT)
            .borderRadius(999)
            // 阴影挂在最外层 Stack 上：它不参与裁切，阴影才能投到胶囊外面去
            .shadow(Theme.floatShadow())
          }
          .width('100%')
          .height(FLOATING_TABS_HEIGHT)
          .padding({ left: PAGE_PADDING, right: PAGE_PADDING })
          .margin({ top: BAR_GAP, bottom: BAR_GAP_BOTTOM })
        }
        .width('100%')
        .padding({ top: this.statusBar() })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .height('100%')
    // 根节点也铺底色：外层底栏切 tab 时本页可能只来得及画出一个空容器
    .backgroundColor(this.pageBg())
  }

  /**
   * 排行时间 chip 的可用宽度上限（= 标题行实测宽度 × 53%，首帧没量到时退回 320 屏的 53%）。
   *
   * 返回数值而不是在 build 里写百分比：百分比是按父容器算的，而这一排的父容器是
   * 「已经扣掉左右 16」的行内容区 —— 用百分比会再被内边距缩一次，53% 实际变成 49% 左右；
   * 更重要的是换算关系只有一处（RANK_CHIP_MAX_RATIO），将来要调只改常量。
   */
  private rankChipsMaxW(): number {
    return this.titleRowW > 0 ? this.titleRowW * RANK_CHIP_MAX_RATIO : RANK_CHIP_MAX_FALLBACK;
  }

  /**
   * 单颗 chip 的宽（实测优先；还没量到时按「字号 + 左右内边距」估）。
   *
   * **为什么把几何抽成 rankChipW() / rankChipX() / rankContentW() 三个方法**：
   * 上一版是两处各量一套 —— 色块的宽取「chip 的 onAreaChange」，这一排的宽取
   * 「Row 的 onAreaChange」，然后色块的 x 再自己写一次 `i × (chipW + gap)`。
   * 两个实测量在同一次布局里并不保证相等：一旦内容宽超过 53% 上限，Row 报上来的是
   * **被夹住**的宽（等于上限），而单颗 chip 报上来的仍是**未夹住**的本征宽 ——
   * 于是色块按本征宽算步长、容器按夹住后的宽裁边界，第 i 颗就累计多走 i 个误差，
   * 最后那颗（「总」）右缘直接越过胶囊，看起来就是「滑块跑出去了」。
   * 现在只留**一个**实测量（chip 宽），色块宽、色块 x、容器自然宽全部由它换算：
   * 三者的关系是纯算术，结构上不可能漂移，也不需要靠 clip 去掩盖。
   */
  private rankChipW(): number {
    return this.rankChipWMeasured > 0
      ? this.rankChipWMeasured
      : RANK_CHIP_FONT + RANK_CHIP_PAD_X * 2;
  }

  /**
   * 第 i 颗 chip 的左缘（相对这一排内容左缘，且**已包含胶囊内边距**）。
   *
   * 内边距是 RANK_BAR_PAD，不是 0：chip 行自己 .padding({ left: RANK_BAR_PAD, right: RANK_BAR_PAD })，
   * 色块的 position 相对的是内层 Stack（没有 padding），所以必须在这里补同一个数 ——
   * 这正是「内边距与色块共用一份常量」的意义：谁先加、加多少，只有一个来源。
   */
  private rankChipX(i: number): number {
    return RANK_BAR_PAD + i * (this.rankChipW() + RANK_CHIP_GAP);
  }

  /**
   * 这一排 chip 的自然宽 = 左右内边距 + n 颗 + (n−1) 条缝。
   *
   * 不再靠 Row 的 onAreaChange 去量：4 颗同宽，宽由 rankChipW() 给出，
   * 自然宽就是它的一次线性换算。容器宽和色块坐标因此共用同一份几何。
   * 注意 ArkUI 的 .width() 是含 padding 的边框盒：Row 钉 200 + 内边距 6×2，
   * 内容区正好 188 = 4×44 + 3×4，chip 既不被压窄也不会多出一截。
   */
  private rankContentW(): number {
    const n: number = RANK_LABELS.length;
    return RANK_BAR_PAD * 2 + n * this.rankChipW() + (n - 1) * RANK_CHIP_GAP;
  }

  /**
   * 这一排 chip 的实际宽度 = min(自然宽 200, 57% 上限)。
   *
   * 为什么要自己算这个 min：Scroll 本身不按内容收缩（它按父约束撑满），
   * 只给它 constraintSize(maxWidth) 的话，4 个 chip 只有 200 也会被摊在一个 205 的框里、
   * 左对齐，最后一项和屏幕右边距之间凭空多出 5 的空档，和下面 tab 胶囊的右缘对不齐。
   * 所以取 min：放得下就贴近右缘、放不下就正好顶在上限上并允许横滑。
   */
  private rankChipsW(): number {
    return Math.min(this.rankContentW(), this.rankChipsMaxW());
  }

  /**
   * 排行时间范围（日/月/年/总）：标题行右侧的一排紧凑 chip，垫一层沉浸材质。
   *
   * 为什么不复用 FloatingTabs：它是 40 高的胶囊 + 一块滑动的选中块，塞进 48 的标题行
   * 会把标题挤到只剩一行，胶囊上下也没有呼吸；标题行要的是「一排小 chip」而不是「一条分段栏」。
   * 但它身上有两点是对的、必须拿回来：**底下那层真材质** 和 **选中块滑过去** ——
   * 上一版把 chip 自绘成纯文字后这两点一起丢了，看起来像裸文字而不是一个控件。
   *
   * 白边 / 阴影 / 显隐（三者都落在这一组的最外层 Stack 上）：
   *   - 白边单独一层、声明在材质之后 —— 容器自己的 border 先于子节点绘制，
   *     会被整块材质玻璃和它自带的 edgeRing 盖掉，白边根本露不出来；
   *   - 阴影挂在不裁切的最外层：材质层为了圆角必须 clip，阴影写在它身上会被一起削掉；
   *   - 显隐不再用 if 增删节点，改由 rankFade / rankSlideY / rankMounted 驱动（见 onModeChanged），
   *     不可见时 Visibility.None：既不占标题行的宽度，也不吃点击。
   *
   * 为什么外面套 Scroll：4 个单字在 360 屏放得下，但窄屏分屏 / 大字体模式下会超，
   * 超了就必须能横滑 —— 直接裁掉等于让用户点不到「总」。放得下时宽度就是内容宽，
   * 外观和一排静态 chip 完全一样，看不到任何滚动痕迹。
   *
   * 为什么 @Builder 不收参数：@Builder 的值参数不会随父状态更新，把下标/选中值当参数传进来，
   * 高亮会停在第一次构建时的项上；这里只读 this（rankIndex()/rankChipW()/rankPillX），父状态一变就重算。
   */
  @Builder
  private rankChips() {
    // Stack：下层材质、上层内容。为什么整组只有**一层**材质 —— 一颗一颗套 MaterialPlane
    // 就是 4 个 Navigation 材质作用域，滑动/点选时逐帧重合成，是明确的掉帧来源
    // （搜索页语言组、历史 chip 都踩过同一个坑）；而且这 4 颗本来就该读成「一组的四个选项」，
    // 一个容器才符合这个语义。
    //
    // 父宽怎么来（材质层唯一的硬要求）：MaterialPlane 内部的 Navigation 是 width('100%')，
    // 只有父级宽度**确定**时它才解析得出、材质才建得起来；而内容层是 Scroll，它按父约束
    // 撑满、并不给出自己的内容宽。所以先把这一整块的宽钉成一个数 —— rankChipsW()
    // = min(内容自然宽, 标题行宽 53%)，Stack 与 Scroll 都用它，材质就跟着这个宽走。
    // 内容自然宽由 rankContentW() 换算（不再单独去量 Row），与色块坐标同源。
    Stack({ alignContent: Alignment.Center }) {
      MaterialPlane({
        kind: 'header',
        radius: 999,
        planeHeight: RANK_PLANE_H,
        // edge: true —— 与搜索页语言胶囊同一条发丝线：浅色模式下这块小玻璃几乎和顶栏同色，
        // 不描边就看不出「这里是一个控件」而不是标题右边的空白。
        // 外面那层已经有 0.7 的 Theme.btnEdge() 白边，这里必须关掉：
        // MaterialPlane 的描边取 Theme.edge()（浅色是黑边），两条边同界会混成偏灰的一圈。
        edge: false
      })

      Scroll() {
        // 内层 Stack 的宽钉成**内容自然宽**（不是 Scroll 的宽）：Scroll 视口被上限夹窄时，
        // 内容仍然按自己的宽排布、由 Scroll 横向滚出去，chip 不会被压窄 ——
        // 这是「色块与 chip 一定是同一份几何」的前提（见 rankChipW 的注释）。
        Stack({ alignContent: Alignment.TopStart }) {
          // 滑动色块：整组只有这一块实底。声明在 chip 行之前 —— Stack 里越靠前越在下，
          // 于是它永远压在文字下面（文字靠字色变化「亮起来」，不再自己画底）。
          // 宽 = rankChipW()、x = rankChipX(选中下标)（已含 RANK_BAR_PAD 起点），
          // 与 chip 用同一份几何（不再各算一套）—— 这是色块右缘不越胶囊的唯一保证。
          // 宽度 0 说明这一颗还没被量到（首帧 / 该 chip 尚未上屏）：**不画**，
          // 绝不在 (0,0) 画一个然后让它窜到中间（那会被读成一次选中变化）。
          if (this.rankChipWMeasured > 0) {
            Row()
              .width(this.rankChipW())
              .height(RANK_PILL_H)
              .borderRadius(999)
              .backgroundColor(Theme.accent())
              .position({ x: this.rankPillX, y: RANK_PILL_Y })
              // 不吃点击：色块与 chip 完全重叠，点在块上也要落到上层 chip 的 onClick
              .hitTestBehavior(HitTestMode.None)
          }

          // Row 钉的是「含内边距的总宽」（= rankContentW()），内边距必须与色块的 x 用的是
          // 同一个 RANK_BAR_PAD —— 上一轮滑块溢出就是两套起点各算一遍攒出来的。
          Row({ space: RANK_CHIP_GAP }) {
            // ForEach 的 (item, index) 是闭包而不是 @Builder 参数，下标每次都重新求值，
            // 所以选中态跟着 rankIndex() 走，不存在「高亮停在旧项」的问题。
            ForEach(RANK_LABELS, (label: string, i: number) => {
              Text(label)
                .fontSize(RANK_CHIP_FONT)
                .fontColor(this.rankIndex() === i ? Color.White : Theme.subText())
                .fontWeight(this.rankIndex() === i ? FontWeight.Medium : FontWeight.Normal)
                // 只给字色做缓动：色块负责「滑过去」，文字负责「亮起来」，两者分工与 FloatingTabs 一致
                .animation({ duration: RANK_PILL_ANIM, curve: Curve.Smooth })
                .height(RANK_CHIP_HEIGHT)
                .padding({ left: RANK_CHIP_PAD_X, right: RANK_CHIP_PAD_X })
                .borderRadius(999)
                // 未选中的底必须透明：底色由下面那块滑动色块统一给，chip 再画一层
                // 会在新区旧区各留一道弧线（读成「没对齐」），也会出现两块都亮着的过渡帧。
                .backgroundColor(Color.Transparent)
                .textAlign(TextAlign.Center)
                .maxLines(1)
                // 实测自己的宽：4 颗等宽，任何一颗报上来的都是同一个数（见 recordRankChipW）。
                // 刻意不写死 .width()：字体放大时 chip 要跟着长，几何再从实测值换算。
                .onAreaChange((oldArea: Area, newArea: Area) => {
                  this.recordRankChipW(parseFloat(newArea.width.toString()));
                })
                .onClick(() => {
                  // 与原来逐项点击等价：先记 tl，再按当前模式重取榜单（requestUrl 一变列表就重查）
                  if (this.rankIndex() !== i) {
                    this.rankTl = RANK_TLS[i];
                    this.url = EhApi.rankUrl(this.rankTl, 0);
                  }
                  this.moveRankPill(i);
                })
            }, (label: string, i: number) => 'rank-' + i.toString())
          }
          .width(this.rankContentW())
          .height(RANK_PLANE_H)
          .padding({ left: RANK_BAR_PAD, right: RANK_BAR_PAD })
          .alignItems(VerticalAlign.Center)
        }
        .width(this.rankContentW())
        .height(RANK_PLANE_H)
      }
      .scrollable(ScrollDirection.Horizontal)
      // 这一排只有 4 项：滚动条会盖住 chip 的下沿，而且它本来也不是「一屏长内容」
      .scrollBar(BarState.Off)
      .height(RANK_PLANE_H)
      .width(this.rankChipsW())
      // 裁切放在 Scroll 上而不是外层 Stack：横滑时两端的 chip 会滚出胶囊边界，只裁内容即可；
      // 外层若也 clip，材质自带的那圈描边外侧会被削掉半条（边会看着断）。
      // 窄屏被 min() 夹窄时，色块与 chip 在同一个内层 Stack 里，因此是**一起**被这条 clip 裁掉的，
      // 不存在色块单独溢出到胶囊外一截的情况（色块从不单独设 clip 或更宽的容器）。
      .clip(true)

      // 白边层：声明在材质与内容**之后**（Stack 里后声明的画在上面），
      // 这样 0.7 的白边不会被材质玻璃和它自带的 edgeRing 盖住。
      // 这一层只有一圈边、没有底、不吃点击，也不裁切 —— 边正好落在圆角上，
      // 一裁就只剩半条发丝线（MaterialPlane 的 edgeRing 是同一个理由）。
      Row()
        .width('100%')
        .height(RANK_PLANE_H)
        .borderRadius(999)
        .border({ width: 0.7, color: Theme.btnEdge() })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no-hide-descendants')
    }
    .height(RANK_PLANE_H)
    .width(this.rankChipsW())
    .borderRadius(999)
    // 阴影挂在这个不裁切的外层：材质层自己被裁了圆角，阴影写在它身上会被一起削掉
    .shadow(Theme.floatShadow())
    // 显隐：始终挂载，靠 visibility + opacity + translate 做进入/离开过渡（见 onModeChanged）。
    // 不可见时是 Visibility.None —— 不参与布局（不占宽度、不挤标题）也不吃点击；
    // 过渡期间仍是 Visible（否则没有起点可淡），这 160ms 里它照常占宽，
    // 但标题是左对齐的单行文字，宽度的收回/让出不会让标题跳动。
    .visibility(this.rankMounted ? Visibility.Visible : Visibility.None)
    .opacity(this.rankFade)
    .translate({ y: this.rankSlideY })
  }

  /**
   * 记录一颗 chip 的实测宽，并把滑动色块**直接**落到位。
   *
   * 为什么可以用「索引 × 等宽」定位：这 4 颗是单字（日/月/年/总），字号、左右内边距、
   * 行高全都相同，宽度必然相等；Row 的 space 也是定值 RANK_CHIP_GAP。
   * 于是第 i 颗的左缘 = rankChipX(i)，只需要一个实测值，不用像搜索页语言组那样
   * 逐颗累加（那边六个标签宽度不等，必须全量重算）。
   *
   * 为什么这里**不** animateTo：这是布局实测（首帧 / 字体缩放 / 分屏），不是用户切换；
   * 让色块从旧坐标滑过来会被读成一次选中变化，首帧更会看到它从左边缘窜到中间。
   * 值没变就直接返回 —— onAreaChange 每帧重排都会回调，不比较会自己把自己再触发一轮。
   */
  private recordRankChipW(w: number): void {
    if (isNaN(w) || w <= 0 || Math.abs(w - this.rankChipWMeasured) < 0.5) {
      return;
    }
    this.rankChipWMeasured = w;
    this.rankPillX = this.rankChipX(this.rankIndex());
  }

  /**
   * 用户点选某一颗：色块滑过去（160 / Smooth）。
   *
   * 宽度还没量到就不动 —— 等 recordRankChipW 落位；色块此时根本不存在，
   * 这里写一个 0 只会让它在出现的第一帧落在最左端。
   */
  private moveRankPill(idx: number): void {
    if (!(this.rankChipWMeasured > 0)) {
      return;
    }
    const x: number = this.rankChipX(idx);
    if (Math.abs(x - this.rankPillX) < 0.5) {
      return;
    }
    animateTo({ duration: RANK_PILL_ANIM, curve: Curve.Smooth }, () => {
      this.rankPillX = x;
    });
  }

  private switchUrl(): void {
    if (this.mode === 0) {
      this.url = EhApi.homeUrl(0);
    } else if (this.mode === 1) {
      this.url = EhApi.popularUrl(0);
    } else if (this.mode === 2) {
      this.url = EhApi.rankUrl(this.rankTl, 0);
    } else {
      this.url = EhApi.watchedUrl(0);
    }
  }
}
