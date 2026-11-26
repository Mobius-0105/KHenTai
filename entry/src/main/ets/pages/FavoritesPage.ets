import { EhApi } from '../core/EhApi';
import { Theme } from '../core/Theme';
import { Cookies } from '../core/Cookies';
import { FavCats } from '../core/Consts';
import { Gallery } from '../core/Models';
import { GalleryListView, galleryBottomInset } from '../ui/GalleryListView';
import { PageHeader } from '../components/PageHeader';
import { MaterialPlane } from '../components/MaterialPlane';

/**
 * 首行与上方内容（分段器 / 页头）之间的呼吸间距。
 * 首页的列表是 headerHeight() + 10（见 HomePage），子页这里只留 8，
 * 顶栏那一截由 LibraryPage 通过 headerHeight 传进来后自己加。
 */
const CARD_TOP_GAP: number = 8;

/** 收藏目录胶囊高度（与改造前那条横条一致） */
const CAT_BAR_H: number = 36;

/** 胶囊离顶栏的下沿距离：8 的呼吸，让它明显「浮」在顶栏下面而不是贴着 */
const CAT_BAR_GAP_TOP: number = 8;

/** 胶囊下沿与首行卡片之间再留 8：卡片从胶囊底下钻出来时有个过渡带 */
const CAT_BAR_GAP_BOTTOM: number = 8;

/** 胶囊左右各内缩 16：不通栏，才像一颗浮在内容上的玻璃条 */
const CAT_BAR_INSET: number = 16;

/**
 * 分类 chip 选中态的过渡时长：160。
 *
 * 与顶栏分段胶囊（FloatingTabs 点按）同一档：两处都是「点一下，选中块换个位置」，
 * 时长不同会让人觉得收藏页比首页慢半拍。160 短到不会拖住点击（手指抬起前就快走完），
 * 又长到能让「块从旧项平移到新项、字色跟着亮起」被看见。
 */
const CAT_ANIM_MS: number = 160;

/** 分类 chip 之间的横向间距（原来是 Row 的 space: 6）：滚入视野的位置推算要用它 */
const CAT_CHIP_GAP: number = 6;

/** 分类条 Scroll 内部左右各 12 的留白：同样被滚入视野的位置推算复用 */
const CAT_BAR_PAD_X: number = 12;

/**
 * 滑动块的**兜底尺寸**（chip 实测值还没回来时用）。
 *
 * 为什么必须有：滑块的大小原来完全取自 onAreaChange 量到的 chip 宽高，而「量到」这件事
 * 依赖首帧布局回调 —— 回调没回填（或被别处重绘抢先）时宽高是 0，
 * `if (catChipW > 0 && catChipH > 0)` 就恒假，整块滑块**一次都不画**，
 * 表现为「选中态没了 / 滑块消失了」。给它一个按文案（「目录 N」11fp）估的尺寸后，
 * 首帧就能画出来，实测值回来再无缝替换（两者差一两 vp，肉眼看不出来）。
 */
const CAT_CHIP_W_FALLBACK: number = 62;
const CAT_CHIP_H_FALLBACK: number = 30;

/**
 * 选中 chip 的常态缩放：1.02。
 *
 * 只做「比旁边稍微浮起来一点」，不做 1.0 → 1.04 → 1.0 的回弹：这条横条本来就是
 * 滚动列表，一弹会让整排文字跟着抖一下，用户读到的不是「选中了」而是「卡了一下」。
 */
const CAT_SELECTED_SCALE: number = 1.02;

