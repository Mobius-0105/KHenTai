import { Gallery } from '../core/Models';
import { Theme } from '../core/Theme';
import { MaterialSurface } from '../components/MaterialSurface';
import { MaterialPlane } from '../components/MaterialPlane';
import { FloatingTabs, FLOATING_TABS_HEIGHT } from '../components/FloatingTabs';
import { ArchivePage } from './ArchivePage';
import { DownloadsPage, DlBulkPills } from './DownloadsPage';
import { FavoritesPage } from './FavoritesPage';
import { HistoryPage } from './HistoryPage';

/**
 * 页面数值。
 * 工程里还没有 core/Tokens.ets，按 docs/V2-UI-SPEC.md 的令牌表取字面量：
 * SPACE_LG 16（页面左右边距）/ RADIUS_MD 12 / RADIUS_ROUND 999。
 */
/**
 * 标题行 48（TITLE_BAR_HEIGHT）—— 分段行在它下面一行，高度由 headerHeight() 统一算。
 *
 * 为什么从 56 收到 48：原来那 56 是留给「标题 22 + 副标题 11」两行字的（行间还要塞 1 的
 * Column space）。副标题删掉后只剩一行 22 号字，再留 56 就是标题上下各空 17，顶栏看着发虚；
 * 48 让标题在一行里仍然居中、上下各 13，既贴住状态栏又不顶边。
 */
const BAR_ROW_HEIGHT: number = 48;
const PAGE_PADDING: number = 16;
const FONT_TITLE: number = 22;    // FONT_SIZE_H2
const FONT_CAPTION: number = 12;  // FONT_SIZE_CAPTION
/** 顶栏动作之间的横向间距（与搜索页顶栏「筛选 / 清空」同一口径：SPACE_SM 8） */
const GAP_SM: number = 8;
/**
 * 标题行与分段行、分段行与下方内容之间的纵向间距：6。
 *
 * 为什么单独定义一个 6，而不继续用 FloatingTabs 导出的 FLOATING_TABS_GAP(8)：
 * 那个 8 是**分段组件自己的**间距口径，别的页（排行页等）还在用；这里要的是本页顶栏
 * 收紧后的排版值。两者绑定的话，改任意一处都会把另一处带歪。副标题删掉之后顶栏本来就
 * 矮了一截，间距再留 8 会让「标题 - 分段 - 内容」三段之间的空隙显得比文字本身还重。
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
 * 顶栏「清空」胶囊：与搜索页顶栏的「清空」完全同尺寸（60×32、全圆角、header 材质）。
 * 宽度必须写死 —— MaterialPlane 内部是 width('100%')，父宽不确定时材质作用域建不起来
 * （见 SearchPage 里那段踩坑注释）；高度 32 也让胶囊在 48 的标题行里垂直居中不顶边。
 */
const CLEAR_PILL_W: number = 60;
const CLEAR_PILL_H: number = 32;
const CLEAR_PILL_RADIUS: number = 999;

/** 顶栏「回到顶部」圆钮：32×32，与「清空」同高同档（理由见 HomePage 的 TOP_BTN_SIZE） */
const TOP_BTN_SIZE: number = 32;
/** 滚动过 480 才出现：与首页 / 搜索页 / 详情页同一个阈值，同一条线同一套手感 */
const TOP_BTN_THRESHOLD: number = 480;
/** 显隐 160 / Smooth：与顶栏其它轻量反馈同档 */
/**
 * 回顶钮的进出动画时长（ms）。
 *
 * 从 160 提到 200：160 与「顶栏其它小控件」同一档，但这颗钮做的事是「从上方滑入」，
 * 位移 8，速度一样时会显得急；200 + Friction 才像「贴上来」而不是「弹出来」。
 */
const TOP_BTN_ANIM: number = 200;
/** 不可见时下沉 4，出现时抬到 0（只做一点点位移，别抢标题的注意力） */
/**
 * 隐藏时向下偏移的位移（vp）。
 *
 * 4 太轻，160ms 内几乎看不出是「滑下来」还是「淡下去」；8 才读得出方向。
 * 注意方向是**从上往下沉**（隐藏时 y>0），符合「往上滑出、露出来」的直觉。
 */
const TOP_BTN_SHIFT: number = 8;

/** 显隐动画：出现 220ms（与分段器文字渐变同长），消失 160ms（收尾要快，不能拖住顶栏） */
const CLEAR_ANIM_IN_MS: number = 220;
const CLEAR_ANIM_OUT_MS: number = 160;
/** 出现时的起始缩放：0.92 小一点起，落到 1 时有一点「弹上来」的量感，但不夸张 */
const CLEAR_SCALE_FROM: number = 0.92;

