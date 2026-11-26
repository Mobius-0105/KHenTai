import { Gallery, GalleryTag } from '../core/Models';
import { Theme } from '../core/Theme';
import { Tokens } from '../core/Tokens';
import { Motion } from '../core/Motion';
import { Namespaces } from '../core/Consts';
import { Prefs } from '../core/Prefs';
import { TagTrans } from '../core/TagTrans';

/**
 * 列表样式常量，取值与 Prefs 的 'list_style' 一一对应。
 *
 * 放成常量类而不是散落的字符串字面量：设置页、列表页、卡片三处都要比对同一个值，
 * 拼错一个字母会静默退化成 compact，很难查。
 */
export class ListStyles {
  static readonly MINIMAL: string = 'minimal';
  static readonly COMPACT: string = 'compact';
  static readonly EXTENDED: string = 'extended';
  static readonly THUMBNAIL: string = 'thumbnail';

  /**
   * 早期版本把封面墙存成 'thumb'，而 Prefs 的默认值现在还是 'thumb'。
   * 统一在这里翻译，老用户的设置不会失效，调用方也不用各自判两遍。
   */
  static normalize(raw: string): string {
    if (raw === ListStyles.MINIMAL || raw === ListStyles.COMPACT ||
      raw === ListStyles.EXTENDED || raw === ListStyles.THUMBNAIL) {
      return raw;
    }
    if (raw === 'thumb') {
      return ListStyles.THUMBNAIL;
    }
    return ListStyles.COMPACT;
  }
}

/**
 * 详细（extended）卡片的几何量：逐项照抄 JHenTai，不再按我们自己的预算表推。
 *
 * 数值来源：
 *  - `ui_config.dart:192-205`：galleryCardHeight 200 / galleryCardHeightWithoutTags 125 /
 *    galleryCardCoverWidth 140 / galleryCardCoverWidthWithoutTags 85 / galleryCardTitleSize 15 /
 *    galleryCardTextSize 12 / galleryCardTagsHeight 70 / galleryRatingStar*Color；
 *  - `eh_gallery_list_card_.dart:83-140`：Row(封面 + Expanded 信息列)、内边距 6/10/6/5、
 *    Column 的 SpaceBetween 三段（Header / 标签 / Footer）；
 *  - `eh_tag.dart:120-131`：chip 水平内边距 6、垂直 3、圆角 8、字号 12。
 */
const EXT_CARD_H: number = 200;
const EXT_CARD_H_NO_TAGS: number = 125;
const EXT_COVER_W: number = 140;
const EXT_COVER_W_NO_TAGS: number = 85;
const EXT_TITLE_SIZE: number = 15;
const EXT_TEXT_SIZE: number = 12;
/** 标题 height: 1.2（ui_config 的 galleryCardTitleSize × 1.2 = 18），两行正好 36 */
const EXT_TITLE_LINE: number = 18;
/** 卡片圆角 15 + 阴影 blur 3 / offset(2,2)（eh_gallery_list_card_.dart:63-81 的 round 卡片） */
const EXT_RADIUS: number = 15;
/** 星级：RatingBar itemSize 16（eh_gallery_list_card_.dart:231），五颗之间留 1 的呼吸 */
const EXT_STAR_SIZE: number = 16;
const EXT_STAR_GAP: number = 1;

/**
 * 标签区：高度 70、3 行、行距 4、列距 4（`eh_gallery_list_card_.dart:179-190`）。
 *
 * 为什么高度必须写死：标签条是**横向 Scroll**，子节点在主轴上拿到无限约束，
 * 高度是唯一能把「3 行」框住的量；让内容自撑的话标签一多卡片就会无限长高。
 */
const EXT_TAGS_H: number = 70;
const EXT_TAGS_ROWS: number = 3;
const EXT_TAGS_GAP: number = 4;

/**
 * 单个 chip 的高度。
 *
 * JHenTai 的 EHTag 自己是 24 高（`eh_tag.dart:121`），但卡片里标签区只有 70 高、
 * crossAxisCount=3、行距 4 —— SliverWaterfallFlow 给每格的**交叉轴**约束是
 * (70 - 4×2) / 3 ≈ 20.7，Container 的 height:24 会被这条约束压下来。
 * 这里用同一个公式算，成品才和 JHenTai 一样；真写死 24 就是 3×24 + 8 = 80，
 * 超出 70 的那 10 只能把第三行裁掉半行字，反而更不像。
 */
