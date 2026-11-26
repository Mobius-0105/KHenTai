import { Categories, CategoryInfo } from './Consts';

/** 列表页里的一行画廊 */
export class Gallery {
  gid: string = '';
  token: string = '';
  title: string = '';
  url: string = '';
  thumbUrl: string = '';
  categoryLabel: string = '其他';
  categoryColor: string = '#8E8E93';
  uploader: string = '';
  posted: string = '';
  pages: number = 0;
  /** 0~5，0 表示没有评分 */
  rating: number = 0;
  /** 当前账号是否已评分 */
  rated: boolean = false;
  expunged: boolean = false;
  /** 收藏夹索引：-1 未收藏 */
  favcat: number = -1;
  /**
   * 列表行里的标签（extended 卡片的标签区用）。
   *
   * 为什么放在 Gallery 而不是只留在 GalleryDetail：列表页只有 HTML 这一份数据，
   * 详情页要再发一次请求才拿得到；而 EH 在「详细」列表布局里就把 `.gt/.gtl/.gtw`
   * 直接写在行内（JHenTai 的 `eh_gallery_list_card_.dart` 也正是从这里的 tags 渲染
   * 标签瀑布流）。站点没开「显示标签」时这里为空，卡片就不画标签区。
   */
  tags: GalleryTag[] = [];

  setCategory(raw: string): void {
    const info: CategoryInfo = Categories.of(raw);
    this.categoryLabel = info.label;
    this.categoryColor = info.color;
  }
}

/** 标签 */
export class GalleryTag {
  ns: string = '';
  key: string = '';
  /** 展示用（命名空间内的名字） */
  name: string = '';
  /** gt = 正常，gtl = 存疑，gtw = 争议 */
  state: string = 'gt';
  color: string = '#8E8E93';
}

/** 详情页 */
export class GalleryDetail {
  gallery: Gallery = new Gallery();
  japTitle: string = '';
  language: string = '';
  sizeText: string = '';
  parentUrl: string = '';
  visible: string = '';
  favCount: number = 0;
  ratingCount: number = 0;
  tags: GalleryTag[] = [];
  /** 缩略图分页链接（/s/ 单图页），按顺序拼好 */
  pageUrls: string[] = [];
  /**
   * 每页的缩略图地址，与 pageUrls **按下标一一对应**
   * （解析不到时放空串，宁可留洞也不能错位：网格第 i 格必须就是第 i 页）。
   */
  pageThumbs: string[] = [];
  /** 每页缩略图的精灵几何（与 pageUrls 同下标；没有就空对象） */
  pageTiles: ThumbTile[] = [];
  /** 缩略图总页数（分页加载用） */
  thumbPageCount: number = 1;
  /**
   * 详情页原始 HTML。
   * 评论、apikey/apiuid 都要从原始页面里抠，单独再请求一次不值当，
   * 所以随详情一起带出来（只在当前详情页存活期间有效，不写盘）。
   */
  rawHtml: string = '';
}

/**
 * 一屏缩略图（详情页 `?p=20` 这类分页请求的返回）。
 * 详情页网格要「图片 + 链接」两份数据，而阅读器/下载器只要链接，
 * 所以用一个小对象一起带出来，避免同一个页面被请求两次。
 */
/**
 * 一格缩略图：**精灵图 + 子矩形**。
 *
 * E-Hentai 现在把一屏（20 张）缩略图拼成一张长条精灵图，每个格子的 style 只描述自己的
 * 子矩形：`width:169px;height:300px;background:… url(SHEET) -169px 0 no-repeat`。
 * 所以 20 个格子天然共享同一个 sheet 地址 —— 之前「一屏同图」不是解析错了，
 * 是我们把「共享 sheet」当成了「每格独立图片」。
 */
export class ThumbTile {
  /** 对应的单图页（/s/…），用来和 urls 对齐 */
  page: string = '';
  /** 精灵图地址 */
  sheet: string = '';
  /** 子矩形在该图内的左上角 x（px，样式里的负偏移取绝对值） */
  x: number = 0;
  /**
   * 子矩形在该图内的左上角 y（px，同样取绝对值）。
   *
   * 为什么必须解析 y：sheet 不是永远单行。站点把一屏 20 格排成 2 行时，第 2 行
   * 的 background-position 是 `-0px -300px` 这种形式，只认 x 的话第二行整排都会
   * 被当成「第 1 行第 1 格」去裁 —— 表现出来是格子内容错位，而整图被压扁。
   */
  y: number = 0;
  /** 子矩形宽高（px） */
  w: number = 0;
  h: number = 0;
  /**
   * 整张精灵图的宽（= 同 sheet 所有格子的 max(x+w)）。
   *
   * 注意它只是**估算**：单位是样式里的 CSS px，站点给的 CSS 宽与图床实际像素
   * 可能不同倍率。渲染（DetailPage.spriteGeom）会优先用 Image.onComplete 实测的真实
   * 像素尺寸；这里只在实测还没到之前兜底，所以不要拿它当「图片真实宽度」使用。
   */
  sheetW: number = 0;
  /**
   * 整张精灵图的高（= 同 sheet 所有格子的 max(y+h)），同样是 CSS px 的估算值（见 sheetW）。
   *
   * 为什么不能用子矩形的 h：background-size 描述的是**整张图**的尺寸，
   * 拿子矩形 h 去设等于告诉渲染器「这张图只有一格那么高」，多行 sheet 会被
   * 纵向压到 h*scale，横图看起来就是被上下压扁。0 表示没解析出来，调用方退回 h。
   */
  sheetH: number = 0;
}