/**
 * 收藏夹。
 *
 * EH 的收藏夹分 10 个目录（favcat 0~9），列表页结构与普通列表一致，
 * 只是地址换成 /favorites.php?favcat=N。未登录时给出的是一张空列表，
 * 所以这里先做登录判断，避免用户对着空白页发呆。
 *
 * `embedded` = true 时本页作为「媒体库」的一段被复用：页头由外层（LibraryPage 的
 * 沉浸材质顶栏）提供，本页不再画自己的标题行，也**不再让外层整体下移** ——
 * 列表是整屏高的，顶部让位由列表自己的 topInset 承担（见 listTopInset）。
 * 默认 false，单独使用时仍带自己的页头，行为与改造前一致。
 *
 * 顶部固定行的归属（谁让位给谁）：
 *   分类胶囊 36 在嵌入模式下**悬浮**在顶栏下沿、压着列表；
 *   列表的 topInset 仍把它整块让出来（headerHeight + 8 + 36 + 8），
 *   所以第一张卡不会一出来就被胶囊压住，但继续往上滚时可以从胶囊背后穿过。
 *
 * 为什么这一条要从「实底常驻层」改成「悬浮胶囊 + 沉浸材质」：
 *   实色底是**整块**遮挡 —— 卡片往上滚，一进入这 36vp 就被同色实底整片吃掉，
 *   离开时又整片冒出来，观感是「消失再出现」的硬切换；
 *   换成 MaterialPlane 后这 36vp 是半透的玻璃，卡片从背后经过时会透出模糊的轮廓，
 *   滚动因此是连续的。左右各缩 16、圆角 999 是为了把它从「贴边工具栏」变成
 *   「浮在内容上的一颗胶囊」：两侧露出的列表说明它没有截断内容，
 *   用户也就不会以为列表被切掉了。
 *   为什么不做成列表首项：列表在 GalleryListView 内部，本页拿不到它的 ListItem 口子；
 *   改造它超出本次允许范围，所以走「悬浮 + topInset 多让出」这一条。
 */
@Component
export struct FavoritesPage {
  onOpen: (g: Gallery) => void = (g: Gallery): void => {};
  onGotoSettings: () => void = (): void => {};
  /** 嵌在媒体库的 Tabs 里：不渲染自己的页头，顶部让位交给列表的 topInset */
  @Prop embedded: boolean = false;
  /**
   * 媒体库顶栏高度（含状态栏）。
   * 由 LibraryPage 唯一计算后传进来 —— 子页不再自己拼状态栏 + 标题行 + 分段行，
   * 两处各算一次就会在改数值时错位。
   */
  @Prop headerHeight: number = 0;

  @State private cat: number = 0;
  @State private url: string = '';
  @State private loggedIn: boolean = false;

  /**
   * 收藏变更信号（AppStorage 键 'favRevision'，由 core/EhApi.ets 的 addFavorite 成功分支写入）。
   *
   * 为什么走 AppStorage 而不是让详情页直接调本页方法：两页之间没有引用关系 ——
   * 详情页是 Index.ets 里盖在上面的一层 Stack，本页在媒体库的 Tabs 里，想把「刷新」这件事
   * 传过来只能靠一个公共的信号位，否则就要把组件实例一路传进去（两层都拿不到对方）。
   *
   * 值本身只是「变更次数」，不参与渲染：它的作用是让 @Watch 在值变化时把我们叫醒。
   * 为什么上游用自增计数而不是布尔，见 EhApi.addFavorite 里那段注释（布尔第二次置 true
   * 不构成变化，第二次收藏不会有任何回调）。
   */
  @StorageProp('favRevision') @Watch('onFavChanged') private favRevision: number = 0;

  /**
   * 「同一地址再查一次」的计数，直接交给 GalleryListView 的 reloadTick。
   *
   * 为什么不用改 url 来触发：url 是「哪个分类的第几页」，重拉第一页时它一个字都没变，
   * 而 @Prop 的 @Watch 只在值变了才回调 —— 改 url 等于什么都没发生（同一个坑见
   * GalleryListView.reloadTick 的注释）。本页只负责把计数 +1，请求与解析仍在列表内部，
   * 分类（cat）与排序自然都保持原样：没有任何一行代码去动 this.cat。
   */
  @State private reloadTick: number = 0;
  /** 媒体库顶栏「回到顶部」的归零信号（LibraryPage 自增，这里透传给列表） */
  @StorageProp('libraryTopTick') private libraryTopTick: number = 0;
  /**
   * 上报用的是「与 AppStorage 现值比较」而不是本地布尔缓存。
   *
   * 缓存会漏一种情况：媒体库切段时 LibraryPage 把 libraryScrollY 归零，
   * 而列表自身还停在原处 —— 本地缓存仍认为「已经报过 481」，于是再也不会重报，
   * 切回来顶栏的回顶钮就消失了。比现值则只写「需要变化」的那一次，同样不逐帧写。
   */

