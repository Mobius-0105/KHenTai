import { display } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { EhApi } from '../core/EhApi';
import { Theme } from '../core/Theme';
import { FavCats, Namespaces, Site } from '../core/Consts';
import { Gallery, GalleryDetail, GalleryTag, ImagePage, ThumbSlice, ThumbTile } from '../core/Models';
import { ImageLoader, ThumbPipeline, ThumbRef } from '../net/ImageLoader';
import { ImageDiskCache } from '../net/ImageDiskCache';
import { ThumbCropper } from '../net/ThumbCropper';
import { History, HistoryItem } from '../core/Prefs';
import { Downloader, DlTask } from '../core/Downloader';
import { TagTrans } from '../core/TagTrans';
import { Prefs } from '../core/Prefs';
import { Cookies } from '../core/Cookies';
import { ApiCred, parseApiCred } from '../core/Comments';
import { voteTag, toggleWatchTag } from '../core/TagVote';
import { MaterialPlane } from '../components/MaterialPlane';
import { MaterialSurface } from '../components/MaterialSurface';
import { Material } from '../core/Material';
import { Tokens } from '../core/Tokens';
import { DetailBackGate } from '../core/BackGate';

// ---------------------------------------------------------------- 工具条尺寸
// 底部悬浮按钮组 = 一排互相独立的玻璃按钮，**没有整条底板**：
// 按钮 46 高，按钮之间间距 10，整排与屏幕左右各 16、距手势条上方 16。
// 尺寸只在这里写一次，barHeight()（定位 + 内容让位）与内容 padding bottom 自动跟随。
/**
 * 收藏写入后的「沉降窗口」（毫秒）。
 *
 * 写请求返回 200 之后，站点 gallerypopups 里的 checked 状态不会立刻反映这次写入；
 * 窗口内读到的、与用户意图不符的旧值**一律不覆盖 UI**（早期是重试一次，实测站点
 * 刷新可能滞后数秒，重试也照样读到旧值），避免「取消收藏后过一会又自己变回已收藏」。
 * 取 8 秒：站点弹窗实测可能滞后数秒，窗口太短等于没设。
 */
const FAV_SETTLE_MS: number = 8000;
/** 沉降窗口内那次重读的间隔（毫秒） */
const TOOL_BTN: number = 46;
/**
 * 按钮间距 10。
 *
 * 原来是 8，且按钮挤在一条底板上、彼此靠底板连成一体；底板去掉后每颗按钮都是独立的
 * 浮起物，间距要比 8 略松一点，中间才透得出内容，不会被读成「一条被切开的横条」。
 */
const TOOL_BAR_GAP: number = 10;
/** 整排距屏幕左右 16、距手势条上方 16 */
const TOOL_BAR_INSET: number = 16;

/**
 * 右下角「回到顶部」圆钮直径（40×40）。
 *
 * 取 40 而不是和工具条一样 46：它是页面内的辅助控件，不是主操作。小一号既让它读成
 * 「浮在工具条之上的另一个层级」，也保证两颗圆的直径不同、不会被看成同一排被切开的按钮。
 */
const TOP_BTN: number = 40;
/**
 * 回顶钮底边到工具条**上沿**的间距。
 *
 * 必须 > 0：两颗圆都贴右边缘，间距为 0 时上下同心会连成一个「8」字，手指也分不清点哪颗。
 * 12 与工具条按钮之间的 10、内容底部让位的 12 同一档呼吸，视觉上是一组而不是硬贴。
 */
const TOP_BTN_GAP: number = 12;
/**
 * 回顶钮出现的滚动阈值（vp）。
 *
 * 为什么是 480：「信息卡（封面 168 + 明细）+ 标签卡」这一屏读下来差不多就是这个高度，
 * 阈值以内用户还在读首屏，按钮提前冒出来只是噪音，而且正好会压住标签卡右侧的标签 ——
 * 那是本页唯一的标签入口，挡住等于把功能藏起来。超过 480 说明用户已经在翻缩略图长列表，
 * 这时「一键回顶」才有意义；同时 480 远大于顶栏高度（≤ 100），不会出现「内容还在顶部却显示」。
 */
const TOP_BTN_THRESHOLD: number = 480;

/** 缩略图网格 4 列，列间距 6 */
const THUMB_COLS: number = 3;
/**
 * 预览网格：列宽上限 / 行高固定（对齐 JHenTai 的 `detailsPageThumbnailWidth/Height` = 150/200）。
 *
 * 原来写死 3 列 + `aspectRatio(0.72)`：横屏或平板上每格被拉得很宽很高，缩略图 contain 进去
 * 只占中间一条，看起来就是"横图被上下压扁"。JHenTai 的做法是**行高固定、列数随宽度增加**，
 * 格子永远接近 150×200，缩略图比例就稳定。
 */
const THUMB_MAX_W: number = 150;
const THUMB_ROW_H: number = 190;
const THUMB_GAP: number = 6;
/**
 * 预览网格的两条并发闸门（详见 ImageLoader.ThumbPipeline）。
 *
 * 一屏 20 格是**同时挂载**的（本页网格在 Scroll 里，ForEach 不是懒加载），每格要
 * 「取 `/s/` 页 → 取图片字节」两次往返。这两段打的是完全不同的服务器：
 *  - HTML 走 e-hentai 主站，配额（509）敏感 → 3；
 *  - 图片走 CDN / H@H 图床，彼此独立、吞吐高 → 6。
 * 合成一个池子时只能取较小值（原来是 4），图片带宽永远吃不饱，而且一屏 20 格要排 5 批，
 * 尾部几格要等前面的**全部**跑完才轮到 —— 用户看到的就是「零散几张一直在转」。
 */
const PAGE_HTML_PARALLEL: number = 3;
const PAGE_IMG_PARALLEL: number = 6;
/**
 * 首屏预取格数。
 *
 * 打开详情页先把前 12 格（3 列 × 4 行，手机上一屏多一点）排进队列且优先级最高：
 * 用户还在读信息卡的时候，这 12 格多半已经好了。预取**不阻塞渲染**、失败也不记死，
 * 等 onAppear 时还能再来一次。
 */
const PAGE_FIRST_PREFETCH: number = 12;
/**
 * 一格从进队到出图的容忍上限（毫秒）。
 *
 * 超过就切到「失败（可点重试）」：509 限流、DNS 卡住、图床慢都表现成「一直转圈」，
 * 而无限转圈是最糟的一种状态 —— 用户既不知道发生了什么，也没法重来。
 */
const PAGE_STUCK_MS: number = 8000;
/**
 * 验收标准（动上面这几个数之前先看一遍，别凭感觉调并发）：
 *  - 二次进入同一画廊：前 12 格 **1 秒内**出图（映射命中 + 字节命中，只剩解码）；
 *  - 首次进入：前 12 格 **3 秒内**出齐。
 * 达不到就先量「映射命中率」与「两条槽位的占用率」：主站 509 一旦触发，整体会更慢，
 * 这时候提高并发只会更糟。
 */
/**
 * `pagePms` 的容量上限。
 *
 * 一屏 20 格、屏高 190：连滚三四屏时用户回头看一眼是常态，缓存留两屏的量（40 张）；
 * 每张是长边 240 的解码结果（约 0.1~0.2MB），40 张不到 8MB，可以接受。
 * 超出只从 Map 里摘掉、不立刻 release —— 那张图可能刚被换下去还在下一帧的渲染里。
 */
/**
 * 精灵裁切（像素级）的说明见 net/ThumbCropper。
 *
 * 为什么不再留开关：旧方案（CSS `backgroundImage` + 自己换算 vp）因为「实测像素 / 行列结构」
 * 在真机上不稳定而关闭；新方案直接把子矩形交给解码器裁像素，不存在换算这一步，
 * 所以判据简化成**这一格有没有可用的 tile**（见 spriteTileOf），不再需要全局开关，
 * 也不会出现「两套渲染并存」的中间态。
 */

/** 逐页取图的重试节奏（毫秒）：对齐阅读器的「组间拉长」，不是固定间隔 */
const PAGE_RETRY_DELAYS: number[] = [600, 2000, 5000];
/** 配额页（509）等得更久：这时候继续打只会把额度用得更光 */
const PAGE_RETRY_DELAYS_QUOTA: number[] = [3000, 8000, 15000];

const PAGE_PM_CAP: number = 40;
/** 已摘出 Map、等待延迟释放的图超过这个数量才开始放：给「刚换下去但还在屏幕上」留出一帧以上 */
const PAGE_RETIRED_CAP: number = 20;
/** 延迟释放的等待时间（毫秒）：必须大于一帧，否则被换下去的那张会被画成黑格 */
const PAGE_RETIRED_DELAY_MS: number = 1500;
/**
 * 每格宽度：3 列 + 2 个 6vp 列间距 → (100% - 12vp) / 3。
 *
 * 为什么不再用「(25% - 4.5vp) + 前三格右 margin」：那种写法把间距摊进宽度里，
 * 只要有一格换行或最后一行不满，行与行就会错半格。现在宽度只由列数决定，
 * 间距全部交给 Row 的 space，四格 + 三个间距精确等于 100%，不依赖屏宽。
 */

/**
 * 顶栏圆形返回键与屏幕左边的距离。
 *
 * 与 PageHeader（components/PageHeader.ets）里的同名常量取同一个值：本页顶栏是自己写的，
 * 评论页走的是 PageHeader，两处必须一致，否则详情页 ↔ 评论页来回退时返回键会左右跳一下。
 */
const BACK_INSET: number = 12;

/**
 * 页头材质下沿到页面第一块内容之间的空隙。
 *
 * 与 PageHeader 的 HEADER_BOTTOM_GAP 取同一个值（components/PageHeader.ets:30）。本页顶栏是
 * **自绘**的（MaterialSurface + 自建 44 圆返回键），拿不到公共组件那一层 6 的下沿间距，
 * 必须自己补一份 —— 否则详情页 ↔ 评论页来回切时，「返回键到内容」的距离会差出 6。
 *
 * 为什么加在**页头下沿**并计入 headerHeight()，而不是给返回键那一行加 padding：
 * 56 的行里返回键本来就上下各留 6，行内再挤只会把键和标题一起顶高，材质下沿仍旧贴着内容；
 * 只有把这 6 算进页头总高，材质层（连同底部发丝线）才会整体下移，内容区按 headerHeight()
 * 让位之后，那 6 的空隙才真实存在。这也是 PageHeader 的做法，两处必须同口径。
 */
const HEADER_BOTTOM_GAP: number = 6;

/**
 * 本地「存档」列表在 Prefs 里的 key。
 *
 * 这份数据的读取方是媒体库的「存档」tab（pages/ArchivePage.ets），写入方只有本页：
 * 值是 **JSON 字符串**（Prefs 只支持 number / string / boolean，存不了数组），
 * 内容是 `{ gid, token, title, thumb, time }` 的数组，按 time 倒序。
 * 两边共用一个 key，所以这里抽成常量 —— 字符串写错一个字，读的那边就永远读到空列表。
 */
const ARCHIVE_KEY: string = 'archive_items';

/**
 * 存档元素。
 *
 * 字段与 ArchivePage 的 ArchiveItem 一一对应（那边只认这五个字段，多写的会在它
 * 「移除单条」写回时被丢掉），所以这里不多加字段。
 */
class ArchiveEntry {
  gid: string = '';
  token: string = '';
  title: string = '';
  thumb: string = '';
  time: number = 0;
}

// ------------------------------------------------------------ 收藏面板尺寸
// 下面这几个数同时被「布局」和「favSheetHeight 的高度估算」使用，所以必须抽成常量：
// 布局里写 48、估算里写 44，面板底部就会稳定地多出/少掉几 vp，最后一行被裁在面板外。

/** 面板头行高：16 号标题 + 36 圆关闭钮，52 能让 36 的钮上下各留 8，视觉居中 */
const FAV_HEAD_H: number = 52;
/** 目录行高：48 = 15 号字 + 上下各 16.5，也是可点行的常规下限（≥44 触摸区） */
const FAV_ROW_H: number = 48;
/** 面板左右内边距：详情页正文是 16，二级面板往里再收 4，读起来是「面板里的内容」 */
const FAV_PAD_X: number = 20;
/**
 * 选中/按下高亮的左右内缩。
 *
 * 高亮块要离面板边缘留一点，否则圆角高亮会贴着屏幕边被读成「整条通栏」；
 * 但文字仍要对齐到 FAV_PAD_X —— 所以高亮缩进 12，行内再补 8，12 + 8 = 20。
 */
const FAV_HL_INSET: number = 12;
/** 面板底部留白（导航条安全区另加，见 favSheetBuilder / favSheetHeight） */
const FAV_PAD_BOTTOM: number = 12;
/** 头部 36 圆关闭钮的直径，与详情页返回键同一档「小圆钮」比例 */
const FAV_CLOSE_SIZE: number = 36;
/** 登录表单输入框 / 按钮高 */
const FAV_FIELD_H: number = 40;
/** 登录表单圆角（12 比 Tokens.RADIUS_ROW 的 19 收敛，40 高的输入框用 19 会像胶囊） */
const FAV_FIELD_RADIUS: number = 12;
/**
 * 未登录表单的内容高估算（不含面板头与底部留白）：
 * 顶部 16 + 说明行 16 + 三行 40 各带 10 间距 = 16 + 16 + 40 + 10 + 40 + 10 + 40 = 172，
 * 再留 10 给可能出现的错误文案（它只在渲染后才有，高度却要在打开那一刻定）。
 */
const FAV_LOGIN_BODY_H: number = 182;
/**
 * 「取消收藏」悬浮胶囊：高 40（14 号字 + 上下各 12，够 44 的触摸下限差一点但胶囊是
 * 视觉焦点、点击落点集中在中间，实测无问题），宽 160 见 FAV_CANCEL_W。
 */
const FAV_CANCEL_PILL_H: number = 40;
/**
 * 胶囊宽度取固定值而不是「文字宽 + 24 × 2」：
 * MaterialPlane 内部的材质 Row 是 width('100%')，放在自适应宽的 Stack 里会形成
 * 「父随子、子随父」的循环，量出来的宽度不确定（可能被撑满整行）。固定 160 = 4 字
 * 56 + 两侧各 52 的余量，看起来仍是一只短胶囊，且点击区稳定。
 */
const FAV_CANCEL_W: number = 160;
/** 胶囊距上方列表 12；整体段高 = 40 + 12 = 52（favSheetHeight 直接用它） */
const FAV_CANCEL_GAP: number = 12;
const FAV_CANCEL_H: number = FAV_CANCEL_PILL_H + FAV_CANCEL_GAP;
/** 「缺 igneous」提示行：10 号字 + 上下 8/4 内边距 */
const FAV_WARN_H: number = 30;
/**
 * 收藏弹层的入场/退场时长（毫秒）。
 * 与阅读器设置面板（ReaderPage 的 SHEET_ANIM_MS）取同一个值：同一个 App 里
 * 「从底部浮起一张卡片」的节奏应当只有一种，换页面不用重新适应。
 */
const FAV_ANIM_MS: number = 220;

/**
 * 详情页标签区的固定排序（取自 EH 详情页标签行的常规顺序）。
 * 不在这张表里的命名空间不会被丢弃 —— 它们按解析到的出现顺序追加在后面。
 */
const NAMESPACE_ORDER: string[] = [
  'reclass', 'language', 'parody', 'character', 'group', 'artist',
  'cosplayer', 'female', 'male', 'mixed', 'other'
];

/** 按命名空间分组后的标签 */
class TagGroup {
  ns: string = '';
  color: string = '#8E8E93';
  tags: GalleryTag[] = [];
}

/**
 * 画廊详情。
 *
 * 数据来自详情页 HTML（`#gn` / `#gdd` / `#taglist` / `#gdt`），
 * 标签解析失败时自动退到 api.php 的 gdata —— 站点改版时这条兜底能救回来。
 *
 * 标签区的数据从哪来（别和「标签集」混为一谈）：
 *  - `EhApi.parseDetail()` 只解析 `#taglist` 里的标签 div（id 形如 `female:stockings`），
 *    产出 `GalleryTag` 数组：ns / key / name / state(gt|gtl|gtw) / color。
 *    HTML 一条都没解析到时，`loadDetail()` 会用 `fillTagsByApi()` 走 api.php 的 gdata
 *    再补一份（此时没有 state，颜色退成命名空间色）。
 *  - 「标签集（tagset）」是站点账号侧的另一套数据（`/mytags?tagset=N` 那个下拉，见
 *    `core/TagSets.ets`），**详情页的 HTML / gdata 里都没有它**，本页也拿不到，不编。
 *    要在这里显示标签集，需要 `EhApi` 先补解析（tagset 名称 / 颜色 / 归属），
 *    当前本页展示的是「这个画廊的标签，按命名空间分组」。
 */
@Component
export struct DetailPage {
  gallery: Gallery = new Gallery();
  onBack: () => void = (): void => {};
  /** startPage 为 0 基页码：点缩略图网格的某一格就从那一页开始读 */
  onRead: (detail: GalleryDetail, startPage: number) => void =
    (d: GalleryDetail, s: number): void => {};
  onComments: (detail: GalleryDetail) => void = (d: GalleryDetail): void => {};
  onTools: (detail: GalleryDetail) => void = (d: GalleryDetail): void => {};
  /**
   * 点标签 → 跳搜索页搜这个标签（参数是拼好的 EH 精确搜索词，如 `female:"big breasts$"`）。
   *
   * 为什么是普通成员而不是 `@Prop`：ArkTS 的 `@Prop` 只支持可观察的数据类型，函数类型会编译报错
   * （本工程 SettingsPage.ets:108 已经踩过并写明）。所以与上面的 onBack / onRead 同一套写法。
   */
  onSearchTag: (q: string) => void = (q: string): void => {};
  /**
   * 未登录时「去登录」：本页是压在 tab 容器之上的一层（Index.ets 的 L_DETAIL），
   * 自己切不了 tab，只能交给 Index —— 它负责先切到设置 tab、再把本页出栈。
   */
  onGotoLogin: () => void = (): void => {};

