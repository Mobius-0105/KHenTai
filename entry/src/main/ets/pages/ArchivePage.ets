import { EhConsts } from '../core/Consts';
import { Gallery } from '../core/Models';
import { Prefs } from '../core/Prefs';
import { Theme } from '../core/Theme';
import { Tokens } from '../core/Tokens';
import { galleryBottomInset } from '../ui/GalleryListView';

/**
 * ============================ 存档数据契约 ============================
 *
 * 写入方在详情页（右上角「存档」按钮），本页只读、只做单条移除，**不改写入格式**：
 *
 *   Prefs key : 'archive_items'
 *   值        : JSON **字符串**（不是 preferences 的数组类型），内容是一个数组，
 *               每个元素形如 { gid: string, token: string, title: string,
 *                             thumb: string, time: number }
 *   time      : 毫秒时间戳，列表按它**倒序**（最近存档的排最前面）
 *
 * 为什么按「数组字符串」读而不是直接读数组：Prefs 只支持 number / string / boolean
 * 三种值，写入方只能 JSON.stringify 后存成字符串，所以这里必须自己 parse。
 *
 * 三种「空」都要当成没有存档，不能让页面白屏或崩：
 *   1) key 不存在 / 空串；2) JSON.parse 抛错；3) parse 出来不是数组（历史脏数据）。
 * 见 load()。
 */
const ARCHIVE_KEY: string = 'archive_items';

/** 网格左右留白：直接取 16（Tokens.SPACE_LG），与 GalleryListView 的网格同源 */
const PAGE_PAD: number = Tokens.SPACE_LG;
/**
 * 网格首行与顶栏之间的呼吸。
 *
 * 取 10 而不是 4：顶栏是压在内容上的一层材质，4 的间距在真机上读成「卡片贴着顶栏下沿」，
 * 和首页 listTopInset() 里那 10 同一口径；两页都是「材质顶栏 + 网格」，数字不一致就会
 * 在来回切页时看到首行起始位置差半格。只改这一个值，Grid 上不再叠 padding ——
 * contentStartOffset 已经是唯一的顶部让位来源（见 listTopInset）。
 */
const LIST_TOP_GAP: number = 10;
/** 卡片之间的间距：与封面墙同一套（Tokens.GRID_GAP 6），切段时节奏不变 */
const GRID_GAP: number = Tokens.GRID_GAP;
/**
 * 单条删除按钮的热区：28，图标 15 号字。
 *
 * 为什么从 24 放大到 28 而不是直接上 44：格子本身只有 4 列时约 78 宽，44 的圆底会盖掉半个信息区；
 * 28 配 15 号图标约 1:1.9，视觉上是个圆点而不是实心块，压在信息区右侧也不抢标题的注意力。
 */
const DEL_SIZE: number = 28;
/** 删除图标字号：与 28 的热区配套（原 13 号在 28 的圆底里会显得孤零零） */
const DEL_ICON_SIZE: number = 15;
/**
 * 标题/时间右侧为 × 预留的宽度：× 的热区 + 8 的间隙。
 *
 * 为什么需要「预留」：× 改成覆盖在信息区右侧之后就不再参与布局，文字会一直铺到卡片右内边距，
 * 末端会钻到 × 的圆底下（圆底是 Theme.line()，压上去就是糊成一块）。
 * 4 列窄卡可用宽度只有 ~58，28 + 8 = 36 已经是「还能看清两个字」与「不压按钮」的折中上限。
 */
const RIGHT_RESERVE: number = DEL_SIZE + 8;
/**
 * 封面比例：与封面墙（GalleryCard.thumbBody 的 `.aspectRatio(0.714)`）同值。
 *
 * 为什么不直接引 Tokens：SPEC 里只有 LIST_CARD_COVER_ASPECT(0.71) 被落成了令牌，
 * 封面墙那个 1:1.4 竖版是写在 GalleryCard 里的字面量，工程里没有 THUMB_ASPECT 令牌。
 * 这里复制同一个数（而不是 0.71）是为了让存档卡与收藏页封面墙**逐像素同比例**；
 * 将来若把 0.714 提成令牌，两处一起换。
 */
