import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { Theme } from '../core/Theme';
import { Categories } from '../core/Consts';
import { EhApi, SearchOptions } from '../core/EhApi';
import { Gallery } from '../core/Models';
import { Prefs, SearchHistory } from '../core/Prefs';
import { Http, HttpResp } from '../core/Http';
import { HNode, Html } from '../parse/Html';
import { TagTrans } from '../core/TagTrans';
import { GalleryListView, galleryBottomInset } from '../ui/GalleryListView';
import { GalleryCard } from '../ui/GalleryCard';
import { MaterialSurface } from '../components/MaterialSurface';
import { searchByImage } from '../core/ImageSearch';
import { MaterialPlane, MATERIAL_EDGE_WIDTH } from '../components/MaterialPlane';

/** 一条搜索建议。hint 是右侧的小字说明（来源：历史 / 标签 / 结果数） */
class SuggestItem {
  text: string = '';
  hint: string = '';

  constructor(text: string, hint: string) {
    this.text = text;
    this.hint = hint;
  }
}

/**
 * 本地标签词表（降级建议用）。
 *
 * 为什么不是直接读 TagTrans：TagTrans 只暴露 translate() 这一个同步查询，
 * `map` 是私有字段也没有枚举接口，本次改动范围又不允许改 TagTrans，
 * 所以无法「从已加载的翻译库里按前缀搜」。
 *
 * 折中办法：这里放一份人工挑选的高频 EH 标签（写全 `namespace:key`，与 EH 的
 * 搜索语法一致，点一下就能直接搜），再用 TagTrans.translate() 把中文名显示在右侧。
 * 词表命中不了时，仍然会靠「搜索历史前缀匹配」兜住用户真正常用的词。
 */
const TAG_WORDS: string[] = [
  'language:chinese', 'language:japanese', 'language:english', 'language:korean',
  'language:translated', 'language:speechless',
  'female:stockings', 'female:yuri', 'female:big breasts', 'female:glasses',
  'female:schoolgirl uniform', 'female:sole female',
  'female:anal', 'female:paizuri', 'female:swimsuit', 'female:kimono',
  'female:twintails', 'female:tomgirl', 'female:mind break',
  'male:sole male', 'male:sole dickgirl', 'male:muscle',
  'other:full color', 'other:uncensored', 'other:full censorship',
  'other:multi-work series', 'other:story arc',
  'parody:touhou project', 'parody:kantai collection', 'parody:fate grand order',
  'parody:genshin impact', 'parody:idolmaster', 'parody:original'
];
/** 建议总条数上限：再多就把搜索结果挤出屏幕了 */
const SUGGEST_LIMIT: number = 8;

/**
 * 尺寸/字号/圆角常量。
 *
 * 工程内没有 core/Tokens.ets（core/ 下只有业务模块），数值取自
 * docs/V2-UI-SPEC.md §3.6 关键尺寸、§3.2 间距、§3.3 字号、§3.5 圆角。
 */
const FIELD_HEIGHT: number = 40;      // SEARCH_FIELD_HEIGHT
/**
 * 标题行高 48（原 56）。
 *
 * 为什么收得到 48：标题下原来那行「站点名 · 关键词」副标题已整行删除，56 正是
 * 「22 号标题 + 11 号副标题」两行所需的高度；只剩一个标题之后再留 56，多出来的
 * 十几个 vp 全是一段压不下去的空白，标题会显得吊在顶栏里。
 */
const BAR_ROW_HEIGHT: number = 48;
/**
 * 顶栏里的两处竖向呼吸，各 6。
 *
 * 上半处是「标题行 → 搜索行」，下半处是「搜索行 → 顶栏材质下沿」。原来是 0 和 8：
 * 标题行 56 里自带一段视觉留白，搜索行再压 8，顶栏整体读起来比首页厚一档。
 * 改成上下对称的 6 之后，胶囊上下到标题/材质下沿的距离一致，顶栏才像「一条栏」。
 */
const HEADER_GAP: number = 6;
/** 搜索行：上下各 6 的呼吸 + 字段 40 = 52（原 48 = 字段 40 + 下边距 8） */
/**
 * 搜索行**底部**的呼吸，比上面的 HEADER_GAP(6) 大。
 *
 * 上行（标题）与下行（内容）承受的视觉重量不同：上方紧接大标题，留 6 正好；
 * 下方直接接结果列表/空态，留 6 会让搜索框看起来压在列表上，取 10。
 * 这个值同时进 SEARCH_ROW_HEIGHT 与搜索行的 padding，只有一处来源。
 */
const SEARCH_GAP_BOTTOM: number = 10;
const SEARCH_ROW_HEIGHT: number = FIELD_HEIGHT + HEADER_GAP + SEARCH_GAP_BOTTOM;
const PILL_RADIUS: number = 999;      // RADIUS_ROUND
/**
 * 顶栏「清空 / 筛选」两颗按钮的**固定宽度**。
 *
 * 为什么要写死：MaterialPlane 里的 Navigation 是 width('100%')，只有父级宽度确定，
 * 它解析出来的才是「按钮宽」；宽度由文字撑开时父宽是不确定的，材质层要么把整行撑满、
 * 要么干脆不创建 —— 上一版就是因为这个退回了 backgroundBlurStyle。
 * 现在把宽度钉住，材质层才有落点，观感才是真材质（见 headerBar 的注释）。
 *
 * 筛选 76 容得下「筛选·9」；清空 60 容得下两个字。
 * 第三颗（搜索）已内嵌进搜索胶囊，不再需要固定宽（见 SEARCH_BTN_* 的注释）。
 */
const BTN_W_FILTER: number = 76;
const BTN_W_CLEAR: number = 60;
/**
 * 内嵌搜索钮的几何：高 32（胶囊 40 上下各余 4）、左右内边距 12、全圆角。
 *
 * 为什么不沿用 40：40 的按钮会顶满胶囊内壁，读起来像「两颗胶囊拼在一起」；
 * 32 与顶栏那几颗小胶囊同一档，才读成「胶囊里的一颗按钮」（与评论输入框同一套比例）。
 * 为什么要右移 4：999 圆角的胶囊在右端收得很急，按钮贴到边上会有一角落在弧线外。
 */
const SEARCH_BTN_H: number = 32;
const SEARCH_BTN_PAD: number = 12;
const SEARCH_BTN_INSET: number = 4;
/** 内嵌搜索钮「有输入 / 无输入」换色：160 与顶栏其它轻量反馈同档 */
const SEARCH_BTN_ANIM: number = 160;
const CHIP_RADIUS: number = 8;        // CHIP_RADIUS
const CHIP_HEIGHT: number = 30;       // 历史 chip 高度（可点区 ≥ 28）
const GAP_SM: number = 8;             // SPACE_SM
/**
 * 结果列表首行与材质顶栏之间的呼吸间距。
 *
 * 首页的口径是 headerHeight() + CARD_TOP_GAP（见 HomePage 的四个 GalleryListView）；
 * 搜索页原来只让到 headerHeight()，第一张卡的标题恰好贴着顶栏下沿，看起来像被压住。
 * 这里取同一个 8，两页的首行位置才是同一套版式。
 */
const CARD_TOP_GAP: number = 8;
const PAGE_PADDING: number = 16;      // SPACE_LG
const CLEAR_PILL_HEIGHT: number = 32;  // 结果态「清空」pill
/**
 * 顶栏「回到顶部」圆钮：32×32，与「清空 / 筛选」同高。
 *
 * 它与那两颗是同一排控件，高度差一档就会被读成「另一类东西」；圆角 999 让它在
 * 一排胶囊里读成一颗图标钮（里面只有箭头、没有文字），不需要再占一颗 60 的宽度。
 */
const TOP_BTN_SIZE: number = 32;
/**
 * 滚动过 480 才出现。
 *
 * 与详情页、首页同一个阈值：同一条线、同一套手感，跨页不用重新适应。
 * 480 ≈ 两张卡的高度，短结果（一屏看完）不该冒出回顶钮。
 */
const TOP_BTN_THRESHOLD: number = 480;
/**
 * 顶栏发丝线的判定容差（vp）：偏移大于它才算「内容已经顶到顶栏下沿」。
 *
 * 不能写 `> 0`：滚动到底的轻微回弹、列表首帧的亚像素位移都会让布尔在 0 附近反复翻转，
 * 每次翻转都是一次整页 build。0.5vp 等于「视觉上完全在顶部」，也把这些噪声吃掉。
 */
const HAIRLINE_EPS: number = 0.5;
/** 显隐 160 / Smooth：与顶栏搜索钮换色、清空钮显隐同档 */
/**
 * 回顶钮的进出动画时长（ms）。
 *
 * 从 160 提到 200：160 与「顶栏其它小控件」同一档，但这颗钮做的事是「从上方滑入」，
 * 位移 8，速度一样时会显得急；200 + Friction 才像「贴上来」而不是「弹出来」。
 */
const TOP_BTN_ANIM: number = 200;
/** 不可见时下沉 4（出现时抬到 0）：只做一点点位移，别抢顶栏的注意力 */
/**
 * 隐藏时向下偏移的位移（vp）。
 *
 * 4 太轻，160ms 内几乎看不出是「滑下来」还是「淡下去」；8 才读得出方向。
 * 注意方向是**从上往下沉**（隐藏时 y>0），符合「往上滑出、露出来」的直觉。
 */
const TOP_BTN_SHIFT: number = 8;
const EMPTY_ICON: number = 56;
const EMPTY_BUTTON_HEIGHT: number = 46; // BUTTON_HEIGHT
const EMPTY_BUTTON_RADIUS: number = 12;
const FONT_TITLE: number = 22;        // FONT_SIZE_H2（大标题层级）
// 原来的 FONT_SUBTITLE(11) 随标题下的副标题一起删掉：本页再没有第二行小字，留着就是死常量。
const FONT_META: number = 13;         // FONT_SIZE_META
const FONT_CAPTION: number = 12;      // FONT_SIZE_CAPTION
const FONT_TAG: number = 11;          // FONT_SIZE_TAG
const LOADING_SIZE: number = 32;      // LOADING_SIZE
/*
 * 底部让位不再写死 80：统一取 galleryBottomInset()（底栏 56 + 离底 4 + 导航条 + 10）。
 * 80 在三段式导航的机器上比真实遮挡高度短 10 来 vp，最后一张卡正好被底栏压住 —— 这就是
 * 原来「搜索页滑不到底」的原因。卡片列表还要用 contentEndOffset（见下面的 GalleryListView），
 * 只有 Scroll（历史）这种不支持 offset 的容器才继续用 padding。
 */

// ------------------------------------------------------------ 筛选面板（对齐原版）
/** 面板卡片的圆角/行高与设置页保持一致 */
const CARD_RADIUS: number = 16;
const ROW_H: number = 56;
const CAT_H: number = 40;             // 分类色块高度
const CAT_RADIUS: number = 8;
const SHEET_BTN_H: number = 44;       // 底部「重置 / 应用」按钮（高度，圆角走 PILL_RADIUS）
/**
 * 底部悬浮按钮行的几何：左右各 16、离底 16（另加导航条高度）、两颗之间 12。
 *
 * 为什么离底还要单独留 16：这一行是浮在内容上的，脚下没有实底托着，
 * 贴到面板边缘会和 dragBar / 手势条糊在一起；16 是面板内容边距同一档。
 */
const SHEET_FLOAT_PAD: number = 16;
const SHEET_FLOAT_GAP: number = 12;
/**
 * 悬浮行占掉的竖向空间：滚动内容末尾要额外让出这么多。
 *
 * 面板里是 Scroll 而不是 List，**没有 contentEndOffset**（那个只属于列表类容器），
 * 所以让位只能写成内容的 padding-bottom；数值必须 ≥ 按钮高 44 + 离底 16，
 * 再留 8 的呼吸，最后一张卡才不会有一截藏在按钮后面。
 */
const SHEET_FLOAT_RESERVE: number = SHEET_BTN_H + SHEET_FLOAT_PAD + 8;
/**
 * 面板右上角关闭圆钮的直径（36）。
 *
 * 取 36 而不是 40：它与 MaterialPlane 在顶栏里那些小块（分类胶囊、清空按钮）同一档高度，
 * 圆钮嵌在 48 高的标题行里上下各余 6，不会被读成比标题还重的一块。
 */
const CLOSE_BTN_H: number = 44;
/** 分类显示顺序、中文标签、配色与 f_cats 位（位序来自 EH：Misc=1 … Western=512） */
/**
 * 分类的 EH 名称与 f_cats 位，顺序严格按位序（Misc=1 … Western=512）。
 * 中文标签与配色不在这里重复定义，统一取 Consts.Categories（与列表卡片同一套色板）。
 */
const CAT_NAMES: string[] = [
  'Misc', 'Doujinshi', 'Manga', 'Artist CG', 'Game CG',
  'Image Set', 'Cosplay', 'Asian Porn', 'Non-H', 'Western'
];
const CAT_BITS: number[] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512];
/** 面板分节标题：下标供 @Builder 取值（builder 不收会变的值参数） */
const SECTION_CATS: number = 0;
const SECTION_LANG: number = 1;
const SECTION_ADV: number = 2;
/** 「更多操作」= 以图搜图 + 跳页：它们随内容滚，所以也算一节 */
const SECTION_MORE: number = 3;
const SECTION_LABELS: string[] = ['分类', '语言', '高级选项', '更多操作'];
/** 高级卡片内的小标题：下标供 @Builder 取值 */
const SUB_SCOPE: number = 0;
const SUB_RATING: number = 1;
const SUB_LABELS: string[] = ['搜索范围（至少一项）', '最低评分'];
/** 搜索范围三行：名称 / 标签 / 简介（f_sname / f_stags / f_sdesc） */
const SCOPE_NAMES: string[] = ['搜索名称', '搜索标签', '搜索简介'];
const SCOPE_PARAMS: string[] = ['f_sname', 'f_stags', 'f_sdesc'];
/** 五个高级开关：下标即意义（f_sto / f_sh / f_sfl / f_sfu / f_sft） */
const SW_TORRENT: number = 0;
const SW_EXPUNGED: number = 1;
const SW_NOLANG: number = 2;
const SW_NOUP: number = 3;
const SW_NOTAG: number = 4;
const SW_NAMES: string[] = ['仅有种子', '仅已删除', '忽略语言过滤', '忽略上传者过滤', '忽略标签过滤'];
const SW_PARAMS: string[] = ['f_sto', 'f_sh', 'f_sfl', 'f_sfu', 'f_sft'];
/**
 * 语言 pill：值与 SearchOptions.LANGS 一一对应（第 0 项是「全部」= 空串）。
 *
 * 单选是对的 —— JHenTai 原版的搜索面板里「语言」就是一个单选下拉
 * （`_buildLanguageSelector`，lib/src/widget/eh_search_config_dialog.dart:526-546），
 * 取值来自 LocaleConsts.language2Abbreviation。我们只是把下拉换成 pill，
 * 语义（一次只能选一种语言，再点另一个就换成那个）和原版一致。
 * 多语言请直接在关键词里写第二个 `language:"xxx"`。
 */
