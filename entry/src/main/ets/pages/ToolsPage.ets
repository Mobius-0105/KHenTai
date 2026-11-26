import { ArchiveSize, ArchiveResult, requestArchive, downloadArchiveTo, unzip } from '../core/Archive';
import { Theme } from '../core/Theme';
import { GalleryDetail, GalleryTag } from '../core/Models';
import { PageHeader, HEADER_BOTTOM_GAP } from '../components/PageHeader';
import { Torrent } from '../core/Torrents';
import { EhApi } from '../core/EhApi';
import { AppContext } from '../core/AppContext';
import { Http } from '../core/Http';
import { Downloader, DlTask } from '../core/Downloader';
import { fileIo, picker } from '@kit.CoreFileKit';

/**
 * 卡片描边宽度（本页新卡片统一用它）。
 *
 * 为什么不用阴影：本页卡片不是浮层，只是背景上的一块内容区，1vp 的 Theme.line() 实线
 * 就足够把它从 Theme.bg() 里「切」出来；加阴影会让「工具」这种密集列表页每张卡都往上浮，
 * 层级反而糊掉。种子卡与入口卡同值，保证两张卡的外轮廓一样粗。
 */
const CARD_EDGE: number = 1;

/**
 * PageHeader 材质自身在栏底多占的那段空隙（＝ components/PageHeader.ets 的
 * HEADER_BOTTOM_GAP）。它是页头内部的留白，不参与 headerHeight() 的计算。
 */
// 唯一来源是 PageHeader 导出的 HEADER_BOTTOM_GAP，不再各写一份 6
const HEADER_SURFACE_GAP: number = HEADER_BOTTOM_GAP;

/**
 * 页头 → 第一张卡想要达到的**视觉**间距。
 *
 * 为什么是 14 而不是 8：本页第一屏是三张「块级卡」（评分 / 归档 / 入口），不像首页那样
 * 是连续列表，首卡与页头之间需要更明确的「页面开始」信号；14 与卡内 12、卡间 8
 * 形成三个不同档次，不会被读成同一级留白。
 */
const CONTENT_BREATH: number = 12;

/**
 * 内容顶部让位 = 12（纯视觉呼吸），见 CONTENT_BREATH。
 *
 * 「页头 → 首卡」这段间距**只有这一个定义点**：页头是 Column 里的同级节点（不是浮层），
 * 它自身已经含 HEADER_SURFACE_GAP(6) 的底边留白；Scroll 不带 padding，这里补的 12 就是
 * 视觉间距的全部来源。以后要调间距只改 CONTENT_BREATH，别再往 Scroll / 内层 Column 上
 * 叠 padding（两处各加一半，数字就对不上，也很难查）。
 *
 * 至于「间距看起来在变」：不是这个数在动，而是 Scroll 的**回弹**把整块内容往下平移了
 * （见 build() 里 Scroll 的 .edgeEffect(EdgeEffect.None)）。数值没变、位置变了，
 * 所以修法是去掉回弹，而不是把 12 调大。
 */
const CONTENT_TOP: number = CONTENT_BREATH;

/**
 * 种子卡第二行的一枚元信息胶囊。
 *
 * 为什么把「文案 + 是否高亮」装进小对象：胶囊样式（10 号字 / line 底 / 999 圆角 /
 * 左右 6 上下 2）要复用三次，而本工程的 @Builder 约定不收值参数，用 ForEach + 数据
 * 比写三段重复的 Text 更好维护；颜色只有两档，就用一个布尔量表达，不引入色板字段。
 */
class TorrentChip {
  text: string = '';
  /** true = 用强调色（做种数是这条种子里唯一的「好」信号，值得高亮） */
  hot: boolean = false;

  constructor(text: string, hot: boolean) {
    this.text = text;
    this.hot = hot;
  }
}

/**
 * 「工具」页：评分 + 归档下载 + H@H / 相似入口 + 种子列表。
 *
 * 这几件事都不是浏览主链路，但都很重（归档要等 H@H、种子页与评分分布要各自请求），
 * 所以从详情页拆出来独立成页，避免把详情页撑成一个大杂烩。
 *
 * 每个数据源都**独立**成一段状态（torrents / ratingStats / hathUrl）：
 * 任何一个请求失败只影响自己那一块（空态或降级文案），不会连带把整页打成空白 ——
 * 这是本页最重要的容错约定，新增区块时务必沿用。
 *
 * 种子改为保存到系统「下载」后，沙箱里的 `filesDir/JHenTai/_torrent/` **不再写入**，
 * 但目录本身保留不动（本页既不 mkdir 也不删）：Storage 的「种子缓存」统计仍指着这个路径，
 * 老用户之前存下来的 .torrent 还在，数字依然是真实的；新用户这里是空目录 → 显示 0 字节，
 * 也是事实而不是 bug，「清理种子缓存」删空目录同样无害。若将来要把这一栏改成
 * 「下载目录里的种子」，那属于 Storage 页的事，不该在本页偷偷删路径让统计对不上。
 */
@Component
export struct ToolsPage {
  detail: GalleryDetail = new GalleryDetail();
  onBack: () => void = (): void => {};

  /**
   * 「查找相似画廊」要跳搜索页，而切 tab 属于宿主（Index）的能力。
   *
   * 默认空实现：Index 目前只给本页传了 detail / onBack，还没接这一根线。所以点击时会
   * **同时**走两条通道 —— ① 这个回调（宿主接上后就能切 tab + 出栈）；
   * ② AppStorage 的 searchInjectKeyword / searchInjectSeq（SearchPage 里已有 @Watch，
   * 页面已创建时会立刻按新词重查）。任一条存在就有效果，且都不需要改 Index。
   */
  onSearch: (q: string) => void = (q: string): void => {};