const THUMB_ASPECT: number = 0.714;
/** 列数下限 / 上限：与设置页的可选档位一致（2~4），越界值一律夹回区间 */
const COL_MIN: number = 2;
const COL_MAX: number = 4;

/**
 * 一条存档。
 *
 * 字段与契约一一对应，不增不减：本页移除单条时会把整份数组写回 Prefs，
 * 多出来的字段这里不认识就会被写丢，所以写入方加了字段要同步到这里。
 */
class ArchiveItem {
  gid: string = '';
  token: string = '';
  title: string = '';
  thumb: string = '';
  time: number = 0;
}

/**
 * 「存档」。
 *
 * 为什么单独一页而不是塞进历史页：两者数据源完全不同 —— 历史是「看过就自动记」，
 * 存档是「用户主动点存档」才有一条，混在一起会让「看过」把「想留着」冲淡。
 *
 * 结构与 HistoryPage 同构（嵌入模式 + 独立模式双支持）：
 *   - 嵌入媒体库时本页不画页头，顶栏由 LibraryPage 的沉浸材质顶栏给；
 *   - 顶部让位只由列表的 contentStartOffset 承担（顶栏高度由 LibraryPage 传入），
 *     列表视口保持整屏高，卡片能从材质顶栏背后穿过；
 *   - 独立使用时（`embedded: false`）在正常布局流里画一行标题，行为与历史页一致。
 *
 * 与历史页的差别有两点，都是需求本身决定的：
 *   1) 内容按网格排（封面是主体，一屏能看更多），不是一行一条的列表；
 *      列数 / 间距 / 封面比例 / 圆角全部取收藏页封面墙的同一套令牌与同一个 Prefs 来源，
 *      两页并排看是同一套卡片，只是存档多一行时间；
 *   2) 没有「清空」批量动作（需求没要求），只有每张卡的单条移除
 *      （× 覆盖在封面下沿到卡片下沿这段的右侧、垂直居中于信息区，不压封面）。
 */
@Component
export struct ArchivePage {
  onOpen: (g: Gallery) => void = (g: Gallery): void => {};
  /** 「去首页看看」按钮。由 LibraryPage 透传；没有接的时候点它不会有反应（见 LibraryPage 的注释） */
  onGotoHome: () => void = (): void => {};
  /** 嵌在媒体库的 Tabs 里：页头由外层给，本页不画 */
  @Prop embedded: boolean = false;
  /** 媒体库顶栏高度（含状态栏），由 LibraryPage 唯一计算后传入 */
  @Prop headerHeight: number = 0;

  /** 按 time 倒序排好的存档；解析失败 / 非数组时为空数组 */
  @State private items: ArchiveItem[] = [];
  /**
   * 列数。
   *
   * **只从 Prefs.columns()（'list_columns'）来，不在本页另存一份**：这是工程里唯一的列数来源，
   * 设置页写的就是这个 key，收藏页的网格也归它管。数值在 syncColumns() 里夹到 2~4。
   */
  @State private cols: number = COL_MIN;

  /**
   * 主题订阅位：Theme.xxx() 读的是不可观测的 Prefs，
   * 只有订阅 Theme.refresh() 写入的 'themeDark'，切主题时本页才会被标记重绘。
   */
  @StorageProp('themeDark') private themeDark: boolean = false;

  aboutToAppear(): void {
    this.syncColumns();
    this.load();
  }

  /**
   * 重读列数。
   *
   * 为什么单独一个方法、并且同时被 aboutToAppear 和 onVisibleAreaChange 调：
   * 收藏/历史两页的样式实时性走两条路 —— @StorageProp('listStyle') 订阅，加上切回 tab 时重读；
   * 而列数（'list_columns'）**不在 AppStorage 里**，只能像历史页 reload 那样「每次可见重读」。
   * 本页本来就要在可见时 load()，顺手把列数一起同步，设置改完切回来立刻就是新列数。
   */
  private syncColumns(): void {
    const c: number = Prefs.columns();
    this.cols = c < COL_MIN ? COL_MIN : (c > COL_MAX ? COL_MAX : c);
  }