  /**
   * 把滚动位置上报给媒体库顶栏（它读 `libraryScrollY` 决定回顶钮显隐）。
   *
   * 只在**跨过阈值**时写一次：滚动是每帧回调，每帧写 AppStorage 会让所有订阅者
   * 逐帧重绘（顶栏材质包含在内），代价远大于这颗按钮本身的收益。
   */
  private reportLibraryScroll(y: number): void {
    const want: number = y > 480 ? 481 : 0;
    if ((AppStorage.get<number>('libraryScrollY0') ?? 0) !== want) {
      AppStorage.setOrCreate<number>('libraryScrollY0', want);
    }
    // 顶栏发丝线：内容是否已经顶到顶栏下沿（0.5 容差）。
    // 必须单独一条通道 —— 上面那组值被量化成 481/0，表达不了「离顶部 1vp」这一档；
    // 同样只在布尔翻转时写，避免逐帧写 AppStorage 连带顶栏材质一起重绘。
    const hair: boolean = y > 0.5;
    if ((AppStorage.get<boolean>('libraryHair0') ?? false) !== hair) {
      AppStorage.setOrCreate<boolean>('libraryHair0', hair);
    }
  }


  /**
   * 列表此刻是否被判为可见（onVisibleAreaChange 的结果）。
   *
   * 普通字段而不是 @State：它只参与刷新时机的判断、不进 build，写成 @State 会让整页
   * 在每次被详情页盖住/露出时白重绘一次。
   */
  private listVisible: boolean = false;

  /**
   * 是否已经收到过第一次「可见」回调。
   *
   * 首帧布局完成时 onVisibleAreaChange 就会报一次可见，而那一刻 GalleryListView 正在
   * aboutToAppear 里拉第一页 —— 若这次也算「回到列表」，一进页面就是两个并发请求。
   * 所以第一次只记录状态、不发刷新。
   */
  private seenVisible: boolean = false;

  /**
   * 列表当前反映的是「哪一版」收藏状态（初始化为进页面时的 favRevision）。
   *
   * favRevision ≠ appliedRev 就等于「欠一次刷新」。用「欠账」而不是「布尔待刷新」的好处：
   * 同一轮里多次信号（连续收藏 / 先加后删）只会让差值存在一次，兑现一次就抹平了，
   * 不需要额外的去重标记，也不会有「置了 pending 却没人来兑现」的悬挂状态。
   */
  private appliedRev: number = 0;

  /**
   * 分类条的横向滚动控制器：点选后把选中项滚到视野中央。
   *
   * 全页只有**一个**分类条实例：嵌入模式的悬浮条与非嵌入模式的流内条互斥（见 build 里
   * 两个 if 的条件分别是 embedded / !embedded），所以一个 Scroller 不会同时绑到两个 Scroll 上。
   */
  private catScroller: Scroller = new Scroller();
  /**
   * 单颗 chip 的实测宽度与分类条的视口宽（vp）。
   *
   * 十颗文案都是「目录 N」（同一个字母数），宽度天然一致，所以只量一颗就够十颗用 ——
   * 但不能写死：fontSize 是 fp，系统调大字号后 chip 会变宽，写死的常量会让「滚入视野」
   * 越滚越偏。视口宽同理，分屏/横屏时和屏幕宽不是一回事。
   *
   * catChipW 是 @State（上一版是普通字段）：滑块的宽度直接读它，普通字段写进去不会
   * 标记本组件重绘 —— 首帧那个「宽 0 → 不画」的结论就再也没机会翻案了。
   * catViewW 只给 scrollTo 算数用，不进 build 属性，保持普通字段免得白重绘。
   */
  @State private catChipW: number = 0;
  private catViewW: number = 0;
  /**
   * 单颗 chip 的实测高度（@State，不是普通字段）。
   *
   * 滑动块的高度必须等于 chip 高、y 必须让块与 chip 垂直居中，所以这个值要能触发重绘；
   * 而宽度只用于 scrollTo 的目标推算、不进 build 属性，保持普通字段即可。
   */
  @State private catChipH: number = 0;
  /**
   * 分类条滑动块的 x 坐标（Scroll **内容层**坐标，从内容左边缘起算）。
   *
   * 为什么不每次 build 现算 idx * (chipW + gap)：
   *  现算出来的属性变化是「一帧直接摆上去」，没有过渡，也就回到原来那种「旧块灭、新块亮」
   *  的淡入淡出观感。只有把写入包进 animateTo，位置才会插值 —— 所以必须单独存成 @State。
   *  初值取第 0 颗的左边界（不是 0）：首帧滑动块就要画在「目录 0」下面，
   *  落 0 会让它压在胶囊圆角外面半颗。
   */
  @State private catPillX: number = CAT_BAR_PAD_X;

