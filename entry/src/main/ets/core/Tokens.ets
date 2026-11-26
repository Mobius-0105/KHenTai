/**
 * 设计令牌：间距 / 字号 / 圆角 / 关键尺寸。
 *
 * 来源：NextE docs/V2-UI-SPEC.md（该文档逐条摘录自 erosTeam/NextE 的
 * shared/src/main/ets/theme/ThemeConstants.ets，是这份工程的权威数值来源）。
 *
 * 为什么单独抽一个文件而不是塞进 Theme.ets：
 *  - Theme 只负责「颜色随深浅色变化」，它的成员是方法，因为取值必须发生在 build() 里；
 *  - 尺寸是常量，编译期就固定，混进 Theme 会让人误以为它们也跟随主题；
 *  - 页面/组件统一从这里取数，改一个数字全站生效，不会再出现 52/56/60 三种标题栏高度。
 *
 * 与 SPEC 的对应关系逐项标在注释里；SPEC 没给、但本工程已有的值（44 触摸区、32 页头动作按钮）
 * 单独放在文件末尾并注明来源是本工程约定，不要当成 SPEC 数值引用。
 */
export class Tokens {
  // ------------------------------------------------------------------ 间距（vp）
  // 来源：SPEC §3.2 SPACE_*（XS/SM/MD/LG/XL/XXL）
  static readonly SPACE_XS: number = 4;
  static readonly SPACE_SM: number = 8;
  static readonly SPACE_MD: number = 12;
  static readonly SPACE_LG: number = 16;
  static readonly SPACE_XL: number = 24;
  static readonly SPACE_XXL: number = 32;

  // ------------------------------------------------------------------ 字号（fp）
  // 来源：SPEC §3.3 FONT_SIZE_*（TINY/TAG/CAPTION/META/BODY/TITLE/HEADING/H2/H1/DISPLAY）
  static readonly FONT_TINY: number = 10;
  static readonly FONT_TAG: number = 11;
  static readonly FONT_CAPTION: number = 12;
  static readonly FONT_META: number = 13;
  static readonly FONT_BODY: number = 14;
  static readonly FONT_TITLE: number = 16;
  static readonly FONT_HEADING: number = 18;
  static readonly FONT_H2: number = 22;
  static readonly FONT_H1: number = 24;
  static readonly FONT_DISPLAY: number = 28;

  // 行高（fp）来源：SPEC §3.3 LINE_HEIGHT_TITLE / LINE_HEIGHT_BODY
  static readonly LINE_TITLE: number = 22;
  static readonly LINE_BODY: number = 20;

  // ------------------------------------------------------------------ 圆角（vp）
  // 来源：SPEC §3.5 RADIUS_*
  static readonly RADIUS_SM: number = 4;
  static readonly RADIUS_MD: number = 22;
  static readonly RADIUS_CARD: number = 24;
  static readonly RADIUS_ROUND: number = 999;
  // 来源：SPEC §3.5 专用圆角 LIST_ROW_RADIUS / CHIP_RADIUS / THUMB_RADIUS / DETAIL_COVER_RADIUS
  static readonly RADIUS_ROW: number = 19;
  static readonly RADIUS_CHIP: number = 8;
  static readonly RADIUS_THUMB: number = 8;
  static readonly RADIUS_DETAIL_COVER: number = 16;
  // 来源：SPEC §3.5 GALLERY_GRID_CARD_RADIUS（网格封面卡，保留给封面墙单独使用）
  static readonly RADIUS_GRID_CARD: number = 16;

  // ------------------------------------------------------------------ 关键尺寸（vp）
  // 来源：SPEC §3.6 同名令牌
  static readonly TITLE_BAR_HEIGHT: number = 56;
  static readonly FLOAT_BAR_HEIGHT: number = 56;
  static readonly FOOTER_HEIGHT: number = 48;
  static readonly BUTTON_HEIGHT: number = 46;
  static readonly SEARCH_FIELD_HEIGHT: number = 40;
  static readonly ACTION_HEIGHT: number = 36;
  static readonly LIST_CARD_HEIGHT: number = 204;
  static readonly GRID_MIN_WIDTH: number = 106;
  static readonly GRID_GAP: number = 6;
  static readonly SPLIT_MIN_WIDTH: number = 720;
  // 来源：SPEC §3.6 LIST_CARD_COVER_ASPECT（列表卡封面宽高比）
  static readonly COVER_ASPECT: number = 0.71;
  // 来源：SPEC §3.6 LOADING_SIZE / LOADING_SIZE_SMALL（大/小两个加载指示器）
  static readonly LOADING_SIZE: number = 32;
  static readonly LOADING_SMALL: number = 24;

  // ------------------------------------------------------------------ 本工程约定（非 SPEC）
  // 最小可点击区域：鸿蒙官方可达性建议 40~48vp，取 44 与 iOS HIG 对齐；
  // SPEC 里没有这个令牌，但 PageHeader 的返回键必须 >=44 才好在拇指区命中。
  static readonly TOUCH_MIN: number = 44;
  // 页头右侧动作按钮高度：SPEC 的 ACTION_HEIGHT 是 36，用在页头会顶满 56 高的栏；
  // 32 能让按钮与 16 号标题在视觉上居中对齐（本工程约定）。
  static readonly HEADER_ACTION_HEIGHT: number = 32;
}