  /**
   * 读存档。
   *
   * 为什么每一层都要兜：写入方是另一个页面，它可能还没写过（空串）、写坏了（parse 抛错）、
   * 或者留下旧版本的脏数据（parse 出来是个对象/数字）。三种情况一律落到「空列表」，
   * 页面显示空态而不是崩在 build 里。
   */
  private load(): void {
    const raw: string = Prefs.str(ARCHIVE_KEY, '');
    if (raw.length === 0) {
      this.items = [];
      return;
    }
    let list: ArchiveItem[] = [];
    try {
      const data: ArchiveItem[] = JSON.parse(raw) as ArchiveItem[];
      // parse 成功不代表是数组：JSON.parse('{}') 也会成功
      if (Array.isArray(data)) {
        list = data;
      }
    } catch (e) {
      list = [];
    }

    const out: ArchiveItem[] = [];
    for (let i = 0; i < list.length; i++) {
      const it: ArchiveItem = this.normalize(list[i]);
      // 缺 gid / token 的条目点不开详情，留着只会是一张死卡
      if (it.gid.length === 0 || it.token.length === 0) {
        continue;
      }
      out.push(it);
    }
    // 契约要求按 time 倒序展示；写入方理论上已排好，这里再排一次是为了不依赖对方。
    out.sort((a: ArchiveItem, b: ArchiveItem): number => b.time - a.time);
    this.items = out;
  }

  /**
   * 逐字段重建一条（与 Downloader.normalize 同一套写法）。
   *
   * 为什么不在 try 里直接信任 parse 结果：写入方换了版本、字段拼错、或者旧数据缺字段时，
   * 借 typeof 逐字段回落到默认值，页面不会因为一个 undefined 就整段空白。
   */
  private normalize(src: ArchiveItem): ArchiveItem {
    const it: ArchiveItem = new ArchiveItem();
    it.gid = typeof src.gid === 'string' ? src.gid : '';
    it.token = typeof src.token === 'string' ? src.token : '';
    it.title = typeof src.title === 'string' ? src.title : '';
    it.thumb = typeof src.thumb === 'string' ? src.thumb : '';
    it.time = typeof src.time === 'number' && src.time > 0 ? src.time : 0;
    return it;
  }