  @State private torrents: Torrent[] = [];
  @State private loadingTorrents: boolean = false;
  @State private torrentError: string = '';
  /** 正在保存的那一条（id 或 url）；非空时拒绝并发点击，同时让该行显示「正在保存…」 */
  @State private torrentBusy: string = '';
  @State private archiveMsg: string = '';
  @State private archiving: boolean = false;
  @State private archiveProgress: string = '';
  /** 评分分布：10 项（半星十档）或 5 项（整星五档）或空（解析失败 → 只显示平均分） */
  @State private ratingStats: number[] = [];
  /** 本次会话里我给的分（站点不返回「我的评分」，只能用本地这个值点亮星星） */
  @State private myRating: number = 0;
  @State private ratingBusy: boolean = false;
  /**
   * 待确认的星级：0 = 没有待确认。
   *
   * 评分不可撤销（站点只允许改分，不保留历史），点一下就直接提交太轻了。
   * 这里沿用「存储管理」那套二次确认：第一次点进入待确认、同星再点才提交，
   * 换星会重置待确认，3 秒不动自动撤销 —— 不做弹窗，避免遮挡这一页的评分分布。
   */
  @State private pendingRating: number = 0;
  private pendingRateTimer: number = -1;

  /**
   * 归档的待确认档位（'' / 'original' / 'resample'）。
   *
   * 归档会消耗 GP 或配额、而且站点侧不可撤回，一点就发请求太轻。
   * 沿用本页二次确认口径：第一次点把按钮换成「确认…」，再点同档才执行，3 秒复位。
   */
  @State private pendingArchive: string = '';
  private pendingArchiveTimer: number = -1;
  /** H@H 入口的待确认态（同一套口径；它会把整本加入下载队列） */
  @State private pendingHath: boolean = false;
  private pendingHathTimer: number = -1;
  @State private ratingLoading: boolean = false;
  /** 详情页 HTML 里解析到的 H@H 直链；空串 = 本站没提供，入口置灰 */
  @State private hathUrl: string = '';
  @State private toast: string = '';
  private toastTimer: number = -1;

  /**
   * 胶囊按钮的按下反馈（只动透明度）。
   *
   * 为什么用 @Styles 而不是在每处 onTouch 里改状态：胶囊出现在列表行与卡片里，位置不固定，
   * 给每个加一个 @State 会为「手感」引入一堆与业务无关的状态；@Styles 只放通用属性
   * （opacity 就是通用属性），可以被任意组件复用，也不会影响布局。
   */
  @Styles
  capsulePressed() {
    .opacity(0.6)
  }