  /**
   * 主题订阅位。
   *
   * 胶囊里的 chip 用 Theme.xxx() 取色，而 Theme 读的是不可观测的 Prefs：
   * 属性表达式里只出现 Theme.xxx() 时切主题不会有任何节点被标记重绘。
   * 所以按 LibraryPage / HomePage 的写法挂上 'themeDark'，并在 catFg/catPillBg 的
   * 两个分支里都读一次，建立重绘依赖（顺带整页配色一起刷新）。
   * 材质层自己也会监听 themeDark 重建（见 MaterialPlane）。
   */
  @StorageProp('themeDark') private themeDark: boolean = false;

  /**
   * 分类 chip 前景色：未选中 subText、选中白。
   *
   * 为什么选中字是白：选中的那颗 chip 底下压着 accent 蓝块（见 catPillBg），
   * 蓝底上再写蓝字等于没有选中态，必须换成白字才有对比。
   * 两个分支同值，读 themeDark 只为建立重绘依赖。
   */
  private catFg(selected: boolean): ResourceColor {
    if (this.themeDark) {
      return selected ? Color.White : Theme.subText();
    }
    return selected ? Color.White : Theme.subText();
  }

  /**
   * 分类条滑动块的底色：accent（蓝）。
   *
   * 为什么色块要独立成层，而不是继续给选中的 chip 画 backgroundColor：
   *  底色挂在 chip 上时，切换只能是「旧 chip 的底色淡出、新 chip 的底色淡入」——
   *  过渡中间必然有一段两块半透明重叠的帧，看着像两颗都选中了，而且**没有任何一帧**
   *  能读出「块从哪滑到哪」。把底色抽成一个独立节点、只动它的 x，任何时刻都只有一块，
   *  位移方向和距离本身就是选中变化的表达 —— 这正是首页顶栏分段胶囊的做法（FloatingTabs）。
   *
   * 两个分支同值，只为建立 themeDark 依赖（Theme.accent() 读的是不可观测的 Prefs）。
   */
  private catPillBg(): ResourceColor {
    if (this.themeDark) {
      return Theme.accent();
    }
    return Theme.accent();
  }

  /** 有没有分类可显示：没有就整颗胶囊都不画，不留一条空玻璃 */
  private showCats(): boolean {
    return FavCats.NAMES.length > 0;
  }

  /**
   * 滑块宽度 / 高度：实测优先，没测到就用兜底尺寸。
   *
   * 为什么不在 build 里写 `if (catChipW > 0)` 决定画不画：那个条件让「画滑块」依赖一次
   * 异步的测量回调，回调没到就永远不画（上一版滑块消失的直接原因）。
   * 现在无条件画、尺寸取「实测 ?? 兜底」，首帧就有东西，实测回来自然收敛。
   */
  private catPillW(): number {
    return this.catChipW > 0 ? this.catChipW : CAT_CHIP_W_FALLBACK;
  }

  private catPillH(): number {
    return this.catChipH > 0 ? this.catChipH : CAT_CHIP_H_FALLBACK;
  }

  /**
   * 滑动块的目标 x：第 idx 颗 chip 的左边界（内容层坐标）。
   *
   * 十颗等宽、间距固定，所以第 idx 颗的左边界 = 左侧留白 + idx × (chip 宽 + 间距)；
   * 块宽直接取 chip 宽，块就正好压在这颗 chip 下面，不需要再算内缩。
   * 宽度用 catPillW()（含兜底），首帧点选也能算对位置，不会退化成「都落在 12」。
   */
  private catPillTarget(idx: number): number {
    return CAT_BAR_PAD_X + idx * (this.catPillW() + CAT_CHIP_GAP);
  }

  /** 记录 chip 实测宽（十颗等宽，取任意一颗都行）；值没变直接返回，避免无谓的状态写入 */
  private recordCatChipW(w: number): void {
    if (!(w > 0) || Math.abs(this.catChipW - w) < 0.5) {
      return;
    }
    this.catChipW = w;
    // 宽度（重新）测到 = 布局落位，不是切换：块直接摆到当前项，不做动画。
    // 首帧若插值会看到块从 0 窜到中间；改字号导致 chip 变宽时也应当是「跟着重排」。
    this.catPillX = this.catPillTarget(this.cat);
  }

  /** 记录 chip 实测高：滑动块的高度来源；同样只在真的变了时写，免得整页重绘 */
  private recordCatChipH(h: number): void {
    if (!(h > 0) || Math.abs(this.catChipH - h) < 0.5) {
      return;
    }
    this.catChipH = h;
  }