const EXT_TAG_H: number = (EXT_TAGS_H - (EXT_TAGS_ROWS - 1) * EXT_TAGS_GAP) / EXT_TAGS_ROWS;
/** 单个 chip 的最大宽度：再长就省略，否则一句话的 other: 标签会把整列撑到屏幕外 */
const EXT_TAG_MAX_W: number = 110;

/** 星级配色（`ui_config.dart:492-496`）：普通星 amber.shade800、未评分星 outline 50% */
const EXT_STAR_COLOR: string = '#FF8F00';
const EXT_STAR_UNRATED_DARK: string = '#809AA0AA';
const EXT_STAR_UNRATED_LIGHT: string = '#806C727C';

/**
 * 把命名空间色转成 12% 透明的同色（chip 底色）。
 *
 * 为什么不用 `Color` 的 opacity：Text 的 backgroundColor 只能吃字符串色值，
 * 透明度必须写进 ARGB 的 alpha 字节；12% ≈ 0x1F。解析层有时给 3 位短色（#abc），
 * 这里一起展开，避免拼出 `#1Fabc` 这种非法值让整块底色失效。
 */
function tagTint(hex: string): string {
  let h: string = hex.trim();
  if (h.startsWith('#')) {
    h = h.substring(1);
  }
  if (h.length === 8) {
    h = h.substring(2);
  }
  if (h.length === 3) {
    h = h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2);
  }
  if (h.length !== 6) {
    return '#1F8E8E93';
  }
  return '#1F' + h.toUpperCase();
}

/**
 * 卡片里的标签顺序：已关注（state = gtw，站点染成橙底的那种）排最前，
 * 其余按 namespace 首次出现的顺序聚合 —— 同一个 namespace 的标签必然相邻。
 *
 * 为什么要自己排：解析层按 HTML 顺序给，一个画廊的标签是「female / male / artist …」
 * 交错出现的；直接铺开会让同色系标签散落各处，横向滚动时很难扫读。
 * JHenTai 在 `eh_gallery_list_card_.dart` 里只做了「已关注优先」，
 * 这里补上 namespace 聚合，两者合起来才是「一眼能读完」的顺序。
 */
function orderForCard(tags: GalleryTag[]): GalleryTag[] {
  const nsRank: Map<string, number> = new Map<string, number>();
  const idx: number[] = [];
  for (let i = 0; i < tags.length; i++) {
    if (!nsRank.has(tags[i].ns)) {
      nsRank.set(tags[i].ns, nsRank.size);
    }
    idx.push(i);
  }
  idx.sort((x: number, y: number): number => {
    const a: GalleryTag = tags[x];
    const b: GalleryTag = tags[y];
    const aw: number = a.state === 'gtw' ? 0 : 1;
    const bw: number = b.state === 'gtw' ? 0 : 1;
    if (aw !== bw) {
      return aw - bw;
    }
    const ar0: number | undefined = nsRank.get(a.ns);
    const br0: number | undefined = nsRank.get(b.ns);
    const ar: number = ar0 === undefined ? 99 : ar0;
    const br: number = br0 === undefined ? 99 : br0;
    if (ar !== br) {
      return ar - br;
    }
    // 同组保持解析顺序（sort 不保证稳定，用原始下标兜底）
    return x - y;
  });
  const out: GalleryTag[] = [];
  for (let k = 0; k < idx.length; k++) {
    out.push(tags[idx[k]]);
  }
  return out;
}

/**
 * 把排好序的标签按「行优先」切成最多 3 行。
 *
 * 为什么不再按列切：列宽只能取该列最宽 chip，短 chip 右侧就会留出一整块空白
 * （用户看到的「四处是空」就是它）。改成行优先后，同一行的 chip 首尾相接，
 * 相邻两个之间的间距恒为 EXT_TAGS_GAP；三行右端参差不齐但都左对齐，观感反而整齐。
 *
 * 分配算法：第 r 行取 `ceil(剩余数 / 剩余行数)`。这样
 *  - 每行至少 1 个（只要总数 ≥ 3，3 行一定都用上，不会出现第一行塞满、后两行空着）；
 *  - 又不至于前重后轻：6 个 → 2/2/2，7 个 → 3/2/2，9 个 → 3/3/3。
 * 总数 < 3 时行数就等于标签数（1 个标签硬拆 3 行没有意义）。
 */
function tagRows(tags: GalleryTag[]): GalleryTag[][] {
  const rows: GalleryTag[][] = [];
  const total: number = tags.length;
  if (total === 0) {
    return rows;
  }
  const rowCount: number = Math.min(EXT_TAGS_ROWS, total);
  let cursor: number = 0;
  for (let r = 0; r < rowCount; r++) {
    const remain: number = total - cursor;
    const remainRows: number = rowCount - r;
    const take: number = Math.ceil(remain / remainRows);
    const row: GalleryTag[] = [];
    for (let k = 0; k < take; k++) {
      row.push(tags[cursor + k]);
    }
    cursor += take;
    rows.push(row);
  }
  return rows;
}