const LANG_VALUES: string[] = ['', 'chinese', 'english', 'japanese', 'korean', 'translated'];
const LANG_LABELS: string[] = ['全部', '中文', 'English', '日本語', '한국어', '翻译'];
/**
 * 语言 chip 的几何：高 28（可点区 ≥ 28）、左右内边距 12、彼此间距 8。
 *
 * 间距从 4 提到 8：改成单行之后 chip 之间没有行距可以「顺带」把两排分开，
 * 六颗并排贴得太近会读成一整条被切开的色带，8 才看得出是六个独立选项。
 *
 * 为什么不再用「固定宽 72 的独立材质胶囊」：那颗宽度是为了让 MaterialPlane 有确定父宽
 * 才被迫钉死的（材质按父宽创建），六颗同宽的实心玻璃并排像一排按钮而不是一组选项；
 * 现在材质统一收到**外层那一颗胶囊**上（见 langCard），chip 回到文字撑开的自然宽，
 * 也就不需要 72 这个「按最长标签估出来的」尺寸了。
 */
const LANG_CHIP_H: number = 28;
const LANG_CHIP_PAD: number = 12;
const LANG_CHIP_GAP: number = 8;
/**
 * 横滑行的左右留白（12），照收藏页分类条的同一档。
 *
 * 选中那颗 chip 后面的 accent() 滑动色块如果从 0 开始，就会压到 999 圆角的弧线上、
 * 看着像被切掉一角；缩进 12 之后色块整块都落在直边段里，圆角圈住的只有材质本身。
 */
const LANG_GROUP_PAD: number = 12;
/**
 * 语言胶囊的整体高度，写死而不是让内容撑开。
 *
 * 为什么必须是个定值：MaterialPlane 是一个 Navigation title 作用域，只有 **planeHeight
 * 这个确定高度**才能建起材质，靠子节点撑开是不成立的。
 * 为什么是 36（= 4 + 28 + 4）：与收藏页的分类条一模一样高，两页里「一条横向选项条」
 * 才是同一种控件；chip 28 在行内垂直居中，上下各余 4 就是自然留白。
 *
 * 为什么改成「单行 + 横向滑动」而不再换行：六颗标签在卡内可用宽度（约 300vp）里必然
 * 排成两行，胶囊高度就被迫撑到 72 —— 比收藏条高一倍，同一个 App 里出现两种高度的选项条。
 * 保留一行、放不下的交给横向 Scroll，高度与收藏条对齐，也省下一行的竖向空间。
 */
const LANG_GROUP_H: number = 36;
/**
 * 滑动色块在轨道里的纵向偏移：(36 - 28) / 2 = 4。
 *
 * 与 chip 在行内的居中量同一个来源 —— 两边都写成公式而不是各写一个 4，
 * 以后改 chip 高度或轨道高度时，色块仍然落在 chip 正后方，不会偏出半个像素。
 */
const LANG_PILL_Y: number = (LANG_GROUP_H - LANG_CHIP_H) / 2;
/**
 * 语言色块横滑时长（160 / Smooth）：与首页 FloatingTabs 的**点按**滑动块同档。
 *
 * 两页里「一个块滑到新选项」的同一种动效必须同参数，否则来回切页会觉得一边更快。
 * 这里只有点按一种来源（语言是单选 chip，没有横滑切页），所以只留这一个时长；
 * 原来跟的是 260，比现在两处的点击反馈都慢半拍，用户的感觉就是「点了不跟手」。
 */
const LANG_PILL_ANIM: number = 160;
/** 最低星级候选：0 = 不限，其余对应 f_srdd */
const RATINGS: number[] = [0, 2, 3, 4, 5];
/** 过滤设置与「关键词 → 条件」快照的本地存储键 */
const KEY_FILTER: string = 'search_filter';
const KEY_HIST_FILTER: string = 'search_history_filters';

/**
 * 搜索页。
 *
 * 关键词支持 EH 的全部高级语法（`artist:xxx`、`female:yuri$`、`-language:chinese` 等），
 * 这里只做 URL 编码，不做任何改写 —— 站点自己解析。
 */
@Component
export struct SearchPage {
  onOpen: (g: Gallery) => void = (g: Gallery): void => {};
  /**
   * 外部（详情页点标签 → Index）灌进来的关键词。
   *
   * 只在「搜索页第一次被创建」时可靠（TabContent 是懒创建，详情页点标签那一刻
   * SearchPage 可能还不存在，此时 @Prop 的初值就是正确的词）；页面已存在时的**再次**注入
   * 走下面的 injectSeq（见 onInjectTick 的注释，V1 子组件 + V2 父组件的 @Prop 同步不可靠）。
   */
  @Prop initialKeyword: string = '';
  /**
   * 注入信号（单调递增的序号）：Index 每灌一次词就 +1 写进 AppStorage。
   *
   * 为什么不用 @Prop 传关键词 + @Watch：本工程 Index 是 @ComponentV2、本页是 @Component，
   * 跨版本从 @Local 同步到 @Prop 的行为不可靠（官方也不推荐），踩过一次「值变了但没重查」。
   * AppStorage 是本页已在其用的通道（@StorageProp('listStyle')），V1 里 @Watch 触发确定。
   * 关键词本身另存一个键，序号只当「敲一下门」。
   */
  @StorageProp('searchInjectSeq') @Watch('onInjectTick') private injectSeq: number = 0;
  /** 上次因注入而提交的词：@Prop 与 injectSeq 万一都触发，靠它去重（同词不重查） */
  private injectedKw: string = '';

  @State private keyword: string = '';
  /** 已提交的关键词（输入框里的字可能还没提交，跳页要用提交过的这个词） */
  @State private activeKw: string = '';
  /**
   * 结果列表地址。挂 @Watch 只为一件事：**换了地址就把回顶钮的滚动量归零**。
   *
   * 换一次搜索 / 跳一次页，结果列表会从第 1 页重建、回到顶部；若不归零，
   * 上一批结果的滚动量会留着，新结果一出来就顶着一颗「明明在顶部却亮着」的回顶钮。
   * 三态里只有结果态接滚动的通道，初始态 / 图搜态不回报，listScrollY 天然是 0。
   */
  @State @Watch('onSearchUrlChanged') private url: string = '';
  /**
   * 当前这一屏的起始页码（0 基，界面显示 pageIndex + 1）。
   *
   * 无限滚动之后它不再随滑动变化 —— 往下滑加载的页由列表内部按「step」递增，
   * 这里只表示 requestUrl 本身是第几页，作为跳页与后续分段的基址。
   */
  @State private pageIndex: number = 0;
  @State private history: string[] = [];
  @State private suggestions: SuggestItem[] = [];
  @State private showSuggest: boolean = false;
  /** 输入框是否持有焦点：联想只在「正在输入」时出现 */
  @State private focused: boolean = false;
  /** 当前关键词是否已提交：提交后联想收起，重新改字才再展开 */
  @State private submitted: boolean = false;
  /** 以图搜图的结果（为空时不占位置） */
  @State private imgResults: Gallery[] = [];
  @State private imgSearching: boolean = false;
  @State private imgError: string = '';
  /** 图搜结果卡片与列表样式保持一致 */
  @StorageProp('listStyle') private listStyle: string = 'compact';
  /**
   * 主题订阅位。
   *
   * Theme.accent()/subText() 读的是不可观测的 Prefs，只写 Theme.xxx() 的节点在切主题时
   * 不会被标记重绘；订阅 Theme.refresh() 写入的 'themeDark' 后，filterFg() 这条分支
   * 才能把顶栏按钮的字色带进重绘（左右分支同值，只为建立依赖）。
   */
  @StorageProp('themeDark') private themeDark: boolean = false;

  // ---------------------------------------------------------------- 筛选条件
  /*
   * 为什么每个过滤项都是独立的 @State 而不是一个 SearchOptions 对象：
   *  ArkTS 的 @State 只观察「对象被整体替换」，改字段不触发重绘；而这些值要在
   *  @Builder 体内被读取才挂得上依赖。拆成基本类型最稳，代价是行数多一点。
   *  提交时才用 opts() 组装成 SearchOptions 交给 EhApi.searchUrl。
   */
  /** 分类「包含」位掩码：0 或 1023 = 全部（不带 f_cats） */
  @State private catsMask: number = 0;
  /** 高级选项总开关（advsearch=1 的闸门） */
  @State private advOn: boolean = false;
  @State private minRating: number = 0;
  @State private pagesFromText: string = '';
  @State private pagesToText: string = '';
  @State private onlyTorrent: boolean = false;
  @State private onlyExpunged: boolean = false;
  @State private noLang: boolean = false;
  @State private noUploader: boolean = false;
  @State private noTag: boolean = false;
  @State private scopeName: boolean = true;
  @State private scopeTags: boolean = true;
  @State private scopeDesc: boolean = false;
  /** seek 日期（yyyy-MM-dd，空 = 不带） */
  @State private seekText: string = '';
  /**
   * 语言筛选（SearchOptions.LANGS 里的值，空 = 不限）；拼进关键词而非 URL 参数
   *
   * 为什么带 @Watch：滑动块的位移必须由「值变了」的那一刻驱动，并包在 animateTo 里，
   * 否则 ArkUI 只会把新坐标直接摆上去（没有滑动过程）—— 与 FloatingTabs 同一个理由。
   */
  @State @Watch('onLangChanged') private lang: string = '';
  /**
   * 六颗 chip 的实测宽度与据此推出的左边位置（单位 vp）。
   *
   * 为什么必须实测宽度：这里不像首页 tab 那样等宽 —— chip 宽由文字撑开（「全部」两字 vs
   * 「English」七个字母），既推不出单宽，也推不出起始 x。色块要严丝合缝压在选中那颗下面，
   * 只能量。
   * 为什么 x 是「推」而不是「量」的：见 recordLangW。
   */
  @State private langW: number[] = [0, 0, 0, 0, 0, 0];
  @State private langX: number[] = [0, 0, 0, 0, 0, 0];
  /**
   * 滑动色块的当前宽 / x（vp，相对 Scroll 内容层左上角）。
   *
   * 单独存状态而不是在 build 里现算：只有「写状态被 animateTo 包住」时位置才会插值；
   * 直接写表达式的话属性变化是瞬时的，看不到块滑过去。
   */
  @State private langPillX: number = 0;
  @State private langPillW: number = 0;

  /** 筛选面板是否展开 */
  @State private filterOpen: boolean = false;
  /** 筛选面板里的「跳转到第 N 页」输入（1 基，界面口径） */
  @State private jumpText: string = '';
  /**
   * 跳页输入的即时提示（空 = 没错误）。
   *
   * 为什么不用页级 toast：这个按钮在 bindSheet 里，面板是一层盖住整页的浮层，
   * 页面底部的胶囊 toast 会被面板挡住，用户什么都看不到。写在输入行下面才确实可见；
   * 输入一改就清掉，不给用户留一条过期的红字。
   */
  @State private jumpHint: string = '';
  /**
   * 强制重载序号：值变化即让结果列表重查当前 URL。
   *
   * 为什么单开一个信号：跳页跳到「当前这一页」时 URL 与原来完全相同，@Prop 的 @Watch
   * 只在值变化时触发，光改 url 收不到通知 —— 而「滑了十几页后回第 1 页」正是最常见的跳页。
   */
  @State private reloadSeq: number = 0;
  /**
   * 结果列表的滚动位置（vp，「离顶部多远」），只给顶栏那颗回顶钮判定显隐。
   *
   * 三态里只有「有结果」那一态接滚动通道：初始态 / 图搜态的容器不是 GalleryListView，
   * 不回报也就保持 0，回顶钮自然不会出现 —— 不需要在每处再写一遍「这态不显示」。
   */
  @State private listScrollY: number = 0;
  /**
   * 顶栏发丝线是否显示：结果列表的内容已经顶到顶栏下沿。
   *
   * 与 listScrollY 分开存（阈值不同：那边 480 才更新、会把 0.5 这一档直接丢掉），
   * 与 @State 而不是普通成员：只有 @State 的写入会触发顶栏重绘。
   */
  @State private hairOn: boolean = false;
  /** 标签库版本号：加载完成后自增，用来触发标签区重绘（TagTrans 的 Map 不是可观察状态） */
  @State private tagTransTick: number = 0;
  /**
   * 回顶信号：点一次 +1，结果列表（GalleryListView.scrollToTopTick）监听到变化就归零。
   *
   * 为什么是自增计数而不是一个布尔量：@Prop 的 @Watch 只在**值变化**时触发，
   * 布尔量连点两次第二次值没变、收不到通知；计数每次 +1 都必然是一次变化
   * （父组件也拿不到子组件实例，没有「直接调方法」这条路）。
   */
  @State private topTick: number = 0;

  /** 防抖定时器句柄（-1 表示没有待执行的） */
  private suggestTimer: number = -1;
  /** 最近一次长按删除的时间戳：长按后系统可能还会补一个 click，用它把那次 click 吃掉 */
  private lastLongPressAt: number = 0;

  aboutToAppear(): void {
    // 标签库懒加载：本页的「已选标签/候选标签」都要中文名，首帧加载完必须重绘一次
    TagTrans.ensureLoaded().then((ok: boolean) => {
      if (ok) {
        this.tagTransTick = this.tagTransTick + 1;
      }
    });
    this.history = SearchHistory.list();
    // 对齐原版：过滤条件本地持久化（NextE SearchFilterSettings.restore），重进搜索页沿用上次设置
    this.loadFilter();
    // 先恢复筛选再提交：注入的词要带上当前语言/分类等条件重新查
    if (this.initialKeyword.trim().length > 0) {
      this.injectKeyword(this.initialKeyword);
    }
  }

  /**
   * 把外部灌进来的词直接当一次提交（详情页点标签 → Index → 这里）。
   *
   * 为什么不去走「只改输入框」：改动输入框只会展开联想，用户还得再点一次搜索；
   * 从标签跳过来的意图很明确，直接 submit 才是「点一下就看到结果」。
   */
  private injectKeyword(q: string): void {
    const k: string = q.trim();
    if (k.length === 0) {
      return;
    }
    // 上一次注入的就是这个词、结果也还在 → 不重复发请求
    // （@Prop 与 injectSeq 两条通道可能各触发一次，靠它收口）
    if (k === this.injectedKw && this.url.length > 0) {
      return;
    }
    this.injectedKw = k;
    this.submit(k);
  }