  /** 记录分类条视口宽（onAreaChange 给的是 Scroll 自身宽度，也就是能看见的那一段） */
  private recordCatViewW(w: number): void {
    if (!(w > 0) || Math.abs(this.catViewW - w) < 0.5) {
      return;
    }
    this.catViewW = w;
  }

  /**
   * 把选中的 chip 滚到视野中央。
   *
   * 为什么必须做：十颗 chip 一次排不下（每颗约 50vp，加上间距远超一屏的可用宽度），
   * 收藏目录常见用法是「一路点到 8、9」，选中的那颗很可能正压在右边被裁掉的位置上 ——
   * 选中态变了但用户看不见，等于没有反馈。
   *
   * 位置是**算**出来的而不是量出来的：十颗等宽，第 i 颗的左边界 = 左右留白 + i × (宽 + 间距)，
   * 目标偏移 = 该项中心 - 视口一半，再夹到 [0, 内容宽 - 视口宽] 之间（首尾两项因此贴边而不是
   * 留白到外面）。chip 宽用含兜底的值（catPillW），所以首帧点选也能算；只有**视口宽**没量到
   * （不该发生，Scroll 一定有宽）时才什么都不做 —— 绝不能拿 0 去滚，那会把条拉到最左端。
   */
  private revealCat(idx: number): void {
    // 用含兜底的宽度，首帧（实测还没回来）点选也能滚到大致正确的位置
    const w: number = this.catPillW();
    const view: number = this.catViewW;
    if (!(view > 0)) {
      return;
    }
    const n: number = FavCats.NAMES.length;
    const contentW: number = CAT_BAR_PAD_X * 2 + n * w + (n - 1) * CAT_CHIP_GAP;
    const left: number = CAT_BAR_PAD_X + idx * (w + CAT_CHIP_GAP);
    const maxOffset: number = contentW - view;
    if (maxOffset <= 0) {
      // 内容比视口窄（分屏/大屏/只剩两三颗）：没有可滚的余量，保持原位
      return;
    }
    let target: number = left + w / 2 - view / 2;
    if (target < 0) {
      target = 0;
    }
    if (target > maxOffset) {
      target = maxOffset;
    }
    this.catScroller.scrollTo({
      xOffset: target,
      yOffset: 0,
      animation: { duration: CAT_ANIM_MS, curve: Curve.Smooth }
    });
  }

  aboutToAppear(): void {
    this.loggedIn = Cookies.isLoggedIn();
    if (this.loggedIn) {
      this.url = EhApi.favUrl(0, 0);
    }
    // 列表的第一页就是此刻服务端的状态：水位对齐到当前值，否则进程里已经攒下的
    // favRevision（比如先进过详情页收藏了一部）会让本页一出现就白拉一次。
    this.appliedRev = this.favRevision;
  }

  /**
   * 收藏信号回调：**只记账，不在这里发请求**。
   *
   * 为什么不直接拉一次第一页：
   *  1. 收藏入口只有详情页，而详情页是盖在上面的一层（Index.ets 的 stack），信号到达的那一刻
   *     用户一定不在看这份列表 —— 立刻刷新的收益是零，等回到可见再拉，时序上就是
   *     「转身回来时列表已经是新的」，和下拉刷新的观感一致；
   *  2. 本页读不到列表的滚动位置（滚动在 GalleryListView 内部的 List/Grid 上，没有对外暴露），
   *     也就无法判断「用户是不是正滚在深处」。当场刷新会把 items 清空重建、滚动位置打回顶部，
   *     这是会打断浏览的硬伤，宁可推迟；
   *  3. 推迟之后，一轮浏览里连收藏 N 次（favRevision +N）只会兑现一次 —— 天然去重。
   *
   * 唯一的唤醒点是 handleVisible（回到可见那一刻）。参数值本身不用，欠账靠
   * favRevision 与 appliedRev 的差值表达，所以这里没有语句。
   */
  private onFavChanged(): void {
  }

