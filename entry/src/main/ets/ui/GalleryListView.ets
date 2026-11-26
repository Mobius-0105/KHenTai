import { EhApi } from '../core/EhApi';
import { Prefs } from '../core/Prefs';
import { Theme } from '../core/Theme';
import { Tokens } from '../core/Tokens';
import { TagTransTick } from '../core/TagTrans';
import { Gallery, GalleryPage, GalleryTag } from '../core/Models';
import { Db, GalleryMetaRow } from '../core/Db';
import { Namespaces } from '../core/Consts';
import { fetchGdata, GDATA_BATCH_SIZE, GdataItem, GalleryRef } from '../net/GalleryMeta';
import { GalleryCard, ListStyles } from './GalleryCard';
import { MaterialPlane } from '../components/MaterialPlane';

/**
 * 悬浮胶囊底栏的几何量（与 Index.ets 的 floatBar 一一对应，那边改了这里要同步）。
 *
 * 为什么把这段算在这里：底栏是**压在内容上**的浮层，列表滑到底时必须自己让出
 * 「底栏 56 + 底栏离底 4 + 导航条」这一段，否则最后一张卡 / 底部状态行会被底栏盖住。
 * 首页、搜索、媒体库三条列表都用下面这个函数取同一个数，不再各自写一个 80 的魔法值
 * （80 在三段式导航的机器上正好短了一截，这就是「最后一张卡被压住」的直接原因）。
 */
const FLOAT_BAR_MARGIN: number = 4;
/** 卡片与底栏之间的呼吸间距：8~12 取中值 10，留白太小像被压着、太大又像列表断了 */
const BOTTOM_BREATH: number = 10;

/**
 * 刷新状态浮层（胶囊）的几何量。
 *
 * 宽是**写死**的而不是自适应：MaterialPlane 的材质层是 width('100%')，一旦外框宽度
 * 由内容自己撑，百分号就只能对到整屏，材质会横铺成一条通栏色带（DetailPage 里记过这个坑）。
 * 给一个固定宽度后，材质层被这块 120 的外框夹住，才是真的「有界玻璃」。
 * 120 = 圈 16 + 间距 6 + 「正在刷新…」约 66（11 号字 5 字）+ 左右留白 16×2，略宽一点更稳。
 */
const REFRESH_PILL_WIDTH: number = 120;
const REFRESH_PILL_HEIGHT: number = 32;
/** 胶囊与顶栏下沿的间距：8 与底栏离底 4 同一档呼吸，贴着顶栏但不粘住 */
const REFRESH_PILL_GAP: number = 8;

/**
 * 列表底部让位量 = 悬浮底栏 56 + 底栏离底 4 + 导航条 + 呼吸 10。
 *
 * 与 CommentsPage.inputBarHeight()（导航条 + 输入条）同一套算法：凡是压在内容上的
 * 贴底浮层，列表的 contentEndOffset 都必须严格等于它的占位，多一分会空出一条，
 * 少一分就被盖住。
 */
export function galleryBottomInset(): number {
  const nav: number | undefined = AppStorage.get<number>('navBarHeight');
  return (nav === undefined ? 0 : nav) + Tokens.FLOAT_BAR_HEIGHT + FLOAT_BAR_MARGIN + BOTTOM_BREATH;
}

/**
 * 通用的画廊列表（首页 / 搜索 / 收藏 / 观看记录共用）。
 *
 * 分页靠 EH 自己的 next 链接：拿不到 next 就到头了，不用自己算页码，
 * 也就不会在站点改版时算错。
 *
 * 底部有两种翻页形态（见 pager / endless 两个开关，互相独立）：
 *  - 分页（pager，默认）：底部一行「继续下滑加载更多」，触底自动取下一页 —— 首页/收藏/观看的既有行为；
 *  - 无限滚动（endless）：新一页 append 到现有数组、滚动位置不动，底部按「加载中/没有更多/重试」换文案。
 * 拆成两个布尔而不是一个枚举，是因为调用方要能分别表达「都不要（纯静态列表）」。
 *
 * 容器有两种：前三种样式用 List（一行一条，信息量不同），封面墙用 Grid（两列）。
 * 不用 List 的 lanes 做双列，是因为封面墙没有横向留白，Grid 的 gap/padding 更好控。
 */