  /**
   * 单条移除：写回 Prefs 并更新列表。
   *
   * 只做「这一条」，不做清空/批量（需求没有要求批量操作）。
   * 写回的是完整数组 —— 契约是「整份数组存一个字符串」，没有删单条的子 key。
   */
  private remove(gid: string): void {
    const kept: ArchiveItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].gid !== gid) {
        kept.push(this.items[i]);
      }
    }
    this.items = kept;
    Prefs.put(ARCHIVE_KEY, JSON.stringify(kept));
  }

  /** 存档条目 -> 详情页用的 Gallery（详情页只认 gid/token + 展示字段，与历史页同一套） */
  private toGallery(it: ArchiveItem): Gallery {
    const g: Gallery = new Gallery();
    g.gid = it.gid;
    g.token = it.token;
    g.title = it.title;
    g.thumbUrl = it.thumb;
    // categoryLabel / categoryColor 故意不写：沿用 Gallery 的默认值。
    // 存档元素里没有分类字段，硬编一个色号会引入契约外的第二套色板。
    g.url = EhConsts.index(Prefs.site()) + '/g/' + it.gid + '/' + it.token + '/';
    return g;
  }

  private pad(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }

  /** 时间列：当天只显示时分，同年省略年份（与历史页完全同口径，两页看起来才是一套） */
  private timeText(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts);
    const now: Date = new Date();
    const hm: string = this.pad(d.getHours()) + ':' + this.pad(d.getMinutes());
    const sameDay: boolean = d.getFullYear() === now.getFullYear() &&
      d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
    if (sameDay) {
      return '今天 ' + hm;
    }
    const md: string = this.pad(d.getMonth() + 1) + '-' + this.pad(d.getDate());
    if (d.getFullYear() === now.getFullYear()) {
      return md + ' ' + hm;
    }
    return d.getFullYear().toString() + '-' + md;
  }

  /** 网格列模板：列数来自设置页。用循环拼而不是字符串 repeat，避免各 API 版本差异 */
  private gridTemplate(): string {
    let t: string = '1fr';
    for (let i = 1; i < this.cols; i++) {
      t = t + ' 1fr';
    }
    return t;
  }

  /**
   * 页面底色。两个分支同色：读 themeDark 只是为了和 AppStorage 建立依赖，
   * 取色规则仍统一交给 Theme（不在本页引入第二套色板）。
   */
  private pageBg(): string {
    if (this.themeDark) {
      return Theme.bg();
    }
    return Theme.bg();
  }

  /**
   * 网格顶部让位：
   *   嵌入 = 媒体库顶栏（传入）+ 首行呼吸（LIST_TOP_GAP，10）；
   *   独立 = 0（标题行在正常布局流里，不再额外让位）。
   * 与历史页 listTopInset() 同一套算法。
   */
  private listTopInset(): number {
    return this.embedded ? this.headerHeight + LIST_TOP_GAP : 0;
  }

  /** 独立使用时的页头：只有标题，没有批量动作（本页不做清空/批量删除） */
  @Builder
  private header() {
    Row() {
      Text('存档')
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text())
      Blank()
      if (this.items.length > 0) {
        Text(this.items.length.toString() + ' 条')
          .fontSize(11)
          .fontColor(Theme.subText())
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
    .alignItems(VerticalAlign.Center)
  }

  /** 媒体库顶栏「回到顶部」：LibraryPage 自增 tick，本页监听后把列表滚回顶部 */
  @StorageProp('libraryTopTick') @Watch('onTopTick') private libraryTopTick: number = 0;
  private listScroller: Scroller = new Scroller();
  /**
   * 不缓存「已上报」的本地布尔：媒体库切段时 LibraryPage 会把 libraryScrollY 归零，
   * 而本页列表还停在原处，本地缓存会认为「报过了」而永不再报 ——
   * 切回来顶栏的回顶钮就消失。改成与 AppStorage 现值比较，只写需要变化的那一次。
   */

  private onTopTick(): void {
    this.listScroller.scrollTo({ xOffset: 0, yOffset: 0,
      animation: { duration: 260, curve: Curve.Smooth } });
  }

  /**
   * 上报滚动位置给媒体库顶栏（读 `libraryScrollY` 决定回顶钮显隐）。
   * 只在跨过阈值时写一次：滚动是每帧回调，逐帧写 AppStorage 会连带顶栏材质一起重绘。
   */
  private reportLibraryScroll(): void {
    const y: number = Math.abs(this.listScroller.currentOffset().yOffset);
    const want: number = y > 480 ? 481 : 0;
    if ((AppStorage.get<number>('libraryScrollY1') ?? 0) !== want) {
      AppStorage.setOrCreate<number>('libraryScrollY1', want);
    }
    // 顶栏发丝线：内容是否已经顶到顶栏下沿（0.5 容差）。单独一条通道 —— 上面那组值
    // 被量化成 481/0，表达不了「离顶部 1vp」；只在布尔翻转时写，避免逐帧重绘顶栏。
    const hair: boolean = y > 0.5;
    if ((AppStorage.get<boolean>('libraryHair1') ?? false) !== hair) {
      AppStorage.setOrCreate<boolean>('libraryHair1', hair);
    }
  }

  build() {
    Column() {
      // 独立使用时带自己的标题行；嵌入媒体库时标题在 LibraryPage 的固定顶栏里
      if (!this.embedded) {
        this.header()
      }

      if (this.items.length === 0) {
        // 空态：版式照历史页（两行说明居中 + 让出悬浮底栏），
        // 但这里多一颗按钮 —— 历史和存档都是「详情页里的动作」产生的数据，
        // 用户第一次进来时最需要的是「去哪儿产生一条」。
        Column({ space: 10 }) {
          Text('还没有存档').fontSize(14).fontColor(Theme.subText())
          Text('详情页右上角点「存档」后，会出现在这里')
            .fontSize(11)
            .fontColor(Theme.subText())
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
          Text('去首页看看')
            .fontSize(13)
            .fontColor(Color.White)
            .padding({ left: 20, right: 20, top: 9, bottom: 9 })
            .borderRadius(10)
            .backgroundColor(Theme.accent())
            .onClick(() => this.onGotoHome())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        // 空态居中块避开悬浮底栏，口径与列表一致
        .padding({ bottom: galleryBottomInset() })
      } else {
        Grid(this.listScroller) {
          ForEach(this.items, (it: ArchiveItem) => {
            GridItem() {
              // 卡片整块内联在 ForEach 里，没有抽成 @Builder：
              // @Builder 的值参数不会随父状态更新（工程约定），而这里每一项都要吃自己的 time/title。
              Column() {
                // 封面：比例取 THUMB_ASPECT（与收藏页封面墙的 0.714 同一档），
                // 下面垫 line 色，图没加载出来时也不是一块空白。
                Stack({ alignContent: Alignment.Center }) {
                  if (it.thumb.length > 0) {
                    Image(it.thumb)
                      .width('100%')
                      .height('100%')
                      .objectFit(ImageFit.Cover)
                  } else {
                    // 没有缩略图时用标题前两个字占位（与封面墙/历史页同一手法），不留纯色空板
                    Text(it.title.length > 0 ? it.title.substring(0, 2) : '存档')
                      .fontSize(Tokens.FONT_TAG)
                      .fontColor(Theme.subText())
                  }
                }
                .width('100%')
                .aspectRatio(THUMB_ASPECT)
                .backgroundColor(Theme.line())
                .onClick(() => {
                  this.onOpen(this.toGallery(it));
                })

                // 信息区：Stack 覆盖，而不是「标题 + × 排同一行」。
                //
                // 为什么选 Stack 而不是继续用 Row：需求要 × 落在「封面下沿 → 卡片下沿」这段的
                // 垂直中线上，也就是**整块信息区**的垂直中心，不再是与标题那一行对齐。
                // alignContent: Alignment.End 一句话就给出「垂直居中 + 贴右」，不用按行高手算偏移；
                // 更关键的是 × 脱离布局流后，文字块能拿满整段信息区宽度 —— 原来 × 要占 28 的布局宽度，
                // 4 列窄卡的标题被压到只剩一个字（~26）。覆盖的代价是文字可能落到 × 底下，
                // 由标题/时间右侧的 RIGHT_RESERVE 预留兜住。
                //
                // × 写成最后一个子节点 = 叠在最上层，命中测试也先到它；而 Stack 自己没有 onClick，
                // 点 × 不会冒泡去开详情（打开详情只挂在标题 / 时间 / 封面这三块上，与改动前一致）。
                //
                // 内边距 10/10/8/10：左右不用 8 是因为卡片圆角 19，8 的时候标题首字会被圆角吃掉一点边；
                // 顶部 8 只隔一条封面（封面自己贴边，多给会把文字区推离封面），底部 10 是整卡收口，
                // 让时间那行不贴着圆角。上下不匀是故意的（8/10），不是笔误。
                Stack({ alignContent: Alignment.End }) {
                  Column({ space: 2 }) {
                    // 标题：maxLines(2) + 省略。原来限 1 行是因为 × 要与「那一行」垂直居中，
                    // 现在居中对象换成整块信息区，就没必要再把标题压成一行了；右侧 padding 预留
                    // RIGHT_RESERVE，保证两行文字都不会钻到 × 的圆底下面。
                    Text(it.title.length > 0 ? it.title : it.gid)
                      .fontSize(Tokens.FONT_CAPTION)
                      .fontColor(Theme.text())
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .padding({ right: RIGHT_RESERVE })
                      .onClick(() => {
                        this.onOpen(this.toGallery(it));
                      })

                    // 时间行同样预留右侧：标题只有 1 行时整块信息区才 ~30 高，28 的 × 几乎盖满它，
                    // 「今天 14:03」这种串刚好能顶到圆底上，不预留就会糊在一起。
                    Text(this.timeText(it.time))
                      .fontSize(Tokens.FONT_TAG)
                      .fontColor(Theme.subText())
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .padding({ right: RIGHT_RESERVE })
                      .onClick(() => {
                        this.onOpen(this.toGallery(it));
                      })
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)

                  // 单条移除：与历史页那行「删除」等价，格子更窄，只留一个 ×。
                  // 底色用 Theme.line()（与历史页删除按钮同一档），不写死半透明黑，跟着主题走。
                  // 尺寸 28（图标 15）不变：位置换了，热区大小与视觉配比仍按原值。
                  // 右侧内边距由外层 Stack 的 10 承担，× 自己不再加 margin，与文字区同一条基线上。
                  Text('×')
                    .fontSize(DEL_ICON_SIZE)
                    .fontColor(Theme.subText())
                    .width(DEL_SIZE)
                    .height(DEL_SIZE)
                    .textAlign(TextAlign.Center)
                    .borderRadius(DEL_SIZE / 2)
                    .backgroundColor(Theme.line())
                    .onClick(() => {
                      this.remove(it.gid);
                    })
                }
                .width('100%')
                .padding({ left: 10, right: 10, top: 8, bottom: 10 })
              }
              .width('100%')
              // 圆角取 RADIUS_ROW(19)：与 GalleryCard 的卡片圆角同一个令牌，
              // 两页的卡在滚动时边缘不会一高一低。
              .borderRadius(Tokens.RADIUS_ROW)
              .backgroundColor(Theme.card())
              // 裁掉封面直角，卡片才是圆角（封面自己不画圆角，只圆上面两个角要靠整卡裁切）
              .clip(true)
            }
          }, (it: ArchiveItem) => it.gid + it.time.toString())
        }
        .width('100%')
        .layoutWeight(1)
        // 列数、间距、左右留白与收藏页的网格同源：列数走 Prefs.columns()，
        // 间距是 Tokens.GRID_GAP(6)、留白是 Tokens.SPACE_LG(16)（GalleryListView.gridList 用的同一组）。
        .columnsTemplate(this.gridTemplate())
        .columnsGap(GRID_GAP)
        .rowsGap(GRID_GAP)
        .padding({ left: PAGE_PAD, right: PAGE_PAD })
        // 顶部让位交给 contentStartOffset：只挪内容起点，视口仍是整屏高，
        // 卡片才能滚到材质顶栏背后；写成容器 padding 会把视口截短，顶栏背后永远是底色。
        .contentStartOffset(this.listTopInset())
        // 底部同理：只在内容末尾补留白，最后一行才能滑到悬浮底栏上方。
        // 在底栏让位之外再多给 8：卡片圆角 19，纯让位值时最后一行会正好贴住底栏上沿，
        // 看起来像被切了一条；8 是本页现有的一档小间距，不引入新层级。
        .contentEndOffset(galleryBottomInset() + 8)
        .scrollBar(BarState.Off)
        .cachedCount(6)
        .onDidScroll(() => {
          this.reportLibraryScroll();
        })
        // 重新可见时补报：切段会把 libraryScrollY 归零，而列表仍停在原处，
        // 没有滚动事件就不会重报 —— 切回来回顶钮会消失。
        .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, ratio: number) => {
          if (isVisible) {
            this.reportLibraryScroll();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
    // tab 容器会一直保留页面实例，aboutToAppear 只跑一次；
    // 切回本 tab 时重新读一次 Prefs，否则刚在详情页存下的那条不会出现。
    // 列数也在这里一起重读：设置页改完列数（'list_columns' 不在 AppStorage 里，
    // 没有 @StorageProp 可订阅）切回来就该是新列数，时机与历史页 reload 完全一致。
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, ratio: number) => {
      if (isVisible && ratio > 0) {
        this.syncColumns();
        this.load();
      }
    })
  }
}