/**
 * 四段文案：顺序与下面 TabContent 的声明顺序**必须一一对应**。
 *
 * 为什么「存档」插在「收藏」紧右边（下标 1）：两者都是「用户主动留下来的东西」，
 * 语义最近，放一起用户找的时候不用横跨整条分段器；下载是「批量存到本地」、
 * 历史是「看过自动记」，都属于「被动/另一层级的记录」，排在后面。
 *
 * 代价：历史页的下标从 2 变成 3 —— 本页所有写死的下标（见 wantClearPill）都要跟着改，
 * 否则「清空」胶囊会跑到存档段上去。
 */
const SEG_LABELS: string[] = ['收藏', '存档', '下载', '历史'];

/**
 * 「下载」段的下标：批量操作胶囊（全部继续 / 全部暂停）只在它出现。
 *
 * 单独起名而不是在 if 里写 2：SEG_LABELS 再加段时，凡是写死数字的地方都要跟着改，
 * 起个名字至少让 grep 一次找全（现在只有这里和 wantClearPill 里的 3）。
 */
const SEG_DOWNLOAD: number = 2;

/**
 * 「媒体库」：把收藏 / 存档 / 下载 / 历史合并成一个 tab。
 *
 * 为什么合并：底栏原来 6 个 tab（首页/搜索/收藏/历史/下载/设置），胶囊在 360vp 宽下每个
 * 只剩 50 出头，文字挤、点击区小于 44vp 的最小触控尺寸，误触率高。这些页面本质都是
 * 「我存下来的东西」，合并后底栏回到 4 项，符合鸿蒙底栏 3~5 项的惯例。
 *
 * 版式与首页对齐：顶部是一条固定沉浸材质顶栏（标题行 48 + 6 + 分段行 40 + 6），
 * 分段胶囊就在顶栏内部；四段内容**整屏铺开、从屏幕顶端开始排**，滚动时从材质顶栏背后穿过。
 * 四个子页用 `embedded: true` 关掉各自的页头，页头只在这里定义一次，
 * 四段的标题栏高度就不会各写一套；顶栏高度也由本页算好传给子页当 topInset。
 *
 * 分段数量与顶栏高度**无关**：headerHeight() 只加「标题行 + 分段行」两段固定高度，
 * 分段器内部按 SEG_LABELS.length 等分宽度（见 FloatingTabs.itemW），所以加一段不会改这里。
 */
@Component
export struct LibraryPage {
  onOpen: (g: Gallery) => void = (g: Gallery): void => {};
  onOpenLocal: (g: Gallery) => void = (g: Gallery): void => {};
  onGotoSettings: () => void = (): void => {};
  /**
   * 存档页空态里「去首页看看」的落点。
   *
   * 为什么是普通成员而不是本页自己切段：切到「收藏」段并不等于回首页（首页是底栏另一个 tab），
   * 本页拿不到 Index 的 tab 状态与 TabsController，只能由上层注入。
   * 没注入时它是空实现 —— 按钮点了不会跳（Index 需要补一行 onGotoHome，见交付说明）。
   */
  onGotoHome: () => void = (): void => {};

  /**
   * 当前分段。挂 @Watch 是因为顶栏「清空」胶囊的显隐同时取决于「是不是历史页」，
   * 切段和「历史记录数变为 0」是两条互不相关的触发路径，必须汇到同一个开关函数里。
   */
  @State @Watch('onClearPillState') private seg: number = 0;
  /** 内层 Tabs 用：点分段器或左右滑动都走它，两边状态同源 */
  private ctrl: TabsController = new TabsController();

  /**
   * 主题订阅位。
   *
   * Theme.bg()/card() 内部读 Prefs（不可观测），只写 Theme.xxx() 的节点在切主题时
   * 不会被标记重绘；订阅 Theme.refresh() 写入的 'themeDark' 后本页才会整体换色。
   */
  @StorageProp('themeDark') private themeDark: boolean = false;