  /** AppStorage 序号变化 = Index 灌了一个新词进来 */
  private onInjectTick(): void {
    const q: string | undefined = AppStorage.get<string>('searchInjectKeyword');
    if (q === undefined || q.length === 0) {
      return;
    }
    this.injectKeyword(q);
  }

  aboutToDisappear(): void {
    if (this.suggestTimer >= 0) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = -1;
    }
  }

  private statusBar(): number {
    const v: number | undefined = AppStorage.get<number>('statusBarHeight');
    return v === undefined ? 0 : v;
  }

  /**
   * 导航条（手势条）高度。
   *
   * 只给筛选面板底部那颗悬浮按钮用：沉浸式下面板一直铺到窗口底边，
   * 按钮要压在导航条之上，否则「应用」会被手势条压住一半。
   * 数据源是 EntryAbility.publishInsets 写进 AppStorage 的 navBarHeight（与
   * galleryBottomInset 同一口径），这里只读不写，页面因此不依赖窗口对象。
   */
  private navBarInset(): number {
    const v: number | undefined = AppStorage.get<number>('navBarHeight');
    return v === undefined ? 0 : v;
  }

  /**
   * 固定头部实际高度（含状态栏）：标题行 48 + 搜索行 52 = 100（原 56 + 48 = 104）。
   *
   * 材质顶栏是压在内容上的一层，所以滚动区的顶部让位量必须严格等于这个值：
   * 小一点内容会被顶栏遮住，大一点顶栏下面会空出一条。
   * 本页所有顶部让位都从这个方法取（列表 / 空态 / 图搜态 / 联想浮层 / 材质高度），
   * 所以标题行、搜索行改数值时只改这里的两个常量，不要在调用点各写一份。
   */
  private headerHeight(): number {
    return this.statusBar() + BAR_ROW_HEIGHT + SEARCH_ROW_HEIGHT;
  }

  /**
   * 列表顶部让位 = 顶栏高度 + 首行呼吸。
   *
   * 只给「卡片列表」用（结果列表 / 以图搜图结果）。为什么不能只让到 headerHeight()：
   * 卡片本身没有上外边距，让位正好等于顶栏时第一行是贴着顶栏下沿出现的，
   * 与首页（headerHeight() + 8）差一档，切换 tab 时能明显看出错位。
   */
  private listTopInset(): number {
    return this.headerHeight() + CARD_TOP_GAP;
  }

  /*
   * 原来的 subtitle()（站点名 · 当前关键词）删掉了，连带那句话的 PREFS 读取、空态兜底文案一起撤掉。
   * 为什么：它是顶栏里唯一一处「解释性文字」，而站点名由设置页决定、关键词就在输入框里，
   * 读者一个都不缺；留着只会把标题行撑到两行高（见 BAR_ROW_HEIGHT）。
   */

  /** 是否已进入「有搜索结果」的状态 */
  private inResult(): boolean {
    return this.url.length > 0 || this.submitted;
  }

  /**
   * 换了结果地址（新搜索 / 清空 / 跳页）：把回顶钮的滚动量归零。
   *
   * 逐字清空的理由见 url 上的 @Watch：新一批结果是从第 1 页重建的、列表已经在顶部，
   * 留着旧滚动量就会让按钮「在顶部亮着」。这里只动一个 UI 状态，不碰任何请求/分页逻辑。
   */
  private onSearchUrlChanged(): void {
    this.listScrollY = 0;
    // 新一批结果重新从顶部开始：顶栏发丝线也要跟着收掉，不能停在上一次搜索的状态
    this.hairOn = false;
    // 新结果列表的首帧会先报 0、随后才报真实偏移；同一帧里按钮被判灭再判亮，
    // 200ms 的位移动画会被打断成「闪一下」。这里抑制一小段时间，等布局稳定再出现。
    this.suppressBtn();
  }

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

  /** 结果列表是否已滑过阈值（决定回顶钮显隐） */
  private topBtnShown(): boolean {
    if (this.btnSuppressed) {
      return false;
    }
    return this.listScrollY > TOP_BTN_THRESHOLD;
  }

  /**
   * 结果列表回报滚动位置。
   *
   * **只在「是否过阈值」翻转时才写状态**：onDidScroll 是每帧回调，逐帧写 @State 会让
   * 整页 build()（顶栏材质 + 结果列表外壳）跟着 60fps 重建；而按钮只关心「过没过 480」，
   * 越线之外的连续距离没有任何消费者，直接丢掉。
   */
  private setListScrollY(y: number): void {
    // 发丝线的判定与回顶钮无关（0.5 vs 480），必须在这句早退**之前**做完，
    // 否则 0→300 这种「没越过 480」的滚动会把线下掉的判定整段吞掉。
    const hair: boolean = y > HAIRLINE_EPS;
    if (hair !== this.hairOn) {
      this.hairOn = hair;
    }
    const now: boolean = y > TOP_BTN_THRESHOLD;
    const was: boolean = this.listScrollY > TOP_BTN_THRESHOLD;
    if (now === was) {
      return;
    }
    this.listScrollY = y;
  }

  /** 点回顶：只发一个自增信号，滚动由列表自己执行（父组件拿不到它的 Scroller） */
  private backToTop(): void {
    this.topTick = this.topTick + 1;
  }

  /**
   * 提交一次搜索。
   *
   * 对齐原版：关键词 + 过滤条件一起进 URL（NextE SearchViewModel.search → buildQuery），
   * 同时把「关键词 → 条件」快照存进历史，点历史条目能还原当时用的筛选。
   */
  private submit(kw: string): void {
    const k: string = kw.trim();
    if (k.length === 0) {
      return;
    }
    // 先写 activeKw 再写 keyword：万一给输入框回填文字触发了 onChange，
    // 那时 activeKw 已是新词，onKeywordChange 不会把 submitted 又改回 false
    this.activeKw = k;
    this.keyword = k;
    this.pageIndex = 0;
    this.submitted = true;
    this.showSuggest = false;
    this.suggestions = [];
    const o: SearchOptions = this.opts();
    SearchHistory.push(k);
    this.history = SearchHistory.list();
    this.saveHistFilter(k, o);
    Prefs.put(KEY_FILTER, o.toJson());
    // 每次都用新对象赋给 url，即使同一个词再搜一次也会触发重载
    this.url = EhApi.searchUrl(k, o, 0);
  }

  /**
   * 清空搜索结果，回到初始态（搜索历史重新可见）。
   *
   * 不删除历史、不改网络逻辑，只是把关键词/结果/联想/提交标记一起复位。
   */
  private clearSearch(): void {
    if (this.suggestTimer >= 0) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = -1;
    }
    // 内嵌搜索钮要回到「无输入」的 40% 主色，用与打字时同一档 160ms，别让它瞬跳
    animateTo({ duration: SEARCH_BTN_ANIM, curve: Curve.Smooth }, () => {
      this.keyword = '';
    });
    this.activeKw = '';
    this.url = '';
    this.pageIndex = 0;
    this.suggestions = [];
    this.showSuggest = false;
    this.submitted = false;
    this.history = SearchHistory.list();
  }

  // ------------------------------------------------------------ 跳页
  /**
   * 跳到指定页（0 基）；越界就地夹住，不做无意义的重请求。
   *
   * 无限滚动之后页面上不再有页码条，「跳页」入口搬到筛选面板的「高级选项」之后
   * （见 actionCard）：结果区只剩一条连续的列表，任何贴在底部的条都会打断「一直往下滑」的手感。
   */
  private goPageAt(index: number): void {
    if (this.activeKw.length === 0) {
      return;
    }
    const next: number = index < 0 ? 0 : index;
    const target: string = EhApi.searchUrl(this.activeKw, this.opts(), next);
    this.pageIndex = next;
    if (target === this.url) {
      // 地址一模一样：靠信号强制重查，否则「回到第 1 页」在滑了很多页之后会毫无反应
      this.reloadSeq = this.reloadSeq + 1;
      return;
    }
    this.url = target;
  }

  /**
   * 严格解析页码：只认纯数字（"3.5" / "3a" / 空 / 0 一律算非法，返回 0）。
   * 用 parseInt 会宽容地吃掉小数和尾巴，用户看不出自己输错了，所以逐字符校验。
   */
  private pageNum(text: string): number {
    const s: string = text.trim();
    if (s.length === 0) {
      return 0;
    }
    for (let i = 0; i < s.length; i++) {
      const c: string = s.charAt(i);
      if (c < '0' || c > '9') {
        return 0;
      }
    }
    const n: number = parseInt(s, 10);
    return n >= 1 ? n : 0;
  }

  /** 筛选面板里的「跳转」：合法就按该页重查（替换结果），不合法在面板内提示并留在面板里 */
  private jumpToPage(): void {
    const n: number = this.pageNum(this.jumpText);
    if (n === 0) {
      this.jumpHint = '请输入大于 0 的整数页码';
      return;
    }
    if (this.activeKw.length === 0) {
      this.jumpHint = '先搜索一个关键词才能跳页';
      return;
    }
    this.jumpHint = '';
    // 关面板再跳：面板盖着结果，跳完用户要立刻看到新的一页
    this.filterOpen = false;
    this.goPageAt(n - 1);
  }

  /**
   * 无限滚动的第 N 段地址：step 是「从当前这一页往后数第几页」（1 基）。
   *
   * **这条通道现在只是兜底**，正常情况下不会被调用：EH 的搜索结果翻页是游标式的，
   * 列表会优先跟随上一页 HTML 里的 `#unext`（GalleryListView.nextPageUrl 里 next 优先），
   * 因为站点给的链接可能带着我们拼不出来的偏移/游标参数。只有站点没给 next（解析失败、
   * 被限流页替换）时，才退回到这里的 `&page=N`。
   *
   * 别把它改回主路径：原来列表优先用它，站点对搜索结果的 page 偏移不认（每页回同一批），
   * 去重后一条不新增，列表就把「重复」当成「到底」——「搜大标签只出十几条」就是这么来的。
   *
   * 基址用 pageIndex 而不是 0：跳页到第 5 页后，requestUrl 已经是第 5 页，
   * 兜底段也应该是第 6 页，不能退回第 2 页。
   * 没有关键词时（例如外部直接灌进来的固定地址），返回空串
   * 让列表完全依赖 EH 给的 next 链接 —— 那类入口本来就没有「第 N 页」的语义。
   */
  private pageUrlFor(step: number): string {
    if (this.activeKw.length === 0) {
      return '';
    }
    return EhApi.searchUrl(this.activeKw, this.opts(), this.pageIndex + step);
  }

  // ------------------------------------------------------------ 筛选条件
  /** 把散落的 @State 组装成 URL 契约对象 */
  private opts(): SearchOptions {
    const o: SearchOptions = new SearchOptions();
    o.cats = this.catsMask;
    o.adv = this.advOn;
    o.minRating = this.minRating;
    o.pagesFrom = this.numOf(this.pagesFromText);
    o.pagesTo = this.numOf(this.pagesToText);
    o.torrent = this.onlyTorrent;
    o.expunged = this.onlyExpunged;
    o.noLang = this.noLang;
    o.noUploader = this.noUploader;
    o.noTag = this.noTag;
    o.scopeName = this.scopeName;
    o.scopeTags = this.scopeTags;
    o.scopeDesc = this.scopeDesc;
    o.seek = this.seekText.trim();
    o.lang = SearchOptions.validLang(this.lang);
    return o;
  }

  private numOf(text: string): number {
    const n: number = parseInt(text.trim(), 10);
    return isNaN(n) || n < 0 ? 0 : n;
  }

  /** 把一份条件灌进各个 @State（历史还原 / 本地恢复共用） */
  private applyOpts(o: SearchOptions): void {
    this.catsMask = o.cats;
    this.advOn = o.adv;
    this.minRating = o.minRating;
    this.pagesFromText = o.pagesFrom > 0 ? o.pagesFrom.toString() : '';
    this.pagesToText = o.pagesTo > 0 ? o.pagesTo.toString() : '';
    this.onlyTorrent = o.torrent;
    this.onlyExpunged = o.expunged;
    this.noLang = o.noLang;
    this.noUploader = o.noUploader;
    this.noTag = o.noTag;
    this.scopeName = o.scopeName;
    this.scopeTags = o.scopeTags;
    this.scopeDesc = o.scopeDesc;
    this.seekText = o.seek;
    this.lang = o.lang;
  }

  /** 对齐原版：本地持久化过滤条件（NextE SearchFilterSettings.persist） */
  private loadFilter(): void {
    this.applyOpts(SearchOptions.parse(Prefs.str(KEY_FILTER, '')));
  }

  /** 任一项改动都立刻落盘，面板被拖动关闭时也不会丢设置 */
  private touchFilter(): void {
    Prefs.put(KEY_FILTER, this.opts().toJson());
  }

  /**
   * 生效中的条件条数，用于页头「筛选·N」角标。
   * 口径与 URL 拼装一致：没真正影响 URL 的项不计数。
   */
  private filterCount(): number {
    let n: number = 0;
    const exclude: number = SearchOptions.excludeCats(this.catsMask);
    if (exclude > 0) {
      n++;
    }
    // 语言虽然不进 f_*，但真的改了关键词（拼了 language:"值"），算一条生效条件
    if (SearchOptions.validLang(this.lang).length > 0) {
      n++;
    }
    if (this.advOn) {
      if (!(this.scopeName && this.scopeTags && !this.scopeDesc)) {
        n++;
      }
      if (this.minRating >= 2) {
        n++;
      }
      if (this.numOf(this.pagesFromText) > 0 || this.numOf(this.pagesToText) > 0) {
        n++;
      }
      if (this.onlyTorrent) {
        n++;
      }
      if (this.onlyExpunged) {
        n++;
      }
      if (this.noLang) {
        n++;
      }
      if (this.noUploader) {
        n++;
      }
      if (this.noTag) {
        n++;
      }
      if (SearchOptions.validDate(this.seekText).length > 0) {
        n++;
      }
    }
    return n;
  }

  /** 重置：条件全部归零（关键词与结果保持不动，等「应用」再重查） */
  private resetFilter(): void {
    this.applyOpts(new SearchOptions());
    Prefs.put(KEY_FILTER, new SearchOptions().toJson());
  }

  /** 关闭面板；apply=true 时回到结果态并重新请求第 1 页 */
  private closeFilter(apply: boolean): void {
    this.filterOpen = false;
    if (!apply) {
      return;
    }
    Prefs.put(KEY_FILTER, this.opts().toJson());
    this.reRun();
  }

  /** 用当前条件重跑第 1 页；没有关键词时只记住设置，不发请求 */
  private reRun(): void {
    if (this.activeKw.length === 0) {
      return;
    }
    this.pageIndex = 0;
    this.url = EhApi.searchUrl(this.activeKw, this.opts(), 0);
  }

  // -------------------------------------------------- 分类色块（f_cats）
  private visCats(): number {
    return this.catsMask === 0 ? SearchOptions.ALL_CATS : this.catsMask;
  }

  private catSelected(idx: number): boolean {
    return (this.visCats() & CAT_BITS[idx]) !== 0;
  }

  /** 点一下切换该分类；全选状态下点掉一个就变成「除它之外全要」 */
  private toggleCat(idx: number): void {
    const next: number = this.visCats() ^ CAT_BITS[idx];
    this.catsMask = next >= SearchOptions.ALL_CATS ? 0 : next;
    this.touchFilter();
  }

  /** 长按：只保留这一项（已经是唯一选中则恢复全选），对齐 NextE CategorySelector 的手势 */
  private soloCat(idx: number): void {
    if (this.visCats() === CAT_BITS[idx]) {
      this.catsMask = 0;
    } else {
      this.catsMask = CAT_BITS[idx];
    }
    this.touchFilter();
  }

  // -------------------------------------------------- 搜索范围（f_sname 等）
  private scopeOn(idx: number): boolean {
    if (idx === 0) {
      return this.scopeName;
    }
    if (idx === 1) {
      return this.scopeTags;
    }
    return this.scopeDesc;
  }

  /** 至少保留一项：三项全不勾在 EH 上是「搜不到东西」，不允许走到那个状态 */
  private toggleScope(idx: number): void {
    const on: number = (this.scopeName ? 1 : 0) + (this.scopeTags ? 1 : 0) + (this.scopeDesc ? 1 : 0);
    if (this.scopeOn(idx) && on <= 1) {
      return;
    }
    if (idx === 0) {
      this.scopeName = !this.scopeName;
    } else if (idx === 1) {
      this.scopeTags = !this.scopeTags;
    } else {
      this.scopeDesc = !this.scopeDesc;
    }
    this.touchFilter();
  }

  // -------------------------------------------------- 五个高级开关
  private switchOn(idx: number): boolean {
    if (idx === SW_TORRENT) {
      return this.onlyTorrent;
    }
    if (idx === SW_EXPUNGED) {
      return this.onlyExpunged;
    }
    if (idx === SW_NOLANG) {
      return this.noLang;
    }
    if (idx === SW_NOUP) {
      return this.noUploader;
    }
    return this.noTag;
  }

  private setSwitch(idx: number, v: boolean): void {
    if (idx === SW_TORRENT) {
      this.onlyTorrent = v;
    } else if (idx === SW_EXPUNGED) {
      this.onlyExpunged = v;
    } else if (idx === SW_NOLANG) {
      this.noLang = v;
    } else if (idx === SW_NOUP) {
      this.noUploader = v;
    } else {
      this.noTag = v;
    }
    this.touchFilter();
  }

  // -------------------------------------------------- 历史里的条件快照
  /*
   * 历史本身仍由 Prefs.SearchHistory 管（纯关键词字符串，设置页「清空历史」也用它），
   * 这里另存一张「关键词 → 条件 JSON」的表，键与历史同寿，不改变原有存储格式。
   */
  private histFilters(): Record<string, string> {
    const raw: string = Prefs.str(KEY_HIST_FILTER, '');
    if (raw.length === 0) {
      return {};
    }
    try {
      return JSON.parse(raw) as Record<string, string>;
    } catch (e) {
      return {};
    }
  }

  private saveHistFilter(kw: string, o: SearchOptions): void {
    const all: Record<string, string> = this.histFilters();
    all[kw] = o.toJson();
    // 只保留还在历史里的词，避免这张表无限增长
    const kept: Record<string, string> = {};
    for (let i = 0; i < this.history.length; i++) {
      const k: string = this.history[i];
      const v: string | undefined = all[k];
      if (v !== undefined) {
        kept[k] = v;
      }
    }
    Prefs.put(KEY_HIST_FILTER, JSON.stringify(kept));
  }

  private dropHistFilter(kw: string): void {
    const all: Record<string, string> = this.histFilters();
    const keys: string[] = Object.keys(all);
    const kept: Record<string, string> = {};
    let changed: boolean = false;
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] === kw) {
        changed = true;
        continue;
      }
      kept[keys[i]] = all[keys[i]];
    }
    if (changed) {
      Prefs.put(KEY_HIST_FILTER, JSON.stringify(kept));
    }
  }

  private clearHistFilters(): void {
    Prefs.put(KEY_HIST_FILTER, '');
  }

  // ------------------------------------------------------------ 搜索建议
  private onKeywordChange(v: string): void {
    this.keyword = v;
    // 改的字和已提交的词不同 → 又回到「输入中」，联想可以重新出现
    if (v.trim() !== this.activeKw) {
      this.submitted = false;
    }
    if (this.suggestTimer >= 0) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = -1;
    }
    const kw: string = v.trim();
    if (kw.length < 2) {
      this.suggestions = [];
      this.showSuggest = false;
      return;
    }
    // 300ms 防抖：EH 对搜索页有频率限制，逐字发请求很容易被限流
    this.suggestTimer = setTimeout(() => {
      this.suggestTimer = -1;
      this.loadSuggest(kw);
    }, 300);
  }

  private async loadSuggest(kw: string): Promise<void> {
    // 本地结果先上屏，网络部分回来再追加，用户不会盯着空白等 1 秒
    const local: SuggestItem[] = this.localSuggest(kw);
    if (this.keyword.trim() !== kw) {
      return;
    }
    this.suggestions = local;
    this.showSuggest = local.length > 0;

    const remote: SuggestItem[] = await this.remoteSuggest(kw);
    if (this.keyword.trim() !== kw) {
      return;
    }
    const merged: SuggestItem[] = local.slice();
    for (let i = 0; i < remote.length; i++) {
      let dup: boolean = false;
      for (let j = 0; j < merged.length; j++) {
        if (merged[j].text === remote[i].text) {
          dup = true;
          break;
        }
      }
      if (!dup && merged.length < SUGGEST_LIMIT) {
        merged.push(remote[i]);
      }
    }
    this.suggestions = merged;
    this.showSuggest = merged.length > 0;
  }

  /** 降级建议：搜索历史包含匹配 + 内置标签词表（带中文翻译） */
  private localSuggest(kw: string): SuggestItem[] {
    const low: string = kw.toLowerCase();
    const seen: Set<string> = new Set<string>();
    const out: SuggestItem[] = [];

    for (let i = 0; i < this.history.length && out.length < SUGGEST_LIMIT; i++) {
      const h: string = this.history[i];
      if (h.toLowerCase().indexOf(low) >= 0 && !seen.has(h)) {
        seen.add(h);
        out.push(new SuggestItem(h, '历史'));
      }
    }

    for (let i = 0; i < TAG_WORDS.length && out.length < SUGGEST_LIMIT; i++) {
      const word: string = TAG_WORDS[i];
      if (seen.has(word)) {
        continue;
      }
      const colon: number = word.indexOf(':');
      const ns: string = colon < 0 ? '' : word.substring(0, colon);
      const key: string = colon < 0 ? word : word.substring(colon + 1);
      // 读 tick 建立依赖：标签库加载完成后这一块会重绘（Map 不是可观察状态）
    const tick: number = this.tagTransTick;
    const zh: string = ns.length === 0 || tick < 0 ? '' : TagTrans.translate(ns, key);
      const lower: string = word.toLowerCase();
      // 整体前缀匹配（female:sto）或中文名前缀匹配（长袜）
      const hit: boolean = lower.indexOf(low) >= 0 || (zh.length > 0 && zh.indexOf(kw) >= 0);
      if (!hit) {
        continue;
      }
      seen.add(word);
      out.push(new SuggestItem(word, zh.length > 0 ? zh : '标签'));
    }
    return out;
  }

  /**
   * 联网建议。
   *
   * EH 没有公开的 autocomplete 接口（这点必须说明白，不能编一个地址出来），
   * 所以退一步：直接请求一次**搜索结果页**，从里面能拿到的两样东西拼建议：
   *  1. `#searchdiv` 里指向 `f_search=` 的链接 —— 老版搜索结果页会在这里放
   *     「相关搜索」入口，能取到就当作站点给的建议；
   *  2. `.searchtext` 的 "Found N results" 文案 —— 它不含候选词，但能证明
   *     当前关键词是有效的，于是把关键词本身作为一条「直达」建议，右侧显示结果数。
   *
   * 两样都取不到（站点改版、页面被限流、网络失败）就不返回任何东西，
   * 由调用方只显示本地建议，功能不会因此不可用。
   */
  private async remoteSuggest(kw: string): Promise<SuggestItem[]> {
    const out: SuggestItem[] = [];
    try {
      const resp: HttpResp = await Http.get(EhApi.searchUrl(kw, this.opts(), 0));
      if (resp.code !== 200) {
        return out;
      }
      const doc: HNode = Html.parse(resp.body);
      const links: HNode[] = doc.find('#searchdiv a');
      for (let i = 0; i < links.length && out.length < 3; i++) {
        const href: string = links[i].attr('href');
        if (href.indexOf('f_search=') < 0) {
          continue;
        }
        const text: string = links[i].textContent().trim();
        if (text.length > 0) {
          out.push(new SuggestItem(text, '站点相关'));
        }
      }
      const countText: string = doc.textOf('.searchtext').trim();
      if (countText.length > 0) {
        out.push(new SuggestItem(kw, countText));
      }
    } catch (e) {
      // 网络失败/被限流：静默降级成本地建议
      return out;
    }
    return out;
  }

  private pickSuggest(text: string): void {
    this.submit(text);
  }

  // ------------------------------------------------------------ 搜索历史
  /**
   * 删除一条历史。
   *
   * SearchHistory 只有 list/push/clear，没有 remove；而 Prefs.ets 不在本次
   * 改动范围内，所以这里用 Prefs.put 直接改写它用的同一个 key（'search_history'）
   * 和同一种格式（JSON 字符串数组），与 SearchHistory.push/clear 完全兼容。
   */
  private removeHistory(kw: string): void {
    const out: string[] = [];
    for (let i = 0; i < this.history.length; i++) {
      if (this.history[i] !== kw) {
        out.push(this.history[i]);
      }
    }
    Prefs.put('search_history', JSON.stringify(out));
    this.dropHistFilter(kw);
    this.history = out;
  }

  /**
   * 长按删除后，系统可能补发一次 click；用时间戳把它吃掉，避免删完又搜一遍。
   * 命中历史里的条件快照就先还原条件 —— 对齐本轮需求「点历史能还原当时的筛选」。
   */
  private tapHistory(kw: string): void {
    if (Date.now() - this.lastLongPressAt < 600) {
      return;
    }
    const all: Record<string, string> = this.histFilters();
    const raw: string | undefined = all[kw];
    if (raw !== undefined && raw.length > 0) {
      this.applyOpts(SearchOptions.parse(raw));
    }
    this.submit(kw);
  }

  /** 选一张本地图片上传到 EH 的以图搜图接口 */
  private async pickImage(): Promise<void> {
    if (this.imgSearching) {
      return;
    }
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const opt: photoAccessHelper.PhotoSelectOptions = {
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      };
      const res: photoAccessHelper.PhotoSelectResult = await picker.select(opt);
      if (res.photoUris.length === 0) {
        return;
      }
      this.imgSearching = true;
      this.imgError = '';
      this.imgResults = await searchByImage(res.photoUris[0]);
      if (this.imgResults.length === 0) {
        this.imgError = '没有找到相似画廊（也可能是上传失败）';
      }
    } catch (e) {
      this.imgError = (e as Error).message;
    }
    this.imgSearching = false;
  }

  // ------------------------------------------------------------ UI 片段
  @Builder
  private suggestPanel() {
    Column() {
      ForEach(this.suggestions, (s: SuggestItem) => {
        Row() {
          Text(s.text)
            .fontSize(13)
            .fontColor(Theme.text())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (s.hint.length > 0) {
            Text(s.hint)
              .fontSize(10)
              .fontColor(Theme.subText())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ left: 8 })
              .constraintSize({ maxWidth: 140 })
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .onClick(() => this.pickSuggest(s.text))
      }, (s: SuggestItem) => s.text + '|' + s.hint)
    }
    .width('100%')
    .backgroundColor(Theme.card())
    .borderRadius(12)
    .clip(true)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 「以图搜图」入口。
   *
   * 为什么收进筛选面板：顶栏标题行最右的位置要让给「筛选」（整行右对齐，那里是动作终点），
   * 原来那颗 40×40 的「图」图标位随之撤掉；而页面上只剩图搜失败态里的「重新选图」，
   * 那不是常规入口（只有失败后才看得到）。把它放在这里与跳页同一层（都是低频动作），
   * 以图搜图的能力一点没丢，标题行也不必再挤第三颗按钮。
   */
  @Builder
  private imgSearchRow() {
    Row({ space: GAP_SM }) {
      Column({ space: 2 }) {
        Text('以图搜图').fontSize(FONT_META).fontColor(Theme.text())
        Text('选一张本地图片，找相似画廊')
          .fontSize(FONT_TAG)
          .fontColor(Theme.subText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('选择图片')
        .fontSize(FONT_CAPTION)
        .fontColor(Theme.accent())
        .fontWeight(FontWeight.Medium)
        .height(CHIP_HEIGHT)
        .padding({ left: 12, right: 12 })
        .textAlign(TextAlign.Center)
        .borderRadius(PILL_RADIUS)
        .backgroundColor(Theme.line())
        .onClick(() => {
          // 先收面板再唤起图库：面板是模态浮层，开着它图库回来时结果会被盖住
          this.filterOpen = false;
          this.pickImage();
        })
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING })
  }

  /**
   * 「跳转到第 N 页」：无限滚动之后唯一的跳页入口，随筛选面板的内容一起滚动
   * （位置在「高级选项」卡之后，见 actionCard）。
   *
   * 为什么搬进来：结果区已经变成一条连续列表，底部再挂页码条就会一直压在「继续下滑」的
   * 手势上；而跳页本身就是低频操作，收进筛选面板（用户找「筛选」时顺手就能看到）更自然。
   * 这里只给输入 + 跳转，不做「‹ › 翻页」——翻页已经是滚动的职责了。
   */
  @Builder
  private jumpRow() {
    Row({ space: GAP_SM }) {
      Text('跳转到')
        .fontSize(FONT_META)
        .fontColor(Theme.text())

      TextInput({ text: this.jumpText, placeholder: (this.pageIndex + 1).toString() })
        .type(InputType.Number)
        .width(64)
        .height(34)
        .textAlign(TextAlign.Center)
        .fontSize(FONT_CAPTION)
        .fontColor(Theme.text())
        .placeholderColor(Theme.subText())
        .backgroundColor(Theme.bg())
        .borderRadius(CHIP_RADIUS)
        .onChange((v: string) => {
          this.jumpText = v;
          // 用户开始改字就把上一次的错误提示收掉，别让他一边改一边看着一条过期的红字
          if (this.jumpHint.length > 0) {
            this.jumpHint = '';
          }
        })

      Text('页')
        .fontSize(FONT_META)
        .fontColor(Theme.text())

      Blank()

      Text('跳转')
        .fontSize(FONT_CAPTION)
        .fontColor(Theme.accent())
        .fontWeight(FontWeight.Medium)
        .height(CHIP_HEIGHT)
        .padding({ left: 12, right: 12 })
        .textAlign(TextAlign.Center)
        .borderRadius(PILL_RADIUS)
        .backgroundColor(Theme.line())
        .onClick(() => this.jumpToPage())
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING })
  }

  /**
   * 「以图搜图」+「跳页」合到的一张卡，跟着内容一起滚（位置在高级选项卡之后）。
   *
   * 为什么从底部固定区搬进来：底部现在只留一颗悬浮的「重置 / 应用」，那里再叠两行
   * 就会被悬浮按钮压住；而这两个入口本身都是低频动作（图搜要跳去系统图库、跳页多数人
   * 用直接下滑代替），放在筛选条件之后、「随时能滚到」比「常驻在眼前」更合适。
   *
   * 为什么两者之间用一条 divider 而不是拆成两张卡：它们同属「动作」而非「条件」，
   * 合卡之后整块与上面的 catCard / langCard / advCard 分得开（一张卡 = 一组同类内容），
   * 卡内再用面板统一的 divider()（左边距 16）区分两行，视觉层级不增加。
   */
  @Builder
  private actionCard() {
    Column() {
      this.imgSearchRow()
      this.divider()
      this.jumpRow()
      // 跳页的错误提示跟着跳页行走：它原来贴在底部固定区，现在必须一起搬进滚动内容，
      // 否则会被悬浮按钮盖住。行为不变 —— 只在非法时出现，输入一改就清掉。
      if (this.jumpHint.length > 0) {
        Text(this.jumpHint)
          .fontSize(FONT_TAG)
          .fontColor(Theme.accent())
          .width('100%')
          .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 8 })
      }
    }
    .width('100%')
    .backgroundColor(Theme.card())
    .borderRadius(CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  // ------------------------------------------------------------ 筛选面板 UI
  /*
   * 所有行 / 色块 builder 只收「下标 / 组别」这类常量，状态一律在体内读 this.xxx：
   * 本工程踩过两次 —— @Builder 的值参数只在创建时求值一次，传 isOn / 文案进去，
   * 状态变了那一行不会重绘。
   */

  @Builder
  private divider() {
    Divider()
      .strokeWidth(0.5)
      .color(Theme.line())
      .margin({ left: 16 })
  }

  @Builder
  private sectionLabel(idx: number) {
    Text(SECTION_LABELS[idx])
      .fontSize(FONT_CAPTION)
      .fontColor(Theme.subText())
      .width('100%')
      .padding({ left: 4, top: 10, bottom: 6 })
  }

  /** 卡片内的小标题（搜索范围 / 最低评分 …） */
  @Builder
  private subLabel(idx: number) {
    Text(SUB_LABELS[idx])
      .fontSize(FONT_TAG)
      .fontColor(Theme.subText())
      .width('100%')
      .padding({ left: 16, top: 10, bottom: 4 })
  }

  // -------------------------------------------------- 分类色块
  @Builder
  private catCell(idx: number) {
    Text(Categories.of(CAT_NAMES[idx]).label)
      .fontSize(FONT_CAPTION)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .textAlign(TextAlign.Center)
      .height(CAT_H)
      .layoutWeight(1)
      .padding({ left: 4, right: 4 })
      .borderRadius(CAT_RADIUS)
      .fontWeight(this.catSelected(idx) ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.catSelected(idx) ? Color.White : Theme.text())
      .backgroundColor(this.catSelected(idx) ? Categories.of(CAT_NAMES[idx]).color : Theme.bg())
      .onClick(() => this.toggleCat(idx))
      .gesture(LongPressGesture({ repeat: false, duration: 500 })
        .onAction((event: GestureEvent) => {
          this.soloCat(idx);
        }))
  }

  @Builder
  private catCard() {
    Column({ space: GAP_SM }) {
      Row({ space: GAP_SM }) {
        this.catCell(0)
        this.catCell(1)
      }.width('100%')

      Row({ space: GAP_SM }) {
        this.catCell(2)
        this.catCell(3)
      }.width('100%')

      Row({ space: GAP_SM }) {
        this.catCell(4)
        this.catCell(5)
      }.width('100%')

      Row({ space: GAP_SM }) {
        this.catCell(6)
        this.catCell(7)
      }.width('100%')

      Row({ space: GAP_SM }) {
        this.catCell(8)
        this.catCell(9)
      }.width('100%')

      Text('点按切换，长按只保留该分类（再长按恢复全选）· f_cats')
        .fontSize(FONT_TAG)
        .fontColor(Theme.subText())
        .width('100%')
        .padding({ top: 2 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.card())
    .borderRadius(CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  // -------------------------------------------------- 语言（拼进关键词）
  /*
   * 为什么语言单独一张卡、不塞进「高级选项」：它不是 f_* 参数，也不受 advsearch=1 约束
   * —— 语言只是关键词里的 `language:<值>$`。放进高级卡片会让人以为必须先打开高级开关。
   */
  /**
   * 单个语言 chip：下标既取标签也取取值，状态在体内读 this.lang（builder 不收值参数）。
   *
   * 选中底**不在这里画**：整组只有一个滑动色块（见 langCard），chip 只剩文字颜色变化。
   * 两层底叠着会在大圆角处露出两道弧线（色的边缘 + 块的边缘），读成「没对齐」；
   * 而且新旧两颗各自淡入淡出时中间会出现「两块都亮着」的过渡帧 —— 这正是首页
   * FloatingTabs 从「逐项变色」改成「一个块滑动」的原因，这里照同一个结论做。
   */
  @Builder
  private langPill(idx: number) {
    Text(LANG_LABELS[idx])
      .height(LANG_CHIP_H)
      .padding({ left: LANG_CHIP_PAD, right: LANG_CHIP_PAD })
      .fontSize(FONT_CAPTION)
      .maxLines(1)
      .textAlign(TextAlign.Center)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .fontWeight(this.lang === LANG_VALUES[idx] ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.langFg(idx))
      // 只给字色做缓动：色块负责「滑过去」，文字负责「亮起来」，两者分工与首页一致
      .animation({ duration: 160, curve: Curve.FastOutSlowIn })
      // 实测自己的宽度，供滑动色块取用（位置由宽度累加推出，见 recordLangW）
      .onAreaChange((oldArea: Area, newArea: Area) => {
        const w: number = parseFloat(newArea.width.toString());
        if (isNaN(w) || w <= 0) {
          return;
        }
        this.recordLangW(idx, w);
      })
      .onClick(() => {
        // 单选：点「全部」= 空串，其余把值换成该语言
        this.lang = LANG_VALUES[idx];
        this.touchFilter();
      })
  }

  /**
   * 记录一颗 chip 的实测宽度，并据此重算**所有** chip 的 x。
   *
   * x 为什么不用 onAreaChange 报的 position.x 直接落：position 是相对父级 Row 的，
   * 而「相对坐标里含不含 Row 左右各 12 的内边距」没有明确口径 —— 一旦口径不同，
   * 整块色块就会相对文字偏 12，而这类偏移在截图上很难一次认准。
   * 换成算术就没有口径问题：第一颗的左边就是自己写的 LANG_GROUP_PAD，
   * 之后每一颗 = 前一颗 x + 前一颗宽 + 间距（Row 的 space），只用得到宽度这一个实测值。
   *
   * 为什么要一次重算全部：onAreaChange 的回调不保证按 0..5 的顺序到达，
   * 只算当前这颗的话，先到的那几颗会用到「邻居宽度还是 0」的结果、永远停在错的位置。
   * 值没变就直接返回 —— onAreaChange 每帧重排都会回调，不比较会自己把自己再触发一轮。
   */
  private recordLangW(idx: number, w: number): void {
    if (Math.abs(this.langW[idx] - w) < 0.5) {
      return;
    }
    const nw: number[] = this.langW.slice();
    nw[idx] = w;
    this.langW = nw;

    const nx: number[] = this.langX.slice();
    let x: number = LANG_GROUP_PAD;
    for (let i = 0; i < nx.length; i++) {
      nx[i] = x;
      x = x + this.langW[i] + LANG_CHIP_GAP;
    }
    // 整组换成新数组：@State 观察的是「数组被整体替换」，比逐项写入可靠
    this.langX = nx;
    // 布局实测阶段一律「直接落位」：这不是用户切换，让块从旧坐标滑过来会被读成一次选中变化，
    // 首帧更会看到块从左边缘窜到中间（FloatingTabs.relayout 的同一结论）。
    this.syncLangPill(false);
  }

  /** 当前语言在 LANG_VALUES 里的下标；认不出的值（旧配置里存过的）按「全部」= 0 处理 */
  private langIndex(): number {
    const i: number = LANG_VALUES.indexOf(this.lang);
    return i < 0 ? 0 : i;
  }

  /**
   * 把滑动色块摆到当前选中 chip 的实测位置上。
   *
   * animate=true 只给「用户点了另一颗」用（@Watch 里）；布局实测（onAreaChange）走 false。
   * 宽度还是 0 说明这一颗还没被量到（首次布局 / 该 chip 尚未上屏）：保持现状直接返回，
   * 等它的 onAreaChange 到了会再调一次 —— 绝不能在这里 animateTo 到 (0,0)，那会让块先消失在左端。
   */
  private syncLangPill(animate: boolean): void {
    const i: number = this.langIndex();
    const x: number = this.langX[i];
    const w: number = this.langW[i];
    if (!(w > 0)) {
      return;
    }
    if (animate) {
      animateTo({ duration: LANG_PILL_ANIM, curve: Curve.Smooth }, () => {
        this.langPillX = x;
        this.langPillW = w;
      });
    } else {
      this.langPillX = x;
      this.langPillW = w;
    }
  }

  /** 选中语言变化：色块滑到新位置（重复点同一颗时值不变，块不动） */
  private onLangChanged(): void {
    this.syncLangPill(true);
  }

  /**
   * chip 前景色：选中是白字，未选中仍是次色。
   *
   * 为什么选中要白：底色已经换成主色实块（见 langPillBg），主色字压在主色块上等于没字，
   * 只有白字才在那个亮度上读得清；未选中没有底，继续用 subText() 与卡内其它说明同档。
   *
   * 两个分支都读 themeDark，只为建立重绘依赖（Theme.xxx() 读的是不可观测的 Prefs，
   * 属性里不出现 themeDark 就收不到主题切换）。
   */
  private langFg(idx: number): ResourceColor {
    const on: boolean = this.lang === LANG_VALUES[idx];
    if (this.themeDark) {
      return on ? Color.White : Theme.subText();
    }
    return on ? Color.White : Theme.subText();
  }

  /**
   * 滑动色块底色：主色实块（主题换色时跟着变）。
   *
   * 为什么从 card() 换成 accent()：语言这一组是「单选状态」，选中项必须一眼看出来。
   * 原来色块与它所在的卡片同底，只靠字色变化区分，选中态几乎是隐形的；给实色主块
   * 之后与分类色块 / 评分 pill 的「选中 = 主色底 + 白字」完全同一套语义。
   */
  private langPillBg(): ResourceColor {
    if (this.themeDark) {
      return Theme.accent();
    }
    return Theme.accent();
  }

  @Builder
  private langCard() {
    Column({ space: 6 }) {
      Row() {
        Text('语言').fontSize(FONT_META).fontColor(Theme.text())
        Blank()
        Text('追加到关键词').fontSize(FONT_TAG).fontColor(Theme.subText())
      }
      .width('100%')

      // 整组语言 chip 共用**一颗**悬浮胶囊，结构与 FavoritesPage.categoryBar() 完全同构：
      // Stack 里垫一层 MaterialPlane（真实布局节点，塞进 background 在真机上是透明的），
      // 上层是横向 Scroll —— 内容铺在材质上，且整层铺满胶囊，点在任意位置都落在 Scroll 上、
      // 不会漏到材质层。宽度占满卡内宽度（外层的卡已经有 12 的内边距），
      // 高度由 LANG_GROUP_H 给定 —— 材质层必须有确定高度，见那个常量的注释。
      //
      // 为什么六颗只留一层材质：一颗一颗套 MaterialPlane 就是六个 Navigation 材质作用域，
      // 滑动/点选时逐帧重合成，是明确的掉帧来源（历史 chip 那一段也是同一个坑）；
      // 而且这六颗本来就该读成一组，一个容器也更符合「一组单选」的语义。
      Stack({ alignContent: Alignment.Center }) {
        MaterialPlane({
          kind: 'header',
          radius: PILL_RADIUS,
          planeHeight: LANG_GROUP_H,
          // edge 关掉、白边改由外层 Stack 画：材质自带的边取 Theme.edge()，
          // 与顶栏那几颗（btnEdge 白边）不是同一个色，同一页里会出现两种边。
          // 外层 Stack 不裁切，0.7 的边与投影都不会被材质的圆角削掉。
          edge: false
        })

        // 单行、横向可滑：六颗在 300vp 的卡宽里排不下，换行会把胶囊撑到 72。
        // 与收藏页分类条一样，放不下的部分交给滑动，高度才守得住 36。
        Scroll() {
          // 色块与 chip 必须同处一层内容里，才能一起横滑。
          // 若把色块放到 Scroll 外面（例如贴在 Stack 上），滚动时它停在原地，文字走了它不走。
          Stack({ alignContent: Alignment.TopStart }) {
            // 滑动选中块：整组语言只有这一块底色，宽/位取当前 chip 的实测值
            // （六颗宽度不等，不能像首页那样用「总宽 / 项数」推）。
            // 声明在 chip 行**之前** —— Stack 里越靠前越在下，于是它永远压在文字下面。
            Row()
              .width(this.langPillW)
              .height(LANG_CHIP_H)
              .borderRadius(PILL_RADIUS)
              .backgroundColor(this.langPillBg())
              .position({ x: this.langPillX, y: LANG_PILL_Y })
              // 不吃点击：点在块上也要落到上层 chip 的 onClick（块和 chip 完全重叠）
              .hitTestBehavior(HitTestMode.None)

            Row({ space: LANG_CHIP_GAP }) {
              this.langPill(0)
              this.langPill(1)
              this.langPill(2)
              this.langPill(3)
              this.langPill(4)
              this.langPill(5)
            }
            // 横向 12：材质本身没有内边距，内部留 12 色块才不会贴到 999 圆角上
            .padding({ left: LANG_GROUP_PAD, right: LANG_GROUP_PAD })
            .height(LANG_GROUP_H)
            // 居中即上下各 4（36 = 4 + 28 + 4），与 LANG_PILL_Y 同一个来源
            .alignItems(VerticalAlign.Center)
          }
          .height(LANG_GROUP_H)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(LANG_GROUP_H)
        // 裁切放在 Scroll 上而不是外层 Stack：横滑时两端的 chip 会滚出胶囊边界，
        // 只裁内容即可；外层若也 clip，材质自带的那圈描边外侧会被削掉半条（边会看着断）。
        .clip(true)
      }
      .width('100%')
      .height(LANG_GROUP_H)
      .borderRadius(PILL_RADIUS)
      // 白边与投影挂在这一层：它不 clip，边是完整的；横滑时被裁的 chip 由里层 Scroll 负责，
      // 两者互不干扰（若在这里 clip，0.7 的边会在四段弧上各被削掉一半）。
      .border({ width: MATERIAL_EDGE_WIDTH, color: Theme.btnEdge() })
      .shadow(Theme.floatShadow())

      // 说明写成「原版的写法」而不是「对齐原版」：原版确实有语言筛选，但它是搜索面板里的
      // 一个单选下拉（eh_search_config_dialog.dart:_buildLanguageSelector），我们换成 pill，
      // 写法沿用原版的 `language:"值"`（引号精确匹配，见 EhApi.searchUrl）。
      Text('原版同款：单选一种语言，拼进关键词 language:"值"')
        .fontSize(FONT_TAG)
        .fontColor(Theme.subText())
        .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.card())
    .borderRadius(CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  // -------------------------------------------------- 高级选项
  /** 总开关行：advsearch=1 的闸门，关着时下面所有 f_* 都不生效 */
  @Builder
  private advRow() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('高级选项').fontSize(FONT_META).fontColor(Theme.text())
        Text('关闭时只带关键词与分类')
          .fontSize(FONT_TAG)
          .fontColor(Theme.subText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.advOn })
        .selectedColor(Theme.accent())
        .onChange((v: boolean) => {
          this.advOn = v;
          this.touchFilter();
        })
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 16, right: 16 })
  }

  /** 搜索范围：名称 / 标签 / 简介（f_sname / f_stags / f_sdesc，至少保留一项） */
  @Builder
  private scopeRow(idx: number) {
    Row({ space: 10 }) {
      Column() {
        if (this.scopeOn(idx)) {
          Text('✓')
            .fontSize(11)
            .fontColor(Color.White)
        }
      }
      .width(20)
      .height(20)
      .borderRadius(6)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(this.scopeOn(idx) ? Theme.accent() : Theme.bg())
      .borderWidth(this.scopeOn(idx) ? 0 : 1)
      .borderColor(Theme.line())

      Text(SCOPE_NAMES[idx])
        .fontSize(FONT_META)
        .fontColor(Theme.text())
        .layoutWeight(1)

      Text(SCOPE_PARAMS[idx])
        .fontSize(FONT_TAG)
        .fontColor(Theme.subText())
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 16, right: 16 })
    .onClick(() => this.toggleScope(idx))
  }

  @Builder
  private ratingPill(idx: number) {
    Text(RATINGS[idx] === 0 ? '不限' : RATINGS[idx].toString() + '★')
      .fontSize(FONT_CAPTION)
      .textAlign(TextAlign.Center)
      .height(34)
      .layoutWeight(1)
      .borderRadius(CHIP_RADIUS)
      .fontColor(this.minRating === RATINGS[idx] ? Color.White : Theme.text())
      .backgroundColor(this.minRating === RATINGS[idx] ? Theme.accent() : Theme.bg())
      .onClick(() => {
        this.minRating = RATINGS[idx];
        this.touchFilter();
      })
  }

  @Builder
  private ratingRow() {
    Column({ space: GAP_SM }) {
      Row() {
        Text('最低评分').fontSize(FONT_META).fontColor(Theme.text())
        Blank()
        Text('f_srdd').fontSize(FONT_TAG).fontColor(Theme.subText())
      }
      .width('100%')

      Row({ space: 6 }) {
        this.ratingPill(0)
        this.ratingPill(1)
        this.ratingPill(2)
        this.ratingPill(3)
        this.ratingPill(4)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }

  @Builder
  private pageRangeRow() {
    Row({ space: 6 }) {
      Column({ space: 2 }) {
        Text('页数范围').fontSize(FONT_META).fontColor(Theme.text())
        Text('f_spf - f_spt').fontSize(FONT_TAG).fontColor(Theme.subText())
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      TextInput({ text: this.pagesFromText, placeholder: '下限' })
        .type(InputType.Number)
        .width(62)
        .height(36)
        .textAlign(TextAlign.Center)
        .fontSize(FONT_CAPTION)
        .fontColor(Theme.text())
        .placeholderColor(Theme.subText())
        .backgroundColor(Theme.bg())
        .borderRadius(CHIP_RADIUS)
        .onChange((v: string) => {
          this.pagesFromText = v;
          this.touchFilter();
        })

      Text('-')
        .fontSize(FONT_CAPTION)
        .fontColor(Theme.subText())

      TextInput({ text: this.pagesToText, placeholder: '上限' })
        .type(InputType.Number)
        .width(62)
        .height(36)
        .textAlign(TextAlign.Center)
        .fontSize(FONT_CAPTION)
        .fontColor(Theme.text())
        .placeholderColor(Theme.subText())
        .backgroundColor(Theme.bg())
        .borderRadius(CHIP_RADIUS)
        .onChange((v: string) => {
          this.pagesToText = v;
          this.touchFilter();
        })
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 16, right: 16 })
  }

  /** 起始日期：EH 唯一的「时间维度」是 seek（没有按时间/相关度排序的参数） */
  @Builder
  private seekRow() {
    Row({ space: 6 }) {
      Column({ space: 2 }) {
        Text('起始日期').fontSize(FONT_META).fontColor(Theme.text())
        Text('只显示此日期之后发布 · seek')
          .fontSize(FONT_TAG)
          .fontColor(Theme.subText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      TextInput({ text: this.seekText, placeholder: 'yyyy-MM-dd' })
        .width(116)
        .height(36)
        .textAlign(TextAlign.Center)
        .fontSize(FONT_CAPTION)
        .fontColor(Theme.text())
        .placeholderColor(Theme.subText())
        .backgroundColor(Theme.bg())
        .borderRadius(CHIP_RADIUS)
        .onChange((v: string) => {
          this.seekText = v;
          this.touchFilter();
        })
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 16, right: 16 })
  }

  @Builder
  private switchRow(idx: number) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(SW_NAMES[idx]).fontSize(FONT_META).fontColor(Theme.text())
        Text(SW_PARAMS[idx])
          .fontSize(FONT_TAG)
          .fontColor(Theme.subText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.switchOn(idx) })
        .selectedColor(Theme.accent())
        .onChange((v: boolean) => {
          this.setSwitch(idx, v);
        })
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 16, right: 16 })
  }

  @Builder
  private advCard() {
    Column() {
      this.advRow()
      if (this.advOn) {
        this.divider()
        this.subLabel(SUB_SCOPE)
        this.scopeRow(0)
        this.divider()
        this.scopeRow(1)
        this.divider()
        this.scopeRow(2)
        this.divider()
        this.subLabel(SUB_RATING)
        this.ratingRow()
        this.divider()
        this.pageRangeRow()
        this.divider()
        this.seekRow()
        this.divider()
        this.switchRow(SW_TORRENT)
        this.divider()
        this.switchRow(SW_EXPUNGED)
        this.divider()
        this.switchRow(SW_NOLANG)
        this.divider()
        this.switchRow(SW_NOUP)
        this.divider()
        this.switchRow(SW_NOTAG)
      }
    }
    .width('100%')
    .backgroundColor(Theme.card())
    .borderRadius(CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 底部悬浮的「重置 / 应用」。
   *
   * 为什么不放在 Column 末尾当最后一行：那样它是一条贴底的不透明横条，会把玻璃面板
   * 拦腰截成两段、白吃掉一截可视高度，而且与上面的卡片之间永远隔着一道硬边；
   * 改成浮层后滚动内容能从两颗胶囊背后穿过，材质才有东西可模糊。
   *
   * 几何：左右各 16（与面板内容同一条边）、离底 16 + 导航条高度（沉浸式下面板铺到窗口底边，
   * 不加这一档「应用」会被手势条压住一半）。两颗等宽（layoutWeight(1)），中间 12。
   * 代价是内容末尾必须让位，见 SHEET_FLOAT_RESERVE。
   */
  @Builder
  private floatActions() {
    Row({ space: SHEET_FLOAT_GAP }) {
      // 「重置」：次要色文字 —— 没有实底，轮廓完全由面板材质 + 描边给出
      Stack({ alignContent: Alignment.Center }) {
        // 不再传 edge: true：MaterialPlane 的描边取 Theme.edge()（浅色是 20% 黑），
        // 这两颗要的是白边，所以把边挪到外面这层 Stack 上显式画（见下）。
        MaterialPlane({
          kind: 'panel',
          radius: PILL_RADIUS,
          planeHeight: SHEET_BTN_H
        })
        Text('重置')
          .width('100%')
          .height(SHEET_BTN_H)
          .fontSize(FONT_META)
          .fontColor(Theme.subText())
          .textAlign(TextAlign.Center)
          .maxLines(1)
      }
      .height(SHEET_BTN_H)
      .layoutWeight(1)
      // 圆角只给描边用，不裁剪内容（clip 默认关）：
      // MaterialPlane 内部那层自己已经按 999 裁过，这里再裁会把描边外侧削掉半条。
      .borderRadius(PILL_RADIUS)
      // 白边与投影统一走 Theme（见 Theme.btnEdge / Theme.floatShadow 的注释）：
      // 三颗浮起控件同源，本页不再写字面量色值。
      .border({ width: MATERIAL_EDGE_WIDTH, color: Theme.btnEdge() })
      .shadow(Theme.floatShadow())
      .onClick(() => this.resetFilter())

      // 「应用」：主色文字 + Medium，强调它才是这段流程的终点
      Stack({ alignContent: Alignment.Center }) {
        MaterialPlane({
          kind: 'panel',
          radius: PILL_RADIUS,
          planeHeight: SHEET_BTN_H
        })
        Text('应用')
          .width('100%')
          .height(SHEET_BTN_H)
          .fontSize(FONT_META)
          .fontColor(Theme.accent())
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .maxLines(1)
      }
      .height(SHEET_BTN_H)
      .layoutWeight(1)
      .borderRadius(PILL_RADIUS)
      // 与「重置」同一条白边、同一档投影（材质都走 'panel'）：两颗并排，任一处不一致都会被看成两种控件
      .border({ width: MATERIAL_EDGE_WIDTH, color: Theme.btnEdge() })
      .shadow(Theme.floatShadow())
      .onClick(() => this.closeFilter(true))
    }
    .width('100%')
    .padding({
      left: PAGE_PADDING,
      right: PAGE_PADDING,
      bottom: this.navBarInset() + SHEET_FLOAT_PAD
    })
  }

  @Builder
  private filterSheet() {
    // 外层 Stack 只做一件事：让底部那颗悬浮按钮行压在内容**之上**（Stack 里越靠后越在上）。
    //
    // 为什么这里可以用 Stack：Column（标题 + Scroll）是 height('100%') 的真实节点，
    // 悬浮行是它的兄弟节点、按 alignContent 贴底 —— 两者在 sheet 内是同一棵布局树里的层级关系，
    // 不像 MaterialPlane 那样依赖「系统栏作用域」，所以叠放本身是成立的（材质那层仍各自独立）。
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // 标题居中：标题铺满整行、自己居中，关闭钮叠在右端。
        // 用 Row + Blank 时标题的「视觉中心」会随右侧按钮宽度偏移（看起来偏左），
        // 叠放后标题相对整行居中，按钮只是压在右端，不参与标题的宽度计算。
        Stack({ alignContent: Alignment.End }) {
          Text('搜索筛选')
            .width('100%')
            .fontSize(FONT_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text())
            .textAlign(TextAlign.Center)
            .maxLines(1)
          // 关闭：圆形玻璃钮 + 一个 × 字。
          //
          // 为什么从文字胶囊改成圆钮：标题行右侧是面板唯一的「退出」动作，胶囊形和
          // 下面那一排「重置 / 应用」同形，容易被当成第三个按钮；做成圆钮后它与
          // 标题行右侧的小图标位同构，读起来就是「收起面板」。
          // 图标直接用文本 '×'：本页历史条目右侧的删除按钮就是同一个写法（见 historyBlock），
          // 工程里没有现成的关闭图资源，也不为这一颗引第三方图示。
          Stack({ alignContent: Alignment.Center }) {
            // 与底部「重置 / 应用」同一套：材质开 panel（阴影由系统材质自带）、白边由外层 Stack 给，
            // 不再用 edge: true（那条是 Theme.edge()，浅色是黑边，和这两颗要的白边不一致）。
            MaterialPlane({
              kind: 'panel',
              radius: PILL_RADIUS,
              planeHeight: CLOSE_BTN_H
            })
            Text('×')
              .width('100%')
              .height(CLOSE_BTN_H)
              // 44 的圆钮里 18 号太小，视觉重量压不住；20 才是圆钮该有的比例
              .fontSize(20)
              .fontColor(Theme.subText())
              .textAlign(TextAlign.Center)
              .maxLines(1)
          }
          .width(CLOSE_BTN_H)
          .height(CLOSE_BTN_H)
          .borderRadius(PILL_RADIUS)
          // 白边画在不被裁的这一层：材质自己 clip 圆角，画在材质上会被削掉半条
          .border({ width: MATERIAL_EDGE_WIDTH, color: Theme.btnEdge() })
          // 与底部「重置 / 应用」同一份投影参数（Theme.floatShadow），三颗浮起控件因此同源
          .shadow(Theme.floatShadow())
          .onClick(() => this.closeFilter(false))
        }
        .width('100%')
        .height(60)
        // 24 而不是 16：标题与圆钮都往里收，和面板内容卡的 12 内边距形成层次，
        // 贴边时圆钮的阴影会被 sheet 边缘压掉一半。
        // 顶部再给 8：标题行贴着 sheet 上沿时，眼神上会觉得被「顶」住了。
        .padding({ left: PAGE_PADDING + 8, right: PAGE_PADDING + 8, top: 8 })

        // 面板内滚动：键盘只由输入框唤起，打开面板本身不弹键盘
        Scroll() {
          Column({ space: 4 }) {
            this.sectionLabel(SECTION_CATS)
            this.catCard()
            this.sectionLabel(SECTION_LANG)
            this.langCard()
            this.sectionLabel(SECTION_ADV)
            this.advCard()
            // 以图搜图与跳页现在跟着内容滚（原来钉在底部，会和悬浮按钮抢同一块地方）
            this.sectionLabel(SECTION_MORE)
            this.actionCard()
          }
          .width('100%')
          // 底部让位：这里没有 contentEndOffset（那是 List/Grid 才有的），只能补 padding，
          // 口径是「悬浮按钮占的高度 + 导航条」。少了最后一张卡会被「重置 / 应用」压住。
          .padding({
            left: PAGE_PADDING,
            right: PAGE_PADDING,
            bottom: this.navBarInset() + SHEET_FLOAT_RESERVE
          })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)

      this.floatActions()
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private historyBlock() {
    Column({ space: GAP_SM }) {
      Row() {
        Text('最近搜索').fontSize(FONT_CAPTION).fontColor(Theme.subText())
        Blank()
        Text('清空')
          .fontSize(FONT_CAPTION)
          .fontColor(Theme.accent())
          .onClick(() => {
            SearchHistory.clear();
            // 关键词清空后，配套的条件快照也一起清掉，避免下次同名关键词被还原成旧条件
            this.clearHistFilters();
            this.history = [];
          })
      }
      .width('100%')

      // 行距 8：靠 chip 自身的 margin(right/bottom) 撑开，不用 Column space 叠两层间距
      //
      // 历史 chip 同样**不加材质**（数量多、会换行、材质图层开销大），
      // 继续用卡片底 + 8 圆角；这样整块历史区在滚动时只是一批普通节点，不会拖累帧率。
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.history, (k: string) => {
          Row({ space: 6 }) {
            Text(k)
              .fontSize(FONT_CAPTION)
              .fontColor(Theme.subText())
              .maxLines(1)
              .constraintSize({ maxWidth: 180 })
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            // 每条右侧的删除态：点 × 直接删，长按整条仍然保留
            Text('×')
              .fontSize(14)
              .fontColor(Theme.subText())
              .width(18)
              .height(18)
              .textAlign(TextAlign.Center)
              .onClick(() => this.removeHistory(k))
          }
          .height(CHIP_HEIGHT)
          .padding({ left: 12, right: 8 })
          .borderRadius(CHIP_RADIUS)
          .backgroundColor(Theme.card())
          .margin({ right: GAP_SM, bottom: GAP_SM })
          .onClick(() => this.tapHistory(k))
          .gesture(LongPressGesture({ repeat: false, duration: 500 })
            .onAction((event: GestureEvent) => {
              this.lastLongPressAt = Date.now();
              this.removeHistory(k);
            }))
        }, (k: string) => 'h-' + k)
      }
      .width('100%')

      Text('点 × 删除，长按整条也可删除').fontSize(FONT_TAG).fontColor(Theme.subText())
    }
    .width('100%')
    // 左右边距由外层滚动容器统一给，这里不再重复加，否则两处各 16 会变成 32
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 统一加载态：居中 32 号 LoadingProgress + 13 号说明。
   * 空态同款结构（圆形图标位 + 13 号副标题）在 build() 的两处空态里就地写，
   * 因为它们各自还要多带一行语法提示 / 一个重试按钮。
   */
  @Builder
  private loadingBlock(label: string) {
    Column({ space: 10 }) {
      LoadingProgress().width(LOADING_SIZE).height(LOADING_SIZE).color(Theme.subText())
      Text(label).fontSize(FONT_META).fontColor(Theme.subText())
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  // ------------------------------------------------------------ 顶栏输入框与按钮的底
  /*
   * 上一轮踩过的两个坑，这里一次说清（结论写在后面，别再回退）：
   *
   *  1. `.background(builder)` 里放 MaterialPlane：真机上**完全透明**。材质挂在 Navigation
   *     的 title 作用域上，只有它作为**真实布局节点**参与合成时系统才创建那层材质；
   *     塞进 background 之后它只是一条「背景绘制指令」，连降级实底都不会画。
   *  2. 宽度由文字撑开时不能包 Stack：MaterialPlane 内部是 width('100%')，父宽不确定时
   *     会被解析成「父容器剩余宽度」，反过来把 Stack 撑满整行，右边几颗被挤出屏幕。
   *     上一版正是因此退成了「半透明白 + backgroundBlurStyle」，观感是一块灰板，不是材质。
   *
   * 现在的做法：**给按钮固定宽度**，父宽就确定了，于是可以正常用
   * `Stack { MaterialPlane(...) ; 内容 }`。宽度只是从「自适应」变成常量，
   * 高度、内边距、间距、右对齐关系全部保持原值，位置一格不动。
   */

  /**
   * 「筛选」按钮的前景色：有生效条件时用主色。
   *
   * 两个分支同值：读 themeDark 只是为了让本节点与 AppStorage 建立依赖（Theme 读的是
   * 不可观测的 Prefs），否则切主题后这行字色会停在旧主题上。
   */
  private filterFg(): string {
    if (this.themeDark) {
      return this.filterCount() > 0 ? Theme.accent() : Theme.subText();
    }
    return this.filterCount() > 0 ? Theme.accent() : Theme.subText();
  }

  /**
   * 内嵌搜索钮的底色：无输入 → 40% 主色（`#66` 前缀），有输入 → 实色主色。
   *
   * 为什么用 '66' 前缀而不是 .opacity(0.4)：opacity 作用在整颗按钮上，会把里面的白色
   * 「搜索」二字一起淡掉，无输入态看起来像按钮被禁用（字也发灰）；只给底色补 alpha，
   * 字始终是白的，传达的是「现在按下也没什么可搜」而不是「这颗按钮坏了」。
   *
   * Theme.accent() 是 '#RRGGBB'，补两位 alpha 拼成 '#AARRGGBB'（ArkUI 认这种写法）。
   * 只取后 6 位：万一以后 Theme 换成带 alpha 的 8 位写法，这里也不会拼出 10 位的非法色值。
   * 两个分支同值读 themeDark，同 filterFg() 只为建立重绘依赖。
   */
  private searchBtnBg(): ResourceColor {
    const c: string = this.themeDark ? Theme.accent() : Theme.accent();
    const hex: string = c.startsWith('#') ? c.substring(1) : c;
    const rgb: string = hex.length > 6 ? hex.substring(hex.length - 6) : hex;
    return (this.keyword.trim().length > 0 ? '#FF' : '#66') + rgb;
  }

  /**
   * 顶栏「回到顶部」圆钮：标题行右侧，**在「清空 / 筛选」的左边**。
   *
   * 为什么是往左插而不是往右：这一行是右对齐的固定尾巴，「清空 / 筛选」贴着内容右边距 16
   * 是最重要的动作终点，位置不能动；回顶是辅助动作，只能顺着往左排（间距仍是 8）。
   * 行本身没有 space，所以这里的 margin(right: 8) 就是它与右边那颗之间的缝
   * （「清空」自己只有 margin-right 8，是给「筛选」的缝）。
   *
   * 显隐不用 if 增删：始终挂载，只改 opacity / translate，160ms 才有过渡落点；
   * 代价是常占 32 宽，标题（两个字）完全吃得消。
   */
  @Builder
  private backToTopBtn() {
    Stack({ alignContent: Alignment.Center }) {
      MaterialPlane({ kind: 'header', radius: PILL_RADIUS, planeHeight: TOP_BTN_SIZE })
      SymbolGlyph($r('sys.symbol.arrow_up'))
        .fontSize(16)
        .fontColor([Theme.text()])
    }
    .width(TOP_BTN_SIZE)
    .height(TOP_BTN_SIZE)
    .borderRadius(PILL_RADIUS)
    // 白边 + 接触阴影画在这层不裁切的 Stack 上：材质自己 clip 圆角，边画在裁切路径上
    // 会被削掉外侧半条；与「清空 / 筛选」用同一份 Theme.btnEdge / Theme.floatShadow。
    .border({ width: 0.7, color: Theme.btnEdge() })
    .shadow(Theme.floatShadow())
    .margin({ right: GAP_SM })
    .opacity(this.topBtnShown() ? 1 : 0)
    .translate({ y: this.topBtnShown() ? 0 : TOP_BTN_SHIFT })
    .animation({ duration: TOP_BTN_ANIM, curve: Curve.Friction })
    // **不可见时必须关掉命中测试**：opacity 0 的节点仍然占位、仍然吃点击，
    // 顶栏里就会留一块「透明但点得到」的死区，点它还会把列表弹回顶部（鬼按钮）。
    // 可见时用 Transparent：贴在顶栏上的横滑 / 下拉手势仍要能穿透这一颗。
    .hitTestBehavior(this.topBtnShown() ? HitTestMode.Transparent : HitTestMode.None)
    .onClick(() => this.backToTop())
  }

  /**
   * 固定顶栏（与首页同一套写法）：材质压在内容上，内容从它下面滚过。
   * 第一行只有标题与右侧「清空 / 筛选」（副标题已删），第二行是胶囊搜索框；
   * 两行之间、以及搜索行到材质下沿，各留 HEADER_GAP 的呼吸。
   */
  @Builder
  private headerBar() {
    // hairline 按需：只有结果列表真的顶到顶栏下沿才画这条 0.5vp 的灰线
    MaterialSurface({
      surfaceHeight: this.headerHeight()
    }) {
      Column() {
        Row() {
          // 标题下原来还有一行「站点名 · 当前关键词」的副标题，已整行删除（含它下面那 1vp 的间距）：
          // 站点名在设置页选、关键词就在下面输入框里，这行不提供任何新信息，却把标题行
          // 顶到 56 高，还让「搜索」读起来像一张卡片的主标题而不是页面标题。
          // 删掉之后这一行只剩一个 22 号字，标题行才收得到 48（见 BAR_ROW_HEIGHT）。
          //
          // layoutWeight(1) 必须保留：标题要把剩余宽度整个吃掉，右侧「清空 / 筛选」才贴得住
          // 内容右边距那 16；不给权重的话 Row 会按内容宽度从左排，两颗按钮会跟着标题跑。
          Text('搜索')
            .fontSize(FONT_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text())
            .maxLines(1)
            .layoutWeight(1)

          // 回到顶部：插在「清空 / 筛选」左边（顺序理由见 backToTopBtn 的注释）
          this.backToTopBtn()

          // 「清空」只在结果态出现：与「筛选」同一套 Stack + MaterialPlane 材质，高 32。
          // 文字同样铺满整块（所以整块 60×32 都可点，点击冒泡到 Stack）。
          // 位置仍是「筛选」左侧，右间距 8 保持不变。
          if (this.inResult()) {
            Stack({ alignContent: Alignment.Center }) {
              // 不再传 edge: true —— 材质自带的描边取 Theme.edge()（浅色是 20% 黑），
              // 而顶栏这一排浮起控件要的是白边（btnEdge）。白边与投影统一画在外层 Stack 上，
              // 那一层不裁切，0.7 的发丝线才不会被材质自己的圆角 clip 削掉半条。
              MaterialPlane({
                kind: 'header',
                radius: PILL_RADIUS,
                planeHeight: CLEAR_PILL_HEIGHT
              })
              Text('清空')
                .width('100%')
                .height(CLEAR_PILL_HEIGHT)
                .fontSize(FONT_CAPTION)
                // 与右边「筛选」**同一个表达式**：两颗按钮同排、同材质，字色一旦不同
                // （一个恒为主色、一个无筛选时转次色）就会被读成两种不同权重的控件。
                // filterFg() 已经带了 themeDark 依赖，切主题时这行字会一起重绘。
                .fontColor(this.filterFg())
                .fontWeight(FontWeight.Medium)
                .textAlign(TextAlign.Center)
                .maxLines(1)
            }
            .width(BTN_W_CLEAR)
            .height(CLEAR_PILL_HEIGHT)
            // 白边 + 接触阴影：它与「筛选」「搜索胶囊」「语言组」同属顶栏里浮在材质上的小块，
            // 四处用同一份 Theme.btnEdge / Theme.floatShadow，深浅色下才是同一种控件。
            // 边画在这层（Stack 不 clip），圆角只用于描边，不参与裁切。
            .borderRadius(PILL_RADIUS)
            .border({ width: MATERIAL_EDGE_WIDTH, color: Theme.btnEdge() })
            .shadow(Theme.floatShadow())
            .margin({ right: GAP_SM })
            .onClick(() => this.clearSearch())
          }

          // 筛选入口：有生效条件时显示「筛选·N」并高亮，一眼能看出结果被过滤过。
          //
          // 为什么放在标题行最右：整行是右对齐的（标题列 layoutWeight(1) 吃掉剩余宽度），
          // 最右就是视觉的「动作终点」；它也是这一行里最重要的常驻动作（「清空」只在结果态
          // 出现），贴住内容右边距 16 才与下面那颗搜索胶囊的右边缘、卡片列表的右边缘同一条线。
          //
          // 材质：固定宽 76 的 Stack + MaterialPlane（真布局节点），文字铺满整块盖在上面
          // 并透明、无自己的底 —— 底的观感完全交给材质层。
          // 宽度恒定是这里的关键：文字在「筛选」和「筛选·9」之间变化时只截断、不回弹，
          // 否则材质层会跟着一起伸缩（Navigation title 作用域按父宽创建）。
          Stack({ alignContent: Alignment.Center }) {
            // 与「清空」同一套：材质不开 edge（那是 Theme.edge() 的黑边），
            // 白边与投影由下面外层 Stack 给，两颗并排才不会出现一白一黑两种边。
            MaterialPlane({
              kind: 'header',
              radius: PILL_RADIUS,
              planeHeight: CLEAR_PILL_HEIGHT
            })
            Text(this.filterCount() > 0 ? '筛选·' + this.filterCount().toString() : '筛选')
              .width('100%')
              .height(CLEAR_PILL_HEIGHT)
              // 左右 8 而不是 12：76 里要放下「筛选·9」又不想靠缩字号去挤
              .padding({ left: 8, right: 8 })
              .fontSize(FONT_CAPTION)
              .fontColor(this.filterFg())
              .fontWeight(this.filterCount() > 0 ? FontWeight.Medium : FontWeight.Normal)
              .textAlign(TextAlign.Center)
              .maxLines(1)
              // 超长就省略号，宽度绝不跟着文字回弹
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width(BTN_W_FILTER)
          .height(CLEAR_PILL_HEIGHT)
          // 与「清空」完全同一份边与阴影（同一宽度、同一档投影）：两颗并排，
          // 任一处不一致都会被读成两种不同权重的控件。
          .borderRadius(PILL_RADIUS)
          .border({ width: MATERIAL_EDGE_WIDTH, color: Theme.btnEdge() })
          .shadow(Theme.floatShadow())
          .onClick(() => {
            // 每次打开面板都清一次跳页提示：上次「输入非法」的红字不该留到这一次
            this.jumpHint = '';
            this.filterOpen = true;
          })
        }
        .width('100%')
        .height(BAR_ROW_HEIGHT)
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING })

        Row() {
          // 胶囊搜索框：高 40、全圆角，底是 panel 材质的**真实布局节点**（MaterialPlane）。
          //
          // 为什么包 Stack：MaterialPlane 只有参与布局时才会创建材质作用域，
          // 挂在 .background(builder) 上的那份在真机上是完全透明的。
          // Stack 的宽度由 layoutWeight(1) 确定（父 Row 有明确宽度），MaterialPlane 的
          // width('100%') 才有落点。
          //
          // 为什么搜索钮从「右边另一颗胶囊」改成**内嵌**：原来两颗 40 高的胶囊并排、中间还夹
          // 8 的缝，读起来是「输入区 + 另一个控件」；内嵌之后整行只有一颗胶囊（与评论输入框
          // 同一套写法），并且原来被按钮独占的 88 全部还给了输入区 —— 长关键词能多看到七八个字。
          Stack({ alignContent: Alignment.Center }) {
            // 不再传 edge: true —— 材质自带的描边是 Theme.edge()（浅色 20% 黑），
            // 而整颗胶囊要的是白边。白边与投影改画在外层 Stack 上（见下面的属性），
            // 那一层不裁切，边才不会被材质自己的圆角削掉半条。
            MaterialPlane({
              kind: 'panel',
              radius: PILL_RADIUS,
              planeHeight: FIELD_HEIGHT
            })
            // 胶囊内的两段：左边吃掉剩余宽度，右边是固定高度的搜索钮，纵向都居中
            Row() {
              TextInput({ text: this.keyword, placeholder: '关键词 / artist:xxx / female:xxx$' })
                .layoutWeight(1)
                .height(FIELD_HEIGHT)
                .fontSize(FONT_META)
                .fontColor(Theme.text())
                .placeholderColor(Theme.subText())
                // 输入框自身必须透明：否则它自己的底色会把下面那层材质整块盖住
                .backgroundColor(Color.Transparent)
                .borderRadius(PILL_RADIUS)
                // 右边 8 而不是 16：紧邻的是一颗有实底的按钮，两者之间不需要再留一段空白
                .padding({ left: 16, right: 8 })
                .enterKeyType(EnterKeyType.Search)
                .onChange((v: string) => {
                  // 只有「无字 → 有字 / 有字 → 无字」这一次跨越才需要换色动画。
                  // 不逐字 animateTo：打字时联想、历史、列表都在同一帧更新，把它们一起拖进
                  // 动画上下文只会白烧帧，而按钮颜色在这条边界内部本来就不变。
                  const had: boolean = this.keyword.trim().length > 0;
                  const has: boolean = v.trim().length > 0;
                  if (had !== has) {
                    animateTo({ duration: SEARCH_BTN_ANIM, curve: Curve.Smooth }, () => {
                      this.onKeywordChange(v);
                    });
                  } else {
                    this.onKeywordChange(v);
                  }
                })
                .onFocus(() => {
                  this.focused = true;
                })
                .onBlur(() => {
                  this.focused = false;
                })
                .onSubmit(() => {
                  this.submit(this.keyword);
                })

              // 内嵌搜索钮：高 32、左右 12、全圆角，白字 + 主色底。
              //
              // 为什么不再套 MaterialPlane：它就压在同一颗胶囊的玻璃上，再加一层材质会得到
              // 两圈几乎重合的描边（真机上读作「边缘发脏」），而且这一圈小面积的玻璃本来
              // 也没有内容可模糊。按钮的「底」由状态色直接给出。
              Text('搜索')
                .height(SEARCH_BTN_H)
                .padding({ left: SEARCH_BTN_PAD, right: SEARCH_BTN_PAD })
                .fontSize(FONT_CAPTION)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
                .textAlign(TextAlign.Center)
                .maxLines(1)
                .borderRadius(PILL_RADIUS)
                // 无输入 → 40% 主色，有输入 → 实色主色（160ms 由 onChange 的 animateTo 给出）
                .backgroundColor(this.searchBtnBg())
                // 右侧 4：999 圆角的胶囊在右端收得很急，贴边会让按钮的一角落到弧线外
                .margin({ right: SEARCH_BTN_INSET })
                .onClick(() => this.submit(this.keyword))
            }
            .width('100%')
            .height(FIELD_HEIGHT)
            .alignItems(VerticalAlign.Center)
          }
          .layoutWeight(1)
          .height(FIELD_HEIGHT)
          // 白边 + 接触阴影挂在这层 Stack 上（不是材质层）：
          //  1. 材质层自己 clip(radius)，边画在那儿会被裁掉外侧半条；
          //  2. Stack 不 clip，0.7 的发丝线与那圈淡阴影都能完整画出来。
          // 圆角只用来给描边定形，不参与裁切；内容本身由里层 MaterialPlane / Scroll 各管各的。
          .borderRadius(PILL_RADIUS)
          .border({ width: MATERIAL_EDGE_WIDTH, color: Theme.btnEdge() })
          .shadow(Theme.floatShadow())
        }
        .width('100%')
        // 56 = 上呼吸 6 + 字段 40 + 下呼吸 10（见 SEARCH_ROW_HEIGHT）
        .height(SEARCH_ROW_HEIGHT)
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: HEADER_GAP, bottom: SEARCH_GAP_BOTTOM })
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      // 顶部避让状态栏：沉浸式下内容铺到状态栏下面，标题要躲开它
      .padding({ top: this.statusBar() })
      .alignItems(HorizontalAlign.Start)
    }
  }

  build() {
    // 顶栏是一层压在内容上的沉浸材质：内容从它下面滚过才有东西可模糊。
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.imgSearching) {
        Column() {
          this.loadingBlock('正在以图搜图…')
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.headerHeight() })
      } else if (this.imgResults.length > 0 || this.imgError.length > 0) {
        Column() {
          Row() {
            Text('以图搜图结果 · ' + this.imgResults.length.toString() + ' 条')
              .fontSize(FONT_CAPTION)
              .fontColor(Theme.subText())
            Blank()
            Text('清除')
              .fontSize(FONT_CAPTION)
              .fontColor(Theme.accent())
              .onClick(() => {
                this.imgResults = [];
                this.imgError = '';
              })
          }
          .width('100%')
          .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 4, bottom: 6 })

          if (this.imgError.length > 0) {
            // 图搜失败是可重试的空态：图标位 + 13 号副标题 + 次要按钮
            Column({ space: 10 }) {
              Column() {
                Text('图').fontSize(20).fontColor(Theme.subText())
              }
              .width(EMPTY_ICON)
              .height(EMPTY_ICON)
              .borderRadius(PILL_RADIUS)
              .backgroundColor(Theme.card())
              .justifyContent(FlexAlign.Center)

              Text(this.imgError)
                .fontSize(FONT_META)
                .fontColor(Theme.subText())
                .textAlign(TextAlign.Center)
                .padding({ left: 32, right: 32 })

              Text('重新选图')
                .fontSize(FONT_META)
                .fontColor(Theme.accent())
                .height(EMPTY_BUTTON_HEIGHT)
                .padding({ left: 24, right: 24 })
                .textAlign(TextAlign.Center)
                .borderRadius(EMPTY_BUTTON_RADIUS)
                .backgroundColor(Theme.card())
                .onClick(() => {
                  this.imgError = '';
                  this.pickImage();
                })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            List({ space: GAP_SM }) {
              ForEach(this.imgResults, (g: Gallery) => {
                ListItem() {
                  GalleryCard({
                    g: g,
                    listStyle: this.listStyle,
                    onTap: (item: Gallery) => this.onOpen(item)
                  })
                }
              }, (g: Gallery) => 'img-' + g.gid + g.token)
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ left: 10, right: 10 })
            // 与搜索结果同一个口径：留白补在内容末尾而不是压缩视口，最后一张卡能完整滑出来
            .contentEndOffset(galleryBottomInset())
            .scrollBar(BarState.Off)
          }
        }
        .width('100%')
        .height('100%')
        // 与结果列表同一个让位口径：以图搜图结果这一段的清单行同样不能贴着顶栏。
        // 这里的顶部让位写在容器上而不是 List 的 contentStartOffset 上 —— List 前面还有
        // 一行「结果数 / 清除」的说明行，再给 List 补一份 offset 会变成两段空白。
        .padding({ top: this.listTopInset() })
        .alignItems(HorizontalAlign.Start)
      } else if (this.url.length === 0) {
        // 还没搜索：历史 / 使用提示都在滚动区里，
        // 顶部让位写在内容自己的 padding 上（不是 Scroll 的 padding），
        // 这样往上滚时这一段会滚到顶栏下面去，材质才透得出内容。
        // 顶栏下原本还有一行「快捷搜索」chip，按用户要求整块移除（不是折叠、不是隐藏）：
        // 它的入口价值低、又占掉初始态最上面的一条，删掉后历史自然上移成为第一块内容。
        Scroll() {
          Column({ space: GAP_SM }) {
            // 历史只在初始态出现：一旦提交过搜索（有结果）就不再露出
            if (this.history.length > 0 && !this.submitted) {
              this.historyBlock()
            } else {
              Column({ space: 10 }) {
                Column() {
                  Text('搜').fontSize(20).fontColor(Theme.subText())
                }
                .width(EMPTY_ICON)
                .height(EMPTY_ICON)
                .borderRadius(PILL_RADIUS)
                .backgroundColor(Theme.card())
                .justifyContent(FlexAlign.Center)

                Text('输入关键词开始搜索').fontSize(FONT_META).fontColor(Theme.subText())

                Text('支持 EH 高级语法，例如\nfemale:stockings$\n-language:chinese\nartist:"some artist"')
                  .fontSize(FONT_TAG)
                  .fontColor(Theme.subText())
                  .textAlign(TextAlign.Center)
              }
              .width('100%')
              // Scroll 里的子节点不能靠 layoutWeight 居中（高度无界），改用固定的上边距。
              // 64 = 原来的 72 减去外层新加的 8：外层已经给了 CARD_TOP_GAP 的呼吸，
              // 这里不再叠一份，空态与「最近搜索」首块相对顶栏的位置保持一致。
              .padding({ top: 64 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({
            left: PAGE_PADDING,
            right: PAGE_PADDING,
            // 顶栏高度 + 首行呼吸（CARD_TOP_GAP）：删掉「快捷搜索」那一行之后，最先出现的是
            // 「最近搜索」的标题，只让到 headerHeight() 会让它贴着顶栏下沿。呼吸只加在这一个
            // 入口（外层容器），历史块与空态里不再各补一份；口径与列表态的 listTopInset() 一致。
            top: this.headerHeight() + CARD_TOP_GAP,
            // Scroll 不支持 contentEndOffset，只能靠 padding 让位；数值仍取同一个口径，
            // 否则初始态里历史的最后一行也会被底栏盖住
            bottom: galleryBottomInset()
          })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      } else {
        Column() {
          // 搜索结果是「无限滚动」：不再有页码条，往下滑就到下一页（append）。
          // 下一页地址**跟随站点给的 #unext 游标**（列表内部 next 优先），pageUrlOf 只作兜底 ——
          // 搜索接口的 page 偏移不可靠，自己拼 page=1/2/3 会拿回同一批结果。
          // 页码相关的入口只剩筛选面板里那一行（jumpRow，在「高级选项」之后，随内容滚动）。
          // pager: false 关掉列表自带的分页提示行，避免与 endless 的底部状态行叠在一起。
          GalleryListView({
            requestUrl: this.url,
            emptyHint: '没有找到结果',
            onOpen: (g: Gallery) => this.onOpen(g),
            // 首行留 8 的呼吸（与首页同一口径），否则第一张卡会贴住顶栏下沿
            topInset: this.listTopInset(),
            // 底部让位与首页同一个口径（底栏 56 + 离底 4 + 导航条 + 呼吸 10）。
            // 原来这里在外层 Column 上写 padding bottom 80：既比真实遮挡高度短，
            // 又把列表视口整体截短，所以最后一张卡总有一截卡在底栏下面。
            bottomInset: galleryBottomInset(),
            pager: false,
            endless: true,
            reloadTick: this.reloadSeq,
            pageUrlOf: (step: number): string => this.pageUrlFor(step),
            // 回顶通道：只有这一态（有结果列表）接，初始态 / 图搜态不接 → listScrollY 保持 0
            showTopHint: true,
            onScrollOffset: (y: number) => this.setListScrollY(y),
            scrollToTopTick: this.topTick
          })
            .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
      }

      // 建议面板是输入时的浮层，不是滚动内容：紧贴搜索框下沿浮在内容之上。
      // 只在「有焦点 + 有字 + 还没提交」时出现；提交或失焦后立刻收起。
      if (this.focused && !this.submitted && this.keyword.trim().length > 0
        && this.showSuggest && this.suggestions.length > 0) {
        Column() {
          this.suggestPanel()
        }
        .width('100%')
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING })
        .margin({ top: this.headerHeight() + 4 })
      }

      // 顶栏最后画：Stack 里越靠后越在上，材质才盖在滚动内容之上
      this.headerBar()
    }
    .width('100%')
    .height('100%')
    // 筛选面板：模态底部面板，打开时页面不滚、键盘不弹（内容里的输入框才会唤键盘）。
    // 用 $$ 双向绑定：用户往下拖动关闭时状态能自动回 false，否则下次点「筛选」打不开。
    .bindSheet($$this.filterOpen, this.filterSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.card()
    })
  }
}