  aboutToAppear(): void {
    // 三件事互不依赖，各自 try 各自降级（见 loadTorrentList / loadRating 的注释）
    this.hathUrl = this.pickHathUrl();
    this.loadTorrentList();
    this.loadRating();
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

  /**
   * 种子列表：GET `gallerytorrents.php?gid=..&t=..`（站点只给 HTML 表格）。
   *
   * 三种结果必须分开呈现，不能都收敛成一句「没有种子」：
   *   - 请求/解析异常 → torrentError = 具体错误（网络、限流、封 IP、HTTP 码）
   *   - 200 且解析到 0 条 → 「该画廊暂无种子」（这才是真的没有）
   *   - 有数据 → 列表
   */
  private async loadTorrentList(): Promise<void> {
    if (this.loadingTorrents) {
      return;
    }
    if (this.detail.gallery.gid.length === 0) {
      // 详情还没就绪就进来了（理论上不会）：给一句能自解释的话，让用户点「刷新」
      this.torrents = [];
      this.torrentError = '画廊信息尚未就绪，请返回重进或点「刷新」';
      return;
    }
    this.loadingTorrents = true;
    this.torrentError = '';
    try {
      this.torrents = await EhApi.loadTorrents(this.detail.gallery);
    } catch (e) {
      this.torrents = [];
      this.torrentError = (e as Error).message;
    }
    this.loadingTorrents = false;
  }

  /**
   * 评分分布：拉 gallerypopups.php?act=stats。
   *
   * 失败路径：EhApi.loadRatingStats 自己就把异常吞掉返回空数组（这张卡是补充信息，
   * 平均分与人数详情里已有），这里再包一层 try 只是防止「以后有人改成抛异常」时
   * 把未捕获异常带进事件循环 —— 那样整页会停在初始帧。
   */
  private async loadRating(): Promise<void> {
    if (this.ratingLoading) {
      return;
    }
    if (this.detail.gallery.gid.length === 0) {
      return;
    }
    this.ratingLoading = true;
    try {
      this.ratingStats = await EhApi.loadRatingStats(this.detail.gallery);
    } catch (e) {
      this.ratingStats = [];
    }
    this.ratingLoading = false;
  }

  /**
   * 从详情页原始 HTML 里找 H@H 入口。
   *
   * 两条判据，先严后宽：
   *   1. 任何指向 hath.network 的绝对地址（H@H 节点域名形如 `xxx.hath.network`）；
   *   2. 兜底：链接文字里带 `H@H` 的 <a>，取其 href（有些版面把地址放在别的域）。
   * 都找不到就返回空串 —— 调用方据此把这一行**置灰不可点**并提示「本站未提供 H@H」，
   * 而不是猜一个地址去下载（猜错就会把一段 HTML 错误页存成文件）。
   */
  private pickHathUrl(): string {
    const html: string = this.detail.rawHtml;
    if (html.length === 0) {
      return '';
    }
    const direct: RegExpMatchArray | null = html.match(/https?:\/\/[^"'\s<>]*hath\.network[^"'\s<>]*/i);
    if (direct !== null) {
      return direct[0];
    }
    const byText: RegExpMatchArray | null = html.match(/<a[^>]*href="([^"]+)"[^>]*>[^<]*H@H[^<]*<\/a>/i);
    if (byText !== null && byText[1].startsWith('http')) {
      return byText[1];
    }
    return '';
  }

  /**
   * 「通过 H@H 获取」：交给**现有下载器**（Downloader.enqueue），不在这里另造一套下载逻辑。
   *
   * 为什么不直接用解析到的那条链接去流式下载：整本下载要的是一页一页的原始图
   * （下载器内部会走 /s/ 页 → H@H 图床，自带限流、断点、队列），单条链接既不带分页
   * 也带不动续传。所以链接在这里是**可用性判据**，真正的搬运仍然走统一队列，
   * 进度与暂停在「媒体库」里可见。
   */
  private startHath(): void {
    if (this.hathUrl.length === 0) {
      return;
    }
    // 与 JHenTai 对齐的语义：这里的 H@H 指「逐页从 H@H 图床取图、存进本地库」，
    // 不是「打包下载」（那是上面的归档）。所以走 Downloader.enqueue —— 它会复用
    // /s/ 页里解析到的 hath 地址、断点续传、限流与队列，本页不另造下载通路。
    //
    // 已经在队列里就只提示、不重复排队：重复 enqueue 会产生同一个 gid 的第二条任务，
    // 两条并发写同一个目录，后完成的那条会把先完成的覆盖掉一部分。
    const exist: DlTask | null = Downloader.find(this.detail.gallery.gid, this.detail.gallery.token);
    if (exist !== null) {
      this.showToast('已在下载队列中（' + this.hathHost() + '）');
      return;
    }
    Downloader.enqueue(this.detail);
    this.showToast('已加入下载队列（H@H · ' + this.hathHost() + '）');
  }

  /** 解析到的 H@H 主机名（用于文案；解析不到返回「未知节点」） */
  private hathHost(): string {
    if (this.hathUrl.length === 0) {
      return '未知节点';
    }
    const m: RegExpMatchArray | null = this.hathUrl.match(/^https?:\/\/([^/]+)/);
    return m === null ? 'H@H 节点' : m[1];
  }

  /** 归档二次确认：第一次点只切文案，同档再点才真发请求（3 秒复位） */
  private askArchive(kind: string, original: boolean): void {
    if (this.archiving) {
      return;
    }
    if (this.pendingArchive === kind) {
      this.clearPendingArchive();
      this.doArchive(original);
      return;
    }
    this.pendingArchive = kind;
    this.clearPendingArchive();
    this.pendingArchiveTimer = setTimeout(() => {
      this.pendingArchive = '';
      this.pendingArchiveTimer = -1;
    }, 3000);
  }

  private clearPendingArchive(): void {
    if (this.pendingArchiveTimer >= 0) {
      clearTimeout(this.pendingArchiveTimer);
      this.pendingArchiveTimer = -1;
    }
  }

  /** H@H 二次确认：第一次点把右侧胶囊换成「确认?」，再点才入队（3 秒复位） */
  private askHath(): void {
    if (this.pendingHath) {
      this.pendingHath = false;
      if (this.pendingHathTimer >= 0) {
        clearTimeout(this.pendingHathTimer);
        this.pendingHathTimer = -1;
      }
      this.startHath();
      return;
    }
    this.pendingHath = true;
    if (this.pendingHathTimer >= 0) {
      clearTimeout(this.pendingHathTimer);
    }
    this.pendingHathTimer = setTimeout(() => {
      this.pendingHath = false;
      this.pendingHathTimer = -1;
    }, 3000);
  }

  /** 归档：请求 → 拿链接 → 流式下载 → 解压 */
  private async doArchive(original: boolean): Promise<void> {
    if (this.archiving) {
      return;
    }
    this.archiving = true;
    this.archiveMsg = '正在向站点申请归档…';
    this.archiveProgress = '';
    try {
      const r: ArchiveResult = await requestArchive(
        this.detail.gallery, original ? ArchiveSize.ORIGINAL : ArchiveSize.RESAMPLE);
      if (!r.ok || r.downloadUrl.length === 0) {
        this.archiveMsg = r.message.length > 0 ? r.message : '申请失败';
        this.archiving = false;
        return;
      }
      const dir: string = AppContext.get().filesDir + '/JHenTai/_archive';
      try {
        if (!fileIo.accessSync(dir)) {
          fileIo.mkdirSync(dir, true);
        }
      } catch (e) {
        this.archiveMsg = '无法创建归档目录';
        this.archiving = false;
        return;
      }
      const name: string = this.detail.gallery.gid + (original ? '_org' : '_res') + '.zip';
      const path: string = await downloadArchiveTo(r.downloadUrl, dir, name,
        (received: number, total: number) => {
          if (total > 0) {
            this.archiveProgress = Math.round(received * 100 / total).toString() + '%';
          } else {
            this.archiveProgress = (received / 1048576).toFixed(1) + ' MB';
          }
        });
      if (path.length === 0) {
        this.archiveMsg = '下载失败（可能没等到 H@H 生成，稍后重试）';
        this.archiving = false;
        return;
      }
      this.archiveMsg = '下载完成，正在解压…';
      const outDir: string = dir + '/' + this.detail.gallery.gid;
      const ok: boolean = await unzip(path, outDir);
      this.archiveMsg = ok ? ('已解压到 ' + outDir) : '解压失败（文件可能不是 zip）';
      this.showToast(ok ? '归档已就绪' : '解压失败');
    } catch (e) {
      this.archiveMsg = (e as Error).message;
    }
    this.archiving = false;
  }

  /** 一行的唯一键：有 id 用 id，没有就退回 url（同一份列表里 url 必然唯一） */
  private torrentKey(t: Torrent): string {
    return t.id.length > 0 ? t.id : t.url;
  }

  /** 该行是否正在保存：决定「保存中…」文案和下载按钮的禁用态 */
  private isBusy(t: Torrent): boolean {
    return this.torrentBusy === this.torrentKey(t);
  }

  /**
   * 第二行的胶囊：尺寸 / 做种 / 连接。
   *
   * 为什么把原本一行挤着的「大小 · 做种/连接 · 时间」拆开：
   *  - 尺寸、做种、连接是三个**不同量纲**的字段，用「 · 」串成一句时视线要逐字读；
   *    拆成胶囊后每项自带边界，扫一眼就能定位「这条种子做种多少」。
   *  - 做种数高亮（accent）：它是选哪条种子的唯一判据，其余两项只是描述。
   *  - 做种为 0 时不标强调色：0 做种不是「好信号」，高亮反而误导。
   * 时间挪到第三行右对齐，因为它只用于「新旧」判断，优先级低于前两项。
   */
  private chipsOf(t: Torrent): TorrentChip[] {
    const out: TorrentChip[] = [];
    if (t.sizeText.length > 0) {
      out.push(new TorrentChip(t.sizeText, false));
    }
    // 「连接」沿用本页旧文案（站点表格里这一列是 peers，即下载者），
    // 不写「下载」是为了和右侧那颗「下载」按钮区分开 —— 同一屏两个「下载」会指错东西。
    out.push(new TorrentChip('做种 ' + t.seeds.toString(), t.seeds > 0));
    out.push(new TorrentChip('连接 ' + t.peers.toString(), false));
    return out;
  }

  /** 千分位：评分人数常见四五位，裸数字读不出量级 */
  private fmtCount(n: number): string {
    const s: string = Math.round(Math.max(0, n)).toString();
    let out: string = '';
    for (let i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 === 0) {
        out += ',';
      }
      out += s.charAt(i);
    }
    return out;
  }

  /** 平均分：0 表示站点没有评分，用「—」而不是 0.0（0.0 会被读成「很难看」） */
  private ratingAvgText(): string {
    const r: number = this.detail.gallery.rating;
    return r <= 0 ? '—' : r.toFixed(1);
  }

  /**
   * 评分人数：详情页解析到的 ratingCount 优先；它是 0（老页面 / 解析失败）时
   * 用分布求和顶上 —— 两个都是站点给的原始数字，不造数据。
   */
  private ratingCountValue(): number {
    if (this.detail.ratingCount > 0) {
      return this.detail.ratingCount;
    }
    let sum: number = 0;
    for (let i = 0; i < this.ratingStats.length; i++) {
      sum += this.ratingStats[i];
    }
    return sum;
  }

  private ratingCountText(): string {
    const n: number = this.ratingCountValue();
    return n > 0 ? this.fmtCount(n) + ' 人评分' : '暂无评分';
  }

  /**
   * 单档条形宽度：按**最大档**归一，不是按总人数。
   *
   * 评分分布天然长尾（多数票集中在最高两档），按总人数归一会让其余八条都被压成
   * 一两像素的线，等于没画；按最大档归一眼就能看出各档的相对高度。
   * 非零档给 2% 下限，避免「有票但看不见」。
   */
  private barPct(count: number): string {
    let max: number = 0;
    for (let i = 0; i < this.ratingStats.length; i++) {
      if (this.ratingStats[i] > max) {
        max = this.ratingStats[i];
      }
    }
    if (max <= 0) {
      return '0%';
    }
    const pct: number = count <= 0 ? 0 : Math.max(2, Math.round(count * 100 / max));
    return pct.toString() + '%';
  }

  /**
   * 标签 → EH 精确搜索词。
   *
   * 与详情页点标签（DetailPage.searchQueryOf）同一套口径：`ns:"text$"`，`$` 写在引号内，
   * 表示精确匹配；含空格的标签必须带引号，否则 EH 会把后半段当独立关键词。
   * 这里重写一遍而不是复用详情页的私有方法：两个页面之间没有可共享的导出点，
   * 而为一行跳转去改 DetailPage 不划算（口径只有三行，注释对齐即可）。
   */
  private tagQuery(tag: GalleryTag): string {
    const ns: string = tag.ns.toLowerCase();
    const key: string = tag.key.length > 0 ? tag.key : tag.name;
    if (key.indexOf(' ') >= 0) {
      return ns + ':"' + key + '$"';
    }
    return ns + ':' + key + '$';
  }

  /** 相似搜索词：前两个 tag 空格相连（EH 多条件默认 AND）；不足两个就用一个，一个都没有返回空串 */
  private similarQuery(): string {
    const tags: GalleryTag[] = this.detail.tags;
    if (tags.length === 0) {
      return '';
    }
    let q: string = this.tagQuery(tags[0]);
    if (tags.length > 1) {
      q = q + ' ' + this.tagQuery(tags[1]);
    }
    return q;
  }

  /** 副标题：「按 tag1 + tag2」；只有一个 tag 时不画那个多余的加号 */
  private similarHint(): string {
    const tags: GalleryTag[] = this.detail.tags;
    if (tags.length === 0) {
      return '';
    }
    if (tags.length < 2) {
      return '按 ' + tags[0].name;
    }
    return '按 ' + tags[0].name + ' + ' + tags[1].name;
  }

  /**
   * 跳搜索：两条通道同时写（见 onSearch 的注释）。
   *
   * 为什么还要写 AppStorage：Index 没接 onSearch 时回调是空实现，光靠它点了没反应。
   * searchInject* 是本工程既有的「详情页点标签 → 搜索页」通道，SearchPage 的 @Watch
   * 会立刻重查；用户回到搜索 tab 就能看到结果（已创建时结果甚至已经拉好了）。
   * 这不是新机制，只是把同一个敲门方式在工具页复用一次。
   */
  private openSimilar(): void {
    const q: string = this.similarQuery();
    if (q.length === 0) {
      return;
    }
    this.onSearch(q);
    AppStorage.setOrCreate<string>('searchInjectKeyword', q);
    const cur: number | undefined = AppStorage.get<number>('searchInjectSeq');
    const seq: number = cur === undefined ? 0 : cur;
    AppStorage.setOrCreate<number>('searchInjectSeq', seq + 1);
    this.showToast('已提交搜索：' + q);
  }

  /**
   * 保存一条种子到系统「下载」目录。
   *
   * 为什么用 DocumentViewPicker 而不是直接写 /storage/.../Download：
   * 公共「下载」目录不属于应用沙箱，普通应用没有它的写权限，也没有哪条权限能让应用直接拿到
   * （MANAGE_DOWNLOAD 之类是系统应用才有的）。鸿蒙对公共目录走的是 SAF：用户在文件选择器里
   * 亲手确认一次位置，系统才把这一次的写权限（以 uri 形式）授予本应用。直接
   * openSync('/storage/.../Download/x.torrent') 在真机上只会拿到 EACCES 或
   * 「非沙箱路径」错误，所以这里必须走 picker —— 它默认落点就是文件管理器的「下载」，
   * 无需在 module.json5 声明任何存储权限，也不受分区/Sandbox 策略变化影响。
   *
   * 顺序是先下载字节、再弹选择器：.torrent 只有几十 KB，先拿到字节能保证用户确认位置后
   * 只剩一次本地写；反过来先弹选择器再下载，一旦下载失败就会在「下载」里留下一个 0 字节空文件。
   * 用户在系统选择器里返回（取消）时 picker 返回空数组，这里静默结束——取消不是失败，不提示。
   *
   * 关于防盗链：.torrent 直链是 x.x.x.x/torrent/<hash>.torrent，E-Hentai 不校验 Referer，
   * 但 ExHentai 必须带登录 Cookie，所以沿用 Http.getBytes（自动带 Cookie 罐），
   * Referer 给种子页地址、与浏览器点下载的行为一致。失败常常是「200 + 一段 HTML 错误页」，
   * 因此拿到字节后仍校验 bencode 头（首字节必须是 'd'），不能把 HTML 存成 .torrent。
   *
   * 注意：这里不再往沙箱 `filesDir/JHenTai/_torrent/` 落盘（缓存目录本身保留，见上方注释）。
   */
  private async downloadTorrent(t: Torrent): Promise<void> {
    if (this.torrentBusy.length > 0) {
      return;
    }
    this.torrentBusy = this.torrentKey(t);
    try {
      const referer: string = EhApi.torrentsUrl(this.detail.gallery);
      const bytes: ArrayBuffer | null = await Http.getBytes(t.url, referer);
      if (bytes === null) {
        this.showToast('种子下载失败（可能已被删除或需要登录）');
        return;
      }
      if (bytes.byteLength === 0 || new Uint8Array(bytes, 0, 1)[0] !== 0x64) {
        // 'd' = bencode 字典；不是它就是站点返回的错误页
        this.showToast('站点没有返回种子文件，稍后再试');
        return;
      }
      const name: string = (t.id.length > 0 ? t.id : Date.now().toString()) + '.torrent';
      // context 用 AppContext 里那份 UIAbilityContext：picker 要的是能代表当前窗口的 Context，
      // 页面里的 getUIContext().getHostContext() 与它是同一个对象，走 AppContext 与本页其它
      // 取 filesDir 的地方保持一致。
      const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(AppContext.get());
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      // 只给建议文件名；目录由用户在系统面板里决定（默认就是「下载」），不硬编码路径
      options.newFileNames = [name];
      const uris: string[] = await viewPicker.save(options);
      if (uris.length === 0) {
        // 用户在选择器里点了返回：静默结束，不写提示（取消 ≠ 失败）
        return;
      }
      // 写 uri：picker 已经建好空文件，直接 READ_WRITE 拿 fd 写入即可，
      // 不要再加 CREATE（对 uri 加 CREATE 在部分设备上会报「文件已存在」）。
      const file: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE);
      try {
        fileIo.writeSync(file.fd, bytes);
      } finally {
        // 必须 closeSync：不关 fd 的话落盘时机不确定，用户在文件管理器里可能看到 0 字节
        fileIo.closeSync(file);
      }
      this.showToast('已保存到「下载」：' + name);
    } catch (e) {
      // 部分机型在取消时不是返回空数组而是抛异常，这里按文案兜一层，避免把「取消」报成失败。
      // 用 '' + 强制拼成字符串：BusinessError.message 在个别分支是 undefined，
      // 直接 .toLowerCase() 会在 catch 里二次抛异常（虽然 finally 仍会复位状态，但日志会很脏）。
      const msg: string = '' + (e as Error).message;
      if (msg.toLowerCase().indexOf('cancel') < 0) {
        this.showToast('保存种子失败');
      }
    } finally {
      // 必须放在 finally：上面的失败分支是 return，写在 try 之后会漏掉，
      // 结果 torrentBusy 永远非空 → 之后每次点击都被「并发保护」挡掉（= 点了没反应）
      this.torrentBusy = '';
    }
  }