  /**
   * ================= 顶栏「清空」胶囊的状态（为什么走 AppStorage） =================
   *
   * 这一颗按钮画在 LibraryPage 的顶栏里，但它要展示的事实与要执行的动作都属于 HistoryPage，
   * 两边各持一半，所以用 AppStorage 做**单一事实来源**，涉及三个键：
   *
   *   historyCount   number   历史记录条数。子页写、本页读 → 决定胶囊显不显示。
   *   historyArmed   boolean  历史页是否已进入「确认」这一步（子页的 confirmClear 镜像）。
   *                           本页读它，把胶囊文案在「清空 / 确认」之间切换。
   *   historyClearReq number  点击信号，自增计数。本页写、子页读 → 子页据此执行原有清空流程。
   *
   * 为什么不用 `@Prop onClearReady: (can) => void` 这类回调（上一轮考虑过，最后否掉）：
   *   1. TabContent 是**按需创建**的。用户没进过历史页时子页实例根本不存在，回调无从发出；
   *      而本页此时需要的是一个「现在就告诉我有没有记录」的**可读值**，不是一次事件。
   *      计数放在 AppStorage 里，实例没建时它就是 0，正好等于「不显示」。
   *   2. 回调是**一次性事件**，错过就永远补不回来（子页被重建、切主题触发材质重建都会重跑
   *      初始化）；AppStorage 是持久状态，实例重建后天然重放，不需要谁去补一发。
   *   3. 函数只能挂普通成员（@Prop 不收函数签名），父级重建时普通成员不保证重新赋值，
   *      闭包容易指到旧实例；@StorageProp/@StorageLink 是声明式的，没有悬空引用。
   *   4. 反方向（本页 -> 子页）也走同一个通道：本页拿不到子页实例的私有方法，与其让父级
   *      重写一遍「确认 + 清理 + 刷新」，不如只发一个自增信号，流程仍由子页唯一实现。
   */
  @StorageProp('historyCount') @Watch('onClearPillState') private historyCount: number = 0;
  @StorageProp('historyArmed') private historyArmed: boolean = false;
  /** 自增计数而不是布尔：清零后第二次点击必须还能被 @Watch 识别成「又变了一次」 */
  @StorageLink('historyClearReq') private clearReq: number = 0;

  /**
   * 胶囊是否已挂载。显隐动画必须「挂载 → 播入场」两步走，
   * 所以它和下面两个动画值分开存：clearShown 决定节点在不在，opacity/scale 决定画成什么样。
   */
  @State private clearShown: boolean = false;
  @State private clearOpacity: number = 0;
  @State private clearScale: number = CLEAR_SCALE_FROM;

  /**
   * ================= 顶栏「回到顶部」的数据通道（为什么走 AppStorage） =================
   *
   * 这一页和搜索页不同：**本页自己没有列表**。四个分段各自是独立组件
   * （FavoritesPage / ArchivePage / DownloadsPage / HistoryPage），滚动容器、Scroller
   * 全在它们内部；父组件拿不到子组件实例，既读不到「滚了多远」，也调不动「滚回 0」。
   * 所以走一条显式的 AppStorage 通道，与顶栏「清空」（historyCount / historyClearReq）
   * 完全同一个套路：
   *
   *   libraryScrollY  number  当前分段列表的滚动偏移（vp，「离顶部多远」）。子页写、本页读
   *                           → 决定这颗钮显不显示。
   *   libraryTopTick  number  自增回顶信号。本页写、子页读 → 子页把它透传给列表的
   *                           scrollToTopTick（那个 @Prop 的 @Watch 会执行 scrollTo(0)）。
   *
   * 子页要接上这条通道只需要两处（**本次改动范围不含那四个文件**）：
   *   1. 给自己的列表传 showTopHint: true 与
   *      onScrollOffset: (y: number) => AppStorage.setOrCreate<number>('libraryScrollY', y)；
   *   2. 把 libraryTopTick 透传成列表的 scrollToTopTick。
   * 在子页接上之前这两个键一直是 0，这颗钮**不会出现** —— 宁可暂时不显示，
   * 也不做一颗「浮出来了却滚不动」的假按钮。
   *
   * 为什么不用 @Prop 回调：TabContent 是按需创建的，没进过某个分段时它的实例根本不存在，
   * 回调无从发出；AppStorage 是持久状态，实例建好后天然重放（与 historyCount 同一结论）。
   */
  /**
   * **每段一个键**：libraryScrollY0..3（收藏/存档/下载/历史）。
   *
   * 之前所有分段共用一个 `libraryScrollY`，切段时要么归零（会让「本来就滚过的分段」
   * 按钮消失）、要么不归零（会让「在顶部的分段」按钮亮着）—— 两种情况都注定错一半，
   * 因为一个变量表达不了「四段各自的滚动位置」。
   * 现在按段分开存，按钮只看当前段的那个值，与首页四个 tab 的做法一致。
   */
  @StorageProp('libraryScrollY0') private sy0: number = 0;
  @StorageProp('libraryScrollY1') private sy1: number = 0;
  @StorageProp('libraryScrollY2') private sy2: number = 0;
  @StorageProp('libraryScrollY3') private sy3: number = 0;
  /**
   * 每段各一个「内容是否已经顶到顶栏下沿」的布尔（顶栏发丝线的唯一依据）。
   *
   * 为什么不复用上面那组 libraryScrollY0..3：子页上报的是**量化后**的值
   * （> 480 时写 481，否则写 0），0.5vp 这一档在那边就被折成 0 了，拿它判发丝线
   * 永远得到 false。所以再开一组只承载「过没过 0.5」的布尔，同样是子页只在翻转时写一次。
   *
   * 每段一个键的理由与 sy0..3 相同：切段时不能带着上一段的状态过去。
   */
  @StorageProp('libraryHair0') private hair0: boolean = false;
  @StorageProp('libraryHair1') private hair1: boolean = false;
  @StorageProp('libraryHair2') private hair2: boolean = false;
  @StorageProp('libraryHair3') private hair3: boolean = false;
  @StorageLink('libraryTopTick') private libraryTopTick: number = 0;