@Component
export struct GalleryListView {
  /** 第一页地址。父组件改这个值即触发重载 */
  @Prop @Watch('onUrlChanged') requestUrl: string = '';
  /** 列表为空时的提示文案 */
  @Prop emptyHint: string = '这里还没有内容';
  /** 顶部内边距：材质顶栏盖在列表上时，内容从这里开始滚 */
  @Prop topInset: number = 0;
  /**
   * 底部让位量：传 galleryBottomInset()（底栏 + 导航条 + 呼吸）。
   *
   * 为什么用 contentEndOffset 而不是 padding：padding 会把列表视口整体缩短，卡片滚到
   * 底栏那一段就贴在视口边界上被裁掉；contentEndOffset 只往「内容末尾」补留白，
   * 卡片照样能从底栏下面穿过去，滑到底时最后一张卡与底部状态行完整停在底栏上方
   * （与 CommentsPage 的 contentEndOffset 同一套写法）。
   *
   * 默认 0：首页 / 收藏 / 下载 / 历史这些没传值的调用点视觉保持原样。
   */
  @Prop bottomInset: number = 0;
  /**
   * 是否由列表自己分页：底部提示行 + 触底自动取下一页。
   *
   * 默认 true，首页/收藏/观看列表一个字都不用改；搜索页改成无限滚动后传 false，
   * 否则底部会同时出现「分页提示行」和「无限滚动状态行」两套东西。
   */
  @Prop pager: boolean = true;
  /**
   * 无限滚动：新一页 append 到现有数组而不是替换，滚动位置自然保住。
   *
   * 关掉分页但打开无限滚动时，底部只剩无限滚动那一行状态，不会再出现页码语义。
   */
  @Prop endless: boolean = false;
  /**
   * 页码兜底：入参是从「当前这一页」往后数的第几页（1 基，第一次兜底传 1）。
   *
   * **只在站点没给 next 时才会被调用**（见 nextPageUrl）：正常翻页一律跟随 `#unext`，
   * 因为 EH 的搜索/列表分页是游标，page 偏移不可靠。这里存在只是为了让「上一页 HTML
   * 没解析出 next」的列表还能往前走一步。
   *
   * 为什么传相对步数而不是绝对页码：列表只知道「已经 append 了几页」，不知道 requestUrl
   * 本身是第几页（跳页之后它就≠1）；让父组件拿自己的页码基数去加，才不会在跳页后倒回去请求
   * 第 2 页。返回空串表示本列表没有页码语义（那就只剩 next 一条路）。
   */
  pageUrlOf: (step: number) => string = (step: number): string => '';
  /**
   * 强制重载信号：值一变就重查当前的 requestUrl。
   *
   * 为什么需要：@Prop 的 @Watch 只在**值变了**才触发，跳页跳到「当前这一页」时 URL 与原来
   * 一字不差，只改 url 是收不到通知的（典型场景：无限滚动滑了十几页后想回到第 1 页）。
   */
  @Prop @Watch('onReloadTick') reloadTick: number = 0;
  onOpen: (g: Gallery) => void = (g: Gallery): void => {};

  // ------------------------------------------------------------ 回到顶部（父页顶栏用）
  /**
   * 是否启用「回顶反馈」：开启后列表把滚动偏移回报给父组件，并接受 scrollToTopTick 的归零信号。
   *
   * 默认 false：收藏 / 存档 / 下载 / 历史这些既有调用点不传，就完全不挂每帧回调，
   * 行为和这次改动之前一模一样（不传 = 白拿一个新 @Prop，没有任何副作用）。
   */
  @Prop showTopHint: boolean = false;
  /**
   * 滚动偏移回调（vp，向下为正 / 这里统一成「离顶部多远」，见 onDidScroll 的写法）。
   *
   * 为什么是普通成员而不是 @Prop：@Prop 只收可观测的值类型，函数签名不能用 @Prop 声明
   * —— 本工程 pageUrlOf / onOpen / onOpenLocal 都是同一个写法。
   */
  onScrollOffset: (y: number) => void = (y: number): void => {};
  /**
   * 「回到顶部」信号：父组件每点一次就 +1，本组件监听到变化就把列表滚回顶部。
   *
   * **为什么用 tick 而不是让父组件直接调方法**：ArkUI 里父组件拿不到子组件实例
   * （没有 ref / 组件句柄），父级对子级只有「属性」这一条下行通道；而 @Prop 的 @Watch
   * 只在**值发生变化**时触发 —— 布尔量连点两次，第二次值没变，收不到通知。
   * 所以用单调递增的计数：每次 +1 都必然是一次变化，也就必然触发一次回顶。
   */
  @Prop @Watch('onScrollToTopTick') scrollToTopTick: number = 0;
  /**
   * 列表 / 网格共用的滚动控制器。
   *
   * 两个用途：回顶（父组件拿不到实例，只能在这里 scrollTo）和读累计偏移
   * （见 onDidScroll —— 用它比读回调参数更稳）。rowList / gridList 是二选一的，
   * 同一时刻只会有其中一个容器绑着它，不存在「一个 Scroller 绑两个列表」的冲突。
   */
  private scroller: Scroller = new Scroller();

  /**
   * 列表样式。@StorageProp 而不是 @State：设置页写 AppStorage 后，
   * 已经挂载在别的 tab 里的列表也会立刻重排，不需要用户手动刷新。
   */
  @StorageProp('listStyle') listStyle: string = ListStyles.COMPACT;

  /**
   * 标签库重绘信号：标签库加载完成 / 设置页切换「标签翻译」后 +1，透传给每张卡片。
   *
   * 为什么挂在列表而不是放到 AppStorage 里让卡片自己 @StorageProp：
   * 卡片有三种列表形态（首页 / 搜索 / 收藏）共用本组件，tick 从这里下发只需接一次；
   * 卡片侧保持普通 @Prop，避免每张卡都去订阅全局键（一屏 30 张就是 30 个订阅）。
   * SearchPage 的以图搜图结果虽然直接铺 GalleryCard，但那时标签库已被本组件加载过，
   * 首帧就是终态，不需要第二条链。
   */
  @StorageProp('tagTransTick') tagTransTick: number = 0;