  /**
   * 可见性回调：记录在不在列表上，并在「刚回到可见」时兑现一次欠账。
   *
   * 为什么「回到可见」是唯一允许打断的时刻：那是用户刚进这一页的一刻，任何滚动位置变化
   * 都读作「重新进入」，不会打断正在进行中的浏览；反过来，在页面持续可见时刷新（信号若
   * 从列表页自己的入口发出来就会出现）一定会把用户正在看的那一段顶掉。
   *
   * 为什么这里不无条件刷新：每次从详情页返回都重拉，等于每看一部漫画回来列表就跳回顶部 ——
   * 那正是本次要避免的事。只有欠账（favRevision ≠ appliedRev）才真的发请求，
   * 「离开再回来顺手刷新」的效果保留，但不打扰没变化的那一轮。
   *
   * 关于并发：本页保证每一轮（一次「可见」）最多 tick 一次；万一两轮交叠（上一轮请求还没
   * 回来，用户又进出一次详情页），GalleryListView 自己的 loadSeq 会丢弃旧结果，
   * 不会把两批数据混在一起 —— 那里本来就是为「翻页途中换请求」准备的。
   */
  private handleVisible(isVisible: boolean): void {
    if (!isVisible) {
      this.listVisible = false;
      return;
    }
    this.listVisible = true;
    if (!this.seenVisible) {
      // 首帧：列表正在 aboutToAppear 里拉第一页，这里再 tick 一次就是并发两个请求
      this.seenVisible = true;
      this.appliedRev = this.favRevision;
      return;
    }
    this.refreshIfStale();
  }

  /**
   * 有欠账就把列表的第一页再拉一次（当前分类、当前排序都不动）。
   *
   * 水位在**发请求之前**就推进：这样「正在加载 / 正在刷新」期间再来一次同版本唤醒
   * （可见性回调抖动、信号重复到达）会被差值为 0 直接挡掉，不需要碰 GalleryListView
   * 内部那个私有 loading —— 它在另一个文件里，本页看不见也拿不到。
   */
  private refreshIfStale(): void {
    if (!this.listVisible || !this.loggedIn || this.url.length === 0) {
      return;
    }
    if (this.favRevision === this.appliedRev) {
      return;
    }
    this.appliedRev = this.favRevision;
    this.reloadTick = this.reloadTick + 1;
  }

  /**
   * 列表顶部让位：
   *   嵌入 = 媒体库顶栏（传入）+ 8（胶囊离顶栏的呼吸）+ 胶囊 36 + 8（胶囊下沿的过渡带）；
   *   独立 = 只补首行呼吸（页头与胶囊都在正常布局流里，已经占了位）。
   */
  private listTopInset(): number {
    if (!this.embedded) {
      return CARD_TOP_GAP;
    }
    if (!this.showCats()) {
      return this.headerHeight + CARD_TOP_GAP;
    }
    return this.headerHeight + CAT_BAR_GAP_TOP + CAT_BAR_H + CAT_BAR_GAP_BOTTOM;
  }