  private statusBar(): number {
    const v: number | undefined = AppStorage.get<number>('statusBarHeight');
    return v === undefined ? 0 : v;
  }

  /**
   * 胶囊此刻是否该在位：历史页 + 确实有记录（两条都满足才出现）。
   *
   * 下标 3 是「历史」在 SEG_LABELS 里的位置（收藏 0 / 存档 1 / 下载 2 / 历史 3）。
   * 这里原来写的是 2 —— 插入「存档」后若不改，胶囊会挂在下载段上，
   * 且历史段里永远看不到「清空」。以后再加段仍然只需要改这一个常量。
   */
  private wantClearPill(): boolean {
    return this.seg === 3 && this.historyCount > 0;
  }

  /**
   * 显隐开关。seg 与 historyCount 变化都会调到这里，两条路径归一，避免「切了段但计数没变」
   * 这类组合下漏判。
   */
  private onClearPillState(): void {
    if (this.wantClearPill()) {
      this.showClearPill();
    } else {
      this.hideClearPill();
    }
  }

  private showClearPill(): void {
    if (!this.clearShown) {
      // 先摆回起始态再挂载：节点第一帧就是「透明 + 缩小」，入场动画才有起点可插值
      this.clearOpacity = 0;
      this.clearScale = CLEAR_SCALE_FROM;
      this.clearShown = true;
      // 真正的入场动画写在胶囊自己的 onAppear 里 —— 挂载和改透明度放在同一帧的话，
      // ArkUI 会把两次状态写入合并，新节点直接以「终态」建成，看不到淡入。
      return;
    }
    // 已在退场动画中途又被要求显示（记录刚清完又写回来）：补一段入场，别停在半透明
    animateTo({ duration: CLEAR_ANIM_IN_MS, curve: Curve.Smooth }, () => {
      this.clearOpacity = 1;
      this.clearScale = 1;
    });
  }

  private hideClearPill(): void {
    if (!this.clearShown) {
      return;
    }
    animateTo({
      duration: CLEAR_ANIM_OUT_MS,
      curve: Curve.Smooth,
      // 卸载必须等动画走完：在 animateTo 的闭包里直接置 clearShown=false 会把节点立刻摘掉，
      // 淡出根本画不出来。onFinish 里再判一次目标态，防止这段时间又切回历史页导致误卸载。
      onFinish: () => {
        if (!this.wantClearPill()) {
          this.clearShown = false;
        }
      }
    }, () => {
      this.clearOpacity = 0;
      this.clearScale = CLEAR_SCALE_FROM;
    });
  }

  /**
   * 页面底色。
   *
   * 两个分支同色：读 themeDark 的目的是让 build() 与 AppStorage 建立依赖，
   * 取色规则仍统一交给 Theme（不在这里引入第二套色板）。
   */
  private pageBg(): string {
    if (this.themeDark) {
      return Theme.bg();
    }
    return Theme.bg();
  }