  @State private items: Gallery[] = [];
  @State private loading: boolean = false;
  @State private loadingMore: boolean = false;
  @State private error: string = '';
  @State private nextUrl: string = '';
  @State private countText: string = '';
  @State private refreshing: boolean = false;
  /**
   * gdata 补评分重绘信号：每补到一批就 +1。
   *
   * 为什么需要它：Gallery 对象是普通成员（不是 @Observed），后台改 `g.rating` 不会通知
   * 已经建好的卡片；把 tick 作为 @Prop 传给 GalleryCard，值一变卡片就重建一次，
   * 星星随之从灰变亮。做法与现有的 tagTransTick / favRevision 完全一致。
   */
  @State private metaTick: number = 0;
  /**
   * 已排队 / 已补过的 gid。
   *
   * 翻页时同一本画廊可能出现在相邻两页（EH 分页会漂移），去重后仍在 items 里；
   * 没有这个集合，同一批会给同一个 gid 重复发 gdata，白吃 1 req/s 的限流。
   * 请求失败时会移除，下一轮还能重试。
   */
  private metaQueued: Set<string> = new Set<string>();
  /**
   * 下拉手势的阶段（Inactive / Drag / OverDrag / Refresh / Done）。
   *
   * 只给刷新指示器换文案用，不参与任何数据逻辑：URL / 分页 / 触底判定都不读它。
   * 为什么不直接用 refreshing：refreshing 只有「刷 / 不刷」两态，而下拉过程中（还没松手）
   * 它一直是 false —— 那段时间的反馈只能靠 RefreshStatus 区分出来。
   */
  @State private refreshStatus: RefreshStatus = RefreshStatus.Inactive;
  /**
   * 无限滚动：已经到底。
   *
   * 只由站点给的**原始**信号决定（本页 0 条 / 没有 next 也没有页码兜底 / next 指回自己），
   * **不看**「去重后新增了几条」—— 去重是展示层的事，站点分页边界漂移时相邻两页出现同一批
   * 画廊是正常的，把它当到底就是「搜索只出一页」的根因（见 loadMore 的注释）。
   */
  @State private noMore: boolean = false;
  /** 无限滚动：上一次翻页失败的原因；非空时底部换成可点重试的一行 */
  @State private moreError: string = '';
  /** 无限滚动：已经 append 了几页（0 = 只有 requestUrl 那一页），用来向父组件要下一段 */
  private step: number = 0;
  /**
   * 请求代次：requestUrl 一变就 +1。
   *
   * 为什么需要：翻页请求在飞的时候用户可能已经改了关键词，回来的旧数据如果直接 append，
   * 就会把上一个搜索的结果混进新列表。所有 await 之后都拿 seq 对一次，对不上就整批丢弃。
   */
  private loadSeq: number = 0;

  aboutToAppear(): void {
    // 以 Prefs 为准灌一次 AppStorage：否则 @StorageProp 只能拿到本地默认值，
    // 用户上次选的样式要到打开设置页才生效。
    AppStorage.setOrCreate<string>('listStyle', ListStyles.normalize(Prefs.listStyle()));
    // 标签翻译的唯一挂载点（首页 / 搜索 / 收藏三条列表都在这里过一遍）：
    // 先按当前开关 bump 一次，标签库 load 完成后再 bump 一次，卡片的 chip 文案才会由
    // 「英文首帧」切成中文。详见 TagTransTick 的注释。
    TagTransTick.sync();
    this.reload();
  }

  onUrlChanged(): void {
    this.reload();
  }

  /** 父组件要求「同一个地址再查一次」（跳页跳到当前页时用） */
  onReloadTick(): void {
    this.reload();
  }

  /**
   * 父组件点了「回到顶部」：滚回 0。
   *
   * 260 / Smooth 与详情页那颗回顶钮同一档 —— 同一个动作在两个页面里必须是同一条曲线，
   * 否则来回切页会觉得一边「弹」一边「飘」。
   * 空态 / 加载态时容器根本没建（build 的另外两个分支），这次 scrollTo 是空操作，
   * 但也不会有人点到它：按钮只在列表真的滚过阈值之后才出现。
   */
  private onScrollToTopTick(): void {
    // 用 scrollToIndex(0, smooth, START) 而不是 scrollTo(yOffset 0)：
    // 列表开了 `contentStartOffset(topInset)`（让内容从半透明顶栏下方开始），
    // 而 scrollTo 的坐标系是**视口**坐标 —— 滚到 0 会把第一张卡顶到屏幕最上沿、
    // 藏到顶栏背后（用户看到的就是「回到屏幕顶部，而不是顶栏底部」）。
    // scrollToIndex + ScrollAlign.START 对齐的是**内容起点**，正好落在 topInset 之下。
    this.scroller.scrollToIndex(0, true, ScrollAlign.START);
  }

  private isThumb(): boolean {
    return this.listStyle === ListStyles.THUMBNAIL || this.listStyle === 'thumb';
  }