  @State private detail: GalleryDetail | null = null;
  @State private loading: boolean = true;
  @State private error: string = '';
  @State private groups: TagGroup[] = [];
  @State private favSheet: boolean = false;
  /**
   * 收藏面板正在播退场动画。
   *
   * 唯一作用是**守卫重复关闭**：面板开着时遮罩与 × 是两条都能点的路，手指连点、
   * 或点完遮罩又补一下 ×，会起两次 animateTo —— 第二次从「滑到一半」重新计时，
   * 观感是面板卡一下再滑走。
   */
  @State private favClosing: boolean = false;
  /**
   * 面板下滑进度：0 = 就位，1 = 完全滑出自己的高度（正好离开屏幕下沿）。
   *
   * 为什么用状态驱动 translate 而不是只靠 TransitionEffect：
   * TransitionEffect 的退场是「节点被 if 摘掉时」由框架补的一段，遮罩与面板各按自己
   * 那条 transition 走，摘节点那一刻就可能出现「遮罩已经没了、面板还压在白底上」。
   * 显式状态 + animateTo 的 onFinish 能把「遮罩淡出」与「面板下滑」放进同一条动画，
   * 并且由我们自己决定什么时候摘节点（动画走完才摘）。
   */
  @State private favSlide: number = 0;
  /** 遮罩不透明度（与 favSlide 同起同落：1 = 打开态，0 = 全透明） */
  @State private favDim: number = 1;
  /**
   * 本账号把这个画廊放在哪个收藏夹（-1 = 未收藏）。
   *
   * 首屏来自 detail 页 HTML 的 `#fav` 精灵图（EhApi.parseDetail 里解析，0 额外请求）；
   * 面板里登录成功、或刚写完收藏时，用 EhApi.favcatOf()（gallerypopups 弹窗里 checked 的单选框）
   * 重新校准一次 —— 详情页 HTML 是登录瞬间生成的，登录后必须换一个来源才拿得到。
   *
   * 为什么不用 this.gallery.favcat 直接渲染：普通成员不可观察，改它不会触发重绘。
   */
  @State private favcat: number = -1;
  /** 下拉刷新中（Refresh 的双向状态） */
  @State private refreshing: boolean = false;
  /** 下拉阶段（不落 @State 就没法在浮层里区分「下拉 / 松手 / 刷新中」） */
  @State private refreshStatus: RefreshStatus = RefreshStatus.Inactive;
  /**
   * 用户最后一次写收藏的**时间戳**与**意图目录**（-1 = 取消）。
   *
   * 只服务于一件事：区分「服务端真的没接受这次写入」和「服务端接受了、但我读得太早」。
   * 没有它，取消收藏后紧接着的校准会把旧值写回来，按钮自己弹回「已收藏」。
   * 不参与渲染，所以不用 @State。
   */
  private favIntentAt: number = 0;
  private favIntent: number = -1;
  /** 收藏请求进行中：按钮与面板都忽略重复点击 */
  @State private favBusy: boolean = false;
  /**
   * 面板里当前被按下的行：-1 无，0..9 = 目录行，10（= FavCats.NAMES.length）= 「取消收藏」行。
   *
   * 为什么不用 stateStyles：@Styles 不能收参数，按下色得跟着「这一行是不是选中的目录」变，
   * 而 stateStyles 表达不了「按下时给 line()、选中时给 accentFill()」这种组合；onTouch 里
   * 改一个 @State 索引，渲染时按索引取色更直接，也不需要给 10 行各写一份样式。
   * 按下态必须落在 Row 自己身上：Row 有 onClick，没有背景变化时点下去毫无反馈，
   * 用户会以为「这行点不动」而反复点。
   */
  @State private favPressed: number = -1;
  /** 面板内的登录表单（只在面板打开期间有效，成功后立刻清空密码） */
  @State private loginUser: string = '';
  @State private loginPass: string = '';
  @State private loginErr: string = '';
  @State private authBusy: boolean = false;
  @State private toast: string = '';
  /**
   * 本漫画是否已在**本地存档列表**里（key `archive_items`）。
   *
   * 为什么不再是 LocalFav：本地收藏（Db 的 fav 表）与「存档」是两回事 ——
   * 存档要能被媒体库的存档 tab 读到，那份数据的唯一来源就是 `archive_items`。
   * 按钮的「已存档」态必须读同一个 key，否则会出现「按钮说已存、存档 tab 里没有」。
   */
  @State private archived: boolean = false;
  @State private cred: ApiCred = new ApiCred();
  @State private tagSheet: boolean = false;
  @State private activeTag: GalleryTag | null = null;
  /**
   * 缩略图网格的「格子数」与页数同源（i 即页码，0 基）。
   *
   * 为什么还留着这个数组：网格的行数/列数是从它的长度算出来的（@State 才能触发行数变化），
   * 而它每补一屏就 +20 —— 里面的缩略图地址已经**不参与渲染**（裁切依据是下面的 tiles），
   * 现在只用它当「网格铺到第几页」的游标。
   */
  @State private thumbs: string[] = [];
  /**
   * 精灵几何（与 pageUrls 同下标），由解析层从详情页 HTML 里带出来。
   *
   * 现在是**唯一的裁切依据**：`x/y/w/h` 是 CSS px，站点给的值与 sheet 真实像素一致
   * （Ehviewer_OHOS 也是直接拿这组值当 `desiredRegion`，见 `ptc.ets:83-89`），
   * 所以直接把子矩形交给 ThumbCropper.crop 裁像素，不再需要任何实测/换算。
   * 有 tile（且 w/h > 0）走裁剪；没有就走逐页真图兜底。
   */
  @State private tiles: ThumbTile[] = [];
  /**
   * 缩略图栅格的实际宽度（vp）。
   *
   * 格子宽度按列数均分，build 期拿不到数字，所以测一次栅格宽度：
   * `cellW()` / `thumbCols()` 都靠它，列数决定一行几格。
   */
  @State private gridW: number = 0;
  /**
   * 本页的缩略图（页号 → PixelMap），**两条路共用一张表**。
   *
   *  - 裁剪路线：ThumbCropper 从 sheet 里裁出来的那一格（正常路径，一屏只下一次 sheet）；
   *  - 逐页路线：`/s/` 页 → 真图 → 解码（没有 tile 或该格裁剪失败时的兜底）。
   * 两条路都写进这里，所以渲染层只需要「有图 / 失败 / 加载中」三态，不必知道图从哪来。
   * 不放 @State：PixelMap 是原生对象，塞进状态代理只会多一层包装；用 pagePmVer 触发重绘。
   */
  private pagePms: Map<number, image.PixelMap> = new Map<number, image.PixelMap>();
  /**
   * 当前在屏幕上的格子。
   *
   * 淘汰时必须跳过它们：按插入顺序淘汰会正好命中「最先加载好的那几格」（通常就在屏幕最上方），
   * 结果就是图已经显示过、又被收回成页码 —— 用户看到的就是「图片变回页码」。
   */
  private visiblePages: Set<number> = new Set<number>();
  /** 已经失败过的页号（最多试两次）：不再对它们发请求 */
  private pageDead: Set<number> = new Set<number>();
  /**
   * 裁剪路线失败的格子。
   *
   * 失败一次就换路：同一张 sheet 裁不出来（图床 403 / 容器坏 / 该格越界），
   * 自动重试再裁一次通常还是同一个结果，最快恢复方式反而是走逐页真图。
   * 用户手动点「点击重试」时会清空它 —— 那是新的网络环境，值得再试一次裁剪。
   */
  private cropFailed: Set<number> = new Set<number>();
  /**
   * 每格连续失败次数。
   *
   * 用途只有一个：第二次失败起，格子文案从「点击重试」换成「请求过于频繁」——
   * 连续两次都失败基本不是偶发抖动，用户需要知道这不是「再点一下就好」。
   */
  private pageFails: Map<number, number> = new Map<number, number>();
  /** 失败格要显示的文案（'点击重试' / '请求过于频繁'），与 pageDead 同生命周期 */
  private pageErrs: Map<number, string> = new Map<number, string>();
  /** 最近一次失败原因（'quota' / 'html' / 'image' / 'timeout'）：诊断用，不进 UI */
  private lastErr: string = '';
  /**
   * 已受理但还没出结果的页号 → 受理时刻。
   *
   * 既是「在队列/在跑」的去重表，也是 8 秒超时的判定依据：
   * 定时器到点时先比对时刻，晚到的旧定时器不会把新一轮请求误判成超时。
   */
  private pageStarts: Map<number, number> = new Map<number, number>();
  /**
   * pageDead 是普通 Set，改它不会触发重绘；这个版本号只在「刚判定失败」和「用户点重试」
   * 时 +1，让格子从「第 N 页」切到「点击重试」再切回来。
   */
  @State private deadVer: number = 0;
  /**
   * 图已经拿到、但 build 还不知道的版本号。
   *
   * 必须被 build 读到：`pagePms` 是不可观察的 Map，set 完界面不会自己刷 ——
   * 表现就是「图都下好了，格子还是页码」。
   */
  @State private pagePmVer: number = 0;
  /**
   * 被容量策略摘出 Map、暂不释放的图。
   *
   * 为什么不立刻 release：大幅滚动时刚被摘掉的那张可能还在**这一帧**的渲染里，
   * 释放后组件拿到已回收的句柄，表现就是黑格。先挂这儿，隔一帧以上再放。
   */
  private retiredPms: image.PixelMap[] = [];
  /**
   * 页号 → `/s/` 页地址。
   *
   * 不能用 `detail.pageUrls`：它只有详情页 HTML 里那 20 条，而网格会继续往后铺。
   * 每补一屏就把它一起追加，两边的下标天然对齐（第 i 格 = 第 i 页）。
   */
  private pageUrls: string[] = [];
  /**
   * 两段式调度器（HTML 3 并发 / 图片 6 并发 / 按行号优先）。
   *
   * 迟建而不是字段直接 new：字段初始化时 `this` 上的回调闭包还没准备好，
   * 而且组件被复用时（阅读器返回再进同一本）需要能整体重建一个干净的队列。
   */
  private pipe: ThumbPipeline | null = null;
  /** 页面是否还在（异步回调回来时可能已经退出：这时解出来的图要立刻还回去） */
  private alive: boolean = true;
  /** 已经拿到的缩略图屏数（一屏 20 张），用于算下一次的 ?p= 偏移 */
  @State private thumbLoaded: number = 1;
  @State private thumbBusy: boolean = false;
  private toastTimer: number = -1;
  /** 最近一次标签长按的时间戳：长按后系统可能补一个 click，用它把那次 click 吃掉 */
  private lastLongPressAt: number = 0;
  /**
   * 内容当前滚动到的位置（vp，向下为正，来自 Scroll 的 onDidScroll）。
   *
   * 只服务于「回到顶部」的显隐判定，不参与任何布局，所以是 @State：值一变就重绘那颗按钮。
   */
  @State private topBtnOn: boolean = false;
  /**
   * 标签库版本号（TagTrans 加载完成时自增）。
   *
   * 为什么需要：tagLabel() 直接查 TagTrans 的静态 Map，而 Map 变了**不是**可观察状态，
   * 界面不会重绘。首帧渲染时库还没解析完（4MB JSON），于是整卡标签停在英文，
   * 之后再也没人触发重绘 —— 表现就是「有些标签一直是英文」。
   * 在 build 里读一次这个计数，库加载完就能把标签卡重画一遍。
   */
  @State private tagTransTick: number = 0;
  /**
   * 详情内容 Scroll 的滚动控制器。
   *
   * 「回到顶部」必须靠 Scroller 才能滚（按钮在 Scroll 外面，拿不到组件自身的方法）。
   * 一个 Scroller 只能绑一个 Scroll —— 本页只有下面那一个内容 Scroll，不会冲突。
   */
  private scrollCtrl: Scroller = new Scroller();

  aboutToAppear(): void {
    // 组件实例可能被复用（阅读器返回后再进同一个详情），这里复位「还活着」的标记，
    // 否则上一次退出时置 false 之后，异步回来的图会全部被当成「页面已销毁」丢掉。
    this.alive = true;
    // 系统返回键：本页是 Index 里栈中的一层普通组件，自己收不到 onBackPress
    // （它只对 @Entry 页面生效），只能把处理器登记给 Index，见 core/BackGate.ets。
    DetailBackGate.register((): boolean => this.onBackPress());
    this.archived = DetailPage.findArchive(this.gallery.gid) !== null;
    this.load();
    // 标签库是懒加载的：本页是第一次需要中文标签的地方之一，主动触发一次
    TagTrans.ensureLoaded().then((ok: boolean) => {
      if (ok) {
        this.tagTransTick = this.tagTransTick + 1;
      }
    });
  }

  aboutToDisappear(): void {
    this.alive = false;
    // 注销返回键处理器：页面已经不在树上，留着它会让下一次返回调到一个死组件
    DetailBackGate.unregister();
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
    // 逐页缩略图的 PixelMap 归本页所有（ImageLoader 不回收到任何全局缓存），
    // 页面销毁必须自己还回去，否则每进一次详情页就漏掉几十张解码结果。
    // 顺带把排队中的页号清掉 —— 页面都没了，排着也没意义。
    this.dropPagePms();
  }

  private showToast(text: string): void {
    this.toast = text;
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout(() => {
      this.toast = '';
      this.toastTimer = -1;
    }, 2400);
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.error = '';
    try {
      const d: GalleryDetail = await EhApi.loadDetail(this.gallery);
      this.detail = d;
      this.groups = DetailPage.groupTags(d.tags);
      // 详情首屏自带前 20 页的页链接，网格先铺这些格子，其余滚到底再补
      this.tiles = d.pageTiles.slice();
      // 页链接清单是**唯一的真相**：格子里的图逐页现取，`thumbs` 只负责「铺几格」，
      // 所以它的长度必须严格等于 pageUrls，否则第 21 格会去取第 20 页的地址。
      //
      // **不清 pagePms**：下拉刷新刷的是同一本画廊，第 i 格的图还是第 i 页，
      // 清掉反而会让已经显示出来的格子退回页码 —— 而 ForEach 的节点会被复用，
      // onAppear 不会再触发一次，那些格子就再也补不回来了。
      this.pageUrls = d.pageUrls.slice();
      const cells: string[] = [];
      for (let i = 0; i < this.pageUrls.length; i++) {
        cells.push(i < d.pageThumbs.length ? d.pageThumbs[i] : '');
      }
      this.thumbs = cells;
      this.thumbLoaded = 1;
      // 投票凭证也从这页的 HTML 里来，顺手解析掉
      this.cred = parseApiCred(d.rawHtml);
      this.remember(d);
      // 收藏态在 parseDetail 里已从本页的 #fav 精灵图解析好（gallery.favcat），
      // 这里只搬进 @State 触发按钮重绘 —— 不额外发请求、不整页重载
      this.favcat = d.gallery.favcat;
      // 首屏预取：走裁剪的格子只需要那张 sheet 一次网络往返（20 格共享），
      // 走逐页的格子按原逻辑排队；两条路都由 requestPage 自己分流。
      this.prefetchFirst(PAGE_FIRST_PREFETCH);
    } catch (e) {
      this.error = (e as Error).message;
    }
    this.loading = false;
  }

  private remember(d: GalleryDetail): void {
    const item: HistoryItem = new HistoryItem();
    item.gid = d.gallery.gid;
    item.token = d.gallery.token;
    item.title = d.gallery.title;
    item.thumb = d.gallery.thumbUrl;
    item.category = d.gallery.categoryLabel;
    item.color = d.gallery.categoryColor;
    item.time = Date.now();
    History.push(item);
  }