  /**
   * 固定头部高度（含状态栏）：状态栏 + 标题行 48 + 6 + 分段行 40 + 6。
   *
   * 分段胶囊从「浮在内容上的独立层」改回顶栏内部的第二行，顶栏就要把它算进高度。
   * 本方法同时是**顶栏高度对子页的唯一来源**：build() 把它原样传给四个子页
   * （FavoritesPage / ArchivePage / DownloadsPage / HistoryPage 的 headerHeight），子页再自己加呼吸。
   * 分工是「这里决定顶栏画多高，子页决定列表从哪儿开始排」——
   * 子页再自己拼一遍状态栏 + 标题行 + 分段行就会两处各算一次，改一个数值就错位。
   *
   * 副标题（原来那行「收藏 · 存档 · 下载 · 历史」）删掉后，这里**整段减去**了它占的
   * line height（约 15）与两侧 8：顶栏从「状态栏 + 112」收到「状态栏 + 100」。
   * 子页拿的是本方法的返回值，不是写死的数，所以四个子页的 contentStartOffset 自动跟着变。
   *
   * 注意：这个高度**不含分段数量**（40 是分段行本身的高度，里面几项都占这 40），
   * 所以从 3 段加到 4 段不需要改这里；子页的 contentStartOffset 也跟着不用动。
   */
  private headerHeight(): number {
    return this.statusBar() + BAR_ROW_HEIGHT
      + BAR_GAP + FLOATING_TABS_HEIGHT + BAR_GAP_BOTTOM;
  }