/**
 * 去掉行文本里冗余的 `ns:` 前缀。
 *
 * 站点开「在缩略图里显示标签」时，`.gt` 框里的文本是 `female:stockings` 这种完整形式；
 * 列表行里命名空间已经由**颜色**表达了（同一色系自然聚在一起，见 orderForCard），
 * 再占宽度写一遍 `female:` 只会把中文译文挤成省略号。所以文案只留 key 那一段。
 * 文本为空时退回 key（解析层保证 key 非空）。
 */
function stripNsPrefix(t: GalleryTag): string {
  const raw: string = t.name.length > 0 ? t.name : t.key;
  const prefix: string = t.ns + ':';
  if (raw.startsWith(prefix)) {
    return raw.substring(prefix.length).trim();
  }
  return raw;
}

/**
 * 列表里的一张画廊卡片，按 listStyle 分成四种排布：
 *  - minimal   极简：44 缩略图 + 单行标题
 *  - compact   紧凑：96x132 封面 + 标题 + 分类/页数/评分
 *  - extended  详细：140x200（无标签 85x125）封面 + 右侧三段式信息列（标题/标签/页脚+星级），
 *              结构照抄 JHenTai 的 `buildGalleryCardInfo`
 *  - thumbnail 封面墙：纯封面，标题压在底部渐变上
 *
 * 为什么外层容器只有一个、内部用 if 分支：按压态/入场动画/卡片底板四种样式都要有，
 * 放在外层只写一遍；真正不同只有内层内容，用 @Builder 分开更好读。
 *
 * 封面直接用 `Image(url)`（EH 的缩略图在 ehgt.org 上公开可读，不需要 Cookie/Referer），
 * 省掉自己下载解码的一整套逻辑；失败时显示占位块，不会留白。
 */
@Component
export struct GalleryCard {
  g: Gallery = new Gallery();
  onTap: (g: Gallery) => void = (g: Gallery): void => {};
  /** 列表样式。必须 @Prop：设置页改完后同一张卡片要实时重排 */
  @Prop listStyle: string = ListStyles.COMPACT;
  /**
   * 标签库重绘信号（由 TagTransTick 维护的全局计数，列表页透传下来）。
   *
   * 为什么必须是 @Prop 而不是读 TagTrans.version：后者是普通静态字段，改了不会让组件重绘。
   * 卡片在 build 期读这个值（见 tagText），标签库 load 完成 / 翻译开关切换时父级把计数 +1，
   * 卡片才会重算 chip 文案。值本身不参与任何判断。
   */
  @Prop transTick: number = 0;
  /**
   * gdata 评分重绘信号（由 GalleryListView 的 metaTick 透传）。
   *
   * 为什么需要：`g` 是普通成员，后台把 `g.rating` 改成 4.5 不会让卡片重建；
   * 只有某个 @Prop/@State 变了才会。这里读一次它（见 rating()），
   * 列表每补到一批 +1，卡片就重算一次星星，和 transTick 是同一套机制。
   */
  @Prop metaTick: number = 0;
  @State private failed: boolean = false;
  /** 按下回弹：用 graphicsLayer 的 scale，不触发重新布局 */
  @State private pressed: boolean = false;
  /** 入场：首帧透明 + 下移 8vp，稍后归位（列表滚动加载时逐张出现） */
  @State private shown: boolean = false;

  aboutToAppear(): void {
    // 延迟一帧再归位，避免首帧就被合成为最终状态、看不到入场
    setTimeout(() => {
      this.shown = true;
    }, 16);
  }

  private isThumb(): boolean {
    return this.listStyle === ListStyles.THUMBNAIL || this.listStyle === 'thumb';
  }

  private isExtended(): boolean {
    return this.listStyle === ListStyles.EXTENDED;
  }

  /**
   * 详细卡是否有标签区。JHenTai 用它决定卡片高度 200/125、封面宽 140/85
   * （`eh_gallery_list_card_.dart:56,123-124`），我们的对应信号就是列表行里有没有标签。
   */
  private hasTags(): boolean {
    return this.g.tags.length > 0;
  }

  private extH(): number {
    return this.hasTags() ? EXT_CARD_H : EXT_CARD_H_NO_TAGS;
  }

  private extCoverW(): number {
    return this.hasTags() ? EXT_COVER_W : EXT_COVER_W_NO_TAGS;
  }