  /**
   * 收藏目录胶囊：底层是系统材质、上层是横向 Scroll，两处（流内 / 悬浮）共用同一份。
   *
   * 必须包 Stack 且让材质成为**真实布局节点**：MaterialPlane 只有参与布局时才会创建
   * 材质作用域，塞进 .background(builder) 会在真机上整块消失。
   * 高度写死 36，宽度由调用方决定（悬浮那份靠左右 16 内边距收窄），
   * MaterialPlane 内部的 width('100%') 才有一个确定的落点。
   */
  @Builder
  private categoryBar() {
    Stack({ alignContent: Alignment.Center }) {
      // 底层：胶囊形的沉浸材质（'header' 与顶栏同一套配方）；不可用时它自己退回实底 + 厚模糊
      // edge: true —— 分类胶囊浮在列表上方，浅色模式下玻璃和卡片底色太接近，
      // 没有边就分不清它是「一条独立控件」还是列表的第一行。
      MaterialPlane({ kind: 'header', radius: 999, planeHeight: CAT_BAR_H, edge: true })

      // 上层：分类 chip。整层铺满胶囊，所以点在任意位置都落在 Scroll 上（不会漏到材质层）
      // 绑 scroller：点选后由 revealCat 把选中项滚进视野中央（见那个方法的注释）
      Scroll(this.catScroller) {
        // Stack 是「滑动块的坐标系」：块与 chip 行共用同一层内容，块的 x 用内容坐标，
        // 横滑时两者一起移动，块才不会滞留在原地（放到 Scroll 外面就变成固定不动的装饰）。
        Stack({ alignContent: Alignment.TopStart }) {
          // 滑动块：整条分类栏唯一的底色。
          // **先声明**，所以永远压在 chip 文字下面；hitTestBehavior(None) 让它不吃点击，
          // 点在块上也要落到上层的 Text（Text 才有 onClick）。
          // 宽 = chip 宽、高 = chip 高、y = 让块与 chip 垂直居中的那一半差值。
          //
          // 这里**不加 if 条件渲染**：上一版写的是 `if (catChipW > 0 && catChipH > 0)`，
          // 而宽高来自 onAreaChange，回调没回填时条件恒假 → 滑块一次都不画（用户看到的就是
          // 「滑块消失了」）。现在无条件画，尺寸走 catPillW()/catPillH()（实测 ?? 兜底 62×30），
          // 首帧就可见，实测回来再收敛到真实值。
          Row()
            .width(this.catPillW())
            .height(this.catPillH())
            .borderRadius(999)
            .backgroundColor(this.catPillBg())
            .position({ x: this.catPillX, y: (CAT_BAR_H - this.catPillH()) / 2 })
            .hitTestBehavior(HitTestMode.None)

          Row({ space: CAT_CHIP_GAP }) {
            ForEach(FavCats.NAMES, (name: string, idx: number) => {
              Text(name.replace('Favorite ', '目录 '))
                .fontSize(11)
                // chip 自身**不画底色**：底色统一由上面那一块滑动块承担。
                // 两层都画的话，选中项会同时出现「跟着字走的底色」和「滑过来的块」，
                // 中间那几帧就是两块叠在一起、边缘发深的脏边。
                .fontColor(this.catFg(this.cat === idx))
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                // 选中项常态放大 1.02（不做回弹）：块已经在平移了，这点放大只让选中字
                // 比旁边略微浮起，与字色同一段 160ms 过渡
                .scale({
                  x: this.cat === idx ? CAT_SELECTED_SCALE : 1.0,
                  y: this.cat === idx ? CAT_SELECTED_SCALE : 1.0
                })
                // 实测宽高：十颗等宽，revealCat 用它推算滚动目标，滑动块用它定宽高
                // （不能写死，fontSize 是 fp，系统调大字号后 chip 会变宽变高）
                .onAreaChange((oldArea: Area, newArea: Area) => {
                  this.recordCatChipW(parseFloat(newArea.width.toString()));
                  this.recordCatChipH(parseFloat(newArea.height.toString()));
                })
                .onClick(() => {
                  // 选中值**和**块坐标必须在同一个 animateTo 里写：
                  // 只写 this.cat 的话，块坐标是派生出来的属性，会在同一帧被直接摆到新位置
                  // （没有过渡，即原来那种淡入淡出）；只写坐标则字色不会跟着亮。
                  animateTo({ duration: CAT_ANIM_MS, curve: Curve.Smooth }, () => {
                    this.cat = idx;
                    this.catPillX = this.catPillTarget(idx);
                  });
                  this.url = EhApi.favUrl(idx, 0);
                  // 十颗排不下，选中的那颗可能正压在屏幕外：点完立刻滚到视野中央
                  this.revealCat(idx);
                })
            }, (name: string) => name)
          }
          // 横向 12：胶囊本身已经左右缩进 16，内部再留 12 就够，块不会贴到圆角上。
          // 块的目标 x 同样以这 12 为起点（见 catPillTarget），两边只有这一个数值来源。
          .padding({ left: CAT_BAR_PAD_X, right: CAT_BAR_PAD_X })
          .height(CAT_BAR_H)
          .alignItems(VerticalAlign.Center)
          // 双保险：即使以后有人把文字行挪到块前面，文字也仍然在上
          .zIndex(1)
        }
        .height(CAT_BAR_H)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(CAT_BAR_H)
      // 视口宽：滚入视野要按「能看见多宽」居中，分屏/横屏时它不等于屏幕宽
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.recordCatViewW(parseFloat(newArea.width.toString()));
      })
    }
    .width('100%')
    .height(CAT_BAR_H)
    // 圆角与材质一致，并裁掉滚动内容的直角边，否则 chip 会从胶囊两端露出去
    .borderRadius(999)
    .clip(true)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 内容层：整屏高，不带 top padding —— 列表要能从屏幕顶端开始铺，
      // 卡片才会滚到材质顶栏背后去（这是「透过顶栏」成立的前提）。
      Column() {
        // 嵌入式不画页头：标题与分段器都在 LibraryPage 的固定顶栏里
        if (!this.embedded) {
          PageHeader({
            title: '收藏夹',
            subtitle: Cookies.summary(),
            showBack: false
          })
        }

        if (!this.loggedIn) {
          Column({ space: 12 }) {
            Text('需要登录才能查看收藏夹').fontSize(14).fontColor(Theme.subText())
            Text('登录后这里会显示站点上的 10 个收藏目录')
              .fontSize(11)
              .fontColor(Theme.subText())
              .textAlign(TextAlign.Center)
            Text('去登录')
              .fontSize(13)
              .fontColor(Color.White)
              .padding({ left: 20, right: 20, top: 9, bottom: 9 })
              .borderRadius(10)
              .backgroundColor('#2F6BD8')
              .onClick(() => this.onGotoSettings())
            Text('刷新状态')
              .fontSize(12)
              .fontColor(Theme.accent())
              .onClick(() => {
                this.loggedIn = Cookies.isLoggedIn();
                if (this.loggedIn) {
                  this.url = EhApi.favUrl(this.cat, 0);
                }
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          // 嵌入时这坨提示不能钻到顶栏下面：让出顶栏高度（居中块随之整体下移半个高度）
          .padding({ top: this.embedded ? this.headerHeight : 0 })
        } else {
          // 独立模式：胶囊在正常流里（页头下方），列表接在它后面。
          // 同样左右缩 16，两处观感一致；无分类时不画，也不占高度。
          if (!this.embedded && this.showCats()) {
            Column() {
              this.categoryBar()
            }
            .width('100%')
            .height(CAT_BAR_H)
            .padding({ left: CAT_BAR_INSET, right: CAT_BAR_INSET })
          }

          GalleryListView({
            requestUrl: this.url,
            // 媒体库顶栏的回顶钮：滚动偏移写 AppStorage（越线才写），tick 触发归零
            showTopHint: true,
            scrollToTopTick: this.libraryTopTick,
            onScrollOffset: (y: number) => {
              this.reportLibraryScroll(y);
            },
            emptyHint: '这个收藏目录是空的',
            onOpen: (g: Gallery) => this.onOpen(g),
            // 顶栏高度由 LibraryPage 传入、胶囊高度与间距由本页算，列表起点只有一个来源
            topInset: this.listTopInset(),
            // 收藏变了之后「同一个地址再查一次」的入口：只换计数，url / 分类 / 排序都不动
            reloadTick: this.reloadTick,
            // 底部让位交给列表的 contentEndOffset：原来写在外层 Column 上的 padding 会把
            // 列表视口整体截短，卡片滚到底栏上沿就被硬切一刀，滑不进底栏下面。
            bottomInset: galleryBottomInset()
          })
            .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      // 这里不写 padding bottom：底部让位改由列表的 contentEndOffset(bottomInset) 承担，
      // 容器再垫一段会让列表视口低于屏幕底，底栏上方空出一条、卡片又在视口边界被切。

      // 嵌入模式的分类胶囊：悬浮层，位置 = 顶栏下沿 + 8。
      // 它压在列表上方（zIndex），列表的 topInset 已经把它那一块让出来了，
      // 所以它既不会被顶栏压住、也不会压住第一张卡；再往上滚的卡片则从胶囊背后穿过，
      // 透出材质的模糊轮廓 —— 这正是从「实底整片遮挡」改成「悬浮 + 材质」的收益。
      if (this.embedded && this.loggedIn && this.showCats()) {
        Column() {
          this.categoryBar()
        }
        .width('100%')
        .height(CAT_BAR_H)
        // 左右各 16：胶囊不通栏，两侧露出列表，看起来才是浮在内容上而不是贴着边
        .padding({ left: CAT_BAR_INSET, right: CAT_BAR_INSET })
        .margin({ top: this.headerHeight + CAT_BAR_GAP_TOP })
        .zIndex(2)
      }
    }
    .width('100%')
    .height('100%')
    // tab 容器会一直保留页面实例，aboutToAppear 只跑一次：本页靠这里知道「用户回没回到列表」。
    // 为什么能收到详情页的遮挡：详情页是 Index.ets 里盖在上面的一层，推入时下层页整体
    // 左移并缩到 0.98（Index.xOf / scaleOf），本页的可见比例因此跌破 1，这里就能收到
    // 一次 false；返回时再收到一次 true —— 那次 true 就是 handleVisible 里兑现欠账的时刻。
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, ratio: number) => {
      this.handleVisible(isVisible && ratio > 0);
    })
  }
}