  // ------------------------------------------------------------ 本地存档
  /**
   * 读本地存档列表。
   *
   * 三种「空」一律当空数组（与 ArchivePage.load() 同口径）：key 不存在 / 空串、
   * JSON.parse 抛错、parse 出来不是数组（脏数据）。写入方是本页、读取方是存档 tab，
   * 任何一方都不能因为对方写坏了而崩在 build 或点击里。
   */
  private static readArchive(): ArchiveEntry[] {
    const raw: string = Prefs.str(ARCHIVE_KEY, '');
    if (raw.length === 0) {
      return [];
    }
    let list: ArchiveEntry[] = [];
    try {
      const data: ArchiveEntry[] = JSON.parse(raw) as ArchiveEntry[];
      // parse 成功不代表是数组：JSON.parse('{}') 也会成功
      if (Array.isArray(data)) {
        list = data;
      }
    } catch (e) {
      list = [];
    }
    const out: ArchiveEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      const it: ArchiveEntry = list[i];
      // 元素级兜底：缺 gid 的条目在存档 tab 里点不开详情，只会有害
      if (it === null || it === undefined || typeof it.gid !== 'string' || it.gid.length === 0) {
        continue;
      }
      out.push(it);
    }
    return out;
  }

  /** 在存档列表里找这条漫画（找不到返回 null）；按钮的「已存档」态就按它判断 */
  private static findArchive(gid: string): ArchiveEntry | null {
    if (gid.length === 0) {
      return null;
    }
    const list: ArchiveEntry[] = DetailPage.readArchive();
    for (let i = 0; i < list.length; i++) {
      if (list[i].gid === gid) {
        return list[i];
      }
    }
    return null;
  }

  /**
   * 存档：把当前漫画写进本地存档列表，供媒体库的「存档」tab 读取。
   *
   * 判定依据：本页这颗按钮**没有网络请求**（站点的归档下载入口在工具页 ToolsPage，
   * 走 core/Archive 的 requestArchive），它只做本地记录，所以「成功」只能定义为
   * 「写入不抛异常」。Prefs.put 是同步写内存 + 异步 flush（flush 失败只记日志），
   * 同步段不会失败；写完立刻按 **读回的结果** 刷新按钮态，而不是乐观置 true ——
   * 这样即使写入被丢弃，按钮也不会和存档 tab 里的实际内容不一致。
   *
   * 去重：同 gid 视为同一条，新的覆盖旧的（时间戳更新，在存档 tab 里因此会排到最前），
   * 不会出现同一本漫画两条记录。
   */
  private saveArchive(): void {
    const gid: string = this.gallery.gid;
    if (gid.length === 0) {
      this.showToast('缺少 gid，无法存档');
      return;
    }
    const entry: ArchiveEntry = new ArchiveEntry();
    entry.gid = gid;
    entry.token = this.gallery.token;
    entry.title = this.gallery.title;
    entry.thumb = this.gallery.thumbUrl;
    entry.time = Date.now();

    const out: ArchiveEntry[] = [entry];
    const old: ArchiveEntry[] = DetailPage.readArchive();
    for (let i = 0; i < old.length; i++) {
      if (old[i].gid !== gid) {
        out.push(old[i]);
      }
    }
    Prefs.put(ARCHIVE_KEY, JSON.stringify(out));

    this.archived = DetailPage.findArchive(gid) !== null;
    this.showToast(this.archived ? '已存档' : '存档失败');
  }

  /** 标签显示文案：开启翻译且命中时用中文，否则原文 */
  private tagLabel(tag: GalleryTag): string {
    if (!Prefs.bool('tag_trans', false)) {
      return tag.name;
    }
    const zh: string = TagTrans.translate(tag.ns, tag.key);
    return zh.length > 0 ? zh : tag.name;
  }

  /**
   * 按命名空间分组。
   *
   * 与旧实现的两点差别（旧版会「少标签」，这也是用户反馈看不到标签的原因之一）：
   *  1. 未知命名空间不再被丢掉：旧版只遍历写死的 11 个命名空间，站点新增/改名的
   *     命名空间（或 gdata 兜底里出现的大小写差异）会导致整组标签消失；
   *  2. 顺序仍然稳定：已知命名空间按 NAMESPACE_ORDER 排，未知的按出现顺序追加。
   */
  private static groupTags(tags: GalleryTag[]): TagGroup[] {
    const out: TagGroup[] = [];
    const byNs: Map<string, TagGroup> = new Map<string, TagGroup>();
    // 先按固定顺序占位（此时组里还是空的，最后统一剔除空组）
    for (let i = 0; i < NAMESPACE_ORDER.length; i++) {
      const g: TagGroup = new TagGroup();
      g.ns = NAMESPACE_ORDER[i];
      g.color = Namespaces.of(g.ns).color;
      byNs.set(g.ns, g);
      out.push(g);
    }
    for (let t = 0; t < tags.length; t++) {
      const ns: string = tags[t].ns.length > 0 ? tags[t].ns : 'other';
      const hit: TagGroup | undefined = byNs.get(ns);
      if (hit === undefined) {
        const created: TagGroup = new TagGroup();
        created.ns = ns;
        created.color = Namespaces.of(ns).color;
        byNs.set(ns, created);
        out.push(created);
        created.tags.push(tags[t]);
      } else {
        hit.tags.push(tags[t]);
      }
    }
    const kept: TagGroup[] = [];
    for (let i = 0; i < out.length; i++) {
      if (out[i].tags.length > 0) {
        kept.push(out[i]);
      }
    }
    return kept;
  }

  /**
   * 拉一次服务端收藏态（未登录 / 读失败都会安静地回到 -1）。
   * 加收藏失败、在别处改过收藏夹时都用它校准，避免按钮停在错的态上。
   */
  /**
   * 下拉刷新：重拉一次详情。
   *
   * 与 load() 的区别只有「自己管 refreshing」：load() 在别处（首帧、失败重试）也被调用，
   * 不该由它去改 Refresh 的状态，否则首帧会看到一个凭空转圈的刷新指示。
   */
  private async reloadByPull(): Promise<void> {
    this.refreshing = true;
    try {
      await this.load();
    } catch (e) {
      this.showToast((e as Error).message);
    }
    this.refreshing = false;
  }

  /** 浮层何时可见：刷新中 + 下拉/过线（拉一点点就给反馈，不等触发） */
  private refreshPillVisible(): boolean {
    return this.refreshing || this.refreshStatus === RefreshStatus.Drag
      || this.refreshStatus === RefreshStatus.OverDrag;
  }

  /**
   * 下拉刷新浮层：钉在顶栏下方居中。
   *
   * 为什么不靠 Refresh 自己的下拉区：那段区域画在组件顶部，而详情页内容是从半透明
   * 顶栏下方开始的，指示器会被顶栏盖住 —— 手指要走完一整个顶栏高度才第一次看见东西。
   * 浮层挂在顶栏之下（headerHeight + 8），拉一点点就出现。
   */
  @Builder
  private refreshPill() {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        // 固定 120 宽：MaterialPlane 内层材质是 width('100%')，宽度由内容自撑会解析到整屏
        MaterialPlane({ kind: 'header', radius: 999, planeHeight: 32 })
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
      .width(120)
      .height(32)
      .borderRadius(999)
      // 描边与阴影挂在不裁剪的这一层：材质自己按 radius 裁圆，边画在它上面会被削一半
      .border({ width: 0.7, color: Theme.btnEdge() })
      .shadow(Theme.floatShadow())
    }
    .width('100%')
    .height(32)
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.None)
    .opacity(this.refreshPillVisible() ? 1 : 0)
    .translate({ y: this.refreshPillVisible() ? 0 : -6 })
    .animation({ duration: 160, curve: Curve.Smooth })
    .position({ x: 0, y: this.headerHeight() + 8 })
  }

  private async refreshFavState(): Promise<void> {
    const v: number = await EhApi.favcatOf(this.gallery);

    // 写入后的「沉降窗口」内，读到与用户意图不一致的值，**视为读到了写入前的旧页面**。
    //
    // 这是「取消收藏后过一会又变成已收藏」的根因：写请求（favcat=-1）返回 200 之后，
    // 站点那边 gallerypopups 弹窗的 checked 状态并不是同一事务更新，紧接着的这次读取
    // 很可能拿到的还是旧 HTML。于是乐观更新先把按钮改成「收藏」，几百毫秒后这次校准
    // 又把旧值写回来 —— 看起来就是「取消成功了，然后又自己变回去了」。
    //
    // 处理：窗口内**一律不覆盖**（早期版本是「重试两次、仍不符就接受服务端」，
    // 但只要站点刷新慢于 1.5 秒，旧值照样写回去、按钮照样弹回，实测无效）。
    // 代价是「站点真的忽略了这次写入」时本页不会立刻自我纠正 —— 但那两种情况的
    // 返回值完全一样，本页无从分辨；下一次明确时机会照常校准（重开面板 / 重进页面 / 登录）。
    if (Date.now() - this.favIntentAt < FAV_SETTLE_MS && v !== this.favIntent) {
      return;
    }
    this.favcat = v;
  }

  /**
   * 返回键：浮层优先于页面出栈。
   *
   * 名字与签名刻意和页面级回调一致，但它**不是框架回调**：onBackPress 只对 @Entry
   * 装饰的页面生效，本页是 Index 栈里的一层普通 @Component，系统不会调到这里。
   * 真正收到返回键的是 Index.onBackPress，它在出栈前通过 DetailBackGate 调过来
   * （见 core/BackGate.ets；别在这里再写一套，两条路都在就等于关两次）。
   *
   * 顺序：收藏面板 → 标签面板 → 都不管（返回 false，让 Index 正常出栈）。
   * 关收藏面板必须走 closeFavSheet()（220ms 下滑 + 淡出），硬置 false 会看到面板瞬间消失。
   * favClosing 期间也返回 true：退场动画没走完时再按一次返回，不该把详情页一起退掉。
   */
  onBackPress(): boolean {
    if (this.favSheet) {
      this.closeFavSheet();
      return true;
    }
    if (this.tagSheet) {
      // 标签面板仍是 bindSheet：置 false 即收起，收起动画由系统半模态自己播
      this.tagSheet = false;
      return true;
    }
    return false;
  }

  /**
   * 打开收藏面板。
   *
   * 入场是「从屏幕下沿之外滑上来」+ 遮罩淡入（220ms / Friction）。挂载与动画必须分两帧：
   * 先把 favSlide / favDim 写成起始态再让节点挂载，动画在 favOverlay 的 onAppear 里起 ——
   * 同一帧里既新建节点又改数值，ArkUI 会把两次写入合并，节点直接以终态建成，看不到滑入
   * （媒体库「清空」胶囊踩过同一个坑，见 LibraryPage.showClearPill 的注释）。
   */
  private openFavSheet(): void {
    if (this.favSheet) {
      return;
    }
    this.loginErr = '';
    this.favClosing = false;
    this.favSlide = 1;
    this.favDim = 0;
    this.favSheet = true;
  }

  /**
   * 关闭收藏面板：遮罩淡出与面板下滑**同时**进行（220ms / Friction，与入场同一套曲线），
   * 动画走完才把节点摘掉。
   *
   * **所有关闭入口都必须走这里**（× / 点遮罩 / 收藏成功后自动关 / 面板里「用 Cookie 登录」
   * 跳设置），否则总有一条路是硬关（直接 favSheet = false）：那一瞬间遮罩与面板一起消失，
   * 与其它入口的动效对不上。
   *
   * favClosing 守卫：退场的 220ms 里 × 与遮罩依然可点，不守卫就会重起一次 animateTo。
   */
  private closeFavSheet(): void {
    if (!this.favSheet || this.favClosing) {
      return;
    }
    this.favClosing = true;
    animateTo({
      duration: FAV_ANIM_MS,
      curve: Curve.Friction,
      onFinish: () => {
        // 此时面板已整个滑到屏幕外、遮罩已全透明，摘节点不会有任何跳变
        this.favSheet = false;
        this.favClosing = false;
        // 复位起始态：下一次 openFavSheet 从同一组值开始，不会继承这次的终态
        this.favSlide = 0;
        this.favDim = 1;
      }
    }, () => {
      // 下滑 + 淡出写在同一段动画里：两者同起同落，不会出现「遮罩没了、面板还在」
      this.favSlide = 1;
      this.favDim = 0;
    });
  }

  /**
   * 收藏 / 取消收藏（cat = 0..9 加入，-1 移除）。
   *
   * 先收面板再发请求：toast 画在页面最外层，被收藏弹层盖住时用户看不见，
   * 所以「失败也要有反馈」的前提是面板已经收起。
   */
  private async setFav(cat: number): Promise<void> {
    if (this.favBusy) {
      return;
    }
    this.closeFavSheet();
    if (!Cookies.isLoggedIn()) {
      this.showToast('请先登录后再收藏');
      return;
    }
    this.favBusy = true;
    try {
      await EhApi.addFavorite(this.gallery, cat);
      // 乐观更新：站点成功后立刻改按钮态，不发整页重载（详情页没必要重读）
      this.favcat = cat;
      // 记下「用户此刻的意图」：紧随其后的校准若读到与之不符的值，说明读到的是旧页面
      this.favIntent = cat;
      this.favIntentAt = Date.now();
      this.showToast(cat >= 0 ? '已收藏到 ' + FavCats.label(cat) : '已取消收藏');
      // 再以服务端为准校一次（写请求被站点悄悄忽略时，这一步会把按钮改回真实态）
      this.refreshFavState();
    } catch (e) {
      this.showToast((e as Error).message);
    }
    this.favBusy = false;
  }

  /**
   * 面板内的账号密码登录。
   *
   * 复用 EhApi.loginPassword（走论坛登录接口，成功后 Set-Cookie 里就有
   * ipb_member_id / ipb_pass_hash，由 Http.collectCookies 写进 Cookie 罐），
   * 失败文案直接来自它：'账号或密码错误' / '需要验证码…' / '登录失败…'。
   *
   * 密码只在内存里存活到这次请求结束：成功或失败都立刻清空，
   * 不写 Prefs、不写日志（Cookie 罐里只有站点下发的 cookie，没有明文密码）。
   */
  private async doSheetLogin(): Promise<void> {
    if (this.authBusy) {
      return;
    }
    if (this.loginUser.trim().length === 0 || this.loginPass.length === 0) {
      this.loginErr = '请填写账号和密码';
      return;
    }
    this.authBusy = true;
    this.loginErr = '';
    try {
      const err: string = await EhApi.loginPassword(this.loginUser, this.loginPass);
      this.loginPass = '';
      if (err.length > 0) {
        this.loginErr = err;
      } else {
        this.loginUser = '';
        this.showToast('登录成功');
        // 面板不关：登录完直接在同一个面板里选收藏夹，少一步返回
        await this.refreshFavState();
      }
    } catch (e) {
      this.loginPass = '';
      this.loginErr = (e as Error).message;
    }
    this.authBusy = false;
  }

  @Builder
  private metaChip(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(Theme.subText())
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .borderRadius(8)
      .backgroundColor(Theme.line())
      .margin({ right: 6, bottom: 4 })
  }

  /**
   * 标签 → EH 精确搜索词（点按标签跳搜索用）。
   *
   * 对齐原版：NextE `EhConstants.exactTagSearchQuery()`（nexte-src/shared/src/main/ets/
   * constants/EhConstants.ets:217-227）给普通命名空间产出 `ns:"text$"` —— `$` 写在引号内，
   * 表示「精确匹配这个标签」，EX 站语义相同（同名标签的子串匹配会被 $ 排除掉）。
   * 单词标签省掉引号（`female:stockings$`）与带引号等价，少两个字符；含空格必须带引号，
   * 否则 EH 会把后半个词当独立关键词。
   *
   * NextE 对 uploader 单独走 `ns:"text"`（不加 $）—— 本页标签区来自 `#taglist`，
   * 上传者在上面的元信息行、不走这个 chip，所以这里不需要那个特例。
   */
  private searchQueryOf(tag: GalleryTag): string {
    const ns: string = tag.ns.toLowerCase();
    const key: string = tag.key.length > 0 ? tag.key : tag.name;
    if (key.indexOf(' ') >= 0) {
      return ns + ':"' + key + '$"';
    }
    return ns + ':' + key + '$';
  }

  /** 标签胶囊：圆角 8，与元信息 chip 同一套尺寸 */
  @Builder
  private tagChip(text: string, color: string, dim: boolean) {
    Text(text)
      .fontSize(11)
      .fontColor(dim ? Theme.subText() : Color.White)
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .borderRadius(8)
      .backgroundColor(dim ? Theme.line() : color)
  }

  /**
   * 标签区里的一组：命名空间行内小标题（左）+ 该组条数（右）+ 可换行的标签 chip。
   *
   * 这里不再自带卡片底/圆角/内边距 —— 外层 tagSetCard() 才是那张卡，
   * 组只是卡内的一段，靠小标题分行，不再各占一张卡。
   */
  @Builder
  private tagGroupBlock(group: TagGroup) {
    Column({ space: 8 }) {
      Row() {
        Text(group.ns)
          .fontSize(12)
          .fontColor(Theme.accent())
        Blank()
        Text(group.tags.length.toString() + ' 条')
          .fontSize(11)
          .fontColor(Theme.subText())
      }
      .width('100%')

      // 自动换行：宽度只由内容决定，不再算固定列宽，屏宽变化也不会错位
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(group.tags, (tag: GalleryTag) => {
          Column() {
            this.tagChip(this.tagLabel(tag), group.color, tag.state === 'gtw')
          }
          .margin({ right: 6, bottom: 6 })
          .onClick(() => {
            // 长按后系统可能还会补一个 click（搜索页的历史 chip 踩过同样的坑），
            // 那个 click 必须吃掉，否则面板刚弹出就被跳去搜索页了
            if (Date.now() - this.lastLongPressAt < 600) {
              return;
            }
            // 点按 = 搜这个标签（精确匹配）；投票/加观看挪到长按，见下面的手势
            this.onSearchTag(this.searchQueryOf(tag));
          })
          .gesture(LongPressGesture({ repeat: false, duration: 500 })
            .onAction((event: GestureEvent) => {
              // 长按 = 原来的标签面板（投票 / 加入观看），功能没有丢
              this.lastLongPressAt = Date.now();
              this.activeTag = tag;
              this.tagSheet = true;
            }))
        }, (tag: GalleryTag) => tag.ns + ':' + tag.name)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 标签集：所有命名空间合成一张卡。
   *
   * 为什么合并：11 个命名空间各自一张 16 圆角的卡、卡间再留 12，一屏会被切成十几块，
   * 每块只有一两个 chip，读起来像十几条互不相关的信息；合并成一张卡后，"这个画廊有哪些标签"
   * 仍然是一整块内容，组与组只靠小标题分层，滚动长度也短了（省掉十几份内边距与卡间距）。
   * 组间只留 12 的垂直间距（Column 的 space），首组自然没有上边距。
   */
  @Builder
  private tagSetCard() {
    Column({ space: 12 }) {
      ForEach(this.groups, (group: TagGroup) => {
        this.tagGroupBlock(group)
      }, (group: TagGroup) => group.ns + '-' + group.tags.length.toString())

      // 两种操作的口径提示：chip 上放小圆点会盖住标签文字，这里用一行说明替代
      Text('点按搜索该标签 · 长按投票 / 加入观看')
        .fontSize(11)
        .fontColor(Theme.subText())
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(Theme.card())
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    // 顶栏改成 MaterialSurface **压在内容上**（与首页同一套）：只有内容能从顶栏下面滚过去，
    // 材质才有东西可模糊、可透出。代价是内容区必须自己让出 headerHeight() 的顶部留白，
    // 不能像原来那样把 header 放在流内占位。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        if (this.loading) {
          Column({ space: 10 }) {
            LoadingProgress().width(32).height(32).color(Theme.subText())
            Text('读取详情…').fontSize(12).fontColor(Theme.subText())
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          // 居中要在顶栏下面居中，否则转圈会跑到玻璃后面
          .padding({ top: this.headerHeight() })
        } else if (this.detail === null) {
          Column({ space: 10 }) {
            Text(this.error.length > 0 ? this.error : '读取失败')
              .fontSize(13)
              .fontColor(Theme.subText())
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Text('重试')
              .fontSize(13)
              .fontColor(Theme.accent())
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .borderRadius(8)
              .backgroundColor(Theme.line())
              .onClick(() => this.load())
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .padding({ top: this.headerHeight() })
        } else {
          // 详情页下拉刷新：重新拉一次详情（简介/标签/缩略图/收藏态）。
          // 不配 builder：下拉区那段会被半透明顶栏盖住，看不见 —— 反馈统一交给
          // 下面的浮层胶囊（与列表页 GalleryListView 同一套做法）。
          Refresh({ refreshing: $$this.refreshing }) {
            Scroll(this.scrollCtrl) {
                Column({ space: 12 }) {
                // 标题 + 信息合成一张卡。
                //
                // 原来是两张：上面「封面 + 标题 + 属性 chip」，下面一行行「上传者 / 语言 / 发布…」。
                // 两张卡间隙只有 12、都带 16 内边距，读起来是同一件事被切成两半；
                // 而且下面那张不是独立内容，全是这部作品的属性。
                // 现在用一条 0.5 的发丝线在卡内分段：线区分「主信息」与「明细」，但不切断卡片。
                Column() {
                  Row({ space: 16 }) {
                    // 封面区域 =「圆角的灰底方块」+「直角的图片」：
                    // 圆角放在这一层（Stack）上，由 clip 裁出四角；里面的 Image 不设圆角。
                    // 只给 Image 设圆角时，圆角会跟着图片内容走，横构图 cover 留白后
                    // 四角会露出底色直角；反过来只给图片去圆角，灰底就变成方角。
                    Stack({ alignContent: Alignment.Center }) {
                      Image(this.gallery.thumbUrl)
                        .width('100%')
                        .height('100%')
                        // 与列表卡（ui/GalleryCard.ets）对齐：横构图封面不再裁切，宁可留底色
                        .objectFit(ImageFit.Contain)
                    }
                    .width(120)
                    .height(168)
                    .borderRadius(12)
                    .clip(true)
                    .backgroundColor(Theme.line())

                    Column({ space: 6 }) {
                      Text(this.gallery.title)
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Theme.text())
                        .maxLines(3)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        // 长按可选：标题里常带社团/作品名，用户需要复制去别处搜索
                        .copyOption(CopyOptions.LocalDevice)
                        .width('100%')
                      if (this.detail.japTitle.length > 0) {
                        Text(this.detail.japTitle)
                          .fontSize(12)
                          .fontColor(Theme.subText())
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .copyOption(CopyOptions.LocalDevice)
                          .width('100%')
                      }
                      Flex({ wrap: FlexWrap.Wrap }) {
                        this.metaChip(this.gallery.categoryLabel)
                        this.metaChip(this.gallery.pages.toString() + ' 页')
                        if (this.detail.sizeText.length > 0) {
                          this.metaChip(this.detail.sizeText)
                        }
                        if (this.gallery.rating > 0) {
                          this.metaChip('★ ' + this.gallery.rating.toFixed(2) + ' (' + this.detail.ratingCount.toString() + ')')
                        }
                      }
                      .width('100%')
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')

                  // 卡内分段线：左右各留 0（跟着卡片内边距走），上下 12 给出呼吸。
                  // 用 0.5 而不是 1：它是同一张卡内部的分段，不是两张卡之间的边界。
                  Divider()
                    .strokeWidth(0.5)
                    .color(Theme.line())
                    .margin({ top: 12, bottom: 12 })

                  // 明细两列排：属性短、条数少，一行一条会把卡片拉得很长；
                  // 两列之后「上传者 / 语言」这类自然成对，纵向长度直接减半。
                  Column({ space: 10 }) {
                    Row({ space: 12 }) {
                      if (this.gallery.uploader.length > 0) {
                        this.infoCell('上传者', this.gallery.uploader)
                      }
                      if (this.detail.language.length > 0) {
                        this.infoCell('语言', this.detail.language)
                      }
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Top)

                    Row({ space: 12 }) {
                      if (this.gallery.posted.length > 0) {
                        this.infoCell('发布', this.gallery.posted)
                      }
                      this.infoCell('收藏数', this.detail.favCount.toString())
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Top)

                    if (this.detail.visible.length > 0) {
                      Row({ space: 12 }) {
                        this.infoCell('可见性', this.detail.visible)
                      }
                      .width('100%')
                    }
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .padding(16)
                .borderRadius(16)
                // 必须显式 clip：只设 borderRadius 时，圆角只作用于**背景**，
                // 子内容（封面图的底色块、发丝线）仍按矩形铺，看起来就是「外框是直角」。
                // 封面自身不要再设圆角，圆角统一由这一层裁。
                .clip(true)
                .backgroundColor(Theme.card())
                .alignItems(HorizontalAlign.Start)

                // 标签：按命名空间分组，但所有组合成一张卡（组只是卡内的小标题分段）
                // 数据来自 EhApi.parseDetail 的 #taglist（或 fillTagsByApi 的 gdata 兜底），
                // 不是账号侧的「标签集」—— 后者详情页拿不到，原因见文件头注释。
                // 读一次 tagTransTick 建立依赖：标签库加载完成后这张卡会重绘
                if (this.groups.length > 0 && this.tagTransTick >= 0) {
                  this.tagSetCard()
                }

                // 页面缩略图：点某一格就从那一页开始读（对齐原版详情页）
                if (this.thumbs.length > 0) {
                  this.thumbGrid()
                }
              }
              .width('100%')
              // 顶部让位必须等于顶栏高度（同一个 headerHeight()），否则不是被遮一条就是多一条空白。
              // 底部让位同理走 barHeight()：底板去掉后它从 nav+16+70 收成 nav+16+46，
              // 这里 +12 是按钮顶到内容之间的呼吸，两块一起套同一个口径，最后一行不会被按钮压住。
              .padding({
                left: 16,
                right: 16,
                top: this.headerHeight() + 12,
                bottom: this.barHeight() + 12
              })
                .alignItems(HorizontalAlign.Start)
              }
              .layoutWeight(1)
              .scrollBar(BarState.Off)
              .align(Alignment.Top)
              // 记录当前滚动位置，只给「回到顶部」的显隐用。
              //
              // **不读回调参数**：这个 SDK 里 onDidScroll 的两个参数口径不统一
              // （可能是「累计偏移 + ScrollState」，也可能是「本帧增量 + ScrollState」）。
              // 若第二参其实是枚举，`yOffset > 480` 永远不成立 —— 按钮就一直不出现，
              // 表现正是「回顶钮是透明/看不见的」。这里改读 scroller 的累计偏移，
              // 只有它一定可靠（而且要回顶本来就需要这个 Scroller）。
              //
              // 只在「跨过阈值」时写一次 @State：滚动是每帧回调，每帧都写会拖整页重绘。
              .onDidScroll(() => {
                const y: number = Math.abs(this.scrollCtrl.currentOffset().yOffset);
                const on: boolean = y > TOP_BTN_THRESHOLD;
                if (on !== this.topBtnOn) {
                  this.topBtnOn = on;
                }
              })
              // 滚到底就自动补 20 屏缩略图（一次 400 张），不再需要点「加载全部页面」。
              // 为什么 20 屏而不是一次全拉：上千页的要 50+ 个请求，滚到底连拉会把列表卡住；
              // 分批既能自动延续，又给用户留了「没滚到底就不发请求」的余地。
              .onScrollEdge((side: Edge) => {
                if (side === Edge.Bottom) {
                  this.loadAllThumbs(1);
                }
              })
            }
          .layoutWeight(1)
          // 触发距离与列表页同口径（110）：同一手势阈值，换页面不用重新适应
          .refreshOffset(110)
          .pullDownRatio(1)
          .onRefreshing(() => {
            this.reloadByPull();
          })
          .onStateChange((state: RefreshStatus) => {
            this.refreshStatus = state;
          })
        }
      }
      .width('100%')
      .height('100%')
      // 收藏面板**不再挂 bindSheet**：系统半模态的跟手位移拦不住，按住面板顶部上滑
      // 整块 sheet 会往上抽、屏幕下沿留缝露出详情页。真实机制与取舍见 favOverlay()。
      // 现在它是一层自绘覆盖层，挂在 build 根 Stack 的最后一个子节点（见 build 末尾）。

      // ---- 顶栏：与首页同一套（沉浸材质 + 22 中黑大标题 + 11 次要色副标题 + 右侧 32 高 pill）
      MaterialSurface({ surfaceHeight: this.headerHeight() }) {
        Column() {
          Row({ space: Tokens.SPACE_SM }) {
            // 圆形玻璃返回键：与 PageHeader 同一套（44×44 圆形材质 + 0.6vp 描边）。
            // 材质平面与可点层是兄弟：材质 hitTestBehavior 为 None，点击必须落在上面那层，
            // 所以箭头套一个同尺寸 Row 来接管 onClick（与底部悬浮工具条同一写法）。
            Stack({ alignContent: Alignment.Center }) {
              MaterialPlane({ kind: 'header', radius: 999, planeHeight: Tokens.TOUCH_MIN })
              Row() {
                SymbolGlyph($r('sys.symbol.chevron_left'))
                  .fontSize(Tokens.FONT_H1)
                  .fontColor([Theme.text()])
              }
              .width(Tokens.TOUCH_MIN)
              .height(Tokens.TOUCH_MIN)
              .justifyContent(FlexAlign.Center)
              .onClick(() => this.onBack())
            }
            .width(Tokens.TOUCH_MIN)
            .height(Tokens.TOUCH_MIN)
            // 为什么与二级页 PageHeader 那颗返回键同参数：
            // 1) 描边统一走 Theme.btnEdge()、宽度同为 0.6 —— 两处都压在沉浸材质上，
            //    白 20% 细边读作「玻璃边缘被灯打亮」，宽度 0.6 是 44 圆上不显粗的上限；
            // 2) 阴影统一走 Theme.floatShadow()，与工具条、评论输入框同一档接触阴影；
            // 3) 阴影挂在 Stack 这一层（返回键最外层），只用 borderRadius 定圆形轮廓：
            //    这里若给 clip(true)，会把 0.6 的描边削掉半条（PageHeader 已踩过，注释见其 :83），
            //    材质的圆形裁切由 MaterialPlane 内部按 radius 自己做，不需要外层 clip。
            .borderRadius(999)
            .border({ width: 0.6, color: Theme.btnEdge() })
            .shadow(Theme.floatShadow())

            Column({ space: 1 }) {
              Text(this.gallery.title)
                .fontSize(Tokens.FONT_H2)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.text())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.headerSubtitle())
                .fontSize(Tokens.FONT_TAG)
                .fontColor(Theme.subText())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text(this.archived ? '已存档' : '存档')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.archived ? '#7FD4A0' : Theme.accent())
              .height(Tokens.HEADER_ACTION_HEIGHT)
              .padding({ left: 12, right: 12 })
              .textAlign(TextAlign.Center)
              .borderRadius(999)
              // 原来是 Theme.card()：浅色下是一块纯白，压在玻璃顶栏上就像补丁。
              // 改为主色 12% 填充，和底栏/分段控件的选中态同一套观感。
              .backgroundColor(this.accentFill())
              // 点一下就写一条存档（key `archive_items`），媒体库的「存档」tab 读它。
              // 这里刻意不再切 LocalFav：本地收藏与存档是两份数据，一个按钮同时改两份，
              // 总有一份会先过期，按钮态就再也说不清是哪一份了。
              .onClick(() => {
                this.saveArchive();
              })
          }
          .width('100%')
          // 行高 = 56 内容区 + 6 下沿空隙；6 同时作为 bottom padding 让出来，
          // 所以返回键仍在那 56 里上下各留 6（视觉重心不动），多出来的只是材质下沿到内容的呼吸。
          // 这三处（MaterialSurface.surfaceHeight / 本行 height / bottom padding）必须是同一套数，
          // 与 PageHeader 的 surfaceHeight = statusBar + barHeight + HEADER_BOTTOM_GAP 等价。
          .height(Tokens.TITLE_BAR_HEIGHT + HEADER_BOTTOM_GAP)
          // 返回键左边距与 PageHeader 取同一个 BACK_INSET（12）：
          // 12 + 44 + 8 = 64 是标题起点，两处对齐后详情页 ↔ 评论页切换时返回键不会跳。
          .padding({
            left: BACK_INSET,
            right: Tokens.SPACE_LG,
            bottom: HEADER_BOTTOM_GAP
          })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ top: this.statusBar() })
        .alignItems(HorizontalAlign.Start)
      }

      // toast 浮层：全页只有这一处 toast 渲染，胶囊外面**不再套任何带底色的容器**
      // （套一层 Theme.card()/白底，深色下就是一整块白板）。
      // 放在 Stack 里而不是 Column 里：弹出/消失不挤压内容，滚动位置不会跳。
      if (this.toast.length > 0) {
        Column() {
          Text(this.toast)
            .fontSize(12)
            .fontColor(Color.White)
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .borderRadius(999)
            .backgroundColor('#E620252E')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .padding({ bottom: this.barHeight() + 8 })
        .hitTestBehavior(HitTestMode.None)
      }

      // ---- 底部悬浮按钮组：阅读 / 下载 / 收藏 / 评论 / 更多
      //
      // 为什么把「条」删掉：原来这里是一层 radius 999 的 MaterialPlane 通铺整条，
      // 里面再摆一排按钮 —— 视觉上是一块长条底板上放了五个按钮，底板自己还有底色、
      // 0.7 描边和一大团投影，内容永远被那块板挡着。现在底板整层删除（材质层、承载它的
      // 宽高/圆角/描边/阴影一并去掉），只留下按钮行：每颗按钮自己带材质与阴影，
      // 读起来是一排独立的浮起物，按钮之间与下方都能透出内容。
      //
      // 材质统一到 header：上一版四颗小圆钮用的是「有界玻璃」（fallbackTint('panel') +
      // backgroundEffect），顶栏返回键用的是 MaterialPlane(kind 'header') —— panel 与 header
      // 是两套染色/亮度配方，同一屏里一眼看出两种玻璃。现在四颗圆钮改回 MaterialPlane
      // kind 'header'，与返回键同一口径，状态差异只由文字色 / 选中底表达。
      // 已知风险：MaterialPlane 的材质落在 Navigation 的 title 作用域里，尺寸按作用域解析，
      // 可能横铺出一条通栏色带；验证与回退方式见 favBarButton 的注释。
      Row({ space: TOOL_BAR_GAP }) {
        Text('开始阅读')
          .layoutWeight(1)
          .height(TOOL_BTN)
          .fontSize(14)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .borderRadius(999)
          .backgroundColor(Theme.accent())
          // 主按钮是**不透明实心**主色，材质铺上去会被完全盖住（等于白加一层），
          // 所以这里不铺材质，只补同档的发丝边 + 接触阴影，让它和旁边四颗玻璃读成同一批浮起控件。
          .border({ width: 0.7, color: Theme.btnEdge() })
          .shadow(Theme.floatShadow())
          // 详情未到就不进阅读器：ReaderPage 会用 detail.pageUrls 组首屏，
          // 拿到 null 直接崩（见 toolsReady() 的注释）。这里先收窄再传，
          // 不再用 `as` 断言骗过编译器。
          .onClick(() => {
            const d: GalleryDetail | null = this.detail;
            if (d === null) {
              return;
            }
            this.onRead(d, 0);
          })
        this.barCircle('下载', () => {
          const d: GalleryDetail | null = this.detail;
          if (d === null) {
            return;
          }
          Downloader.enqueue(d);
          this.showToast('已加入下载队列');
        }, false, false)
        this.favBarButton()
        this.barCircle('评论', () => {
          const d: GalleryDetail | null = this.detail;
          if (d === null) {
            return;
          }
          this.onComments(d);
        }, false, false)
        this.barCircle('更多', () => {
          const d: GalleryDetail | null = this.detail;
          if (d === null) {
            return;
          }
          this.onTools(d);
        }, false, false)
      }
      .width('calc(100% - 32vp)')
      .height(TOOL_BTN)
      .alignItems(VerticalAlign.Center)
      // 未就绪 = 不可点 + 半透明：让「按了没反应」变成看得见的「还不能按」。
      // enabled(false) 会连带关掉子节点的命中测试（按钮的 onClick 不会再触发），
      // opacity 只影响这一层的绘制，不改任何布局尺寸。
      .enabled(this.toolsReady())
      .opacity(this.toolsReady() ? 1 : 0.5)
      // 整排只负责定位：左右 16 由 x 与 width 承担，底部 16（+ 手势条）由 translate 承担。
      // 这里**没有** clip：0.7 的发丝边正好压在外圈路径上，裁一刀会被削掉一半；
      // 描边和阴影都由各按钮自己画，这一层不再画任何底色/边框。
      .position({ x: TOOL_BAR_INSET, y: '100%' })
      .translate({ y: -(this.barHeight()) })

      // 刷新浮层：根 Stack 的最后一个子节点，压在内容与工具条之上
      this.refreshPill()
      // ---- 回到顶部：**根 Stack 的最后一个子节点**，保证压在所有内容与工具条之上
      //
      // 之前把它放在内容与工具条之间，存在被后声明的节点盖住的可能（尤其工具条与刷新浮层
      // 都在它之后声明）。顺序在 ArkUI 里就是层级：越晚声明越靠上，所以这里放到最后。
      //
      // 底色用 Theme.card()（实色）+ 描边 + 阴影：不再依赖材质是否生效。
      // 前面两版分别用了「白玻璃」和「材质 + 浅灰底」，在浅色页面上都几乎看不见 ——
      // 一颗浮在内容上的按钮，**可见性优先于材质感**，材质只作为叠加层提供质感。
      Column() {
        Stack({ alignContent: Alignment.Center }) {
          MaterialPlane({ kind: 'header', radius: 999, planeHeight: TOP_BTN })
          Row() {
            SymbolGlyph($r('sys.symbol.arrow_up'))
              .fontSize(18)
              .fontColor([Theme.text()])
          }
          .width(TOP_BTN)
          .height(TOP_BTN)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            // scrollTo + animation：Scroll 的 scrollEdge 只接 velocity，落地是瞬时跳顶（会闪）
            this.scrollCtrl.scrollTo({
              xOffset: 0,
              yOffset: 0,
              animation: { duration: 260, curve: Curve.Smooth }
            });
          })
        }
        .width(TOP_BTN)
        .height(TOP_BTN)
        .borderRadius(999)
        // 只留沉浸材质（不铺实色）：按钮已能正常出现，实底会把材质完全盖住，
        // 与顶部/底部那批玻璃钮不是一套观感。描边与阴影保留，负责勾出轮廓。
        .border({ width: 0.7, color: Theme.btnEdge() })
        .shadow(Theme.floatShadow())
      }
      .width('100%')
      .height('100%')
      .padding({
        right: TOOL_BAR_INSET,
        bottom: this.barHeight() + TOP_BTN_GAP + (this.topBtnShown() ? 0 : 4)
      })
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.End)
      .opacity(this.topBtnShown() ? 1 : 0)
      .animation({ duration: 160, curve: Curve.Smooth })
      // Transparent：按钮能点，滚动手势照常穿透到下层；不可见时 None，避免鬼按钮
      .hitTestBehavior(this.topBtnShown() ? HitTestMode.Transparent : HitTestMode.None)

      // ---- 收藏弹层（自绘）：根 Stack 的**最后一个**子节点，
      // 所以它盖在顶栏、底部工具条、toast、回顶钮之上，打开时不会被任何浮层压住。
      // 用 if 增删节点：关掉之后节点必须离开树 —— 常驻的全屏遮罩即使 hitTest 设 None，
      // 也会在某些命中路径上吞掉整页点击（阅读器设置面板上一版踩过，见 ReaderPage.settingsOverlay）。
      if (this.favSheet) {
        this.favOverlay()
      }
    }
    .width('100%')
    .height('100%')
    // ---- 标签面板：本页**只在这一个节点上**绑 sheet。
    //
    // bindSheet 的宿主节点是按「目标节点 id」登记的，同一个节点上链两次 bindSheet，
    // 后一次会复用同一个 sheet 节点并覆盖掉前一次的 builder 与 isShow 绑定。
    // 收藏面板现在改成了自绘覆盖层（见 favOverlay），不再占用 sheet 宿主，
    // 所以这条约束只剩标签面板自己；以后若要再挂一条 sheet，仍须另找一个宿主节点。
    //
    // isShow 用 `$$`（双向）：否则用户下拉关掉面板时状态不会回写，tagSheet 会停在 true ——
    // 下次再 set true 就不是「状态变化」，面板永远弹不出来（第二次点了没反应）。
    .bindSheet($$this.tagSheet, this.tagSheetBuilder(), {
      height: 240,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.card(),
      maskColor: '#99000000'
    })
  }

  /**
   * 工具条是否就绪（detail 已拿到）。
   *
   * 根因在这里：底部悬浮工具条在 build() 里是**无条件渲染**的 —— 它在
   * `if (loading) / else if (detail === null) / else` 这三分支的**外面**，
   * 所以页面被推入的第一帧它就已经满不透明、可点，而此刻 `load()` 还在等
   * `EhApi.loadDetail()` 的 HTTP 返回，`this.detail` 仍是 null。
   *
   * 各按钮原来写 `this.detail as GalleryDetail`：`as` 只是**编译期**断言，
   * 运行时不会拦 null，null 会原封不动传下去，然后在被调方炸掉：
   *  - 开始阅读 → ReaderPage.aboutToAppear 里 `this.detail.pageUrls`（ReaderPage.ets:181）
   *  - 评论   → CommentsPage.aboutToAppear 里 `this.detail.rawHtml`（CommentsPage.ets:38）
   *  - 下载   → Downloader.enqueue 里 `detail.gallery`（core/Downloader.ets:260）
   * 三条都是同步解引用 null，都没有 try/catch，直接闪退。
   *
   * 为什么表现成「立刻点崩、稍等就正常」：loadDetail 的往返差不多就是几百毫秒，
   * 和 Index.ets 里 350ms 的推入动画同一量级 —— 网络稍快时，详情返回与动画结束
   * 几乎同时发生，用户手快就正好落在 `detail === null` 的窗口里。
   * 所以这里守的是**数据未就绪**，不是动画中间态。
   */
  private toolsReady(): boolean {
    return this.detail !== null;
  }

  /**
   * 收藏面板高度 = min(内容估算, 屏高 × 60%)。
   *
   * 为什么按内容估算而不是写死：
   *  1) 内容高随状态变 —— 未登录只有表单（矮），已登录是 10 行目录（高），
   *     已收藏时还多一段「取消收藏」；
   *  2) 写死大值在小屏（分屏、折叠内屏）会顶到状态栏，写死小值（上一版 320）又放不下
   *     10 个目录，底部「取消收藏」被裁在面板外点不到 —— 那会被读成「收藏按钮没用」。
   *
   * 公式（foot = 底部留白 + 导航条安全区，两态都要）：
   *   未登录：52(头) + 182(表单) + foot
   *   已登录：52(头) + [30 缺 igneous 提示] + 10 × 48(目录) + [52 取消胶囊段] + foot
   *   （取消胶囊段 = 40 胶囊 + 12 上间距，见 FAV_CANCEL_H；未收藏时整段不计入）
   *
   * 超出 60% 屏高的部分由面板里的 List 自己滚（favListPanel 就是 List + layoutWeight(1)）。
   *
   * 自绘弹层（favOverlay）后高度是 build 期实时求值的，不再受「系统半模态只在打开那一刻
   * 取一次高度」的限制：面板开着时刚好登录成功，它会立刻按已登录的内容高重新排布。
   */
  private favSheetHeight(): number {
    const cap: number = this.screenHeight() * 0.6;
    const foot: number = FAV_PAD_BOTTOM + this.navBarInset();
    if (!Cookies.isLoggedIn()) {
      return Math.min(FAV_HEAD_H + FAV_LOGIN_BODY_H + foot, cap);
    }
    let content: number = FAV_HEAD_H + FavCats.NAMES.length * FAV_ROW_H;
    if (this.favWarnShown()) {
      content = content + FAV_WARN_H;
    }
    if (this.favcat >= 0) {
      content = content + FAV_CANCEL_H;
    }
    return Math.min(content + foot, cap);
  }

  /**
   * 是否显示「缺 igneous」那行提示。
   *
   * 抽成方法是因为 favListPanel 要按它渲染、favSheetHeight 要按它算高 —— 两边各写一次
   * 条件，条件一改（比如以后表域也有同类限制），高度就会和内容差一行。
   */
  private favWarnShown(): boolean {
    if (!Cookies.isLoggedIn()) {
      return false;
    }
    return Prefs.site() === Site.EX && !Cookies.hasIgneous();
  }

  /**
   * 导航条（手势条）高度。
   *
   * 面板内容自己要避让这一段：弹层贴屏幕物理底边（favOverlay 不带任何底部 margin），
   * 不减去导航条的话，面板最后一行会压在系统手势条下面，既不好点也难看。
   * 取不到就按 0（只是少一点留白）。
   */
  private navBarInset(): number {
    const v: number | undefined = AppStorage.get<number>('navBarHeight');
    return v === undefined ? 0 : v;
  }

  /**
   * 屏幕高（vp）。
   *
   * display 给的是 px，面板高度要 vp，所以必须除 densityPixels。
   * 取不到就按 800 估 —— 它只影响封顶值，不影响列表内容与滚动。
   */
  private screenHeight(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      return d.height / d.densityPixels;
    } catch (e) {
      return 800;
    }
  }

  /**
   * 底部悬浮按钮组占用的高度（含导航条避让与屏边距）。
   * 组成：导航条 + 16（整排与屏底边距）+ 46（按钮高，不再有上下各 12 的条内边距）。
   *
   * 底板去掉后这里必须跟着变：原来是 16 + 70（46 按钮 + 上下各 12），现在就是
   * 16 + 46。内容底部的 padding（+12）与 toast 的抬升（+8）都读它，所以只要这里
   * 改对，页面尾部既不会被按钮压住、也不会多出一条空白。
   */
  private barHeight(): number {
    return this.navBarInset() + TOOL_BAR_INSET + TOOL_BTN;
  }

  /**
   * 「回到顶部」是否可见（= 是否可点）。
   *
   * 抽成方法而不是在 build 里把条件抄三遍：opacity / translate / hitTestBehavior 三处
   * 必须是同一个判定 —— 任意一处写岔，就会出现「看得见但点不动」或「看不见却挡住点击」。
   * 阈值含义见 TOP_BTN_THRESHOLD。
   */
  private topBtnShown(): boolean {
    return this.topBtnOn;
  }

  /** 状态栏高度：顶栏自己要吃这一段，内容让位也要算它，否则内容会钻到状态栏下面 */
  private statusBar(): number {
    const v: number | undefined = AppStorage.get<number>('statusBarHeight');
    return v === undefined ? 0 : v;
  }

  /**
   * 顶栏实际高度（含状态栏与下沿空隙）= 状态栏 + 56 + 6。
   *
   * 顶栏是**压在内容上**的一层（和首页一致），所以滚动区的顶部留白必须严格等于这个值 ——
   * 两边各写一个数字，早晚会差几 vp，出现「被遮一条」或「顶上多一条空白」。
   *
   * 6 是页头下沿的呼吸（见 HEADER_BOTTOM_GAP）：它必须算进总高，材质面
   * （MaterialSurface.surfaceHeight 读的就是本方法）、页头 Row 的高度与底部 padding
   * 才是一套数；漏掉任何一处，就会出现「材质比行矮一条」或「发丝线画在内容中间」。
   */
  private headerHeight(): number {
    return this.statusBar() + Tokens.TITLE_BAR_HEIGHT + HEADER_BOTTOM_GAP;
  }

  /** 顶栏副标题：分类 · 页数 */
  private headerSubtitle(): string {
    const pages: string = this.totalPages().toString() + ' 页';
    return this.gallery.categoryLabel.length > 0
      ? this.gallery.categoryLabel + ' · ' + pages
      : pages;
  }

  /**
   * 主色 12% 填充：与媒体库分段控件 / 底栏选中态同一套数值。
   * 深色底上纯色块会发闷，所以用主色的低透明度叠加，文字再走 Theme.accent()。
   */
  private accentFill(): string {
    return Theme.isDark() ? '#245AA9FF' : '#162F6BD8';
  }

  /** 总页数：优先用元信息里的 Length，没有就退回已解析到的链接数 */
  private totalPages(): number {
    if (this.gallery.pages > 0) {
      return this.gallery.pages;
    }
    return this.thumbs.length;
  }

  /** 缩略图一共几屏（详情页每屏 20 张） */
  private thumbSlices(): number {
    return this.detail === null ? 1 : this.detail.thumbPageCount;
  }

  /**
   * 一次补一屏页链接（`?p=1/2/3…` 里的 `?p=<屏号>`），滚到底自动继续。
   *
   * 补的不再是「缩略图地址」，而是**下一页的 `/s/` 页地址**：格子里的图现在逐页现取，
   * 所以要铺出第 21 格就必须先知道第 21 页的地址。这和阅读器里 collect() 补页是同一个来源。
   * `thumbLoaded` 每成功一屏 +1，界面能持续看到「已载入 N」在涨；
   * 中途任何一屏返回空/抛错就停下，保留已拉到的部分（已载入的本来就是有效数据）。
   */
  private async loadAllThumbs(batches: number = 1): Promise<void> {
    if (this.thumbBusy || this.detail === null) {
      return;
    }
    this.thumbBusy = true;
    try {
      let done: number = 0;
      while (this.thumbLoaded < this.thumbSlices() && done < batches) {
        // thumbLoaded 本身就是「已载入的分屏数」= 下一页的 p（不是图片偏移）
        const slice: ThumbSlice = await EhApi.loadThumbPageUrlsWithImages(this.gallery.url, this.thumbLoaded);
        if (slice.urls.length === 0) {
          // 到底了（或站点拒绝继续给）：把进度拉满，别让按钮一直转
          this.thumbLoaded = this.thumbSlices();
          break;
        }
        // 按**页链接**去重后再拼：站点在 p 越界时会把同一屏回两次，
        // 不去重的话网格里会出现重复的格子（第 21、22 格其实是同一页）。
        const freshThumbs: string[] = [];
        const freshTiles: ThumbTile[] = [];
        const freshUrls: string[] = [];
        const haveTiles: boolean = slice.tiles.length === slice.thumbs.length;
        for (let i = 0; i < slice.urls.length; i++) {
          if (this.pageUrls.indexOf(slice.urls[i]) >= 0) {
            continue;
          }
          freshUrls.push(slice.urls[i]);
          // thumbs 只是「格子数」的载体（内容已不参与渲染），有缩略图地址就用，没有就留空串
          freshThumbs.push(i < slice.thumbs.length ? slice.thumbs[i] : '');
          freshTiles.push(haveTiles ? slice.tiles[i] : new ThumbTile());
        }
        if (freshUrls.length === 0) {
          // 这一屏全是重复：再往下翻也不会有新页，直接收尾，避免死循环
          this.thumbLoaded = this.thumbSlices();
          break;
        }
        this.pageUrls = this.pageUrls.concat(freshUrls);
        this.thumbs = this.thumbs.concat(freshThumbs);
        this.tiles = this.tiles.concat(freshTiles);
        this.thumbLoaded = this.thumbLoaded + 1;
        done = done + 1;
      }
    } catch (e) {
      this.showToast('缩略图加载失败');
    }
    this.thumbBusy = false;
  }

  /** 长按「已载入 N」的诊断信息：唯一地址数 + 前三条地址 */
  private showThumbDiag(): void {
    const uniq: Set<string> = new Set<string>();
    for (let i = 0; i < this.thumbs.length; i++) {
      uniq.add(this.thumbs[i]);
    }
    const head: string[] = [];
    for (let i = 0; i < this.thumbs.length && i < 3; i++) {
      const u: string = this.thumbs[i];
      head.push((i + 1).toString() + '. ' + (u.length > 70 ? u.substring(0, 70) + '…' : u));
    }
    // 每批的现场：n=锚点数 t=地址数 u=唯一数 p=配对命中 r=域内 /t/ 数
    const trace: string = EhApi.diag.length > 0 ? ('\n批: ' + EhApi.diag.join(' | ')) : '';
    // 精灵几何：tiles 条数 + 前三条的 x/y/w/h，用来判断偏移是否算对
    let geo: string = '\ntiles=' + this.tiles.length.toString();
    for (let k = 0; k < this.tiles.length && k < 3; k++) {
      const g: ThumbTile = this.tiles[k];
      geo += ' [' + g.x.toString() + ',' + g.y.toString() + ' ' + g.w.toString() + 'x' + g.h.toString() + ']';
    }
    const page0: string = this.detail !== null && this.detail.pageUrls.length > 0
      ? ('\n页链0: ' + this.detail.pageUrls[0]) : '';
    AlertDialog.show({
      title: '预览图解析',
      message: '共 ' + this.thumbs.length.toString() + ' 条，唯一 ' + uniq.size.toString() + ' 条\n'
        + head.join('\n') + geo + page0 + trace
        + (EhApi.lastSnippet.length > 0 ? ('\n原文: ' + EhApi.lastSnippet) : ''),
      confirm: {
        value: '知道了',
        action: () => {
        }
      }
    });
  }

  // ------------------------------------------------------------ 精灵裁切（像素级）
  /**
   * 第 i 格可用的裁切矩形；null = 这一格走逐页真图。
   *
   * 判据只有「有没有 tile 且宽高有效」——这正是 Ehviewer_OHOS 的 `canCropPreview`
   * （`ptc.ets:137`：`width > 0 && height > 0`）。坐标与尺寸直接用站点给的 CSS px，
   * 不做任何换算（参考项目已确认与 sheet 真实像素一致，`gdp.ets` 的 parsePreviewSet 同源）。
   */
  private spriteTileOf(i: number): ThumbTile | null {
    const t: ThumbTile | undefined = this.tiles[i];
    if (t === undefined || t.sheet.length === 0 || t.w <= 0 || t.h <= 0) {
      return null;
    }
    return t;
  }

  /**
   * 第 i 格已经解好的缩略图（没有就 null）。
   *
   * 这里必须先读一次 `pagePmVer`：@State 只有在 build 期被读到才建立依赖，
   * 而真正存图的 `pagePms` 是不可观察的 Map —— 不读这个版本号，图下好了格子也不会重绘。
   * （`pagePmVer < 0` 不可能成立，写在这里只是让这次读取留在 build 路径上。）
   */
  private pmOf(i: number): image.PixelMap | null {
    if (this.pagePmVer < 0) {
      return null;
    }
    const pm: image.PixelMap | undefined = this.pagePms.get(i);
    return pm === undefined ? null : pm;
  }

  /**
   * 还掉本页所有逐页缩略图并清空队列（只在本页销毁时调用）。
   *
   * 为什么下拉刷新不调它：刷的是同一本画廊，第 i 格的图还是第 i 页；而 ForEach 的节点
   * 会被复用、onAppear 不会再触发一次 —— 清掉之后那些格子会永远停在页码上。
   */
  private dropPagePms(): void {
    this.pagePms.forEach((pm: image.PixelMap) => {
      try {
        pm.release();
      } catch (e) {
      }
    });
    this.pagePms.clear();
    for (let i = 0; i < this.retiredPms.length; i++) {
      try {
        this.retiredPms[i].release();
      } catch (e) {
      }
    }
    this.retiredPms = [];
    this.pageDead.clear();
    this.pageFails.clear();
    this.pageErrs.clear();
    this.pageStarts.clear();
    this.cropFailed.clear();
    // 整个队列丢弃：页面都要销毁了，排队中的格子没有意义；在途结果由管道自己释放
    const p: ThumbPipeline | null = this.pipe;
    if (p !== null) {
      p.stop();
      this.pipe = null;
    }
    // 让格子重画一次：清空后应该回到页码占位
    this.pagePmVer = this.pagePmVer + 1;
  }

  /**
   * 为第 i 格取一张缩略图（按需：格子挂到树上时调用）。
   *
   * 现在的分工全在 requestPage 里：
   *  - 有 tile（站点给了 sprite 子矩形）→ ThumbCropper 按像素裁一块，**一屏 20 格
   *    只发一次 sheet 请求**（ThumbCropper 内部按 sheet 地址去重）；
   *  - 没有 tile / 该格裁剪失败过 → 原来的 `/s/` 页 → 真图 → 解码（比例天然正确）。
   *
   * 请求节奏：裁剪路线的并发由 ThumbCropper 的 4 个槽位控制，
   * 逐页路线交给 ThumbPipeline（HTML 3 / 图片 6 / 行号小者优先），
   * 这里只做「格子级去重 + 登记超时」。
   */
  private ensurePageThumb(i: number): void {
    this.requestPage(i);
  }

  /** 这一格是否已判定失败（读 deadVer 建立重绘依赖） */
  private isDeadCell(i: number): boolean {
    // deadVer 只是用来让 build 依赖它；逻辑上不影响判断
    const tick: number = this.deadVer;
    return tick >= 0 && this.pageDead.has(i);
  }

  /** 失败格的文案：连续失败两次就不再骗用户「再点一下就好」 */
  private deadText(i: number): string {
    const tick: number = this.deadVer;
    if (tick < 0) {
      return '';
    }
    const msg: string | undefined = this.pageErrs.get(i);
    return msg === undefined ? '点击重试' : msg;
  }

  /** 用户点重试：清掉失败标记，连缓存一起清干净再重新排队（并重新允许走裁剪） */
  private retryPageThumb(i: number): void {
    this.pageDead.delete(i);
    this.pageFails.delete(i);
    this.pageErrs.delete(i);
    // 用户主动重试是新的网络环境：上一轮裁剪失败可能只是当时 sheet 挂了，值得再裁一次
    this.cropFailed.delete(i);
    this.lastErr = '';
    this.deadVer = this.deadVer + 1;
    this.healAndRequest(i);
  }

  /**
   * 清掉这一页的「直链映射 + 字节缓存」后重新排队（自愈）。
   *
   * 为什么字节也要清：`ImageLoader.loadThumb` 的字节缓存同样以 `/s/` 页地址为键，
   * 上一轮如果是半张坏图（解码失败），不清掉的话重试读到的还是同一份。
   * 直链则一定清：过期 token 是 403 的头号原因，留着它重试等于保证再失败一次。
   */
  private async healAndRequest(i: number): Promise<void> {
    const pageUrl: string = this.pageUrls[i];
    if (pageUrl === undefined) {
      return;
    }
    EhApi.dropImagePage(pageUrl);
    await ImageDiskCache.remove(pageUrl);
    // 裁剪路线还要把 sheet 的字节一并清掉：手动重试时那份 sheet 可能正是坏的，
    // 留着它会让「点重试」永远读到同一份坏字节（ThumbCropper 只认 sheet 地址这个键）。
    // 已经换到逐页路线的格子不算 —— 它失败的是 `/s/` 页，清 sheet 只会让别的格子白下一次。
    if (!this.cropFailed.has(i)) {
      const t: ThumbTile | null = this.spriteTileOf(i);
      if (t !== null) {
        await ImageDiskCache.remove(t.sheet);
      }
    }
    if (!this.alive) {
      return;
    }
    this.requestPage(i);
  }

  /**
   * 把第 i 格交给「裁剪」或「逐页调度器」。
   *
   * 分流只在一处：有 tile 且没失败过 → 裁像素（ThumbCropper）；否则 → ThumbPipeline。
   * 去重靠 `pageStarts`：它既是「已受理」标记（排队中 / 在跑都算），
   * 也是 8 秒超时的判定基准。
   */
  private requestPage(i: number): void {
    if (i < 0 || i >= this.pageUrls.length) {
      return;
    }
    if (this.pagePms.has(i) || this.pageDead.has(i) || this.pageStarts.has(i)) {
      return;
    }
    const at: number = Date.now();
    this.pageStarts.set(i, at);
    const t: ThumbTile | null = this.cropFailed.has(i) ? null : this.spriteTileOf(i);
    if (t !== null) {
      this.cropPage(i, t);
    } else {
      this.pipeOf().request(i);
    }
    this.armPageTimeout(i, at, 1);
  }

  /**
   * 裁剪路线：从 sheet 里裁出第 i 格。
   *
   * 失败不直接判死，而是**换路**：这一格以后都走逐页真图（cropFailed），
   * 并由 pageStarts 的清理 + 重新 requestPage 立刻排队。
   * 为什么要换路而不是重裁：裁不出来通常是 sheet 级问题（403 / 容器坏 / 该格越界），
   * 重裁大概率还是同一个结果，而逐页真图是已经验证过的兜底。
   */
  private async cropPage(i: number, t: ThumbTile): Promise<void> {
    let pm: image.PixelMap | null = null;
    try {
      // referer 用这一格的 `/s/` 页（与 ImageLoader.loadThumb 同口径）：
      // 图床对 H@H 的 Referer 校验只认主站来源，直链自己的地址会被 403。
      const referer: string = t.page.length > 0 ? t.page : this.gallery.url;
      pm = await ThumbCropper.crop(t.sheet, t.x, t.y, t.w, t.h, referer);
    } catch (e) {
      pm = null;
    }
    if (pm !== null) {
      this.acceptPage(i, pm);
      return;
    }
    if (!this.alive) {
      return;
    }
    this.cropFailed.add(i);
    this.pageStarts.delete(i);
    this.requestPage(i);
  }

  /** 调度器懒建：回调闭包要绑到本实例上，字段初始化阶段还不适合 new */
  private pipeOf(): ThumbPipeline {
    const cur: ThumbPipeline | null = this.pipe;
    if (cur !== null) {
      return cur;
    }
    const p: ThumbPipeline = new ThumbPipeline(PAGE_HTML_PARALLEL, PAGE_IMG_PARALLEL,
      (i: number): number => this.pagePrio(i),
      (i: number): Promise<ThumbRef> => this.resolvePageRef(i),
      (i: number, url: string): Promise<image.PixelMap | null> => this.decodePage(i, url),
      (i: number, pm: image.PixelMap): void => {
        this.acceptPage(i, pm);
      },
      (i: number, reason: string): void => {
        this.failPage(i, reason);
      });
    this.pipe = p;
    return p;
  }

  /**
   * 优先级：行号小者优先。
   *
   * 网格是自上而下铺的，行号就是「离视口顶部多远」的近似（顶部信息卡高度不定，
   * 但网格本身是等行高的，按行算已经足够）。每次调度都现算，所以用户往下滚之后，
   * 补的仍然是眼前那几行，而不是排队最久的那几格。
   */
  private pagePrio(i: number): number {
    const cols: number = this.thumbCols();
    return Math.floor(i / (cols > 0 ? cols : 1));
  }

  /** 阶段一：取图片直链。命中持久化映射时**不发任何请求**（省掉一整次 HTML 往返） */
  private async resolvePageRef(i: number): Promise<ThumbRef> {
    const out: ThumbRef = new ThumbRef();
    const pageUrl: string = this.pageUrls[i];
    if (pageUrl === undefined) {
      return out;
    }
    try {
      // imagePageCached 内部：先查 Db.pageImage（同步内存），未命中才走 HTML 并回写
      const page: ImagePage = await EhApi.imagePageCached(pageUrl);
      out.url = page.imageUrl;
      out.limited = page.limited;
      out.ok = !page.limited && page.imageUrl.length > 0;
    } catch (e) {
      out.ok = false;
    }
    return out;
  }

  /** 阶段二：取字节 + 解码（字节缓存命中就不发请求） */
  private async decodePage(i: number, url: string): Promise<image.PixelMap | null> {
    const pageUrl: string = this.pageUrls[i];
    if (pageUrl === undefined) {
      return null;
    }
    return await ImageLoader.loadThumb(pageUrl, url);
  }

  /** 成功：入 Map 并触发重绘 */
  private acceptPage(i: number, pm: image.PixelMap): void {
    this.pageStarts.delete(i);
    if (!this.alive) {
      // 页面已经退出：这张图没人用了，直接还回去（ImageLoader 不持有任何图）
      try {
        pm.release();
      } catch (e) {
      }
      return;
    }
    if (this.pagePms.has(i)) {
      // 超时判死后又补回来的第二张：同一格只留一张，多的必须还回去，否则就是泄漏
      try {
        pm.release();
      } catch (e) {
      }
      return;
    }
    this.pagePms.set(i, pm);
    this.pageDead.delete(i);
    this.pageFails.delete(i);
    this.pageErrs.delete(i);
    this.evictPagePms(i);
    // Map 不可观察：自增版本号，让所有格子在下一次重绘时读到新图
    this.pagePmVer = this.pagePmVer + 1;
    // 同一帧里把「失败」态也擦掉（超时后补回来的图就属于这种）
    this.deadVer = this.deadVer + 1;
  }

  /**
   * 失败处理：**第一次**失败清缓存重排，第二次才判定失败。
   *
   * 配额页（509）不重试：再打一次只会把额度用光，后面每一格都会跟着失败。
   */
  private failPage(i: number, reason: string): void {
    this.pageStarts.delete(i);
    this.lastErr = reason;
    let n: number = 0;
    const old: number | undefined = this.pageFails.get(i);
    if (old !== undefined) {
      n = old;
    }
    n = n + 1;
    this.pageFails.set(i, n);
    // 重试节奏对齐阅读器：**组间拉长**，而不是失败一次就判死。
    // 之前「第一次失败 → 立刻重试 → 第二次失败 → 请求过于频繁」的问题在于：
    // 网络抖一下就进了终态，用户看到一屏「请求过于频繁」，但过几秒其实就通了。
    const delays: number[] = reason === 'quota' ? PAGE_RETRY_DELAYS_QUOTA : PAGE_RETRY_DELAYS;
    if (n <= delays.length && this.alive) {
      const wait: number = delays[n - 1];
      this.scheduleRetry(i, wait);
      return;
    }
    // 真正放弃：文案统一「点击重试」，不再区分原因 —— 用户只需要知道「能点」
    this.markDead(i, '点击重试');
  }

  /**
   * 延迟重排某一格。
   *
   * 用 `pageFails` 的计数当身份：等待期间用户点重试或页面退出，计数会变/页面会死，
   * 回调里据此丢弃过期的定时器，避免"旧任务把新状态覆盖掉"。
   */
  private scheduleRetry(i: number, wait: number): void {
    if (!this.alive) {
      return;
    }
    const gen: number = this.pageFails.get(i) ?? 0;
    this.pageStarts.delete(i);
    setTimeout(() => {
      if (!this.alive || this.pageStarts.has(i) || this.pagePms.has(i)) {
        return;
      }
      if ((this.pageFails.get(i) ?? 0) !== gen) {
        return;
      }
      this.healAndRequest(i);
    }, wait);
  }

  private markDead(i: number, msg: string): void {
    this.pageStarts.delete(i);
    this.pageDead.add(i);
    this.pageErrs.set(i, msg);
    this.deadVer = this.deadVer + 1;
  }

  /**
   * 8 秒兜底：到点还没出图就切成「失败（可点重试）」。
   *
   * 三个细节：
   *  1. 定时器不逐个清理，而是拿「受理时刻」对齐：回调里发现这一格的时刻已经变了
   *     （说明中间重试过一轮），那就是一颗过期的定时器，直接忽略；
   *  2. `extra > 0` 时先看它是不是**还在队列里排着**：一次网络都没发出去的格子，
   *     慢不是它的问题（首屏预取会占住前 12 个槽位），再给一窗时间；
   *  3. 裁剪路线的格子也要这一窗：它排在 ThumbCropper 的 4 个槽位后面，而第 1 格
   *     还在下整张 sheet，看起来和「图床慢」一模一样，不该判死。
   */
  private armPageTimeout(i: number, at: number, extra: number): void {
    setTimeout(() => {
      if (!this.alive || this.pageStarts.get(i) !== at) {
        return;
      }
      const cropping: boolean = this.spriteTileOf(i) !== null && !this.cropFailed.has(i);
      if (extra > 0 && (cropping || this.pipeOf().isQueued(i))) {
        this.armPageTimeout(i, at, extra - 1);
        return;
      }
      this.pipeOf().cancel(i);
      this.lastErr = 'timeout';
      this.markDead(i, '点击重试');
    }, PAGE_STUCK_MS);
  }

  /**
   * 首屏预取：前 N 格直接排队（优先级最高），用户滚到之前就已经好了。
   *
   * 裁剪路线在这里特别划算：前 12 格通常同属一张 sheet，只发 1 次网络请求 + 12 次解码。
   */
  private prefetchFirst(count: number): void {
    const n: number = Math.min(count, this.pageUrls.length);
    for (let i = 0; i < n; i++) {
      this.requestPage(i);
    }
  }

  /**
   * 容量控制：超过 PAGE_PM_CAP 就摘掉最早进 Map 的那张，但**不立刻释放**。
   *
   * 立刻 release 会把「刚被换下去、这一帧还在画」的那张变成黑格（阅读器底部条踩过这个坑：
   * 大幅跳页时淘汰的那张还在屏幕上，句柄已回收 → 黑块）。所以先挂进 retiredPms，
   * 攒到 PAGE_RETIRED_CAP 以上才把最早的一批延迟释放。
   */
  private evictPagePms(keep: number): void {
    while (this.pagePms.size > PAGE_PM_CAP) {
      // 找「最旧、且不在屏幕上」的一条；找不到就停下（宁可超容量，也不能把正在显示的收走）
      let victim: number = -1;
      this.pagePms.forEach((pm: image.PixelMap, idx: number) => {
        if (victim >= 0) {
          return;
        }
        if (idx !== keep && !this.visiblePages.has(idx)) {
          victim = idx;
        }
      });
      if (victim < 0) {
        break;
      }
      const pm: image.PixelMap | undefined = this.pagePms.get(victim);
      this.pagePms.delete(victim);
      if (pm !== undefined) {
        this.retiredPms.push(pm);
      }
    }
    if (this.retiredPms.length > PAGE_RETIRED_CAP) {
      const drop: number = this.retiredPms.length - PAGE_RETIRED_CAP;
      const batch: image.PixelMap[] = this.retiredPms.slice(0, drop);
      this.retiredPms = this.retiredPms.slice(drop);
      setTimeout(() => {
        for (let k = 0; k < batch.length; k++) {
          try {
            batch[k].release();
          } catch (e) {
          }
        }
      }, PAGE_RETIRED_DELAY_MS);
    }
  }

  /** 单格宽度（vp）：栅格宽减去列间距后按当前列数均分；还没测量时给一个保守值 */
  private cellW(): number {
    const w: number = this.gridW > 0 ? this.gridW : 340;
    const cols: number = this.thumbCols();
    return (w - THUMB_GAP * (cols - 1)) / cols;
  }

  /** 单格高度：固定值（见 THUMB_ROW_H 的说明） */
  private cellH(): number {
    return THUMB_ROW_H;
  }

  /** 当前列数：按栅格宽度算，列宽不超过 THUMB_MAX_W，最少 3 列（窄屏）/ 最多 8 列 */
  private thumbCols(): number {
    const w: number = this.gridW > 0 ? this.gridW : 340;
    // ceil 而不是 floor：JHenTai 用 `maxCrossAxisExtent: 150`，语义是「列宽**不超过** 150」，
    // 所以列数应向上取整；floor 得到的是「列宽至少 150」，800vp 时会排成 4 列、格宽 179。
    const fit: number = Math.ceil((w + THUMB_GAP) / (THUMB_MAX_W + THUMB_GAP));
    if (fit < THUMB_COLS) {
      return THUMB_COLS;
    }
    return fit > 8 ? 8 : fit;
  }

  /** 行号数组：每 4 格一行，交给外层 ForEach 遍历（行数随 thumbs 增长自动变） */
  private thumbRowIds(): number[] {
    const out: number[] = [];
    const rows: number = Math.ceil(this.thumbs.length / this.thumbCols());
    for (let r = 0; r < rows; r++) {
      out.push(r);
    }
    return out;
  }

  /** 第 row 行覆盖的缩略图下标（最后一行可能不满 4 个） */
  private thumbColIds(row: number): number[] {
    const out: number[] = [];
    const cols: number = this.thumbCols();
    const start: number = row * cols;
    for (let i = start; i < this.thumbs.length && i < start + cols; i++) {
      out.push(i);
    }
    return out;
  }

  /**
   * 缩略图网格。
   *
   * 为什么改成「每行 4 格」自己排行，而不用一个 Flex 自动换行或 Grid：
   *  - 这块在 Scroll 里，Grid 必须有确定高度，而高度取决于屏宽，算不出来；
   *  - 自动换行的 Flex 只能靠「前三格右 margin、第四格不留」补差，一旦某格宽度带小数，
   *    行与行就会错半格 —— 旧版 (25% - 4.5vp) 就是这么歪的。
   * 现在每格宽度由 `cellW()` 按**当前列数**均分（列间距交给 Row 的 space），
   * 行高固定 `THUMB_ROW_H`，所以横屏/平板只是列变多，格子比例不会变形。
   */
  @Builder
  private thumbGrid() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('页面 · ' + this.totalPages().toString())
          .fontSize(12)
          .fontColor(Theme.text())
        Blank()
        if (this.thumbs.length > 0) {
          Text('已载入 ' + this.thumbs.length.toString())
            .fontSize(10)
            .fontColor(Theme.subText())
            // 长按这里弹出解析诊断：真机上出现「一屏同图」时，这一条信息就能判定
            // 是「解析到的地址本来就相等」还是「渲染层复用节点」，不用再猜。
            .gesture(LongPressGesture().onAction(() => {
              this.showThumbDiag();
            }))
        }
      }
      .width('100%')

      Column({ space: THUMB_GAP }) {
        ForEach(this.thumbRowIds(), (row: number) => {
          Row({ space: THUMB_GAP }) {
            // 每格的身份只由「画廊 + 页号」构成，缩略图地址 **不进 key**：
            // 身份是「第几页」，内容会随加载状态变（先页码、后图片），两者不能混在一起。
            ForEach(this.thumbColIds(row), (i: number) => {
              this.thumbCell(i)
            }, (i: number) => this.gallery.gid + '-' + i.toString())
          }
          .width('100%')
        }, (row: number) => 'thumb-row-' + row.toString())
      }
      .width('100%')
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const w: number = Number(newValue.width);
        if (w > 0 && Math.abs(w - this.gridW) > 0.5) {
          this.gridW = w;
        }
      })

      // 尾部加载态：滚到底自动补一屏（20 张），这里给出「正在加载」的动效。
      // 没有这个的话，滚到底之后要等整整一个网络往返才有新格子出现，
      // 期间界面完全静止 —— 用户会以为「就这么多」，然后反复上拉。
      if (this.thumbLoaded < this.thumbSlices()) {
        Row({ space: 6 }) {
          if (this.thumbBusy) {
            LoadingProgress()
              .width(14)
              .height(14)
              .color(Theme.accent())
            Text('加载中…')
              .fontSize(11)
              .fontColor(Theme.subText())
          } else {
            Text('继续上拉加载下一批（20 页）')
              .fontSize(11)
              .fontColor(Theme.subText())
          }
        }
        .width('100%')
        .height(28)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(Theme.card())
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 单格缩略图：宽按列数均分、高固定 THUMB_ROW_H、圆角 8，页码角标贴右下。
   * 不在这里写任何左右 margin —— 列间距由外层 Row 的 space 统一给。
   *
   * 三态（从上到下按优先级），裁剪与逐页两条路**共用这一套**：
   *  - 有图（裁剪出来的 / 逐页真图）→ `Image(pm)` + Contain，比例就是原图比例；
   *  - 失败：`!` + 「点击重试」，点格子本体重试；
   *  - 排队 / 加载中：页码 + 8vp 小转圈，说明「还没好，但在动」。
   */
  @Builder
  private thumbCell(i: number) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.pmOf(i) !== null) {
        // 裁剪出来的小图尺寸就是 tile 的像素尺寸（= 原图比例），所以 Contain 不会变形；
        // 逐页真图本来就按长边 240 等比解码，同样成立。
        // 用 Contain（不是 Cover）：格子高 190 是固定的，Cover 会把竖图上下裁掉一截，
        // 缩略图是用来「认页」的，宁可留底色也要看全。
        Image(this.pmOf(i) as image.PixelMap)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .backgroundColor(Theme.line())
      } else if (this.isDeadCell(i)) {
        // 失败：给一个明确的符号 + 可执行的文案，而不是继续转圈
        Column({ space: 2 }) {
          Text('!')
            .fontSize(15)
            .fontColor(Theme.subText())
          Text(this.deadText(i))
            .fontSize(10)
            .fontColor(Theme.subText())
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.line())
      } else {
        // 排队 / 加载中：页码说明「这是第几页」，小转圈说明「还在动」。
        // 8vp 是有意压小的：一屏十几格同时转，转圈过大就变成噪点。
        Column({ space: 4 }) {
          Text('第 ' + (i + 1).toString() + ' 页')
            .fontSize(11)
            .fontColor(Theme.subText())
          LoadingProgress()
            .width(8)
            .height(8)
            .color(Theme.subText())
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.line())
      }
      Text((i + 1).toString())
        .fontSize(10)
        .fontColor(Color.White)
        .padding({ left: 4, right: 4, top: 1, bottom: 1 })
        .borderRadius(6)
        .backgroundColor('#99000000')
        .margin({ right: 4, bottom: 4 })
    }
    .width(this.cellW())
    .height(this.cellH())
    .borderRadius(8)
    .clip(true)
    // 按需加载的触发点：格子挂到树上才去取这一页的图。
    // 网格在 Scroll 里（ForEach 非懒加载），所以一进来就是整屏 20 格同时触发；
    // 并发上限分两处兜底：裁剪路线是 ThumbCropper 的 4 个槽位（一屏只下一次 sheet），
    // 逐页路线是 ThumbPipeline 的两条闸门（HTML 3 / 图片 6）。
    .onAppear(() => {
      this.visiblePages.add(i);
      this.ensurePageThumb(i);
    })
    .onDisAppear(() => {
      this.visiblePages.delete(i);
    })
    .onClick(() => {
      // 失败格：点一下重试（而不是进阅读器 —— 用户点它的意图是「这张怎么没有」）
      if (this.isDeadCell(i)) {
        this.retryPageThumb(i);
        return;
      }
      // 第 i 格就是第 i 页（0 基），直接把起点交给阅读器
      this.onRead(this.detail as GalleryDetail, i);
    })
  }

  /**
   * 工具条次按钮：46×46 圆形，自带一层沉浸材质。
   *
   * active = 该按钮代表的功能已经处于「开」的状态 → 主色实心 + 白字；
   * muted  = 前置条件不满足 → 次要色，但不置灰成不可点。
   *
   * 结构 = (材质层 MaterialPlane) + (文字 / 选中填充层)，外面再包一层只画边和阴影的 Stack：
   *  - 材质层与顶栏返回键**同一 kind、同一参数口径**（header / radius 999 / 平面高 = 按钮高）：
   *    上一版这里用的是「有界玻璃」（Material.fallbackTint('panel') + backgroundEffect），
   *    而 panel 与 header 是两套染色/亮度配方 —— 底部这排和顶栏那颗返回键摆在同一屏里，
   *    一眼就能看出是两种玻璃，用户反馈的「不统一」就是它。现在统一走 MaterialPlane。
   *  - 双线怎么避免：MaterialPlane 的 `edge` 保持默认 false（它给的是 Theme.edge() 的一圈，
   *    与外层 0.7 的 Theme.btnEdge() 叠起来就是一粗一细两道边）；外层的材质**边**仍然只有
   *    最外层那一条 0.7 白边。
   *  - 材质层自己按 radius 裁圆（MaterialPlane 内部 clip），所以**不要**在这里再给外层加
   *    clip(true)：0.7 的发丝边压在圆角路径上，裁一刀会被削掉一半（返回键、PageHeader:83 都记过）。
   *
   * 已知风险（已知并接受，先按沉浸材质改）：MaterialPlane 把材质塞进 Navigation 的 title
   * 作用域，尺寸按作用域解析而不是按这个 46 的圆 —— 若作用域按整行解析，材质会在按钮所在的
   * 高度横铺出一条通栏色带。验证方法写在 favBarButton 的注释里。
   *
   * 注意：「收藏」这颗**不用**它，走 favBarButton() —— 它的文案/底色要跟着 this.favcat
   * 变，而这里的 active/muted 是值参数，状态变了不会重新求值（见 favBarButton 的注释）。
   */
  @Builder
  private barCircle(label: string, onTap: () => void, active: boolean, muted: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      // 材质层：和顶栏返回键同一套（kind 'header' / radius 999 / planeHeight 46）
      MaterialPlane({ kind: 'header', radius: 999, planeHeight: TOOL_BTN })

      // 文字层：未选中时透明底，让下面的材质透出来；选中时用不透明主色把材质完全盖住
      // （这一层是「选中态」语义，不是第二层材质 —— 三态只靠文字色 + 这层选中底区分）
      Text(label)
        .width(TOOL_BTN)
        .height(TOOL_BTN)
        .fontSize(11)
        .fontColor(active ? Color.White : (muted ? Theme.subText() : Theme.accent()))
        .textAlign(TextAlign.Center)
        .borderRadius(999)
        .backgroundColor(active ? Theme.accent() : Color.Transparent)
        .onClick(onTap)
    }
    .width(TOOL_BTN)
    .height(TOOL_BTN)
    .borderRadius(999)
    // 边与阴影画在**不被裁剪**的这一层（见方法头注释）；宽度 0.7 与搜索页那批悬浮按钮同口径，
    // 颜色/阴影统一走 Theme.btnEdge() / Theme.floatShadow()，与页头返回键、收藏面板关闭钮同档。
    .border({ width: 0.7, color: Theme.btnEdge() })
    .shadow(Theme.floatShadow())
  }

  /**
   * 底部按钮组「收藏」按钮。
   *
   * 为什么不复用 barCircle(label, onTap, active, muted)：**@Builder 的值参数不会随父状态
   * 更新**（同一个坑 FloatingTabs.ets:264 已经写明）。收藏成功后 `favcat` 变成 0..9，
   * 但按钮的文案/底色是从参数算出来的，参数不会被重新求值 —— 于是文字永远停在「收藏」、
   * 也不会变成实心蓝，用户看到的就是「点了没反应」。这里把 this.favcat 直接读在 builder
   * 体内，状态一变这个节点就会被标记重绘；顺带满足「@Builder 不收值参数」。
   *
   * 颜色口径与 barCircle 完全一致：已收藏 = 主色实心 + 白字；未登录 = 次要色（仍可点，
   * 点开的是面板里的登录表单）。材质也统一到顶栏那一套（MaterialPlane kind 'header'），
   * 三态只靠文字色 + 已收藏的选中底区分，判定条件与 onClick 一个值都没动。
   *
   * 验证「材质有没有横铺」（改完必须看一眼，这是本方案唯一的已知风险）：
   *  1) 打开任意详情页，把内容滚到底部按钮后面，看四颗圆按钮**左右两侧同一高度**上
   *     有没有一条与按钮同色的横带 —— 特别是屏幕最左/最右边缘；
   *  2) 收藏面板（已登录、已收藏）里也看一遍同样高度，那里曾经横铺过一条通栏色带；
   *  3) 若整条屏幕被一条色带贯穿 → 说明 title 作用域按整行解析、材质溢出了这个 46 的圆，
   *     必须回退成有界玻璃（Material.fallbackTint('header') + backgroundEffect）；
   *     若只在圆内 → 材质正常，可以保留。
   */
  @Builder
  private favBarButton() {
    // 容器换成「沉浸材质 + 发丝边 + 阴影」（与 barCircle / 顶栏返回键同一套），三态的文字色与
    // 实心填充一个值都没动：未登录 = 次要色，已登录未收藏 = 主色字，已收藏 = 主色实心 + 白字。
    // 材质只负责「这颗按钮是浮起物」这件事，不再靠底板托着。
    Stack({ alignContent: Alignment.Center }) {
      // 材质层：kind / radius / planeHeight 与顶栏返回键、barCircle 完全同口径
      MaterialPlane({ kind: 'header', radius: 999, planeHeight: TOOL_BTN })

      Text(this.favcat >= 0 ? '已收藏' : '收藏')
        .width(TOOL_BTN)
        .height(TOOL_BTN)
        .fontSize(11)
        .fontColor(this.favcat >= 0 ? Color.White
          : (Cookies.isLoggedIn() ? Theme.accent() : Theme.subText()))
        .textAlign(TextAlign.Center)
        .borderRadius(999)
        // 只有「已收藏」才盖不透明主色（三态的实心态保持原样）；其余两种让材质露出来。
        // 这层底是「选中态」语义，不是第二层材质 —— 未登录/已登录未收藏都只改文字色，不再叠底色。
        .backgroundColor(this.favcat >= 0 ? Theme.accent() : Color.Transparent)
        .onClick(() => {
          // 面板本身只读 gallery（不读 detail），未就绪时打开也不会崩；
          // 但整排按钮已被 enabled(false)，这里同样守一下，保证行为一致。
          if (!this.toolsReady()) {
            return;
          }
          // 未登录不静默：先给一句提示，再打开面板的「登录」分支（面板里有账号密码表单）
          if (!Cookies.isLoggedIn()) {
            this.showToast('未登录：登录后才能收藏');
          }
          // 打开走 openFavSheet：它负责清错误文案、先摆起始态（面板在屏外）再挂载节点。
          // 直接写 favSheet = true 的话，节点第一帧就是「已在位」的终态，没有滑入。
          this.openFavSheet();
        })
    }
    .width(TOOL_BTN)
    .height(TOOL_BTN)
    .borderRadius(999)
    .border({ width: 0.7, color: Theme.btnEdge() })
    .shadow(Theme.floatShadow())
  }

  /**
   * 两列明细里的一个单元：上标签、下值。
   *
   * 为什么是上下结构而不是「标签 64 宽 + 值」的行内结构：一行一条时标签可以固定 64 宽左对齐，
   * 两列并排后每列只有半行宽，固定 64 会把值挤成两三个字一行，所以改成上下。
   */
  @Builder
  private infoCell(label: string, value: string) {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(10)
        .fontColor(Theme.subText())
        .maxLines(1)
      Text(value)
        .fontSize(12)
        .fontColor(Theme.text())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 上传者/语言/发布时间这些经常要复制出去，长按可选
        .copyOption(CopyOptions.LocalDevice)
        .width('100%')
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 收藏弹层：遮罩 + 贴底卡片（自绘，不使用系统半模态 bindSheet）。
   *
   * 为什么彻底放弃系统半模态 —— 「按住面板顶部上滑、下方露出详情页」的真实机制：
   *
   *  1) `dragBar: false` 只去掉抓手的**视觉**，跟手位移不是它管的。跟手是 framework
   *     绑在 **sheet 内容节点**上的 pan 手势：手指落在面板内容区（包括 52 高的头、
   *     包括 List 滚到顶之后的那一段）往上滑，整块 sheet 就被平移；sheet 贴屏幕底挂，
   *     往上挪多少 vp，屏幕下沿就空出多少 vp —— 底下详情页正是从这条缝里漏出来的。
   *  2) `detents` 不设、`preferType: SheetType.BOTTOM` 也拦不住它：单档只决定「弹到多高」，
   *     不决定「能不能被手指推动」；上滑仍会把它顶起来，然后回弹。
   *  3) `shouldDismiss` / `onWillDismiss` 只能否掉「关闭」这个**结果**，
   *     否不掉「跟手位移」这个**过程**。SDK 里专门有 `onWillSpringBackWhenDismiss`
   *     （拦截关闭后的弹回），恰好说明框架是「先跟手、被拦下再弹回」——
   *     位移那一帧已经发生了，露底也已经发生了。
   *
   * 结论：只要还用 bindSheet，就没有「任何手势都不露底」的开关。所以改成与阅读器设置面板
   * 同一套做法：Stack 覆盖层 + 遮罩 + 显式开合（`favSheet` 这个 @State 就是唯一开关）。
   *
   * 关键点：**面板自己不挂任何手势**。没有 pan 手势就没有位移，往上滑最多是面板里的
   * List 滚到头（edgeEffect 已关），不可能把面板搬离屏幕下沿 —— 这才是「不露底」的保证。
   * 关闭全部收敛到 closeFavSheet()（× / 点遮罩 / 收藏成功后 / 系统返回 / 「用 Cookie 登录」），
   * 那里统一播 220ms 的下滑 + 淡出，动画走完才摘节点 —— 不存在「某条路是硬关」。
   */
  @Builder
  private favOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 遮罩：盖满整屏。除了「点它关闭」，它同时把下层详情页的滚动与点击一起挡住，
      // 避免面板开着时手指误操作到后面的列表。
      //
      // 不透明度由 favDim 驱动（与面板下滑共用 closeFavSheet 里同一条 animateTo），
      // 所以关闭时遮罩和面板是同起同落的；不写 TransitionEffect.OPACITY ——
      // 那样遮罩会按「节点被摘掉的那一刻」自己淡出，比面板先没，中途露出一帧
      // 「空面板压在白底上」的画面（这正是本次要修的问题）。
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .opacity(this.favDim)
        .onClick(() => {
          this.closeFavSheet();
        })

      // 面板本体：贴底、不透明、圆角只在上沿。
      // 高度仍是 favSheetHeight()（内容高与屏高 60% 取小），底部**不留任何缝**：
      // 它直接铺到屏幕物理底边，手势条那一段由它自己的 Theme.card() 盖住，
      // 所以这里不能再加 padding / margin（加了就又变成一条「壳层底色横带」）。
      Column() {
        this.favSheetBuilder()
      }
      .width('100%')
      .constraintSize({ maxWidth: 560 })
      .height(this.favSheetHeight())
      .backgroundColor(Theme.card())
      .borderRadius({ topLeft: 20, topRight: 20 })
      // 圆角之外、内容滚出边界之外都不该有像素透出来
      .clip(true)
      // 入场/退场：整体沿 y 下滑「自己的高度」—— 面板贴底，位移等于高度时正好完全
      // 离开屏幕下沿。位移量必须是具体数值（vp）而不是 '100%'：百分比由节点自身高度
      // 解析，面板高度会随登录态/favcat 变化，动画途中改高度会让落点漂移；
      // 这里用 favSlide × favSheetHeight()，落点始终等于「刚好滑出去」的那一档。
      .translate({ y: this.favSlide * this.favSheetHeight() })
      // 淡出与下滑共用 favDim（入场同理是淡入）：与改造前的入场观感一致 ——
      // 面板是「滑上来」的，不是「从屏幕外硬怼进来」的
      .opacity(this.favDim)
    }
    .width('100%')
    .height('100%')
    .onAppear(() => {
      // 节点已挂载、起始态（favSlide = 1 / favDim = 0）已画过一帧，这里补入场动画。
      // 不能把这段动画写在 openFavSheet 里：同一帧里新建节点 + 改数值会被合并，
      // 节点直接以终态建成，看不到滑入（见 openFavSheet 的注释）。
      animateTo({ duration: FAV_ANIM_MS, curve: Curve.Friction }, () => {
        this.favSlide = 0;
        this.favDim = 1;
      });
    })
  }

  /**
   * 收藏面板：固定的头 + 两种形态的身体。
   *
   *  - 未登录 → 紧凑登录表单（登录成功后同一个面板自己切成目录列表，不跳页）；
   *  - 已登录 → 10 个目录（List）+ 底部固定的「取消收藏」。
   *
   * 为什么头统一抽出来：旧版未登录时没有标题、也没有关闭钮，面板只能靠下拉手势收起，
   * 第一次进来的人找不到出口。现在头永远在，面板永远有一个明确的 ×。
   *
   * 头的分隔线通栏、只画一条：它区分「这是面板标题」与「下面是内容」；若给每行目录
   * 各画一条线，10 行会读成设置表单，而这里只是一次选择。
   *
   * 面板的底色由内容根（下面这个 Column）与外壳（favOverlay 的卡片）**同源**画成
   * Theme.card()，所以从面板头到屏幕底边只有一种底色，不存在「差一档的横带」。
   */
  @Builder
  private favSheetBuilder() {
    Column() {
      this.favSheetHead()
      if (!Cookies.isLoggedIn()) {
        this.loginPanel()
      } else {
        this.favListPanel()
      }
    }
    .width('100%')
    .height('100%')
    // 面板底色在这里画一次 —— 判断依据与「为什么这样修」：
    //
    // 1) 先排除「高度比内容高，多出一段卡底」：
    //    这个 Column 是 height('100%')，两个分支的根（loginPanel / favListPanel 的根 Column）
    //    都是 layoutWeight(1)，所以 favSheetHeight() 无论给多大，多出来的高度都会被它们吃掉
    //    —— 面板内部**不可能**出现一段没人认领的空卡。
    // 2) 再排除「某个子容器画了不透明底」：登录表单那两个输入框是 40 高、圆角 12、带 0.5 描边
    //    （只在未登录态出现）；favRowBg 的行内高亮只铺在 48 高的行上；胶囊段（favListPanel 末尾）
    //    已经没有任何 backgroundColor。都不是通栏底。
    // 3) 于是曾经的「底部那条固定横带」只剩一个来源：bindSheet 自己的 backgroundColor
    //    （BindOptions 默认还是 Color.White，与行底的 Theme.card() 不是同一次取值，
    //    系统那层还会吃圆角/阴影/材质染色）。改自绘之后这条来源已经不存在了 ——
    //    外壳卡片与这里用的是同一个 Theme.card()，叠在一起也看不出接缝。
    .backgroundColor(Theme.card())
    // clip(true)：圆角之外、内容滚出边界之外都不该有像素透出来。
    .clip(true)
    // 这里**不加底部 padding**。
    //
    // 原来给面板根补了 `FAV_PAD_BOTTOM + navBarInset()`，本意是让开系统手势条；但这段留白
    // 同时把「列表视口」往上顶了一截 —— 留白本身由壳层/面板底色补上，就成了一条固定、
    // 不随滚动移动的横带。现在让列表视口直接铺到屏幕最底，让位改由「胶囊自己抬高 +
    // 列表 contentEndOffset」完成，面板根不再参与。
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 面板头：标题相对整行居中 + 右侧 36 圆关闭钮（叠在标题之上）。
   *
   * 为什么用 Stack 而不是 Row + layoutWeight(1)：Row 里标题的可分配宽度被右侧的钮
   * 先切掉 36，textAlign(Center) 只能在那条「少了 36 的槽」里居中，视觉上标题会整体
   * 偏左半格；Stack 让标题独占整行宽度（width 100% + 居中），钮作为覆盖层叠在右端，
   * 不参与标题的宽度计算，标题才是真正相对整行居中。
   *
   * 标题左右各留 44（= 36 钮 + 8 呼吸）的内边距：窄屏时标题文字不会顶到钮上，
   * 居中是布局意义上的居中，留白只是让「文字与钮不重叠」这件事有确定边界。
   *
   * 关闭钮与详情页返回键同一套参数（MaterialPlane + Theme.btnEdge() 0.6 白边 +
   * Theme.floatShadow()）：面板是浮在页面上的另一层，钮的样子和页面里的返回键一致，
   * 才会被读成「同一类动作 —— 退出这一层」。直径取 36 而不是 44：头只有 52 高，
   * 44 的钮会顶满整行、没有呼吸。
   */
  @Builder
  private favSheetHead() {
    Column() {
      Stack({ alignContent: Alignment.End }) {
        Text('收藏到目录')
          .width('100%')
          .fontSize(Tokens.FONT_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text())
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 左右各让出关闭钮的宽度，标题在「剩下那条对称的槽」里居中 —— 因为两侧
          // 让出的一样多，文字的光学中心仍然落在整行中线上
          .padding({ left: FAV_CLOSE_SIZE + 8, right: FAV_CLOSE_SIZE + 8 })
        Stack({ alignContent: Alignment.Center }) {
          // 关闭钮同样不用 MaterialPlane：面板里**任何**小块材质都会按 Navigation title 作用域
          // 的整条宽度解析，在钮所在的高度横铺出一条通栏色带（胶囊那颗已经因此换成有界玻璃，
          // 见 favListPanel 末尾的注释）。这里改成同一套有界玻璃，面板内不再有任何
          // 全宽材质层 —— 若底部仍有一条，那它一定是 sheet 自己的壳层，与内容无关。
          Stack() {
          }
          .width(FAV_CLOSE_SIZE)
          .height(FAV_CLOSE_SIZE)
          .borderRadius(999)
          .clip(true)
          .backgroundColor(Material.fallbackTint('header'))
          .backgroundEffect({ radius: 24, saturation: 1.8, brightness: Theme.isDark() ? 0.85 : 1.08 })
          Text('×')
            .width(FAV_CLOSE_SIZE)
            .height(FAV_CLOSE_SIZE)
            .fontSize(18)
            .fontColor(Theme.subText())
            .textAlign(TextAlign.Center)
            .maxLines(1)
        }
        .width(FAV_CLOSE_SIZE)
        .height(FAV_CLOSE_SIZE)
        // 圆形轮廓只靠 borderRadius：clip(true) 会把 0.6 的描边削掉半条（返回键踩过，注释见 build 里那颗）
        .borderRadius(999)
        .border({ width: 0.6, color: Theme.btnEdge() })
        .shadow(Theme.floatShadow())
        .onClick(() => {
          // 与点遮罩同一条路：统一下滑 + 淡出，favClosing 会挡掉连点
          this.closeFavSheet();
        })
      }
      .width('100%')
      .height(FAV_HEAD_H)
      .padding({ left: FAV_PAD_X, right: FAV_PAD_X })

      Divider()
        .strokeWidth(0.5)
        .color(Theme.line())
    }
    .width('100%')
  }

  /**
   * 未登录态：紧凑登录表单。
   *
   * 为什么不做「列表 + 点了提示请先登录」：那样每点一行都是一次失败反馈，用户会认为
   * 收藏坏了。现在把入口直接摆出来，登录成功后 favSheetBuilder 自动切到目录列表。
   *
   * 输入框底色是 Theme.card()（面板底也是 card，等于同色），所以必须补一条 0.5 的
   * Theme.line() 细边，否则「可输入区域」在浅色下完全看不见边界。
   */
  @Builder
  private loginPanel() {
    Column({ space: 10 }) {
      Text('登录后即可同步收藏')
        .fontSize(Tokens.FONT_TAG)
        .fontColor(Theme.subText())
        .width('100%')
      TextInput({ placeholder: '用户名 / 邮箱', text: this.loginUser })
        .height(FAV_FIELD_H)
        .width('100%')
        .fontSize(Tokens.FONT_META)
        .fontColor(Theme.text())
        .placeholderColor(Theme.subText())
        .backgroundColor(Theme.card())
        .border({ width: 0.5, color: Theme.line() })
        .borderRadius(FAV_FIELD_RADIUS)
        .padding({ left: 12, right: 12 })
        .onChange((v: string) => {
          this.loginUser = v;
        })
      TextInput({ placeholder: '密码', text: this.loginPass })
        .type(InputType.Password)
        .height(FAV_FIELD_H)
        .width('100%')
        .fontSize(Tokens.FONT_META)
        .fontColor(Theme.text())
        .placeholderColor(Theme.subText())
        .backgroundColor(Theme.card())
        .border({ width: 0.5, color: Theme.line() })
        .borderRadius(FAV_FIELD_RADIUS)
        .padding({ left: 12, right: 12 })
        .onChange((v: string) => {
          this.loginPass = v;
        })
      if (this.loginErr.length > 0) {
        // 工程里没有 error 色令牌，红字是个字面色（旧版 '#FF8A8A'），这里不再引第二处硬编码：
        // 改成主色显示 —— 文案本身（“账号或密码错误”/“需要验证码”）已经把语义说清楚了。
        Text(this.loginErr)
          .fontSize(Tokens.FONT_TAG)
          .fontColor(Theme.accent())
          .width('100%')
      }
      Row({ space: 12 }) {
        Text(this.authBusy ? '登录中…' : '登录')
          .layoutWeight(1)
          .height(FAV_FIELD_H)
          .fontSize(Tokens.FONT_BODY)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .borderRadius(FAV_FIELD_RADIUS)
          .backgroundColor(Theme.accent())
          .opacity(this.authBusy ? 0.6 : 1)
          .onClick(() => {
            this.doSheetLogin();
          })
        // 次按钮做成纯文字：Cookie 登录要跳去设置页，是「另一条路」，
        // 给它同等的块级重量会让主次不分（而且它不解决本面板里的即时登录）。
        Text('用 Cookie 登录')
          .fontSize(Tokens.FONT_TAG)
          .fontColor(Theme.accent())
          .padding({ left: 4, right: 4 })
          .onClick(() => {
            // 这条路要跳设置页（Index 会把详情页出栈），面板也得按统一动效先收起来，
            // 否则详情页一退，面板是随节点一起硬消失的
            this.closeFavSheet();
            this.onGotoLogin();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: FAV_PAD_X, right: FAV_PAD_X, top: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 已登录态：目录列表 + 底部「取消收藏」。
   *
   * 为什么从 Column + Scroll 换成 List：
   *  1) List 按行滚动，不会出现 Scroll 里「半行停在面板边缘」的观感；
   *  2) ForEach 直接产出 ListItem，选中/按下态都挂在行自己身上，不用再套一层 Column；
   *  3) 与 SearchPage 的结果列表同一套写法，滚动行为在全工程一致。
   *
   * 行之间**不画分隔线**：10 行等距，靠 48 的行高 + 选中行的勾来区分。每行一条线会让
   * 面板读起来像设置项列表（一堆并列的开关），而这里是一次「选一个」的动作。
   *
   * 「取消收藏」放在 List **外面**、钉在面板底部：它是破坏性动作，必须一眼可见、不用滚。
   * 它不再是一整行 + 分隔线，而是一颗居中的悬浮胶囊（材质 + 白边 + 阴影）：分隔线会让它
   * 继续读成「第 11 个目录」，形状上的断句才说明「这不是目录，是删除」。
   */
  @Builder
  private favListPanel() {
    Column() {
      if (this.favWarnShown()) {
        Text('缺 igneous：本次收藏会走 E-Hentai 域（同一账号，结果等价）')
          .fontSize(Tokens.FONT_TINY)
          .fontColor(Theme.subText())
          .width('100%')
          .padding({ left: FAV_PAD_X, right: FAV_PAD_X, top: 8, bottom: 4 })
      }
      // 列表铺满整块面板（视口一直到屏幕最底），胶囊作为悬浮层叠在它上面。
      Stack({ alignContent: Alignment.Bottom }) {
        List() {
          ForEach(FavCats.NAMES, (name: string, idx: number) => {
            ListItem() {
              Row() {
                Text(name)
                  .fontSize(15)
                  .fontColor(Theme.text())
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                // 勾选符号说明：全工程只引了 sys.symbol.chevron_left 一个系统符号，
                // 没有 checkmark 的现成用法（grep 过），为一个勾去改资源引用不划算 ——
                // 用文本 '✓'，字号与目录名同号、颜色走 accent()，读作「已选中」而不是「另一个按钮」。
                if (this.favcat === idx) {
                  Text('✓')
                    .fontSize(15)
                    .fontColor(Theme.accent())
                }
              }
              .width('100%')
              .height(FAV_ROW_H)
              // 行内缩 8 + List 缩进 12 = 20：文字左缘与面板头标题严格对齐
              .padding({ left: FAV_PAD_X - FAV_HL_INSET, right: FAV_PAD_X - FAV_HL_INSET })
              .borderRadius(12)
              .backgroundColor(this.favRowBg(idx))
              .alignItems(VerticalAlign.Center)
              .onTouch((e: TouchEvent) => {
                this.trackFavPress(e, idx);
              })
              .onClick(() => {
                this.setFav(idx);
              })
            }
          }, (name: string) => name)
        }
        .width('100%')
        .height('100%')
        // 左侧/右侧缩进保留，**底部不再留白**：列表视口要铺到屏幕最底。
        // top: 8 让第一行与面板头的分隔线之间有一点呼吸（列表紧贴分隔线时，第一行会被读成
        // 「分隔线的一部分」）。只在这里加，不再给 List 另设 contentStartOffset —— 两处都加会变成 16。
        .padding({ left: FAV_HL_INSET, right: FAV_HL_INSET, top: 8 })
        // 胶囊是浮在列表上的，最后几行会滚到它下面 —— 用 contentEndOffset 留出让位高度，
        // 保证第 10 个目录能滚出胶囊之外（否则最后一行永远被胶囊盖住、点不到）。
        .contentEndOffset(this.favcat >= 0
          ? FAV_CANCEL_PILL_H + FAV_CANCEL_GAP + FAV_PAD_BOTTOM + this.navBarInset()
          : FAV_PAD_BOTTOM + this.navBarInset())
        .scrollBar(BarState.Off)
        // 关掉越界回弹：Spring 会把列表内容拽出视口上沿，面板顶部一瞬间露出空白，
        // 空白处透出的就是面板之下的详情页 —— 面板里不该有"被拽动的边缘"。
        .edgeEffect(EdgeEffect.None)

        // 没收藏时整颗胶囊都不出现（连它占的 12 间距一起省掉）：点了也只会失败，徒增困惑
        if (this.favcat >= 0) {
          // 为什么做成「悬浮胶囊」而不是列表下面再加一行：
          // 之前是 48 高整行 + 上分隔线，和第 11 个目录长得一模一样，破坏性动作被读成
          // 「又一个可选目录」；改成居中的小胶囊 + 材质 + 阴影，它在层级上明显浮于列表之上，
          // 与「选目录」这件事被一次形状上的断句分开了。
          Row() {
            Stack({ alignContent: Alignment.Center }) {
              // 材质层再套一个 160×40 的裁切盒：MaterialPlane 内部的材质 Row 是 width('100%')，
              // 而它挂在 Navigation 的 title 作用域里，宽度按「作用域」解析而不是按这个 Stack
              // （见 FAV_CANCEL_W 的注释：这个作用域曾经把内部 Row 撑满整行）。
              // 一旦它按整行宽落下来，40 高的材质就会在胶囊的位置横铺出一条通栏色块 ——
              // 用户读成「按钮底下那条固定栏的纯色底还在」的就是它，不是哪个容器自己的
              // backgroundColor（取消段这里已经没有任何 backgroundColor / 上边框 / Divider）。
              // 裁切只加在材质这一层：描边与阴影留在外层 Stack（那层不能 clip，
              // 0.6 的发丝边压在圆角路径上会被削掉一半）。
              Stack() {
              }
              .width(FAV_CANCEL_W)
              .height(FAV_CANCEL_PILL_H)
              .borderRadius(999)
              .clip(true)
              // 这里**不用** MaterialPlane：它把材质塞进一个 Navigation 的 title 作用域，
              // 而该作用域按整条宽度解析（与顶栏同一套机制）。于是 40 高的材质会在胶囊位置
              // 横铺成一条通栏色带、压住列表底部 —— 这正是「面板底部那条色块会覆盖滑动区域、
              // 和标题栏一样」的来源，不是哪个容器的 backgroundColor。
              // 关键点：系统材质是独立合成层，外层 clip(true) 裁不住它，所以上一轮加裁切无效。
              // 改成「有界玻璃」：底色 + backgroundEffect 只作用于这块 Stack 自己的形状与尺寸，
              // 不可能出界；参数取 core/Material.ets 里材质降级路径的同一组值，观感一致。
              .backgroundColor(Material.fallbackTint('header'))
              .backgroundEffect({ radius: 24, saturation: 1.8, brightness: Theme.isDark() ? 0.85 : 1.08 })

              Text('取消收藏')
                .fontSize(14)
                .fontColor(Theme.subText())
                .maxLines(1)
            }
            .width(FAV_CANCEL_W)
            .height(FAV_CANCEL_PILL_H)
            .borderRadius(999)
            // 描边与阴影挂在**不被裁剪**的这一层：这层不能加 clip(true)，
            // 0.6 的发丝描边压在圆角路径上会被削掉一半（见上方工具条的同类注释）。
            .border({ width: 0.6, color: Theme.btnEdge() })
            // 阴影恢复成 Theme.floatShadow()（与返回键、工具条同一档）。
            // 曾经怀疑它是「压在列表底部的那条横带」而去掉过一版：用户确认那条横带
            // **在改成悬浮胶囊之前就存在**、且**不随列表滚动**，即面板壳层，与胶囊无关。
            .shadow(Theme.floatShadow())
            .onClick(() => {
              this.setFav(-1);
            })
          }
          .width('100%')
          // Stack 默认 Start 对齐，这里必须显式居中，否则胶囊会贴左缘
          .justifyContent(FlexAlign.Center)
          // 抬高到手势条之上：面板根不再留底部 padding，让位改由胶囊自己承担
          .margin({ bottom: FAV_PAD_BOTTOM + this.navBarInset() })
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    // layoutWeight(1) 而不是 height('100%')：父 Column 里它上面还有 52 高的面板头，
    // 写 100% 会多出 52，列表底部（含「取消收藏」）正好被推出面板外。
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 目录行底色：按下 > 选中 > 常态。
   *
   * 常态用 Theme.card()：面板底本来就是 card，视觉上等于透明 —— 这样不必引入
   * Color.Transparent 这类字面色，行也能保持「可换底色」的稳定尺寸。
   */
  private favRowBg(idx: number): string {
    if (this.favPressed === idx) {
      return Theme.line();
    }
    return this.favcat === idx ? this.accentFill() : Theme.card();
  }

  /**
   * 记录按下行，给行一个即时反馈。
   *
   * 为什么必须有：行只有 onClick 时，手指按下去到松手之间界面没有任何变化，
   * 48 高的行 + 面板动画的延迟会让人以为「没点上」，于是反复点、甚至以为面板卡死。
   * Up/Cancel 都要清空，否则松手后高亮会一直留在那一行。
   * 点击结束会关面板（setFav 第一句就是 closeFavSheet()），所以这里不必额外清。
   */
  private trackFavPress(e: TouchEvent, idx: number): void {
    if (e.type === TouchType.Down) {
      this.favPressed = idx;
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      this.favPressed = -1;
    }
  }

  /** 标签操作面板：投票 / 加入观看 */
  @Builder
  private tagSheetBuilder() {
    Column({ space: 10 }) {
      Text(this.activeTag === null ? '标签' : this.activeTag.name)
        .fontSize(15)
        .fontColor(Theme.text())
        .margin({ top: 10 })
      Text(this.cred.ok() ? '投票会直接影响这条标签的可信度' : '投票需要登录（缺少 apikey）')
        .fontSize(10)
        .fontColor(this.cred.ok() ? Theme.subText() : '#E8963C')

      Row({ space: 10 }) {
        Text('可信')
          .layoutWeight(1)
          .height(38)
          .fontSize(12)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .borderRadius(10)
          .backgroundColor('#2E7D4F')
          .onClick(() => {
            this.voteActiveTag(true);
          })
        Text('有误')
          .layoutWeight(1)
          .height(38)
          .fontSize(12)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .borderRadius(10)
          .backgroundColor('#8A3B3B')
          .onClick(() => {
            this.voteActiveTag(false);
          })
      }
      .width('100%')

      Text('加入观看列表')
        .fontSize(12)
        .fontColor(Theme.accent())
        .width('100%')
        .height(36)
        .textAlign(TextAlign.Center)
        .borderRadius(8)
        .backgroundColor(Theme.line())
        .onClick(() => {
          this.watchActiveTag();
        })

      // 这次是长按进来的，顺带说明「点按」现在是搜索，避免以为标签不能再投票
      Text('提示：点按标签直接搜索，长按才打开本面板')
        .fontSize(10)
        .fontColor(Theme.subText())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
  }

  private async voteActiveTag(up: boolean): Promise<void> {
    const tag: GalleryTag | null = this.activeTag;
    this.tagSheet = false;
    if (tag === null) {
      return;
    }
    if (!this.cred.ok()) {
      this.showToast('投票需要登录');
      return;
    }
    const ok: boolean = await voteTag(this.cred, this.gallery, tag.ns, tag.key, up);
    this.showToast(ok ? '已投票' : '投票失败（可能已经投过）');
  }

  private async watchActiveTag(): Promise<void> {
    const tag: GalleryTag | null = this.activeTag;
    this.tagSheet = false;
    if (tag === null) {
      return;
    }
    const ok: boolean = await toggleWatchTag(this.gallery, tag.ns, tag.key, true);
    this.showToast(ok ? '已加入观看列表' : '操作失败（需要登录）');
  }
}