  /**
   * 卡片内边距：封面墙要贴满（封面自己就是卡片），详细卡也要贴满 ——
   * JHenTai 的封面是顶到卡片左/上/下边的，内边距只加在右侧信息列上（6/10/6/5）。
   * 极简 8、紧凑 12 保持不变。
   */
  private cardPadding(): number {
    if (this.isThumb() || this.isExtended()) {
      return 0;
    }
    return this.listStyle === ListStyles.MINIMAL ? Tokens.SPACE_SM : Tokens.SPACE_MD;
  }

  /**
   * 卡片圆角：详细卡取 JHenTai 的 15（eh_gallery_list_card_.dart:74），
   * 其它三种仍取 SPEC 的列表行 19 —— 只改 extended，不动另外三支。
   */
  private cardRadius(): number {
    return this.isExtended() ? EXT_RADIUS : Tokens.RADIUS_ROW;
  }

  /**
   * 卡片底色。
   *
   * 详细卡原来是「页面底色 + 阴影」把自己抬起来（JHenTai 的 surface + boxShadow）；
   * 现在去掉了阴影，靠阴影抬升的做法就不成立了 —— 底色改成**纯白**，
   * 让它以「一块白卡」的方式和页面底色分开。暗色主题没有纯白可用，
   * 仍取卡片色（否则白底 + 白字），这是唯一按主题分叉的地方。
   */
  private cardBg(): string {
    if (this.isThumb()) {
      return Theme.line();
    }
    if (this.isExtended()) {
      return Theme.isDark() ? Theme.card() : '#FFFFFF';
    }
    return Theme.card();
  }

  /**
   * 阴影：**全部取消**。
   *
   * 详细卡原先照抄 JHenTai 的 boxShadow（blur 3 / offset(2,2)），
   * 去掉阴影后卡片与页面的分离改由「纯白底色 + 圆角」承担，更干净。
   * 属性链里不能按分支省略，所以统一返回一个全透明、0 半径的空值。
   */
  private cardShadow(): ShadowOptions {
    return { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 };
  }

  /**
   * 已评分时的星色：JHenTai 用 colorScheme.error（ui_config.dart:496），
   * 本工程按约定换成主题强调色，与详情页那颗「已评分」提示同色。
   */
  private starColor(): string {
    return this.g.rated ? Theme.accent() : EXT_STAR_COLOR;
  }

  /** 未评分星色：outline 50%（ui_config.dart:494） */
  private starUnrated(): string {
    return Theme.isDark() ? EXT_STAR_UNRATED_DARK : EXT_STAR_UNRATED_LIGHT;
  }

  /**
   * 读评分（0~5）。
   *
   * 第一行的 metaTick 是**依赖声明**，值本身不参与运算：g 是普通成员，rating 变了不会
   * 触达卡片；build 期读一次 @Prop，列表补分后 metaTick 一变，整张卡就重建、星星跟着变。
   * 与 tagText() 里读 transTick 是同一个写法。
   */
  private rating(): number {
    if (this.metaTick < 0) {
      return 0;
    }
    return this.g.rating;
  }

  /** compact 用：页数 · 评分 · 上传者 挤在一行 */
  private metaLine(): string {
    const parts: string[] = [];
    if (this.g.pages > 0) {
      parts.push(this.g.pages.toString() + ' 页');
    }
    if (this.rating() > 0) {
      parts.push('★ ' + this.rating().toFixed(1));
    }
    if (this.g.uploader.length > 0) {
      parts.push(this.g.uploader);
    }
    return parts.join(' · ');
  }

  /**
   * chip 文案：翻译开关 + 标签库就绪 → 中文，否则回落原文（去掉 ns: 前缀）。
   *
   * 回退规则与 DetailPage.tagLabel 一致（译文为空串 = 没有译文，不当成空标签）：
   * TagTrans.translate 在「界面语言非中文 / 未命中」时都返回空串，这里据此回落。
   *
   * 第一行的 `this.transTick` 是**依赖声明**，不参与判断：TagTrans.version 是普通静态
   * 字段，卡片只有在 build 期读过某个 @Prop/@State 才会在它变化时重绘；列表页在
   * ensureLoaded() 完成与设置页开关切换后自增 tick，这里读一次就完成了订阅。
   */
  private tagText(t: GalleryTag): string {
    if (this.transTick >= 0 && Prefs.bool('tag_trans', false) && TagTrans.isReady()) {
      const zh: string = TagTrans.translate(t.ns, t.key);
      if (zh.length > 0) {
        return zh;
      }
    }
    return stripNsPrefix(t);
  }