  /** 当前分段的列表是否已滑过阈值（决定回顶钮显隐） */
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
    const y: number = this.seg === 0 ? this.sy0
      : (this.seg === 1 ? this.sy1 : (this.seg === SEG_DOWNLOAD ? this.sy2 : this.sy3));
    return y > TOP_BTN_THRESHOLD;
  }

  /**
   * 顶栏发丝线是否显示 = 当前分段的内容是否已顶到顶栏下沿。
   *
   * 抽成方法而不是在 build 里照抄一遍三元链：topBtnShown() 已经有一份同样的「按段取值」，
   * 两处写岔就会出现「线在 A 段亮、按钮按 B 段判」的错位。
   */
  private topHairline(): boolean {
    if (this.seg === 0) {
      return this.hair0;
    }
    if (this.seg === 1) {
      return this.hair1;
    }
    return this.seg === SEG_DOWNLOAD ? this.hair2 : this.hair3;
  }

  /**
   * 点回顶：只 +1 发信号。
   *
   * 为什么是自增计数而不是布尔量：@Prop / @StorageLink 的 @Watch 只认「值变了」，
   * 布尔量连点两次第二次收不到；计数每次都变，子页每次都能收到一次「滚回顶部」。
   */
  private backToTop(): void {
    this.libraryTopTick = this.libraryTopTick + 1;
  }

  /**
   * 顶栏「回到顶部」圆钮：标题行右侧，「清空」的左边。
   *
   * 为什么在左边：「清空」是行尾的破坏性动作（贴内容右边距 16，位置不能动），
   * 回顶是辅助动作，顺着往左排；行内没有 space，「清空」自己带 margin-left 8，
   * 所以这颗只需要紧挨着它、不用再加缝（否则会变成 16，比「清空」自己的 8 更宽）。
   *
   * 显隐不用 if 增删节点：始终挂载，只改 opacity / translate，160ms 才有过渡落点。
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
    // 白边 + 接触阴影画在这层不裁切的 Stack 上（材质自己 clip 圆角，画在裁切路径上会被削半条），
    // 与「清空」同一份 Theme.btnEdge / Theme.floatShadow，同排才是同一种控件。
    .border({ width: 0.7, color: Theme.btnEdge() })
    .shadow(Theme.floatShadow())
    .opacity(this.topBtnShown() ? 1 : 0)
    .translate({ y: this.topBtnShown() ? 0 : TOP_BTN_SHIFT })
    .animation({ duration: TOP_BTN_ANIM, curve: Curve.Friction })
    // **不可见时必须关掉命中测试**：opacity 0 的节点照样占位、照样吃点击，
    // 顶栏右上角会留一块「透明但点得到」的死区，点下去还会发一次回顶信号（鬼按钮）。
    // 可见时用 Transparent：贴在顶栏上的横滑手势仍要能穿透这一颗。
    .hitTestBehavior(this.topBtnShown() ? HitTestMode.Transparent : HitTestMode.None)
    .onClick(() => this.backToTop())
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 内容层：**整屏高、不设 top padding**。
      // 为什么这一版能彻底去掉让位：四个子页各自的顶部固定行都已经处理好了自己的归属
      //   - 收藏页：分类横条常驻在顶栏下沿（子页内的 Stack 层），列表 topInset 多让出 36；
      //   - 存档页：没有固定行（只有网格），topInset 就是顶栏 + 4；
      //   - 下载页：批量操作（全部继续 / 全部暂停）也提到本页顶栏标题行右侧，
      //     列表首项只剩仅 Wi-Fi 卡 56，随内容滚走；
      //   - 历史页：列表干净了（原来那条「清空」动作行已提到本页顶栏右上角，见下方胶囊）。
      // 于是「顶栏多高」由子页的 topInset 一处生效，外层再把整块下移就等于让位两次
      // （顶栏下面空一条 + 内容永远进不到材质背后），材质背后只剩固定底色。
      Column() {
        // 段内容用内层 Tabs：横向滑动就能在 收藏/存档/下载/历史 之间切换。
        // 系统段控件本身不能滑动，所以把 Tabs 的 bar 高度设为 0 藏起来，
        // 视觉由顶栏里的分段胶囊（FloatingTabs）承担，两边用 ctrl 同步同一个下标。
        Tabs({ barPosition: BarPosition.Start, index: this.seg, controller: this.ctrl }) {
          // 每个 TabContent 的直接子节点先包一层带底色的容器：
          // 切段时目标子页的第一帧可能还没取到数据，没有底色就会露出窗口的白/黑底
          // ——「闪白」来自这一帧空底，不是过渡动画。
          TabContent() {
            Column() {
              FavoritesPage({
                onOpen: (g: Gallery) => this.onOpen(g),
                onGotoSettings: () => this.onGotoSettings(),
                embedded: true,
                // 顶栏高度只由本页算一次，子页拿去当列表的 topInset 基数
                headerHeight: this.headerHeight()
              })
            }
            .width('100%')
            .height('100%')
            .backgroundColor(this.pageBg())
          }

          // 第 2 段：存档（紧挨收藏，理由见 SEG_LABELS 的注释）。
          // TabContent 的声明顺序 = 分段器下标顺序，插在这里就等于插在「收藏」右边。
          TabContent() {
            Column() {
              ArchivePage({
                onOpen: (g: Gallery) => this.onOpen(g),
                onGotoHome: () => this.onGotoHome(),
                embedded: true,
                headerHeight: this.headerHeight()
              })
            }
            .width('100%')
            .height('100%')
            .backgroundColor(this.pageBg())
          }

          TabContent() {
            Column() {
              DownloadsPage({
                onOpenLocal: (g: Gallery) => this.onOpenLocal(g),
                embedded: true,
                headerHeight: this.headerHeight()
              })
            }
            .width('100%')
            .height('100%')
            .backgroundColor(this.pageBg())
          }

          // 第 4 段：历史。下标 3 是顶栏「清空」胶囊的判定依据（wantClearPill），
          // 再往前插段时必须同步改那个数字。
          TabContent() {
            Column() {
              HistoryPage({
                onOpen: (g: Gallery) => this.onOpen(g),
                embedded: true,
                headerHeight: this.headerHeight()
              })
            }
            .width('100%')
            .height('100%')
            .backgroundColor(this.pageBg())
          }
        }
        .barHeight(0)
        .scrollable(true)
        // 260ms：比分段高亮的 180ms 略长，滑动手感连续、落位后还有一点收尾
        .animationDuration(260)
        // Tabs 自身也铺底色，动画中间态不会露出窗口底色
        .backgroundColor(this.pageBg())
        // bar 高度为 0 时也把 bar 背景设透明，避免个别版本给隐藏的 bar 画实色带
        .barBackgroundColor(Color.Transparent)
        // 裁掉滑动中溢出的相邻段内容
        .clip(true)
        .onChange((index: number) => {
          this.seg = index;
          // 切段期间抑制回顶钮：旧段/新段的偏移会在同一帧里来回翻转，动画会被打断成「跳动」
          this.suppressBtn();
          // 这里**不再**把 libraryScrollY 归零。
          //
          // 之前归零是为了「在收藏里滑下去、切到存档（明明在顶部）时按钮不亮」；
          // 但归零与子页的「可见时补报」存在竞态：两个分段都滚过阈值时，
          // 新分段可见 → 报 481，紧接着这里归零 → 按钮消失（切一次就不见了）。
          // 现在把「当前分段是否滚过阈值」完全交给**可见的子页自己上报**：
          // 它在 onVisibleAreaChange 里读自己的滚动位置，顶部就是 0、滚过就是 481，
          // 不存在两个来源互相覆盖。
        })
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      // 这里刻意**没有** top padding：内容层从屏幕顶端（状态栏下面）开始铺，整屏高。
      // 顶部让位改由四个子页各自的 topInset 承担（见上面文件头注释）。
      // 底部同样不补留白：子页已把 contentEndOffset 设成 galleryBottomInset()，
      // 列表视口保持整屏高，卡片才能从底栏下面穿过去；这里再加一段就是双份空白。

      // 顶栏叠层：整块 Column 只占顶栏高度，靠 zIndex 压在内容之上。
      // 为什么套一层 Column 而不是直接给 MaterialSurface 写 zIndex：自定义组件的
      // 通用属性要挂在外层容器上才稳（也要避免把属性写到 @Builder 声明区后面）。
      // 语义是「这一层永远在内容之上」——以后有人在顶栏之后再插 toast / 提示条，
      // 也不会把它压下去。
      Column() {
        // hairline 按需：只有当前分段的内容顶到顶栏下沿时才画那条 0.5vp 灰线
        MaterialSurface({
          surfaceHeight: this.headerHeight()
        }) {
          Column() {
            Row() {
              // 标题直接挂在行上（不再套一层 Column 放副标题）：
              // 副标题「收藏 · 存档 · 下载 · 历史」只是把下面四个分段的名字又念了一遍，
              // 分段胶囊就在正下方，信息完全重复，还白占了顶栏一行高度。
              // 删掉后 Column 只剩一个子节点，留着等于给布局多一层无意义的包裹，
              // 所以连 Column 一起去掉，让 Text 自己吃 layoutWeight —— 右侧「清空」的
              // 定位规则不变（标题先吃满剩余宽度，胶囊固定 60 宽）。
              Text('媒体库')
                .fontSize(FONT_TITLE)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.text())
                .maxLines(1)
                .layoutWeight(1)

              // 回到顶部：插在「清空」左边（位置理由见 backToTopBtn 的注释）
              this.backToTopBtn()

              // 顶栏右上角的「清空」：只在历史段且库里还有记录时出现。
              // 位置与搜索页顶栏按钮同口径 —— 行尾（right padding 16 贴住内容右边线），
              // 与左侧标题列之间留 8；标题列 layoutWeight(1) 会先吃满剩余宽度，
              // 胶囊宽度固定 60，所以不会压到标题（「媒体库」三字远小于可用宽度）。
              //
              // 材质用 MaterialPlane（真布局节点）而不是 backgroundBlurStyle：
              // 系统材质只在真实参与布局的节点上才创建，塞进 .background(builder) 会是全透明的。
              if (this.clearShown) {
                Stack({ alignContent: Alignment.Center }) {
                  // edge: true —— 与搜索页顶栏的「清空」同一颗东西（同宽同高同色），
                  // 那边有了边、这边没有，切 tab 时会看出两页的按钮不是一套。
                  MaterialPlane({
                    kind: 'header',
                    radius: CLEAR_PILL_RADIUS,
                    planeHeight: CLEAR_PILL_H,
                    // 白边已在外层 Stack 上（0.7 的 Theme.btnEdge），这里关掉材质自带的
                    // Theme.edge()，否则两条同界细线会混成偏灰的一圈。
                    edge: false
                  })
                  // 文案读的是子页镜像过来的确认态：第一下「清空」进入待确认，第二下「确认」才真清。
                  Text(this.historyArmed ? '确认' : '清空')
                    .width('100%')
                    .height(CLEAR_PILL_H)
                    .fontSize(FONT_CAPTION)
                    // 字色：次要色（灰）。
                    //
                    // 曾经取 Theme.accent()，理由是「清空」出现即代表可执行，语义等价于搜索页筛选的
                    // 「有条件态」。但这里是媒体库顶栏，右侧同时还挂着分段胶囊，主色字会把「清空」读成
                    // 与分段同级的**主操作**；而它其实是低频破坏性动作（还要再点一次「确认」）。
                    // 取灰之后它退回次要层级，破坏性动作也不该抢第一眼注意力。
                    .fontColor(Theme.subText())
                    .fontWeight(FontWeight.Medium)
                    .textAlign(TextAlign.Center)
                    .maxLines(1)
                }
                .width(CLEAR_PILL_W)
                .height(CLEAR_PILL_H)
                // 白边 + 接触阴影：MaterialPlane 的 edge 只在材质内部勾一圈，压在半透明顶栏上
                // 边界仍偏软；外面再补一条 0.7 的白发丝边和一个大半径淡阴影，胶囊才真正「浮起来」，
                // 也和搜索页顶栏那两颗按钮（筛选 / 清空）保持同一套边缘语言。
                // borderRadius 只用来给「边框和阴影」定形状 —— 圆角矩形是按节点轮廓画的，
                // 不补它的话白边会是一个直角矩形框在胶囊外面。
                .borderRadius(CLEAR_PILL_RADIUS)
                .border({ width: 0.7, color: Theme.btnEdge() })
                .shadow(Theme.floatShadow())
                .margin({ left: GAP_SM })
                .opacity(this.clearOpacity)
                .scale({ x: this.clearScale, y: this.clearScale })
                // 入场：节点已经挂载、第一帧以 0 / 0.92 画出来之后才起动画
                .onAppear(() => {
                  animateTo({ duration: CLEAR_ANIM_IN_MS, curve: Curve.Smooth }, () => {
                    this.clearOpacity = 1;
                    this.clearScale = 1;
                  });
                })
                // 这里**只发信号**：确认两步、Db.clearHistory、列表刷新全部留在 HistoryPage，
                // 父级重写一遍就会出现「两处各自实现一套清空流程」的漂移。
                .onClick(() => {
                  this.clearReq = this.clearReq + 1;
                })
              }

              // 下载段的批量操作：下载子页在嵌入模式下没有自己的页头（顶栏只在本页定义一次），
              // 它那两颗「全部继续 / 全部暂停」只能挂到这块标题行右侧 —— 与上面历史段的「清空」
              // 同一个位置、同一套边缘语言，用户的肌肉记忆不会因为换了一段就失效。
              //
              // 组件自己订阅 Downloader：TabContent 按需创建，用户没进过下载段时子页实例还不存在，
              // 若让子页把状态推上来，本页就得不到「有没有任务」这个事实。
              // 外层套 Row 是为了把左边距定住 —— 自定义组件上不挂通用属性，
              // 与上面「清空」胶囊的 margin 口径一致（GAP_SM 8）。
              if (this.seg === SEG_DOWNLOAD) {
                Row() {
                  DlBulkPills()
                }
                .height(CLEAR_PILL_H)
                .alignItems(VerticalAlign.Center)
                .margin({ left: GAP_SM })
              }
            }
            .width('100%')
            .height(BAR_ROW_HEIGHT)
            .padding({ left: PAGE_PADDING, right: PAGE_PADDING })

            // 分段胶囊：顶栏内部的第二行（不再是压在子页内容上的浮层）。
            // 左右 16 由这一行给足，胶囊自己 width('100%')；上下各 6 与 headerHeight() 对应。
            Row() {
              // 这一层是「边框 + 阴影的壳」，不是布局层：FloatingTabs 是共用组件
              // （排行页等处也在用），直接给它加边会连带改掉别的页的样子；
              // 所以在媒体库这一层包一个等尺寸容器，把白边与阴影画在壳上，
              // 胶囊组件本身一字不动。
              // 宽度必须是 100%（= 整行减去左右各 16 的内容宽），给固定值会在窄屏盖住胶囊、
              // 在宽屏浮在胶囊外面。
              Column() {
                FloatingTabs({
                  items: SEG_LABELS,
                // 外面这层已经加了 Theme.btnEdge() 白边，组件自带的那圈 edge() 必须关掉：
                // 两条边同界，半透明白压在 15% 黑上会混成偏灰的一圈。
                edgeRing: false,
                  selected: this.seg,
                  onSelect: (i: number) => {
                    this.seg = i;
                    this.ctrl.changeIndex(i);
                  }
                })
              }
              .width('100%')
              .height(FLOATING_TABS_HEIGHT)
              // 圆角要跟上胶囊的全圆角，否则白边是个直角框；也不能 clip(true)，
              // 裁剪会把投在外面的阴影一起切掉。
              .borderRadius(FLOATING_TABS_HEIGHT / 2)
              .border({ width: 0.7, color: Theme.btnEdge() })
              .shadow(Theme.floatShadow())
            }
            .width('100%')
            .height(FLOATING_TABS_HEIGHT)
            .padding({ left: PAGE_PADDING, right: PAGE_PADDING })
            .margin({ top: BAR_GAP, bottom: BAR_GAP_BOTTOM })
          }
          .width('100%')
          // 顶部避让状态栏：沉浸式下内容铺到状态栏下面，标题要躲开它
          .padding({ top: this.statusBar() })
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      // 只有这一层吃点击（标签/胶囊），其余是全屏内容自己滚动；
      // 手势落到顶栏范围内时不会漏给背后的卡片，落到顶栏之外时正常传给列表。
      .zIndex(2)
    }
    .width('100%')
    .height('100%')
    // 根节点也铺底色：外层切 tab 时本页可能只画出一个空容器
    .backgroundColor(this.pageBg())
  }
}