  private async reload(): Promise<void> {
    if (this.requestUrl.length === 0) {
      return;
    }
    // 换 URL = 换一次搜索/筛选：页码与「到底」标记必须一起归零，不能接着上一批 append
    this.loadSeq = this.loadSeq + 1;
    const seq: number = this.loadSeq;
    this.loading = true;
    this.error = '';
    this.items = [];
    this.nextUrl = '';
    this.step = 0;
    this.noMore = false;
    this.moreError = '';
    try {
      const page: GalleryPage = await EhApi.loadList(this.requestUrl);
      if (seq === this.loadSeq) {
        this.items = page.items;
        this.nextUrl = page.nextUrl;
        this.countText = page.countText;
        // 先把缓存命中的评分同步补上（首屏就有星），未命中的再后台排队 —— 不 await
        this.enrich(page.items);
        // 第一页就没有 next（结果不足一页）时，无限滚动直接显示「没有更多了」，别让用户白滑。
        //
        // 但必须再加一个条件：**页码兜底也给不出下一段**才算到底。搜索页永远能拼出 page=N，
        // 所以即使 #unext 解析失败（站点改版、被限流页替换），结果也不会被截死在第一页；
        // 首页/收藏/观看这些没有 pageUrlOf 的列表仍旧是「没 next 就是到底」，行为不变。
        if (this.endless && page.nextUrl.length === 0 && this.pageUrlOf(1).length === 0) {
          this.noMore = true;
        }
        if (page.items.length === 0) {
          this.error = this.emptyHint;
        }
      }
    } catch (e) {
      if (seq === this.loadSeq) {
        const err: Error = e as Error;
        this.error = err.message;
      }
    }
    if (seq === this.loadSeq) {
      this.loading = false;
      this.refreshing = false;
    }
  }

  /**
   * 下一页地址。顺序本身就是 EH 的分页语义，不要调换：
   *
   *  1. **站点给的 next（`#unext`）优先**。EH 的列表/搜索结果翻页是**游标**式的，
   *     下一页只能跟着上一页 HTML 里的这个链接走：它可能带着我们拼不出来的参数
   *     （站点自己的偏移/会话态），自己按页码猜一定会漂。
   *  2. 父组件的 `pageUrlOf`（`&page=N`）只作**兜底**：站点没给 next 时才用
   *     （解析失败，或入口本身没有 next 语义）。
   *
   * 原来这里是反的（endless 下先问 pageUrlOf，拿不到才用 next），于是搜索页从来不走
   * `#unext`，只用 page=1/2/3… 往后翻；站点对搜索结果不认这个偏移时每页都回同一批，
   * 列表就把「重复」当成「到底」——这是「搜大标签只出十几条」的直接原因。
   */
  private nextPageUrl(): string {
    if (this.nextUrl.length > 0) {
      return this.nextUrl;
    }
    if (this.endless) {
      return this.pageUrlOf(this.step + 1);
    }
    return '';
  }