export class ThumbSlice {
  /** 单图页链接（/s/...） */
  urls: string[] = [];
  /** 缩略图地址，与 urls 同下标 */
  thumbs: string[] = [];
  /** 精灵几何，与 urls 同下标 */
  tiles: ThumbTile[] = [];
}

/** 列表页（首页/搜索/收藏/排行通用） */
export class GalleryPage {
  items: Gallery[] = [];
  nextUrl: string = '';
  prevUrl: string = '';
  /** 例如 "1 - 25 of 12,345" */
  countText: string = '';
  /** 页码（我们自己算，用于显示） */
  page: number = 0;
}

/** 单图页解析结果 */
export class ImagePage {
  pageUrl: string = '';
  imageUrl: string = '';
  nextUrl: string = '';
  prevUrl: string = '';
  /** 该图在画廊里的序号（0 基） */
  index: number = 0;
  width: number = 0;
  height: number = 0;
  /** 509 / 加载失败占位图 */
  limited: boolean = false;
}

/** 统一错误：UI 只认 message */
export class EhError extends Error {
  kind: string = 'unknown';

  constructor(kind: string, message: string) {
    super(message);
    this.kind = kind;
  }
}

/** URL 工具 */
export class EhUrl {
  /** /g/1234567/abcdef1234/ -> gid + token */
  static parseGallery(url: string): Gallery | null {
    const m: RegExpMatchArray | null = url.match(/\/g\/(\d+)\/([0-9a-fA-F]+)/);
    if (m === null) {
      return null;
    }
    const g: Gallery = new Gallery();
    g.gid = m[1];
    g.token = m[2];
    const base: string = url.split('?')[0];
    g.url = base.endsWith('/') ? base : base + '/';
    return g;
  }

  static isGallery(url: string): boolean {
    return /\/g\/\d+\/[0-9a-fA-F]+/.test(url);
  }

  /** /s/<hash>/<gid>-<index> -> index */
  static imageIndex(url: string): number {
    const m: RegExpMatchArray | null = url.match(/-(\d+)(?:-|\/|$)/);
    if (m === null) {
      return 0;
    }
    const v: number = parseInt(m[1], 10);
    return isNaN(v) ? 0 : v;
  }

  /** 补全相对地址（EH 里常见 //ehgt.org/... 与 /xxx 两种） */
  static absolute(url: string, base: string): string {
    if (url.length === 0) {
      return '';
    }
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    if (url.startsWith('//')) {
      return 'https:' + url;
    }
    if (url.startsWith('/')) {
      return base + url;
    }
    return base + '/' + url;
  }

  /** 加/替换查询参数（不依赖 URL 类，ArkTS 里没有完整实现） */
  static withParams(url: string, key: string, value: string): string {
    const q: number = url.indexOf('?');
    const base: string = q < 0 ? url : url.substring(0, q);
    const query: string = q < 0 ? '' : url.substring(q + 1);
    const parts: string[] = query.length === 0 ? [] : query.split('&');
    const out: string[] = [];
    let replaced: boolean = false;
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i];
      if (p.startsWith(key + '=')) {
        if (!replaced) {
          out.push(key + '=' + value);
          replaced = true;
        }
      } else if (p.length > 0) {
        out.push(p);
      }
    }
    if (!replaced) {
      out.push(key + '=' + value);
    }
    return base + '?' + out.join('&');
  }

  /**
   * 详情页第 pageIndex 个缩略图分页。
   *
   * **`p` 是「页索引」，不是「图片偏移」**：p=1 给的是第 21~40 张。
   * 之前所有调用方都传 `页号 * 20`（把 p 当 offset 用），于是第二屏请求成了 p=20
   * —— 要么拿到 401 之后的图、要么超出总页数被站点回一屏第一页，
   * 表现就是「预览图重复同一张 / 后面缺一大段」。
   * 参数名从 offset 改成 pageIndex 就是为了让这个错一眼可见。
   */
  static detailPage(galleryUrl: string, pageIndex: number): string {
    if (pageIndex <= 0) {
      return galleryUrl + '?hc=1';
    }
    return galleryUrl + '?p=' + pageIndex.toString() + '&hc=1';
  }
}