  build() {
    Column() {
      PageHeader({
        title: '更多',
        subtitle: this.archiving ? '正在处理…' : '',
        onBack: () => this.onBack()
      })

      Scroll() {
        Column({ space: 14 }) {
          // ---- 评分
          //
          // 放在最前：进这个页面的人刚在详情页看完整本，第一件想知道的是「它到底好不好」，
          // 评分卡压在最上面，与详情页顶部的评分形成连续阅读。
          this.ratingCard()

          // ---- 相似：紧跟评分。
          // 用户看完评分自然会想「还有没有类似的」，这两张卡是同一条思路的下一步；
          // H@H / 归档都是“拿到整本”的手段，属于另一组，排在后面。
          if (this.detail.tags.length > 0) {
            this.similarCard()
          }

          // ---- 归档
          this.archiveCard()

          // ---- H@H（下载手段，与上面的相似分开，理由见 hathCard 注释）
          this.hathCard()

          // ---- 种子区：**一张卡**装表头 + 全部种子条目。
          //
          // 之前是「表头一张卡、每条种子各自一张卡」，于是表头与列表在视觉上被切成两组；
          // 现在合成一张：卡内表头（种子 + 刷新）→ 0.5 发丝线 → 每个种子一段，
          // 段与段之间用同一条发丝线分。卡内不再嵌套卡片（嵌套会多出两层圆角与阴影）。
          Column() {
            Row({ space: 8 }) {
              Text('种子').fontSize(13).fontColor(Theme.text())
              Blank()
              // 刷新只剩这一处：接口是整页重拉，挂到每一行在语义上是错的
              Text('刷新')
                .fontSize(11)
                .fontColor(Theme.accent())
                .fontWeight(FontWeight.Medium)
                .padding({ left: 8, right: 4, top: 4, bottom: 4 })
                .enabled(!this.loadingTorrents)
                .opacity(this.loadingTorrents ? 0.45 : 1)
                .onClick(() => this.loadTorrentList())
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            if (this.loadingTorrents || this.torrents.length === 0) {
              // 读取中 / 空 / 失败：一行说明 + 可选重试，不再单独占一张卡
              this.torrentPlaceholderRow()
            } else {
              ForEach(this.torrents, (t: Torrent) => {
                Divider()
                  .strokeWidth(0.5)
                  .color(Theme.line())
                  .margin({ top: 10, bottom: 10 })

                Column({ space: 6 }) {
                  // 第一行：种子名独占。
                  //
                  // 为什么把「下载」从这一行挪走：名字与胶囊同排时，名字的可用宽度被 28 高的
                  // 按钮压掉一截，长名字几乎一进来就是省略号，而种子名恰恰是选种子的第一判据。
                  // 现在名称吃满整行，动作下移到第三行右端（见下）。
                  // layoutWeight(1) 必须留在 Row 里：在 Column 里它表示「纵向占比」，会把行高撑开。
                  Row() {
                    Text(t.name)
                      .fontSize(13)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Theme.text())
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)

                  // 元信息胶囊：Flex 换行，避免窄屏把最后几颗挤出卡外
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(this.chipsOf(t), (c: TorrentChip) => {
                      Text(c.text)
                        .fontSize(10)
                        .fontColor(c.hot ? Theme.accent() : Theme.subText())
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .borderRadius(999)
                        .backgroundColor(Theme.line())
                        .maxLines(1)
                        .margin({ right: 6, bottom: 4 })
                    }, (c: TorrentChip) => t.url + c.text)
                  }
                  .width('100%')

                  // 第三行：左「发布日期」+ 右「下载」。
                  //
                  // 日期从右下移到左下：它属于「这条种子是什么」的说明，跟上面的胶囊同侧起排，
                  // 三条信息共用一条左基准线；右下则专门留给动作 —— 一端读信息、一端做动作，
                  // 扫视时不会被按钮截断。
                  // Blank() 负责顶开两端：日期缺失（老种子没有 added）时它照样吃掉整段空隙，
                  // 「下载」不会因为少一段文字就往左跑，每一条的按钮都对齐在同一条右基准线上。
                  Row() {
                    if (t.added.length > 0) {
                      Text(t.added)
                        .fontSize(10)
                        .fontColor(Theme.subText())
                        .textAlign(TextAlign.Start)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    Blank()
                    if (this.isBusy(t)) {
                      Text('保存中…').fontSize(10).fontColor(Theme.subText())
                    } else {
                      // 只有这颗胶囊可点：整卡（或整行）可点会让「横向滑一下」「按住准备滚动」
                      // 都弹系统文件选择器 —— 行本身就是滚动热区，热区只留按钮，
                      // 点击意图才和视觉一致。
                      Text('下载')
                        .height(28)
                        .fontSize(12)
                        .textAlign(TextAlign.Center)
                        .fontColor(Color.White)
                        .padding({ left: 14, right: 14 })
                        .borderRadius(999)
                        .backgroundColor(Theme.accent())
                        .stateStyles({ pressed: this.capsulePressed })
                        .onClick(() => this.downloadTorrent(t))
                    }
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                // 故意不挂 onClick：热区只在「下载」胶囊上（见第三行注释）
              }, (t: Torrent) => t.url)
            }
          }
          .width('100%')
          .padding(12)
          .borderRadius(12)
          .backgroundColor(Theme.card())
          .border({ width: CARD_EDGE, color: Theme.line() })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        // 顶部让位 = 12（纯视觉呼吸），见 CONTENT_TOP。
        // Scroll 不支持 contentStartOffset，且本页 PageHeader 是 Column 里的同级节点
        // （不是浮层），Scroll 顶边已经等于「栏底 + 6」，所以这里只补视觉呼吸，不叠加栏高。
        .padding({ left: 16, right: 16, top: CONTENT_TOP, bottom: 40 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // 间距「会变」的根因就在这里：Scroll 默认 edgeEffect 是 Spring，下拉到顶后再拉会把
      // **整个内容层**（上面那个 Column）整体往下平移，Column 的 padding 并没有变，
      // 变的只是它在视口里的 y —— 于是「页头 → 首卡」从 12 涨到 12+回弹量，松手又弹回去。
      // 顶栏本身是 Column 的同级节点、不参与滚动，所以只要关掉回弹，这段间距就恒为 12。
      // 为什么选 None 而不是给顶栏加背景盖住：本页首卡不是列表项（一张大卡），越界回弹
      // 露出来的只有页面底色，没有任何「继续拉还有内容」的信息，关掉不损失语义。
      .edgeEffect(EdgeEffect.None)
      // 内容不足一屏时靠上排：Scroll 默认可能把内容视为可居中对象（尤其外层有
      // layoutWeight 撑满高度时），显式 align Top 后首卡到顶栏的距离恒为 CONTENT_TOP。
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 提交评分。
   *
   * 顺序是「先提交、成功后再刷统计」：先刷新会把还没生效的平均分拉回来，
   * 界面上表现为「点了星，数字没变」，用户会重复点。
   */
  /** 点星只记录选择；真正提交由右上角那颗「提交 N 星」按钮触发 */
  private askRate(stars: number): void {
    if (this.ratingBusy) {
      return;
    }
    this.pendingRating = stars;
    this.clearPendingRate();
    this.pendingRateTimer = setTimeout(() => {
      this.pendingRating = 0;
      this.pendingRateTimer = -1;
    }, 4000);
  }

  /** 提交当前选中的星数；没有选中就忽略 */
  private submitRating(): void {
    if (this.pendingRating <= 0 || this.ratingBusy) {
      return;
    }
    const stars: number = this.pendingRating;
    this.clearPendingRate();
    this.pendingRating = 0;
    this.rate(stars);
  }

  private clearPendingRate(): void {
    if (this.pendingRateTimer >= 0) {
      clearTimeout(this.pendingRateTimer);
      this.pendingRateTimer = -1;
    }
  }

  private async rate(stars: number): Promise<void> {
    if (this.ratingBusy) {
      return;
    }
    this.ratingBusy = true;
    try {
      await EhApi.rateGallery(this.detail.gallery, stars);
      this.myRating = stars;
      this.showToast('已评分 ' + stars.toString() + ' 星');
      await this.loadRating();
    } catch (e) {
      this.showToast((e as Error).message);
    }
    this.ratingBusy = false;
  }

  /** 归档卡：两档打包按钮 + 进度/结果一行（内容与文案沿用原实现） */
  /**
   * 评分卡：平均分 + 人数（右上角是提交按钮）+ 五颗星 + 分布。
   *
   * 提交按钮放在**卡片右上角**而不是星星旁边：星级是「选」，按钮是「确认」，
   * 两者的位置要分开，否则连续点星很容易误触到提交。
   * 选了星才出现、4 秒不动自动消失（评分站点侧不可撤回，中间态不能一直挂着）。
   */
  @Builder
  private ratingCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text(this.ratingAvgText())
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .lineHeight(26)
          .fontColor(Theme.text())
        Text(this.ratingCountText())
          .fontSize(10)
          .fontColor(Theme.subText())
          .layoutWeight(1)

        if (this.pendingRating > 0) {
          Text(this.ratingBusy ? '提交中…' : '提交 ' + this.pendingRating.toString() + ' 星')
            .height(26)
            .fontSize(11)
            .fontColor(Color.White)
            .padding({ left: 10, right: 10 })
            .borderRadius(999)
            .backgroundColor(Theme.accent())
            .opacity(this.ratingBusy ? 0.5 : 1)
            .onClick(() => {
              this.submitRating();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 星级：点一下只记录选择，不提交
      Row({ space: 6 }) {
        ForEach([1, 2, 3, 4, 5], (n: number) => {
          Text('★')
            .fontSize(20)
            .fontColor(n <= (this.pendingRating > 0 ? this.pendingRating : this.myRating)
              ? Theme.accent() : Theme.subText())
            .opacity(this.ratingBusy ? 0.5 : 1)
            .onClick(() => {
              this.askRate(n);
            })
        }, (n: number) => 'rate-star-' + n.toString())
        Text(this.myRating > 0 ? '已评 ' + this.myRating.toString() + ' 星' : '点星评分')
          .fontSize(10)
          .fontColor(Theme.subText())
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.ratingStats.length > 0) {
        Column({ space: 5 }) {
          // 档位数字由长度反推：10 项就是 10..1（半星十档），5 项就是 5..1
          ForEach(this.ratingStats, (count: number, i: number) => {
            Row({ space: 8 }) {
              Text((this.ratingStats.length - i).toString())
                .fontSize(10)
                .fontColor(Theme.subText())
                .width(16)
                .textAlign(TextAlign.End)
              // 底槽 + 填充叠在 Stack 里：底槽永远满宽，填充按比例
              Stack({ alignContent: Alignment.Start }) {
                Row()
                  .width('100%')
                  .height(4)
                  .borderRadius(2)
                  .backgroundColor(Theme.line())
                Row()
                  .width(this.barPct(count))
                  .height(4)
                  .borderRadius(2)
                  .backgroundColor(Theme.accent())
              }
              .layoutWeight(1)
              .height(4)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          })
        }
        .width('100%')
      } else if (this.ratingLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(12).height(12).color(Theme.subText())
          Text('读取评分分布…').fontSize(10).fontColor(Theme.subText())
        }
      } else {
        Text('站点未给出评分分布，只显示平均分')
          .fontSize(10)
          .fontColor(Theme.subText())
          .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(Theme.card())
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private archiveCard() {
    Column({ space: 10 }) {
      Text('归档下载').fontSize(13).fontColor(Theme.text()).width('100%')
      Text('由站点打包整本（走 H@H，需要 GP 或配额）。下载后会自动解压到沙箱。')
        .fontSize(10)
        .fontColor(Theme.subText())
        .width('100%')
      Row({ space: 10 }) {
        this.archiveButtonOriginal()
        this.archiveButtonResample()
      }
      .width('100%')
      if (this.archiveMsg.length > 0) {
        Text(this.archiveMsg + (this.archiveProgress.length > 0 ? ' · ' + this.archiveProgress : ''))
          .fontSize(11)
          .fontColor(Theme.subText())
          .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(Theme.card())
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * H@H 入口卡。与「相似」分开成两张卡：
   * 它们是两件互不相关的事（一个下载、一个跳搜索），并排在一张卡里会被读成
   * 「同一组动作的两个选项」；分开之后各自都有独立标题，也更方便以后单独增删。
   */
  @Builder
  private hathCard() {
    Column({ space: 10 }) {
      // 解析不到链接时整行置灰、副标题直说「本站未提供 H@H」。
      // 置灰但**保留点击**：点了给 toast 解释原因，比「完全没反应」更容易判断是
      // 「站点没有」还是「应用出错」。
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text('通过 H@H 获取')
            .fontSize(13)
            .fontColor(this.hathUrl.length > 0 ? Theme.text() : Theme.subText())
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.hathUrl.length > 0
            ? '逐页经 H@H 图床取图（' + this.hathHost() + '），加入下载队列'
            : '本站未提供 H@H')
            .fontSize(10)
            .fontColor(Theme.subText())
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.hathUrl.length === 0 ? '不可用' : (this.pendingHath ? '确认?' : '下载'))
          .height(28)
          .fontSize(12)
          .textAlign(TextAlign.Center)
          .fontColor(this.hathUrl.length > 0 ? Theme.accent() : Theme.subText())
          .padding({ left: 12, right: 12 })
          .borderRadius(999)
          .border({ width: CARD_EDGE, color: Theme.line() })
          .opacity(this.hathUrl.length > 0 ? 1 : 0.5)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        if (this.hathUrl.length === 0) {
          this.showToast('本站未提供 H@H');
          return;
        }
        this.askHath();
      })
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor(Theme.card())
    .border({ width: CARD_EDGE, color: Theme.line() })
    .alignItems(HorizontalAlign.Start)
  }

  /** 相似画廊入口卡（单独一张）：tags 为空时调用方不渲染，这里不做空态 */
  @Builder
  private similarCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text('查找相似画廊')
            .fontSize(13)
            .fontColor(Theme.text())
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.similarHint())
            .fontSize(10)
            .fontColor(Theme.subText())
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 整张卡只有这颗胶囊挂 onClick（原来挂在下面那层 Row 上）。
        // 为什么收窄热区：这张卡在滚动列表里，手指「按住准备滑」时只要有一点位移就会被
        // 判成点击 —— 用户只是想看副标题，却被整页切走；而卡上唯一的动作本来就只有「搜索」，
        // 让热区等于按钮，语义与视觉才一致（卡片是说明，胶囊是动作）。
        Text('搜索')
          .height(28)
          .fontSize(12)
          .textAlign(TextAlign.Center)
          .fontColor(Theme.accent())
          .padding({ left: 12, right: 12 })
          .borderRadius(999)
          .border({ width: CARD_EDGE, color: Theme.line() })
          // 按下反馈只降透明度、不改底色：底色是 Theme.card() 上的描边胶囊，
          // 换底色会闪一下白/灰；降透明度在任何深浅色下都只是「按下去了一点」。
          .stateStyles({ pressed: this.capsulePressed })
          .onClick(() => this.openSimilar())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor(Theme.card())
    .border({ width: CARD_EDGE, color: Theme.line() })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 种子的加载 / 空 / 失败态：一张薄卡。
   *
   * 不收参数：三种状态全部从 this 推导（loadingTorrents / torrentError），
   * 符合本工程「@Builder 不按值收参」的约定 —— 传进来的布尔值在状态翻转时不会更新。
   */
  /** 种子区的读取 / 空 / 失败行：不带卡片底（它已经在种子卡内部） */
  @Builder
  private torrentPlaceholderRow() {
    Row({ space: 8 }) {
      if (this.loadingTorrents) {
        LoadingProgress().width(14).height(14).color(Theme.subText())
        Text('读取中…').fontSize(11).fontColor(Theme.subText()).layoutWeight(1)
      } else {
        Text(this.torrentError.length > 0 ? this.torrentError : '该画廊暂无种子')
          .fontSize(11)
          .fontColor(this.torrentError.length > 0 ? Theme.accent() : Theme.subText())
          .layoutWeight(1)
          .maxLines(2)
        if (this.torrentError.length > 0) {
          Text('重试')
            .fontSize(11)
            .fontColor(Theme.accent())
            .fontWeight(FontWeight.Medium)
            .padding({ left: 8, right: 4, top: 4, bottom: 4 })
            .onClick(() => {
              this.loadTorrentList();
            })
        }
      }
    }
    .width('100%')
  }

  @Builder
  private torrentPlaceholderCard() {
    Row({ space: 8 }) {
      if (this.loadingTorrents) {
        LoadingProgress().width(14).height(14).color(Theme.subText())
        Text('读取中…').fontSize(11).fontColor(Theme.subText()).layoutWeight(1)
      } else {
        Text(this.torrentError.length > 0 ? this.torrentError : '该画廊暂无种子')
          .fontSize(11)
          .fontColor(this.torrentError.length > 0 ? Theme.accent() : Theme.subText())
          .layoutWeight(1)
          .maxLines(2)
        // 有错误才需要重试；「确实没有种子」重试也是同一个结果，不给无效按钮
        if (this.torrentError.length > 0) {
          Text('重试')
            .fontSize(11)
            .fontColor(Theme.accent())
            .fontWeight(FontWeight.Medium)
            .padding({ left: 8, right: 4, top: 4, bottom: 4 })
            .onClick(() => {
              this.loadTorrentList();
            })
        }
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor(Theme.card())
    .border({ width: CARD_EDGE, color: Theme.line() })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 归档按钮拆成两颗无参 @Builder。
   *
   * 原来是一个 `archiveButton(label, original)`：按值传参的 @Builder 在 ArkUI 里
   * 不会随状态刷新，且本工程约定不收值参数，所以拆成「原始档 / 压缩档」两份 —
   * 差异只有三处字面量（文案、original、是否押 GP 的说明），重复成本可接受。
   */
  @Builder
  private archiveButtonOriginal() {
    Text(this.archiving ? '申请中…'
      : (this.pendingArchive === 'original' ? '确认下载原始档？' : '原始档'))
      .layoutWeight(1)
      .height(46)
      .fontSize(13)
      .fontColor(this.archiving ? Theme.subText() : Color.White)
      .textAlign(TextAlign.Center)
      .borderRadius(12)
      .backgroundColor(this.archiving ? Theme.line() : Theme.accent())
      .onClick(() => {
        this.askArchive('original', true);
      })
  }

  @Builder
  private archiveButtonResample() {
    Text(this.archiving ? '申请中…'
      : (this.pendingArchive === 'resample' ? '确认下载压缩档？' : '压缩档'))
      .layoutWeight(1)
      .height(46)
      .fontSize(13)
      .fontColor(this.archiving ? Theme.subText() : Color.White)
      .textAlign(TextAlign.Center)
      .borderRadius(12)
      .backgroundColor(this.archiving ? Theme.line() : Theme.accent())
      .onClick(() => {
        this.askArchive('resample', false);
      })
  }
}