  /**
   * 追加并去重。
   *
   * EH 的分页边界会漂移（`next` 是按偏移取的，站点有新投稿时同一条画廊可能出现在相邻两页），
   * 直接 push 会让 ForEach 的 key 重复 —— 界面上就是两张一模一样的卡，点哪张都行但很困惑。
   */
  private merge(cur: Gallery[], next: Gallery[]): Gallery[] {
    const out: Gallery[] = cur.slice();
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < out.length; i++) {
      seen.add(out[i].gid + out[i].token);
    }
    for (let i = 0; i < next.length; i++) {
      const key: string = next[i].gid + next[i].token;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      out.push(next[i]);
    }
    return out;
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore) {
      return;
    }
    // 两套翻页都关着 = 纯静态列表（调用方只想展示一页）
    if (!this.pager && !this.endless) {
      return;
    }
    // 到底不再请求；上次失败也不自动重试 —— 触底回调会连着触发，不能拿它去打站点
    if (this.noMore || this.moreError.length > 0) {
      return;
    }
    const url: string = this.nextPageUrl();
    if (url.length === 0) {
      this.noMore = true;
      return;
    }
    const seq: number = this.loadSeq;
    this.loadingMore = true;
    try {
      const page: GalleryPage = await EhApi.loadList(url);
      if (seq === this.loadSeq) {
        const merged: Gallery[] = this.merge(this.items, page.items);
        this.items = merged;
        this.nextUrl = page.nextUrl;
        this.step = this.step + 1;
        // 新一页同样先吃缓存、再排队；只对新页 items 处理，已在队列里的 gid 会被去重
        this.enrich(page.items);
        // 「到底」只由站点给的**原始**信号判定，绝不看「去重后新增了几条」：
        //  1. 本页原始条数为 0 → 翻过了末页；
        //  2. 站点没给 next，且页码兜底也给不出地址 → 没有下一段；
        //  3. 站点的 next 指回了刚刚请求的这一页 → 它自己也没有下一页（否则原地死循环）。
        // 去重本身只做展示层过滤：站点分页边界会漂移（相邻两页出现同一批 gid 很正常），
        // 原来「added === 0 就判到底」会把这种正常重叠升级成永久到底 —— 搜索页因此只出一页。
        if (this.endless) {
          if (page.items.length === 0) {
            this.noMore = true;
          } else if (page.nextUrl.length === 0 && this.pageUrlOf(this.step + 1).length === 0) {
            this.noMore = true;
          } else if (page.nextUrl.length > 0 && page.nextUrl === url) {
            this.noMore = true;
          }
        }
      }
    } catch (e) {
      // 分页模式（首页/收藏）仍然静默：用户下拉重刷即可，不要在底部弹错误打断浏览；
      // 无限滚动才把失败摆到底部，否则用户只会看到一条永远加载不出来的列表。
      if (seq === this.loadSeq && this.endless) {
        const err: Error = e as Error;
        this.moreError = err.message;
      }
    }
    this.loadingMore = false;
  }

  /** 底部重试：先清掉错误，否则 loadMore 的「失败不自动重试」守卫会直接挡回去 */
  private retryMore(): void {
    this.moreError = '';
    this.loadMore();
  }

  /**
   * 列表页补评分 / 补标签（不阻塞渲染）。
   *
   * 数据来源只能是 gdata：列表 HTML 里没有分数（见 EhApi.parseRow 的注释），
   * v1.33.3 的「按 .ir 宽度推星」已经删掉。
   *
   * 流程：
   *  1. 先查 Db 缓存，命中就**同步**写回 Gallery —— 这样首屏直接有星，不用等网络；
   *  2. 没命中的按 25 条一批丢给 fetchGdata 排队（全局串行、间隔 ≥1s）；
   *  3. 每批回来改完内存对象后把 metaTick +1，卡片重绘。
   *
   * 这个方法本身是同步的：调用点不需要 await，列表已经把灰星卡片画出来了。
   */
  private enrich(items: Gallery[]): void {
    const pending: Gallery[] = [];
    for (let i = 0; i < items.length; i++) {
      const g: Gallery = items[i];
      if (g.rating > 0) {
        continue;
      }
      const hit: GalleryMetaRow | null = Db.galleryMeta(g.gid);
      if (hit !== null) {
        if (hit.rating > 0) {
          g.rating = hit.rating;
        }
        if (g.pages <= 0 && hit.pages > 0) {
          g.pages = hit.pages;
        }
        continue;
      }
      if (g.gid.length === 0 || g.token.length === 0 || this.metaQueued.has(g.gid)) {
        continue;
      }
      this.metaQueued.add(g.gid);
      pending.push(g);
    }
    for (let i = 0; i < pending.length; i += GDATA_BATCH_SIZE) {
      this.fetchMetaChunk(pending.slice(i, i + GDATA_BATCH_SIZE));
    }
  }

  /** 一批（≤25）gdata：回来后就地改 Gallery，再发重绘信号 */
  private async fetchMetaChunk(chunk: Gallery[]): Promise<void> {
    const refs: GalleryRef[] = [];
    for (let i = 0; i < chunk.length; i++) {
      const r: GalleryRef = { gid: chunk[i].gid, token: chunk[i].token };
      refs.push(r);
    }
    const list: GdataItem[] | null = await fetchGdata(refs);
    if (list === null) {
      // 失败：把 gid 放回候选，下次翻页/刷新还能重试（否则这本画廊整场都灰着）
      for (let i = 0; i < chunk.length; i++) {
        this.metaQueued.delete(chunk[i].gid);
      }
      return;
    }
    let changed: boolean = false;
    for (let i = 0; i < list.length; i++) {
      const meta: GdataItem = list[i];
      // 先落缓存：即使这个 gid 已经不在当前列表里（用户换了搜索词），下次打开也能直接命中
      Db.putGalleryMeta(meta.gid, meta.rating, meta.pages);
      const g: Gallery | null = this.findByGid(meta.gid);
      if (g === null) {
        continue;
      }
      if (g.rating <= 0 && meta.rating > 0) {
        g.rating = meta.rating;
        changed = true;
      }
      if (g.pages <= 0 && meta.pages > 0) {
        g.pages = meta.pages;
        changed = true;
      }
      // 标签：HTML 抓的优先（它的 name 是站点显示名，翻译要用），空着才用 gdata 补
      if (g.tags.length === 0 && meta.tags.length > 0) {
        this.fillTagsFromGdata(g, meta.tags);
        changed = true;
      }
    }
    if (changed) {
      this.metaTick = this.metaTick + 1;
    }
  }

  private findByGid(gid: string): Gallery | null {
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].gid === gid) {
        return this.items[i];
      }
    }
    return null;
  }

  /** gdata 的 `ns:name` → GalleryTag（与 HTML 解析同一套字段，配色走 Namespaces） */
  private fillTagsFromGdata(g: Gallery, raw: string[]): void {
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < raw.length; i++) {
      const s: string = raw[i];
      const colon: number = s.indexOf(':');
      if (colon <= 0 || colon >= s.length - 1) {
        continue;
      }
      const ns: string = s.substring(0, colon).trim();
      const key: string = s.substring(colon + 1).trim();
      if (ns.length === 0 || key.length === 0 || seen.has(s)) {
        continue;
      }
      seen.add(s);
      const tag: GalleryTag = new GalleryTag();
      tag.ns = ns;
      tag.key = key;
      // gdata 的 name 就是 key（没有站点显示名），不额外加 ns: 前缀 —— 卡片会自己剥
      tag.name = key;
      tag.color = Namespaces.of(ns).color;
      g.tags.push(tag);
    }
  }

  /**
   * 触底前预取多少条 ≈ 600vp。
   *
   * 为什么按「条数」而不是按偏移：List/Grid 的 onScrollIndex 只给下标，拿不到内容总高，
   * 精确算 600vp 需要自己累加每条高度，站点/样式一改就失效。按样式换算够用，
   * 数值取自 GalleryCard 各样式高度（极简 44 / 紧凑 132 / 详细 200）+ 6 的行距。
   */
  private prefetchAhead(): number {
    if (this.isThumb()) {
      return 6;   // 封面墙两列：约 3 行
    }
    if (this.listStyle === ListStyles.MINIMAL) {
      return 12;
    }
    if (this.listStyle === ListStyles.EXTENDED) {
      return 4;
    }
    return 5;
  }

  @Builder
  private moreRow() {
    Row({ space: Tokens.SPACE_SM }) {
      LoadingProgress()
        .width(Tokens.LOADING_SMALL)
        .height(Tokens.LOADING_SMALL)
        .color(Theme.subText())
      Text(this.loadingMore ? '正在加载更多…' : '继续下滑加载更多')
        .fontSize(Tokens.FONT_TAG)
        .fontColor(Theme.subText())
    }
    .width('100%')
    // 底栏高度 48（SPEC FOOTER_HEIGHT）：翻页提示和底栏等高，滚动到底时视觉不塌。
    // 它让位到底栏上方靠的是列表的 contentEndOffset(bottomInset) —— 这一行是最后一个
    // ListItem，末尾留白落在它之后，所以这里不再重复加底部外边距。
    .height(Tokens.FOOTER_HEIGHT)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 无限滚动的底部状态行：加载中 / 没有更多 / 失败重试。
   *
   * 不收值参数（工程约定 @Builder 不接会变的值）：文案靠 this 上的 @State 分支，
   * 状态一变这一行自己就重绘。
   *
   * 它是列表的最后一个 item：三种文案都读到了，用户正是在「滑到最底」这一刻看它，
   * 所以它必须停在底栏上方 —— 这件事由容器的 contentEndOffset(bottomInset) 保证，
   * 这里保持 FOOTER_HEIGHT 高、不再叠底部外边距（叠了会变成两段留白）。
   */
  @Builder
  private endlessFooter() {
    Row({ space: Tokens.SPACE_SM }) {
      if (this.moreError.length > 0) {
        Text('加载失败，点此重试')
          .fontSize(Tokens.FONT_TAG)
          .fontColor(Theme.accent())
          .height(Tokens.FOOTER_HEIGHT)
          .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG })
          .textAlign(TextAlign.Center)
          .onClick(() => this.retryMore())
      } else if (this.loadingMore) {
        LoadingProgress()
          .width(Tokens.LOADING_SMALL)
          .height(Tokens.LOADING_SMALL)
          .color(Theme.subText())
        Text('正在加载…')
          .fontSize(Tokens.FONT_TAG)
          .fontColor(Theme.subText())
      } else if (this.noMore) {
        Text('没有更多了')
          .fontSize(Tokens.FONT_TAG)
          .fontColor(Theme.subText())
      } else {
        Text('继续下滑加载更多')
          .fontSize(Tokens.FONT_TAG)
          .fontColor(Theme.subText())
      }
    }
    .width('100%')
    .height(Tokens.FOOTER_HEIGHT)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 空态 / 错误态共用一套内联样式：图标位（44 圆底）+ 13 号副标题 + 46 高次要按钮。
   * 两态合并是因为用户看到的都是「这里现在没内容」，只有提示文案不同；
   * 分开写会各自漂移成不同字号和内边距。
   */
  @Builder
  private emptyState(glyph: string, message: string) {
    Column({ space: Tokens.SPACE_MD }) {
      Text(glyph)
        .fontSize(Tokens.FONT_HEADING)
        .fontColor(Theme.subText())
        .width(Tokens.TOUCH_MIN)
        .height(Tokens.TOUCH_MIN)
        .textAlign(TextAlign.Center)
        .borderRadius(Tokens.RADIUS_ROUND)
        .backgroundColor(Theme.line())

      Text(message)
        .fontSize(Tokens.FONT_META)
        .fontColor(Theme.subText())
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: Tokens.SPACE_XXL, right: Tokens.SPACE_XXL })

      Text('重新加载')
        .fontSize(Tokens.FONT_BODY)
        .fontColor(Theme.accent())
        .height(Tokens.BUTTON_HEIGHT)
        .padding({ left: Tokens.SPACE_XL, right: Tokens.SPACE_XL })
        .textAlign(TextAlign.Center)
        .borderRadius(Tokens.RADIUS_MD)
        .backgroundColor(Theme.line())
        .onClick(() => this.reload())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  /** 浮层何时可见：刷新中，以及下拉/过线阶段（让反馈在第一次下拉位移就出现） */
  private refreshPillVisible(): boolean {
    return this.refreshing || this.refreshStatus === RefreshStatus.Drag
      || this.refreshStatus === RefreshStatus.OverDrag;
  }

  /**
   * 下拉刷新浮层：钉在顶栏下方居中。
   *
   * 为什么需要它（Refresh 自带的下拉区不够用）：
   *   Refresh 把下拉区画在**组件顶部**，而列表用 contentStartOffset(topInset) 从半透明
   *   顶栏下方开始 —— 那块区域整个被顶栏盖住。手指要走完一整个顶栏高度（≈100vp）
   *   才第一次看见任何文字，体感就是「要拉半屏」。浮层挂在 topInset 之下，拉一点点就出现。
   *
   * 三态都走这一颗：下拉 / 松手 / 刷新中，不再需要在下拉区里另画一套。
   * 所以上一版那个 refreshTip builder 被删掉了 —— 它画的位置本来就是看不见的。
   */
  @Builder
  private refreshPill() {
    Row() {
      // 外层 Stack 给材质一个**有界**的宽（MaterialPlane 内层材质是 width('100%')，
      // 宽度由内容自撑会解析到整屏，横铺成通栏色带），并承载描边与阴影。
      Stack({ alignContent: Alignment.Center }) {
        MaterialPlane({ kind: 'header', radius: 999, planeHeight: REFRESH_PILL_HEIGHT })
        Row({ space: 6 }) {
          if (this.refreshing) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(Theme.accent())
          } else {
            Text(this.refreshStatus === RefreshStatus.OverDrag ? '↑' : '↓')
              .fontSize(Tokens.FONT_TAG)
              .fontColor(Theme.subText())
              .height(16)
              .textAlign(TextAlign.Center)
          }
          Text(this.refreshing
            ? '正在刷新…'
            : (this.refreshStatus === RefreshStatus.OverDrag ? '松手刷新' : '下拉刷新'))
            .fontSize(Tokens.FONT_TAG)
            .fontColor(Theme.text())
            .maxLines(1)
        }
      }
      .width(REFRESH_PILL_WIDTH)
      .height(REFRESH_PILL_HEIGHT)
      .borderRadius(999)
      // 描边与阴影挂在不裁剪的这一层：材质自己按 radius 裁圆，边画在它上面会被削一半
      .border({ width: 0.7, color: Theme.btnEdge() })
      .shadow(Theme.floatShadow())
    }
    .width('100%')
    .height(REFRESH_PILL_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.None)
    .opacity(this.refreshPillVisible() ? 1 : 0)
    .translate({ y: this.refreshPillVisible() ? 0 : -6 })
    .animation({ duration: 160, curve: Curve.Smooth })
    .position({ x: 0, y: this.topInset + REFRESH_PILL_GAP })
  }

  /** 一行一条：极简 / 紧凑 / 详细 */
  @Builder
  private rowList() {
    // 行间距用 SPEC 的 GALLERY_GRID_GAP(6)：列表和封面墙取同一个间隙，切换样式时节奏不变
    List({ space: Tokens.GRID_GAP, scroller: this.scroller }) {
      ForEach(this.items, (g: Gallery) => {
        ListItem() {
          GalleryCard({
            g: g,
            listStyle: this.listStyle,
            transTick: this.tagTransTick,
            metaTick: this.metaTick,
            onTap: (item: Gallery) => this.onOpen(item)
          })
        }
      }, (g: Gallery) => g.gid + g.token)

      if (this.endless) {
        ListItem() {
          this.endlessFooter()
        }
      } else if (this.pager && this.nextUrl.length > 0) {
        ListItem() {
          this.moreRow()
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG })
    // 顶部避让交给 contentStartOffset 而不是 padding：padding 会被下拉刷新当成内容的一部分，
    // 刷新指示器会顶在顶栏下面出不来；contentStartOffset 只挪内容起点，指示器仍在屏幕内。
    .contentStartOffset(this.topInset)
    // 底部同理，而且是本问题的根因：底栏压在列表上，视口必须保持整屏高，
    // 只在内容末尾补一段留白，最后一张卡 / endlessFooter 才能滚到它上方完整露出。
    .contentEndOffset(this.bottomInset)
    .scrollBar(BarState.Off)
    .cachedCount(3)
    // 滚动偏移只给顶栏那颗「回到顶部」用；showTopHint 关着时这里立刻返回，等于没挂。
    //
    // **不读回调参数，改读 Scroller.currentOffset()**：onDidScroll 的两个参数在不同 API
    // / 不同容器上有两种口径（「累计偏移 + ScrollState」或「本帧增量 + ScrollState」），
    // 增量还得自己累加、换 URL 时要记得归零 —— 多一套状态就多一处会漂的地方。
    // Scroller 里拿到的**一定是累计偏移**，而且它本来就要为回顶而存在，不必再引入第二个来源。
    // 取绝对值：不同容器的偏移符号有正负两种写法，而按钮要的只是「离顶部多远」。
    .onDidScroll(() => {
      if (!this.showTopHint) {
        return;
      }
      this.onScrollOffset(Math.abs(this.scroller.currentOffset().yOffset));
    })
    // 重新可见时补报一次：媒体库切段会把父级记录的偏移归零，而列表自身停在原处，
    // 没有新的滚动事件就不会再上报 —— 顶栏的回顶钮于是在切回来后消失。
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, ratio: number) => {
      if (isVisible && this.showTopHint) {
        this.onScrollOffset(Math.abs(this.scroller.currentOffset().yOffset));
      }
    })
    .onScrollIndex((start: number, end: number) => {
      // 无限滚动按 600vp 换算出的条数预取；分页模式沿用原来的「剩 3 条」
      const ahead: number = this.endless ? this.prefetchAhead() : 3;
      if (end >= this.items.length - ahead) {
        this.loadMore();
      }
    })
  }

  /** 封面墙：两列等比封面，列宽由 columnsTemplate 均分 */
  @Builder
  private gridList() {
    Grid(this.scroller) {
      ForEach(this.items, (g: Gallery) => {
        GridItem() {
          GalleryCard({
            g: g,
            listStyle: ListStyles.THUMBNAIL,
            onTap: (item: Gallery) => this.onOpen(item)
          })
        }
      }, (g: Gallery) => 't-' + g.gid + g.token)

      if (this.endless) {
        // GridItem 默认只占一格，横跨两列才不会把状态行挤成半宽
        GridItem() {
          this.endlessFooter()
        }
        .columnStart(0)
        .columnEnd(1)
      } else if (this.pager && this.nextUrl.length > 0) {
        // GridItem 默认只占一格，横跨两列才不会把提示挤成半宽
        GridItem() {
          this.moreRow()
        }
        .columnStart(0)
        .columnEnd(1)
      }
    }
    .width('100%')
    .height('100%')
    .columnsTemplate('1fr 1fr')
    .columnsGap(Tokens.GRID_GAP)
    .rowsGap(Tokens.GRID_GAP)
    .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG })
    .contentStartOffset(this.topInset)
    // 封面墙与行列表同一口径：网格也吃这段底部留白，否则两列卡片的最后一行同样被底栏压住
    .contentEndOffset(this.bottomInset)
    .scrollBar(BarState.Off)
    .cachedCount(6)
    // 与 rowList 完全同一份口径（理由写在那边）：封面墙同样要能回报「离顶部多远」，
    // 否则切到缩略图样式后顶栏的回顶钮就再也不出现了。
    .onDidScroll(() => {
      if (!this.showTopHint) {
        return;
      }
      this.onScrollOffset(Math.abs(this.scroller.currentOffset().yOffset));
    })
    // 重新可见时补报一次：媒体库切段会把父级记录的偏移归零，而列表自身停在原处，
    // 没有新的滚动事件就不会再上报 —— 顶栏的回顶钮于是在切回来后消失。
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, ratio: number) => {
      if (isVisible && this.showTopHint) {
        this.onScrollOffset(Math.abs(this.scroller.currentOffset().yOffset));
      }
    })
    .onScrollIndex((start: number, end: number) => {
      // 封面墙一屏能放 6~8 张，分页模式提前 4 格预取更不容易看到空档；
      // 无限滚动改成按 600vp 换算（见 prefetchAhead）
      const ahead: number = this.endless ? this.prefetchAhead() : 4;
      if (end >= this.items.length - ahead) {
        this.loadMore();
      }
    })
  }

  build() {
    Stack() {
      if (this.loading) {
        Column({ space: Tokens.SPACE_MD }) {
          LoadingProgress()
            .width(Tokens.LOADING_SIZE)
            .height(Tokens.LOADING_SIZE)
            .color(Theme.subText())
          Text('加载中…').fontSize(Tokens.FONT_CAPTION).fontColor(Theme.subText())
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        // 文案等于 emptyHint 说明是真空列表，否则是请求失败，用不同图标位区分
        this.emptyState(this.error === this.emptyHint ? '∅' : '!',
          this.error.length > 0 ? this.error : this.emptyHint)
      } else {
        // **不传 builder**：旧版在下拉区里画「箭头 + 文字」，但那段区域画在组件顶部、
        // 被半透明顶栏盖住 —— 拉一小段看不见，要拉满一个顶栏高度才出现，等于没有。
        // 现在反馈统一交给 refreshPill（挂在顶栏下沿，拉一点点就出现，且能区分三态）。
        Refresh({ refreshing: $$this.refreshing }) {
          // 包一层 Column：Refresh 只接受单个子组件，而容器要按样式二选一
          Column() {
            if (this.isThumb()) {
              this.gridList()
            } else {
              this.rowList()
            }
          }
          .width('100%')
          .height('100%')
        }
        // 触发阈值从默认 64 放宽到 72：用户反馈「轻轻一滑就进刷新」比「拉不出来」更烦，
        // 稍微加长一点只吃真正的下拉意图，减少滚动到顶时的手势误触。
        // 110 是「减少滚动到顶时的误触」与「别让人拉到烦」之间的折中：
        // 指示器可见性已经不靠这个值了（浮层在下拉阶段就出现），
        // 所以这里可以放心往大调，只影响触发所需的位移。
        .refreshOffset(110)
        // 跟手比例 1：手指下拉多少、内容就下移多少。默认 0.5 时下拉 40 只位移 20，
        // 指示器被「吃」掉一半 —— 这也是必须拉很深才看得到文字的第二个原因。
        .pullDownRatio(1)
        .onRefreshing(() => {
          this.reload();
        })
        // 只把阶段记下来供指示器分支；请求仍由 onRefreshing 触发，这里不做任何副作用
        .onStateChange((state: RefreshStatus) => {
          this.refreshStatus = state;
        })
      }

      // 刷新状态浮层：必须是根 Stack 的**最后一个**子节点（压在所有内容与 Refresh 之上，
      // 包括空态/错误态），且与上面三种分支并列 —— 不放进 Refresh 内部，否则又会跟着
      // 下拉区一起被顶栏盖住。它始终挂载、只改透明度，见 refreshPill 的注释。
      this.refreshPill()
    }
    .width('100%')
    .height('100%')
  }
}