  /**
   * 固定尺寸封面，失败退化成可点击的重试块。
   *
   * `leftOnly`：详细卡要「只圆左边两个角」。JHenTai 的封面是顶到卡片边缘的，
   * 圆角由外层 ClipRRect(15) 一次性裁出来（eh_gallery_list_card_.dart:76-79）；
   * 我们不给外层开 clip（否则会把自己那圈 3vp 阴影一起裁掉），所以改成封面自己
   * 按左圆右直来裁 —— 视觉等价，阴影也还在。
   */
  @Builder
  private cover(w: number, h: number, radius: number, leftOnly: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      if (!this.failed && this.g.thumbUrl.length > 0) {
        Image(this.g.thumbUrl)
          .width('100%')
          .height('100%')
          // contain 而不是 cover：EH 的封面规范是 250×350（0.714），和格子比例一致时两者相同；
          // 但遇到横构图封面时，cover 会裁掉左右，contain 是「宽铺满、按比例算高、上下留底色」，
          // 与 JHenTai 列表卡的 fitWidth 语义一致。宁可留一条底色，也不要把封面裁得认不出。
          .objectFit(ImageFit.Contain)
          .onError(() => {
            this.failed = true;
          })
      } else {
        // 加载失败：给一个可点的重试（对齐 JHenTai 的失败图标 + 点击重载）
        Column({ space: 4 }) {
          Text('!')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.subText())
          Text('点击重试')
            .fontSize(10)
            .fontColor(Theme.accent())
        }
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          // 复位后让 Image 重新请求（同 URL 会走图片库缓存，失败结果不会长期驻留）
          this.failed = false;
        })
      }
    }
    .width(w)
    .height(h)
    .borderRadius({
      topLeft: radius,
      topRight: leftOnly ? 0 : radius,
      bottomLeft: radius,
      bottomRight: leftOnly ? 0 : radius
    })
    .clip(true)
    .backgroundColor(Theme.line())
  }

  /** 分类色块 + 已删除标记，compact/extended 共用 */
  @Builder
  private catLine() {
    Row({ space: Tokens.SPACE_XS }) {
      // 胶囊按 SPEC 的 CHIP_RADIUS(8) + 8×4 内边距：10 号字配 8 的横边距刚好不夹字
      Text(this.g.categoryLabel)
        .fontSize(Tokens.FONT_TINY)
        .fontColor(Color.White)
        .padding({
          left: Tokens.SPACE_SM,
          right: Tokens.SPACE_SM,
          top: Tokens.SPACE_XS,
          bottom: Tokens.SPACE_XS
        })
        .borderRadius(Tokens.RADIUS_CHIP)
        .backgroundColor(this.g.categoryColor)
      if (this.g.expunged) {
        Text('已删除')
          .fontSize(Tokens.FONT_TINY)
          .fontColor('#FF8A8A')
          .padding({
            left: Tokens.SPACE_SM,
            right: Tokens.SPACE_SM,
            top: Tokens.SPACE_XS,
            bottom: Tokens.SPACE_XS
          })
          .borderRadius(Tokens.RADIUS_CHIP)
          .borderWidth(0.7)
          .borderColor('#66FF8A8A')
      }
    }
    .width('100%')
  }

  @Builder
  private minimalBody() {
    Row({ space: Tokens.SPACE_MD }) {
      // 44 是极简行的封面边长（同时也是最小可点击高度的下限），不是间距令牌，所以写字面量
      this.cover(44, 44, Tokens.RADIUS_THUMB, false)
      Text(this.g.title)
        .fontSize(Tokens.FONT_META)
        .fontColor(Theme.text())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    // 44 封面 + 上下各 8 内边距 = 60，比原 64 略紧一档，列表同屏能多露出一行
    .height(44)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private compactBody() {
    Row() {
      this.cover(96, 132, Tokens.RADIUS_THUMB, false)

      Column({ space: Tokens.SPACE_SM }) {
        Text(this.g.title)
          .fontSize(Tokens.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .lineHeight(Tokens.LINE_BODY)
          .fontColor(Theme.text())
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Blank()

        this.catLine()

        Text(this.metaLine())
          .fontSize(Tokens.FONT_TAG)
          .fontColor(Theme.subText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (this.g.posted.length > 0) {
          Text(this.g.posted)
            .fontSize(Tokens.FONT_TINY)
            .fontColor(Theme.subText())
            .width('100%')
        }
      }
      .layoutWeight(1)
      .height(132)
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: Tokens.SPACE_MD,
        right: Tokens.SPACE_XS,
        top: Tokens.SPACE_XS,
        bottom: Tokens.SPACE_XS
      })
    }
    .width('100%')
  }

  /**
   * 一个标签 chip，按 JHenTai 的 `EHTag` 复刻（eh_tag.dart:120-131）：
   * 高 24（受 70/3 的行高约束后 ≈20.7，见 EXT_TAG_H）、水平内边距 6 / 垂直 3、
   * 圆角 8、字号 12、单行省略。
   *
   * 文字取命名空间色，底色取同色 12% —— 去掉 `ns:` 前缀之后命名空间只剩颜色这一条线索
   * （见 stripNsPrefix），扫读时先靠颜色定位再读字。
   *
   * 用 Row 而不是 Text 承载内边距：JHenTai 是「Container(height 24) > Align(center) > Text」，
   * 24 高的框里文字是**垂直居中**的；Text 自己设 padding 时文字贴顶，第三行看起来会偏上。
   *
   * **不加 onClick**：整张卡片已经绑了「点进详情」，chip 再拦截点击会让卡片中部
   * 出现一片点不动的死区（JHenTai 的列表标签也是纯展示，点击交给外层卡片）。
   */
  @Builder
  private tagChipView(t: GalleryTag) {
    Row() {
      Text(this.tagText(t))
        .fontSize(EXT_TEXT_SIZE)
        // EHTag 的 Text 是 `height: 1`（eh_tag.dart:72）= 行高 1.0×字号；
        // 不写这行，默认行高（≈1.4×12=16.8）会撑出 chip 的内框（20.7-6=14.7），文字被上下切掉
        .lineHeight(EXT_TEXT_SIZE)
        .fontColor(Namespaces.of(t.ns).color)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 超长标签（例如 other: 下的一句话）截断即可，否则一列能宽到把整条标签带撑爆
        .constraintSize({ maxWidth: EXT_TAG_MAX_W })
    }
    .height(EXT_TAG_H)
    // JHenTai 的左右 6 是外层 Container 的 padding，垂直 3 由 24 高的框自己居中
    .padding({ left: 6, right: 6, top: 3, bottom: 3 })
    .borderRadius(Tokens.RADIUS_CHIP)
    .backgroundColor(tagTint(Namespaces.of(t.ns).color))
  }

  /**
   * 标签区：固定 70 高、横向可滚动的「3 行」布局。
   *
   * 结构：Scroll(横向) → Column(3 行) → Row(该行的 chip)。每行只有内容宽度（不写 100%），
   * 三行按 tagRows 的数量分配、全部左对齐；chip 之间只有 EXT_TAGS_GAP 的 4，
   * 不会再出现「列宽取最宽 chip」导致的大块右侧空白。
   *
   * 行宽不等是预期的：Column 的宽度取最宽那一行，短行右边自然空出（但那不是 chip 之间的空），
   * 视觉上就是左对齐、右端参差，与 JHenTai 横向 waterfall 的观感一致。
   */
  @Builder
  private tagStrip() {
    Scroll() {
      Column({ space: EXT_TAGS_GAP }) {
        ForEach(tagRows(orderForCard(this.g.tags)), (row: GalleryTag[], ri: number) => {
          Row({ space: EXT_TAGS_GAP }) {
            ForEach(row, (t: GalleryTag) => {
              this.tagChipView(t)
            }, (t: GalleryTag) => 'tag-' + t.ns + ':' + t.key)
          }
          .alignItems(VerticalAlign.Top)
        }, (row: GalleryTag[], ri: number) => 'row-' + ri.toString() + '-'
          + (row.length > 0 ? row[0].ns + ':' + row[0].key : 'empty'))
      }
      .height(EXT_TAGS_H)
      .alignItems(HorizontalAlign.Start)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    // 到边界不拉出回弹：卡片是个小格子，回弹会把内容从圆角里拽出去
    .edgeEffect(EdgeEffect.None)
    .width('100%')
    .height(EXT_TAGS_H)
  }

  /**
   * 页脚，照抄 `buildGalleryInfoFooter`（eh_gallery_list_card_.dart:197-223）：
   *   第一行：[分类 chip] [Blank] [收藏标记(若有)] [页数(若有)]
   *   SizedBox(height: 2)
   *   第二行：[五颗星] [Blank] [时间]
   *
   * 条件渲染与 JHenTai 的 `if (xx != null)` 一致：语言 / 阅读进度环 / 下载图标这些字段
   * 我们的列表行里根本没有，就**不画** —— 不为了「凑齐」伪造数据。
   */
  @Builder
  private extFooter() {
    Column({ space: 2 }) {
      Row() {
        Text(this.g.categoryLabel)
          .fontSize(Tokens.FONT_TINY)
          .fontColor(Color.White)
          .height(16)
          .lineHeight(16)
          .padding({ left: 5, right: 5 })
          .borderRadius(Tokens.RADIUS_SM)
          .backgroundColor(this.g.categoryColor)

        Blank()

        Row({ space: 4 }) {
          // 收藏标记：favcat 在列表行里解析不到就是 -1，此时不画（JHenTai 的 isFavorite）
          if (this.g.favcat >= 0) {
            SymbolGlyph($r('sys.symbol.heart_fill'))
              .fontSize(12)
              .fontColor([Theme.accent()])
          }
          // JHenTai 的 _buildPageCount：`${pageCount}P`
          if (this.g.pages > 0) {
            Text(this.g.pages.toString() + 'P')
              .fontSize(EXT_TEXT_SIZE)
              .fontColor(Theme.subText())
          }
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        this.ratingBar()

        Blank()

        Text(this.g.posted)
          .fontSize(EXT_TEXT_SIZE)
          .fontColor(Theme.subText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 被删除的画廊时间带删除线（JHenTai 的 isExpunged 处理）
          .decoration({
            type: this.g.expunged ? TextDecorationType.LineThrough : TextDecorationType.None
          })
      }
      .width('100%')
      .height(EXT_STAR_SIZE)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 五颗星（JHenTai `_buildRatingBar`，eh_gallery_list_card_.dart:225-239）：
   * itemCount 5、itemSize 16、allowHalfRating、ignoreGestures。
   *
   * ArkTS 没有 RatingBar，用 SymbolGlyph 拼。rating = 0 时五颗全是未评分色，
   * **不隐藏** —— JHenTai 的 RatingBar 也是这么显示的。
   */
  @Builder
  private ratingBar() {
    Row({ space: EXT_STAR_GAP }) {
      this.star(0)
      this.star(1)
      this.star(2)
      this.star(3)
      this.star(4)
    }
  }

  /**
   * 第 i 颗星（0 基）。
   *
   * 半星做法：底层永远画一颗**未评分色**的实心星；整颗达标就在上面叠一颗评分色实心星；
   * 半颗则叠一个宽度只有 8 的 Row，里面放同尺寸的评分色星，靠 `.clip(true)` 裁掉右半截。
   * 不用 star（空心）+ star_fill 叠：两个字形的重心与描边宽度不同，半颗的接缝会错位；
   * 同字形只做重叠 + 裁剪，中缝才严丝合缝。
   *
   * Stack 必须用 TopStart 对齐：半星那层只有 8 宽，居中会让它盖到星星的中缝上。
   */
  @Builder
  private star(i: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      SymbolGlyph($r('sys.symbol.star_fill'))
        .fontSize(EXT_STAR_SIZE)
        .width(EXT_STAR_SIZE)
        .height(EXT_STAR_SIZE)
        .fontColor([this.starUnrated()])

      if (this.rating() >= i + 1) {
        SymbolGlyph($r('sys.symbol.star_fill'))
          .fontSize(EXT_STAR_SIZE)
          .width(EXT_STAR_SIZE)
          .height(EXT_STAR_SIZE)
          .fontColor([this.starColor()])
      } else if (this.rating() >= i + 0.5) {
        Row() {
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(EXT_STAR_SIZE)
            .width(EXT_STAR_SIZE)
            .height(EXT_STAR_SIZE)
            .fontColor([this.starColor()])
        }
        .width(EXT_STAR_SIZE / 2)
        .height(EXT_STAR_SIZE)
        .clip(true)
      }
    }
    .width(EXT_STAR_SIZE)
    .height(EXT_STAR_SIZE)
  }

  /**
   * 详细卡主体，结构照抄 `buildFlatGalleryCard`（eh_gallery_list_card_.dart:83-140）：
   *   Row [ 封面 140x200（无标签 85x125） ] [ Expanded 信息列，padding 6/10/6/5 ]
   * 信息列是 Column + **SpaceBetween** 的三段：Header（标题 + 上传者）/ 标签 / Footer。
   *
   * 为什么必须 SpaceBetween：这正是 JHenTai 的排版逻辑 —— 标题短的时候页脚贴底，
   * 而不是所有内容从顶部往下堆（旧版那样做，标题一行时下半张卡是空的）。
   */
  @Builder
  private extendedBody() {
    Row() {
      // 封面高 = 卡片高；只圆左两角，右边与信息列相接（圆角由外层卡片 15 统一裁出）
      this.cover(this.extCoverW(), this.extH(), EXT_RADIUS, true)

      Column() {
        // ---------------- Header：标题 2 行 + 上传者
        Column() {
          Text(this.g.title)
            .fontSize(EXT_TITLE_SIZE)
            // height: 1.2（ui_config.dart:151），两行正好 36
            .lineHeight(EXT_TITLE_LINE)
            .fontColor(Theme.text())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          if (this.g.uploader.length > 0) {
            Text(this.g.uploader)
              .fontSize(EXT_TEXT_SIZE)
              .fontColor(Theme.subText())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              // JHenTai 这里是 marginOnly(top: 2)
              .margin({ top: 2 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ---------------- 标签：只有 withTags && tags 非空才挂载（dart:136）
        if (this.hasTags()) {
          this.tagStrip()
        }

        // ---------------- Footer
        this.extFooter()
      }
      .layoutWeight(1)
      .height(this.extH())
      // 三段式：Header 贴顶、Footer 贴底、中间标签区留白由 SpaceBetween 分配
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 6, right: 10, top: 6, bottom: 5 })
    }
    .width('100%')
    .height(this.extH())
  }

  @Builder
  private thumbBody() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (!this.failed && this.g.thumbUrl.length > 0) {
        Image(this.g.thumbUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .onError(() => {
            this.failed = true;
          })
      } else {
        Text(this.g.categoryLabel.substring(0, 2))
          .fontSize(Tokens.FONT_META)
          .fontColor(Theme.subText())
      }

      // 底部压一层黑渐变：封面可能是纯白图，不加渐变白字会读不出来
      Column() {
        Text(this.g.title)
          .fontSize(Tokens.FONT_CAPTION)
          .fontColor(Color.White)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .width('100%')
      .padding({
        left: Tokens.SPACE_SM,
        right: Tokens.SPACE_SM,
        top: Tokens.SPACE_XL,
        bottom: Tokens.SPACE_SM
      })
      .linearGradient({
        angle: 180,
        colors: [['#00000000', 0.0], ['#CC000000', 1.0]]
      })
    }
    .width('100%')
    // 1:1.4 竖版，宽高比 = 1 / 1.4（SPEC 的 THUMB_ASPECT 1.414 就是这个比例）
    .aspectRatio(0.714)
  }

  build() {
    Column() {
      if (this.isThumb()) {
        this.thumbBody()
      } else if (this.listStyle === ListStyles.MINIMAL) {
        this.minimalBody()
      } else if (this.listStyle === ListStyles.EXTENDED) {
        this.extendedBody()
      } else {
        this.compactBody()
      }
    }
    .width('100%')
    .padding(this.cardPadding())
    .borderRadius(this.cardRadius())
    // 底色按样式分支（详细卡 = 页面底色，见 cardBg 的注释）
    .backgroundColor(this.cardBg())
    // 没有阴影之后，详细卡也可以裁了：白卡 + 圆角 15，内容（含封面）必须被圆角裁住，
    // 否则封面直角会从圆角里探出来。
    .clip(true)
    // 阴影已全部取消（见 cardShadow 的注释）
    .shadow(this.cardShadow())
    // 按压回弹 0.97 + 入场（透明→1、下移 8→0）共用同一条 animation：
    // 时长/曲线取 Motion，按下与归位的心跳就与详情页转场保持同一套节奏。
    .scale({ x: this.pressed ? 0.97 : 1, y: this.pressed ? 0.97 : 1 })
    .opacity(this.shown ? 1 : 0)
    .translate({ y: this.shown ? 0 : Tokens.SPACE_SM })
    .animation({ duration: Motion.STATE_RESET, curve: Motion.standard })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressed = true;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => this.onTap(this.g))
  }
}

/** 标签小胶囊（详情页用） */
@Component
export struct TagChip {
  @Prop text: string = '';
  @Prop color: string = '#8E8E93';
  @Prop dim: boolean = false;

  build() {
    Text(this.text)
      .fontSize(Tokens.FONT_TAG)
      .fontColor(this.dim ? Theme.subText() : Color.White)
      .padding({
        left: Tokens.SPACE_SM,
        right: Tokens.SPACE_SM,
        top: Tokens.SPACE_XS,
        bottom: Tokens.SPACE_XS
      })
      .borderRadius(Tokens.RADIUS_CHIP)
      .backgroundColor(this.dim ? Theme.line() : this.color)
      .opacity(this.dim ? 1 : 0.92)
  }
}

/** 命名空间前缀标签（例如 “female:”） */
export function namespaceLabel(ns: string): string {
  return Namespaces.of(ns).label;
}
