import { EhConsts, Namespaces, Site } from './Consts';
import { Cookies } from './Cookies';
import { EhError, EhUrl, Gallery, GalleryDetail, GalleryPage, GalleryTag, ImagePage, ThumbSlice, ThumbTile } from './Models';
import { Http, HttpResp } from './Http';
import { HNode, Html } from '../parse/Html';
import { Prefs } from './Prefs';
import { Db } from './Db';
import { Torrent } from './Torrents';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'JHenTai.Api';

/** EH 十个分类的位掩码总和（对齐原版：Shared/EhConstants 'SUM_CATS'，也是 f_cats 的全集） */
const ALL_CATS_MASK: number = 1023;

/**
 * 搜索过滤条件。
 *
 * 字段与 EH 搜索表单的 `f_*` 参数一一对应（口径取自 NextE 的 SearchFilterState / EhApiService，
 * 它本身是 eros_fe 的移植，见 nexte-src 同名文件）：
 *
 *  | 字段          | 参数                     | 含义                             |
 *  |---------------|--------------------------|----------------------------------|
 *  | cats          | f_cats                   | **包含**位掩码；EH 收的是排除位，拼 URL 时取反 |
 *  | adv           | advsearch=1              | 高级块总开关；不开则 EH 丢弃全部 f_s* |
 *  | scopeName     | f_sname=on               | 搜索画廊名称                     |
 *  | scopeTags     | f_stags=on               | 搜索标签                         |
 *  | scopeDesc     | f_sdesc=on               | 搜索简介                         |
 *  | minRating     | f_sr=on & f_srdd=N       | 最低星级（2..5）                 |
 *  | pagesFrom/To  | f_sp=on & f_spf/f_spt    | 页数区间                         |
 *  | torrent       | f_sto=on                 | 仅显示有种子的画廊               |
 *  | expunged      | f_sh=on                  | 仅显示已删除（expunged）的画廊   |
 *  | noLang        | f_sfl=on                 | 忽略账号默认的作品语言过滤       |
 *  | noUploader    | f_sfu=on                 | 忽略账号默认的上传者过滤         |
 *  | noTag         | f_sft=on                 | 忽略账号默认的标签过滤           |
 *  | seek          | seek=yyyy-MM-dd           | 从该日期（含）之后的结果开始     |
 *
 * 注意：EH 的搜索接口**没有**「按上传时间 / 相关度排序」参数 —— 结果顺序固定为发布时间倒序，
 * 唯一的「时间维度」是 seek（跳到某日期之后）。所以这里不造 sort 字段。
 *
 * 注意二：EH 的搜索表单**没有** `f_language` 这类参数。语言是**关键词**里的
 * `language:"<值>"`（引号 = 精确匹配）—— 这不是推断，是 JHenTai 原版的实现：
 * `SearchConfig.toQueryParameters()` 里 `params['f_search'] = (params['f_search'] ?? '') +
 * ' language:"$language"'`（lib/src/model/search_config.dart:152-154）。
 * 所以下面的 `lang` 不是 `f_*` 参数，而是拼进 `f_search` 的搜索词（见 searchUrl）。
 */
export class SearchOptions {
  static readonly ALL_CATS: number = ALL_CATS_MASK;

  /**
   * 语言筛选的合法取值 = EH `language:` 命名空间下的标签名。
   *
   * 取值来源对齐 JHenTai 原版（不是凭印象）：
   *  - 原版搜索面板确实有「语言」一项，是**单选下拉**，列表来自
   *    `LocaleConsts.language2Abbreviation`（lib/src/consts/locale_consts.dart:2-18，共 15 种），
   *    下拉里额外放一项 null 表示「不限」、并显式排除了 japanese
   *    （lib/src/widget/eh_search_config_dialog.dart:526-546 `_buildLanguageSelector`）。
   *  - 所以语言是单选，不是多选。
   *
   * 这里只放面板能显示的 5 种：全 14 种 pill 一屏放不下；其余语言直接手写
   * `language:"russian"` 仍然有效（关键词支持 EH 全部高级语法，本工程不改写）。
   * `translated` 是**比原版多出来的一个**（原版下拉里没有它），但它同属 language 命名空间、
   * 站点也认，保留是因为「只看翻译作品」是常用诉求。
   */
  static readonly LANGS: string[] = ['chinese', 'english', 'japanese', 'korean', 'translated'];

  cats: number = 0;
  adv: boolean = false;
  minRating: number = 0;
  pagesFrom: number = 0;
  pagesTo: number = 0;
  torrent: boolean = false;
  expunged: boolean = false;
  noLang: boolean = false;
  noUploader: boolean = false;
  noTag: boolean = false;
  scopeName: boolean = true;
  scopeTags: boolean = true;
  scopeDesc: boolean = false;
  seek: string = '';
  /**
   * 语言筛选：取值见 `SearchOptions.LANGS`，空串 = 不限。
   *
   * 它不是 `f_*` 参数 —— EH 没有 `f_language`，语言只能写进关键词（见 searchUrl 的拼装）。
   * 存在这里的目的是「持久化 + 历史快照」：SearchOptions 整体序列化，语言条件就跟着走。
   */
  lang: string = '';

  /** 语言取值归一：只认 LANGS 里的值，别的一律当「不限」（防止脏数据拼出非法关键词） */
  static validLang(raw: string): string {
    const s: string = raw.trim().toLowerCase();
    if (s.length === 0) {
      return '';
    }
    for (let i = 0; i < SearchOptions.LANGS.length; i++) {
      if (SearchOptions.LANGS[i] === s) {
        return s;
      }
    }
    return '';
  }

  /** 搜索范围是否就是 EH 的默认口径（名称 + 标签，不含简介） */
  scopeIsDefault(): boolean {
    return this.scopeName && this.scopeTags && !this.scopeDesc;
  }

  /** f_cats 要传的「排除位」：全选或全不选都不带这个参数 */
  static excludeCats(include: number): number {
    if (include <= 0 || include >= ALL_CATS_MASK) {
      return 0;
    }
    return ALL_CATS_MASK - include;
  }

  /** 只认 yyyy-MM-dd；不合法就返回空串（不带 seek，别污染 URL） */
  static validDate(raw: string): string {
    const s: string = raw.trim();
    if (s.length !== 10) {
      return '';
    }
    if (s.charAt(4) !== '-' || s.charAt(7) !== '-') {
      return '';
    }
    for (let i = 0; i < s.length; i++) {
      if (i === 4 || i === 7) {
        continue;
      }
      const c: string = s.charAt(i);
      if (c < '0' || c > '9') {
        return '';
      }
    }
    return s;
  }

  toJson(): string {
    return JSON.stringify(this);
  }

  /** 还原持久化/历史里的快照；坏数据一律退回默认值，绝不抛异常 */
  static parse(raw: string): SearchOptions {
    const o: SearchOptions = new SearchOptions();
    if (raw.length === 0) {
      return o;
    }
    try {
      const src: SearchOptions = JSON.parse(raw) as SearchOptions;
      if (src === null || typeof src !== 'object') {
        return o;
      }
      o.cats = typeof src.cats === 'number' && src.cats >= 0 ? src.cats : 0;
      o.adv = src.adv === true;
      o.minRating = typeof src.minRating === 'number' && src.minRating >= 0 ? src.minRating : 0;
      o.pagesFrom = typeof src.pagesFrom === 'number' && src.pagesFrom > 0 ? src.pagesFrom : 0;
      o.pagesTo = typeof src.pagesTo === 'number' && src.pagesTo > 0 ? src.pagesTo : 0;
      o.torrent = src.torrent === true;
      o.expunged = src.expunged === true;
      o.noLang = src.noLang === true;
      o.noUploader = src.noUploader === true;
      o.noTag = src.noTag === true;
      o.scopeName = src.scopeName !== false;
      o.scopeTags = src.scopeTags !== false;
      o.scopeDesc = src.scopeDesc === true;
      o.seek = typeof src.seek === 'string' ? SearchOptions.validDate(src.seek) : '';
      o.lang = typeof src.lang === 'string' ? SearchOptions.validLang(src.lang) : '';
      return o;
    } catch (e) {
      return o;
    }
  }
}

/**
 * E-Hentai / ExHentai 的请求与 HTML 解析。
 *
 * 选择器全部来自 JHenTai 原版 `eh_spider_parser.dart` 的解析表（原版把解析委托给
 * `EHSpiderParser`，不使用 CSS 选择器字符串；这里换成等价的 CSS 选择器，
 * 但**字段口径保持一致**，便于和原版行为对照）。
 *
 * 两个解析原则：
 *  1. 列表行不依赖具体布局类名（gltm/gltc/glte 三种布局的 td class 不同），
 *     而是“找行里第一个指向 /g/ 的链接 + .glink 标题 + 行内 'N pages' 文本”；
 *  2. 详情页的元信息不依赖 tr 的序号，而是按 `.gdt1` 的**标签文本**匹配
 *     （Parent / Visible / Language / File Size / Length / Favorited），
 *     站点改版增减一行也不会错位。
 */
export class EhApi {
  /** 详情页一屏缩略图数量（EH 固定 20） */
  static readonly THUMB_PAGE_SIZE: number = 20;
  /** 缩略图解析诊断（最近 8 条）：真机出现「一屏同图」时，这是唯一能拿到的现场数据 */
  static diag: string[] = [];
  private static lastPairs: number = 0;
  private static lastRaw: number = 0;
  private static lastImgs: number = 0;
  private static lastDerived: number = 0;
  /** 首个 /s/ 链接附近的一小段原文：真机上看一眼就能知道站点现在把缩略图放在哪 */
  static lastSnippet: string = '';

  private static index(): string {
    return EhConsts.index(Prefs.site());
  }

  // ------------------------------------------------------------------ URL
  static homeUrl(page: number): string {
    return EhApi.index() + '/?page=' + page.toString();
  }

  static popularUrl(page: number): string {
    return EhApi.index() + '/popular?page=' + page.toString();
  }

  /**
   * 搜索列表 URL（对齐原版：NextE `getGalleryList` 的 f_* 拼装，nexte-src/shared/src/main/ets/network/
   * EhApiService.ets:507-611）。拼装规则：
   *
   *  1. `f_search` 永远带（关键词已 trim + encode）；`page` 是 **0 基偏移**，永远带。
   *  2. `f_cats` 只在「部分选中」时带，值 = 1023 - 包含位（EH 收排除位）。
   *  3. 高级块（`advsearch=1` + 各 `f_*`）只在**真的改了高级项**时才带：`advsearch=1` 是闸门，
   *     缺了它 EH 会把后面所有 f_s* 静默丢掉。所以「只翻开关、什么都没设」不会污染 URL。
   *  4. 搜索范围三项按勾选逐个带；三项就是 EH 默认口径（名称 + 标签）时整段省略。
   *  5. 未设置（0 / false / 空）的参数一律不带，绝不写默认值。
   *  6. 语言**不是** URL 参数：EH 没有 `f_language`，语言是关键词里的 `language:"<值>"`，
   *     拼在用户关键词后面（空格分隔）、整串一起编码一次。它也不需要 `advsearch=1`
   *     —— 高级闸门只约束 f_s* 那批，`language:` 属于普通标签语法。
   *     写法与取值来源见 SearchOptions.LANGS 的注释（JHenTai 原版 search_config.dart:152-154）。
   *
   * **EH 的真实分页语义（重要，别再拿 page 往后翻）**：
   * 搜索结果页的翻页是**游标**式的 —— 站点在每一页底部给出 `<a id="unext" href="...">`，
   * 下一页必须**原样跟随**这个链接（解析成 `GalleryPage.nextUrl`，见 parseList），因为它可能带着
   * 我们拼不出来的站点侧偏移/游标参数。`page=N` 只是首屏与「跳页」用的偏移量，在搜索接口上
   * **不可靠**：服务端可能忽略它，或按偏移重排后返回与上一页重叠（甚至完全相同）的一批结果。
   * 所以这里拼出来的 page URL 只用于首屏、跳页、以及「站点没给 next 时」的兜底；
   * 无限滚动的正常路径是 nextUrl（见 GalleryListView.nextPageUrl 的顺序）。
   *
   * 这条差异正是「大标签只出十几条就显示没有更多了」的一半原因：搜索页原来优先用本函数
   * 反复拼 page=1/2/3…，站点回同一页，去重后一条不新增，列表便把「重复」误判成「到底」。
   *
   * `opts` 允许传 number 以兼容旧的两参数调用（QuickSearch 里的 `searchUrl(kw, 0)`），
   * 此时等价于「无过滤 + 该页码」。
   */
  static searchUrl(keyword: string, opts: SearchOptions | number, page: number = 0): string {
    let o: SearchOptions;
    let p: number = page;
    if (typeof opts === 'number') {
      o = new SearchOptions();
      p = opts;
    } else {
      o = opts;
    }

    // 语言筛选用关键词标签实现，写法照抄 JHenTai 原版：
    //   SearchConfig.toQueryParameters() →
    //   params['f_search'] = (params['f_search'] ?? '') + ' language:"$language"';
    //   （lib/src/model/search_config.dart:152-154）
    // 即「引号包住取值」的精确匹配，**不是** `language:xxx$`；多个条件靠空格 AND，也不受 advsearch 约束。
    // 拼接顺序：用户关键词在前、语言标签在后 —— 原版也是同一个 append 方向（先 keyword 后 language），
    // 这样历史里看到的词仍以用户输入开头。
    // 注意只在这里拼**一次**，下面统一 encodeURIComponent 一次，绝不二次编码（引号会被编码成 %22，EH 认）。
    const base: string = keyword.trim();
    const lang: string = SearchOptions.validLang(o.lang);
    let query: string = base;
    if (lang.length > 0) {
      const langTag: string = 'language:"' + lang + '"';
      query = base.length > 0 ? base + ' ' + langTag : langTag;
    }
    const kw: string = encodeURIComponent(query);
    let url: string = EhApi.index() + '/?f_search=' + kw;

    const exclude: number = SearchOptions.excludeCats(o.cats);
    if (exclude > 0) {
      url += '&f_cats=' + exclude.toString();
    }

    // 高级块：真改了才带 advsearch。范围偏离默认也算「改了」。
    const advActive: boolean = o.adv && (
      o.minRating >= 2 || o.pagesFrom > 0 || o.pagesTo > 0 || o.torrent || o.expunged ||
        o.noLang || o.noUploader || o.noTag || !o.scopeIsDefault() ||
        SearchOptions.validDate(o.seek).length > 0);
    if (advActive) {
      url += '&advsearch=1';
      if (!o.scopeIsDefault()) {
        if (o.scopeName) {
          url += '&f_sname=on';
        }
        if (o.scopeTags) {
          url += '&f_stags=on';
        }
        if (o.scopeDesc) {
          url += '&f_sdesc=on';
        }
      }
      if (o.minRating >= 2) {
        url += '&f_sr=on&f_srdd=' + o.minRating.toString();
      }
      if (o.pagesFrom > 0 || o.pagesTo > 0) {
        url += '&f_sp=on';
        if (o.pagesFrom > 0) {
          url += '&f_spf=' + o.pagesFrom.toString();
        }
        if (o.pagesTo > 0) {
          url += '&f_spt=' + o.pagesTo.toString();
        }
      }
      if (o.torrent) {
        url += '&f_sto=on';
      }
      if (o.expunged) {
        url += '&f_sh=on';
      }
      if (o.noLang) {
        url += '&f_sfl=on';
      }
      if (o.noUploader) {
        url += '&f_sfu=on';
      }
      if (o.noTag) {
        url += '&f_sft=on';
      }
    }

    // seek 也属于高级块：没有 advsearch=1 时 EH 同样不认
    const seek: string = SearchOptions.validDate(o.seek);
    if (advActive && seek.length > 0) {
      url += '&seek=' + encodeURIComponent(seek);
    }

    return url + '&page=' + p.toString();
  }

  static favUrl(cat: number, page: number): string {
    return EhApi.index() + '/favorites.php?favcat=' + cat.toString() + '&page=' + page.toString();
  }

  static watchedUrl(page: number): string {
    return EhApi.index() + '/watched?page=' + page.toString();
  }

  /** 排行页：tl=15 日榜 / 13 月榜 / 12 年榜 / 11 总榜 */
  static rankUrl(tl: number, page: number): string {
    return EhApi.index() + '/toplist.php?tl=' + tl.toString() + '&p=' + page.toString();
  }

  // ------------------------------------------------------------------ 列表
  static async loadList(url: string): Promise<GalleryPage> {
    const resp: HttpResp = await Http.get(url);
    if (resp.code === 404) {
      throw new Error('页面不存在（404）');
    }
    if (resp.code !== 200) {
      throw new Error('站点返回 ' + resp.code.toString());
    }
    return EhApi.parseList(resp.body, EhApi.index());
  }

  static parseList(html: string, base: string): GalleryPage {
    const doc: HNode = Html.parse(html);
    const page: GalleryPage = new GalleryPage();

    // 三种布局的行容器不同，逐个尝试
    let rows: HNode[] = doc.find('.itg.gltc tr');
    if (rows.length === 0) {
      rows = doc.find('.itg.gltm tr');
    }
    if (rows.length === 0) {
      rows = doc.find('.itg.glte tr');
    }
    if (rows.length === 0) {
      rows = doc.find('.itg tr');
    }
    if (rows.length === 0) {
      // 缩略图布局（.itg.gld）没有 table，每行是一个 div
      rows = doc.find('.itg.gld > div');
    }

    for (let i = 0; i < rows.length; i++) {
      const row: HNode = rows[i];
      if (row.findFirst('th') !== null) {
        continue;
      }
      const g: Gallery | null = EhApi.parseRow(row, base);
      if (g !== null) {
        page.items.push(g);
      }
    }

    // 分页：优先 #unext / #uprev，没有就退化成 .gtb 里的 “>”。
    //
    // nextUrl 是**权威的下一页地址**（EH 的游标），调用方必须原样跟随，不能自己拼 page=N；
    // 空串 = 站点自己说没有下一页了（或解析失败，此时调用方还有页码兜底）。
    const next: HNode | null = doc.findFirst('#unext');
    if (next !== null) {
      page.nextUrl = EhUrl.absolute(next.attr('href'), base);
    } else {
      page.nextUrl = EhApi.findGtbNext(doc, base, true);
    }
    const prev: HNode | null = doc.findFirst('#uprev');
    if (prev !== null) {
      page.prevUrl = EhUrl.absolute(prev.attr('href'), base);
    } else {
      page.prevUrl = EhApi.findGtbNext(doc, base, false);
    }

    page.countText = doc.textOf('.searchtext');
    return page;
  }

  /** .gtb 里的翻页按钮：找文本为 ">" / "<" 的链接 */
  private static findGtbNext(doc: HNode, base: string, forward: boolean): string {
    const links: HNode[] = doc.find('.gtb a');
    const want: string = forward ? '>' : '<';
    for (let i = 0; i < links.length; i++) {
      if (links[i].textContent().trim() === want) {
        return EhUrl.absolute(links[i].attr('href'), base);
      }
    }
    return '';
  }

  /**
   * 解析列表行里的标签（详细布局的 `.gt/.gtl/.gtw`）。
   *
   * 数据口径与详情页 `#taglist` 一致：ns / key / name / state / color，
   * 这样列表卡片和详情页对同一个标签显示的配色完全相同（都来自 Namespaces 色表）。
   *
   * 为什么以 title 为主、文本为辅：title 是完整的 `ns:tag`，而框里显示的只是名字，
   * 名字里可能自带冒号（例如某些 `other:` 标签），只靠文本切分会把命名空间切错。
   */
  private static parseRowTags(row: HNode, g: Gallery): void {
    const nodes: HNode[] = row.find('.gt, .gtl, .gtw');
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < nodes.length; i++) {
      const text: string = nodes[i].textContent();
      // 三种候选写法都认：title（列表行，最准）/ id（详情页那种 ta_ns:key）/ 框内文本
      let full: string = nodes[i].attr('title');
      if (full.indexOf(':') < 0) {
        const rawId: string = nodes[i].attr('id');
        full = rawId.startsWith('ta_') ? rawId.substring(3) : rawId;
      }
      if (full.indexOf(':') < 0) {
        full = text;
      }
      const colon: number = full.indexOf(':');
      if (colon <= 0) {
        continue;
      }
      const ns: string = full.substring(0, colon).trim();
      const key: string = full.substring(colon + 1).trim();
      const id: string = ns + ':' + key;
      if (ns.length === 0 || key.length === 0 || seen.has(id)) {
        continue;
      }
      seen.add(id);

      const tag: GalleryTag = new GalleryTag();
      tag.ns = ns;
      tag.key = key;
      tag.name = text.length > 0 ? text : key;
      // 只看 class：gtw = 已关注（站点会把它染成橙底），gtl = 争议/低权重
      const cls: string[] = nodes[i].classes();
      for (let c = 0; c < cls.length; c++) {
        if (cls[c] === 'gtw' || cls[c] === 'gtl' || cls[c] === 'gt') {
          tag.state = cls[c];
        } else if (cls[c] === 'tup') {
          tag.state = 'gtw';
        } else if (cls[c] === 'tdn') {
          tag.state = 'gtl';
        }
      }
      tag.color = Namespaces.of(ns).color;
      g.tags.push(tag);
    }
  }

  /** 解析一行；不是画廊行返回 null */
  private static parseRow(row: HNode, base: string): Gallery | null {
    let href: string = '';
    const anchors: HNode[] = row.find('a');
    for (let i = 0; i < anchors.length; i++) {
      const h: string = anchors[i].attr('href');
      if (h.indexOf('/g/') >= 0) {
        href = h;
        break;
      }
    }
    if (href.length === 0) {
      return null;
    }
    const parsed: Gallery | null = EhUrl.parseGallery(EhUrl.absolute(href, base));
    if (parsed === null) {
      return null;
    }
    const g: Gallery = parsed;

    // 标题：.glink 是各布局共有的
    let title: string = row.textOf('.glink');
    if (title.length === 0) {
      // 缩略图布局把标题放在 a 的 title 属性里
      for (let i = 0; i < anchors.length; i++) {
        const t: string = anchors[i].attr('title');
        if (t.length > 0) {
          title = t;
          break;
        }
      }
    }
    g.title = title;

    // 封面
    const img: HNode | null = row.findFirst('img');
    if (img !== null) {
      let src: string = img.attr('data-src');
      if (src.length === 0) {
        src = img.attr('src');
      }
      g.thumbUrl = EhUrl.absolute(src, base);
    }

    // 分类：.cs 是缩略图/紧凑布局的分类块，扩展布局用 .cn
    let cat: string = row.textOf('.cs');
    if (cat.length === 0) {
      const cn: HNode | null = row.findFirst('.cn');
      if (cn !== null) {
        cat = cn.textContent();
      }
    }
    g.setCategory(cat);

    // 标签（只有「详细」列表布局才有）：站点把每个标签写成
    //   <div class="gt|gtl|gtw" title="female:stockings">stockings</div>
    // 它只在站点设置里开启「显示标签」时才出现在行内，所以解析不到是常态，
    // 这时 tags 保持空数组，卡片不画标签区（不是 bug）。
    // 与 JHenTai 的 `eh_gallery_list_card_.dart`（buildGalleryCardTagWaterFlow）同一份数据来源。
    EhApi.parseRowTags(row, g);

    // 上传者：指向 uploader 的链接
    for (let i = 0; i < anchors.length; i++) {
      if (anchors[i].attr('href').indexOf('uploader') >= 0) {
        g.uploader = anchors[i].textContent();
        break;
      }
    }

    // 发布时间：行内带 id 属性的节点（如 id="posted_12345"），或直接匹配日期
    const all: HNode[] = row.descendants();
    for (let i = 0; i < all.length; i++) {
      const id: string = all[i].attr('id');
      if (id.startsWith('posted')) {
        g.posted = all[i].textContent();
        break;
      }
    }
    if (g.posted.length === 0) {
      const m: RegExpMatchArray | null = row.textContent().match(/\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}/);
      if (m !== null) {
        g.posted = m[0];
      }
    }
    // 被删除（expunged）的画廊，发布时间会被 <s> 包起来
    if (row.findFirst('s') !== null && g.posted.length > 0) {
      g.expunged = true;
    }

    // 页数：行文本里的 “N pages”
    const pm: RegExpMatchArray | null = row.textContent().match(/(\d+)\s*pages?/i);
    if (pm !== null) {
      g.pages = parseInt(pm[1], 10);
    }

    // 评分：**列表 HTML 里没有数字**，这里不再试图从 `.ir` 的样式推。
    //
    // 核对 JHenTai 原版 `eh_spider_parser.dart:1008`：列表行只能从 `.ir` 的 class
    // 判断「本账号是否评过」（hasRated），拿不到分值；分数来自 gdata 接口
    // （`jt_req.dart:383 requestGalleryMetadatas` 那一族，见 net/GalleryMeta.ets）。
    //
    // v1.33.3 曾按 `.ir` 的 style="width:Npx" 除以 16 推星星 —— 那个宽度属于别的元素，
    // 结果 rating 一直是 0、卡片全灰。这段推断已经删掉，rating 留给 gdata 异步补。
    const ir: HNode | null = row.findFirst('.ir');
    if (ir !== null) {
      // 已评分：站点会在这个 div 上多加一个 class（本账号评过时才有），只有一个 class 就是没评过
      g.rated = ir.classes().length > 1;
    }
    return g;
  }

  // ------------------------------------------------------------------ 详情
  static async loadDetail(gallery: Gallery): Promise<GalleryDetail> {
    const resp: HttpResp = await Http.get(EhUrl.detailPage(gallery.url, 0));
    if (resp.code !== 200) {
      throw new Error('详情页请求失败（' + resp.code.toString() + '）');
    }
    const detail: GalleryDetail = EhApi.parseDetail(resp.body, gallery);
    detail.rawHtml = resp.body;
    // 标签为空说明站点改版了选择器，退到 api.php 的 gdata（稳定得多）
    if (detail.tags.length === 0) {
      await EhApi.fillTagsByApi(detail);
    }
    return detail;
  }

  static parseDetail(html: string, base: Gallery): GalleryDetail {
    const doc: HNode = Html.parse(html);
    const d: GalleryDetail = new GalleryDetail();
    d.gallery = base;

    const title: string = doc.textOf('#gn');
    if (title.length > 0) {
      d.gallery.title = title;
    }
    d.japTitle = doc.textOf('#gj');
    d.gallery.setCategory(doc.textOf('#gdc .cs'));

    // 本账号的收藏态（eros_fe 的 #fav 精灵图，NextE EhGalleryDetailParser.ets:45-104 同一算法）：
    //   已收藏 → <div id="fav"><div style="... -0px -40px ..." title="Favorite 2"></div></div>
    //   未收藏 → <div id="fav"></div>（没有内层 div）
    // 目录号由内层 div 的 background-position 的 Y 反推：每格 19px、首格 Y=2，
    // 所以 slot = floor((y - 2) / 19)。**不靠 title 判断**：收藏夹名是用户可自定义的，
    // 默认名才是 "Favorite N"，拿它做映射会在改过名的账号上失效。
    // 这样详情页首屏就带着收藏态，不用再为了一次状态判断多发一个 gallerypopups 请求。
    // 每次都从「未收藏」重新判定：同一个 Gallery 对象可能被重解析（历史/缓存），
    // 不能把上一次的目录号留在身上。
    d.gallery.favcat = -1;
    // 取 #fav 里的所有 div（不限定「直接子节点」：站点曾在中间套过一层 wrapper），
    // 第一个带 background-position 的就是目录图标。
    const favSprites: HNode[] = doc.find('#fav div');
    for (let i = 0; i < favSprites.length; i++) {
      const bm: RegExpMatchArray | null = favSprites[i].attr('style').match(/-?\d+px\s+-?(\d+)px/);
      if (bm === null) {
        continue;
      }
      const slot: number = Math.floor((parseInt(bm[1], 10) - 2) / 19);
      if (slot >= 0 && slot <= 9) {
        d.gallery.favcat = slot;
        break;
      }
    }

    // 元信息表：按 .gdt1 的标签文本匹配，不依赖行号
    const rows: HNode[] = doc.find('#gdd tr');
    for (let i = 0; i < rows.length; i++) {
      const label: string = rows[i].textOf('.gdt1').replace(':', '').trim();
      const valueNode: HNode | null = rows[i].findFirst('.gdt2');
      if (valueNode === null) {
        continue;
      }
      const value: string = valueNode.textContent();
      if (label === 'Parent') {
        const a: HNode | null = valueNode.findFirst('a');
        d.parentUrl = a === null ? '' : EhUrl.absolute(a.attr('href'), EhApi.index());
      } else if (label === 'Visible') {
        d.visible = value;
      } else if (label === 'Language') {
        d.language = value;
      } else if (label === 'File Size') {
        d.sizeText = value;
      } else if (label === 'Length') {
        const m: RegExpMatchArray | null = value.match(/(\d+)/);
        if (m !== null) {
          d.gallery.pages = parseInt(m[1], 10);
        }
      } else if (label === 'Favorited') {
        const m: RegExpMatchArray | null = value.match(/([\d,]+)/);
        if (m !== null) {
          d.favCount = parseInt(m[1].split(',').join(''), 10);
        }
      }
    }

    // 评分
    const ratingText: string = doc.textOf('#rating_label');
    const rm: RegExpMatchArray | null = ratingText.match(/(\d+(?:\.\d+)?)/);
    if (rm !== null) {
      d.gallery.rating = parseFloat(rm[1]);
    }
    const rc: string = doc.textOf('#rating_count');
    const rcm: RegExpMatchArray | null = rc.match(/([\d,]+)/);
    if (rcm !== null) {
      d.ratingCount = parseInt(rcm[1].split(',').join(''), 10);
    }

    // 标签：两种站点标记都要认。
    //
    //  新版 EH/E-Hentai：<a id="ta_female:stockings" class="tup|tdn">Stockings</a>（在 <td> 里）
    //  旧版/部分镜像：   <div id="female:stockings" class="gt|gtl|gtw" style="color:#xxx">
    //
    // 只认 div 会在新版站点上解析出 0 个标签——这是「详情页看不到标签」的根因，
    // 所以先按 a 找，找不到再退回 div，并且要剥掉 a 上多出来的 "ta_" 前缀。
    let tagNodes: HNode[] = doc.find('#taglist a');
    if (tagNodes.length === 0) {
      tagNodes = doc.find('#taglist div');
    }
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < tagNodes.length; i++) {
      const rawId: string = tagNodes[i].attr('id');
      const id: string = rawId.startsWith('ta_') ? rawId.substring(3) : rawId;
      if (id.indexOf(':') < 0) {
        continue;
      }
      if (seen.has(id)) {
        continue;
      }
      seen.add(id);
      const tag: GalleryTag = new GalleryTag();
      const colon: number = id.indexOf(':');
      tag.ns = id.substring(0, colon);
      tag.key = id.substring(colon + 1);
      tag.name = tagNodes[i].textContent();
      // 状态：新版用 tup（已关注）/ tdn（已隐藏），旧版用 gtw / gtl，统一映射到 gtw / gtl
      const cls: string[] = tagNodes[i].classes();
      for (let c = 0; c < cls.length; c++) {
        if (cls[c] === 'gtl' || cls[c] === 'gtw' || cls[c] === 'gt') {
          tag.state = cls[c];
        } else if (cls[c] === 'tup') {
          tag.state = 'gtw';
        } else if (cls[c] === 'tdn') {
          tag.state = 'gtl';
        }
      }
      const style: string = tagNodes[i].attr('style');
      // 直接从 style 里取第一个十六进制色值，不用带转义的 \s（避免正则字面量被工具链改写）
      const cm: RegExpMatchArray | null = style.match(/#[0-9a-fA-F]{3,6}/);
      tag.color = cm === null ? Namespaces.of(tag.ns).color : cm[1];
      d.tags.push(tag);
    }

    // 缩略图页链接 + 缩略图地址：/s/xxxx/1234-0
    EhApi.collectThumbLinks(doc, d.pageUrls, d.pageThumbs, html, d.pageTiles);

    // 总图数： "Showing 1 - 20 of 1,234 images"
    const body: string = doc.textContent();
    const tm: RegExpMatchArray | null = body.match(/of\s+([\d,]+)\s+images/i);
    let total: number = d.pageUrls.length;
    if (tm !== null) {
      const v: number = parseInt(tm[1].split(',').join(''), 10);
      if (!isNaN(v) && v > 0) {
        total = v;
      }
    }
    d.thumbPageCount = Math.max(1, Math.ceil(total / EhApi.THUMB_PAGE_SIZE));
    return d;
  }

  /**
   * 从详情页文档里收集 `#gdt` 的缩略图：链接进 urls，图片地址进 thumbs。
   *
   * 两份数组**必须等长**：详情页网格用下标当页码，缺一张就会整体错位，
   * 所以取不到缩略图时也 push 空串占位。
   */
  private static collectThumbLinks(doc: HNode, urls: string[], thumbs: string[],
    raw: string = '', tileOut: ThumbTile[] = []): void {
    const links: HNode[] = doc.find('#gdt a');
    for (let i = 0; i < links.length; i++) {
      const href: string = links[i].attr('href');
      if (href.indexOf('/s/') < 0) {
        continue;
      }
      urls.push(EhUrl.absolute(href, EhApi.index()));
      thumbs.push(EhApi.thumbUrlOf(links[i]));
    }
    // ---- 覆盖：直接用**原始 HTML** 在 #gdt 区段里扫 /t/ 缩略图路径，按顺序回填。
    //
    // 为什么不再只靠 DOM：站点现在的 #gdt 里，真缩略图可能挂在 data-src、内联 style、
    // 甚至内层 div 的 data-background 上，层级和属性名每个版面都不一样；而**地址本身的
    // 形态是稳定的** —— EH 的缩略图一定在 `/t/<两位>/<两位>/<hash>-...` 路径下。
    // 直接对原串做一次全局匹配，既不依赖层级，也不依赖属性名，跟 JHenTai 里那种
    // 「正则取 background:url(...)」的做法是同一个思路，只是把范围放宽到整段 #gdt。
    //
    // 只在数量对得上时覆盖（`>=` 而不是 `===`：#gdt 前后可能夹着别的 /t/ 引用，
    // 多出来的尾部直接忽略），数量不够就保留 DOM 的逐项结果，不会把数组搞乱。
    // 优先级 1：精灵图解析（站点当前版面）。命中时 urls / thumbs / tiles 三者一起对齐。
    const tiles: ThumbTile[] = EhApi.parseThumbTiles(raw);
    if (tiles.length >= urls.length && urls.length > 0) {
      for (let i = 0; i < urls.length; i++) {
        urls[i] = tiles[i].page;
        thumbs[i] = tiles[i].sheet;
        tileOut[i] = tiles[i];
      }
      EhApi.lastPairs = tiles.length;
      EhApi.lastDerived = 1;
      return;
    }
    EhApi.lastPairs = 0;

    // 优先级 1：按位置配对（页链接 + 自己的缩略图），一次把两个数组都对齐
    const pairs: ThumbSlice = EhApi.thumbPairsFromRaw(raw);
    EhApi.lastPairs = pairs.urls.length;
    if (pairs.urls.length >= urls.length && urls.length > 0) {
      for (let i = 0; i < urls.length; i++) {
        urls[i] = pairs.urls[i];
        thumbs[i] = pairs.thumbs[i];
      }
      if (thumbs.length >= 5) {
        hilog.info(0x0000, TAG, 'pairs=%{public}d first=%{public}s', pairs.urls.length, thumbs[0]);
      }
      return;
    }

    // 优先级 1.5：整份文档里按顺序取图床地址（站点现在的缩略图形态）。
    // 只在数量对得上时用，且**不动 urls** —— 页链接那边是对的。
    const imgs: string[] = EhApi.imageUrlsFromRaw(raw);
    EhApi.lastImgs = imgs.length;
    if (imgs.length >= thumbs.length && thumbs.length > 0) {
      for (let i = 0; i < thumbs.length; i++) {
        thumbs[i] = EhUrl.absolute(imgs[i], EhApi.index());
      }
    }

    // 优先级 1.6：站点只给一张时，**只把这一张贴到第一格，其余留空**。
    //
    // 试过两条拼地址的路，都被实测否掉了：
    //   - 按 `-<page>` 递推图床路径：20 条形状正确、全部 404（client 段是按图分配的）；
    //   - 用页 token 拼 ehgt.org 老缩略图：同样全部 404（站点已不再发布这批静态图）。
    // 再猜下去只会继续制造 404 请求。留空后界面显示页码，至少不再空白、也不会重复。
    if (imgs.length < thumbs.length && thumbs.length > 0) {
      for (let i = 0; i < thumbs.length; i++) {
        thumbs[i] = '';
      }
      thumbs[0] = EhUrl.absolute(imgs[0], EhApi.index());
      EhApi.lastDerived = 1;
    } else {
      EhApi.lastDerived = -1;
    }

    // 优先级 2：老办法（全局 /t/ 列表按顺序填），配对失败时才用
    const fromRaw: string[] = EhApi.thumbUrlsFromRaw(raw);
    EhApi.lastRaw = fromRaw.length;
    if (fromRaw.length >= urls.length && urls.length > 0) {
      for (let i = 0; i < urls.length; i++) {
        thumbs[i] = EhUrl.absolute(fromRaw[i], EhApi.index());
      }
    } else if (fromRaw.length > 0) {
      // 数量对不上时**逐项补**：DOM 那一列可能全是同一个地址（旧版就是这样），
      // 而原串扫出来的顺序是对的，能补多少补多少，比整段放弃更接近正确。
      for (let i = 0; i < urls.length && i < fromRaw.length; i++) {
        thumbs[i] = EhUrl.absolute(fromRaw[i], EhApi.index());
      }
    }
    // 整批仍然全等 = 解析侧没救回来，留一条日志便于定位（真机日志里搜 batch-collapsed）
    if (thumbs.length >= 5) {
      let same: boolean = true;
      for (let i = 1; i < thumbs.length; i++) {
        if (thumbs[i] !== thumbs[0]) {
          same = false;
          break;
        }
      }
      if (same) {
        hilog.warn(0x0000, TAG, 'batch-collapsed: %{public}d thumbs all equal, rawLen=%{public}d',
          thumbs.length, raw.length);
      }
    }

    // 记录一批现场：锚点数 / 地址数 / 唯一数 / 配对命中数 / 域内 /t/ 数
    let uniq: number = 0;
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < thumbs.length; i++) {
      if (!seen.has(thumbs[i])) {
        seen.add(thumbs[i]);
        uniq++;
      }
    }
    // href 唯一数：用来判断是不是「20 个格子其实是同一个链接」
    const hseen: Set<string> = new Set<string>();
    for (let i = 0; i < urls.length; i++) {
      hseen.add(urls[i]);
    }
    const hp: number = raw.indexOf('/s/');
    if (hp > 0 && EhApi.lastSnippet.length === 0) {
      EhApi.lastSnippet = raw.substring(Math.max(0, hp - 60), Math.min(raw.length, hp + 300));
    }

    // 嵌套检测：锚点的祖先里还有锚点 = 上一格没闭合，子树会串味
    let nest: number = 0;
    for (let i = 0; i < links.length; i++) {
      let cur: HNode | null = links[i].parent;
      while (cur !== null && cur.tag.length > 0) {
        if (cur.tag === 'a') {
          nest++;
          break;
        }
        cur = cur.parent;
      }
    }
    EhApi.diag.push('d=' + nest.toString()
      + ' n=' + urls.length.toString() + ' h=' + hseen.size.toString()
      + ' t=' + thumbs.length.toString() + ' u=' + uniq.toString()
      + ' p=' + EhApi.lastPairs.toString() + ' r=' + EhApi.lastRaw.toString()
      + ' i=' + EhApi.lastImgs.toString() + ' dv=' + EhApi.lastDerived.toString());
    if (EhApi.diag.length > 8) {
      EhApi.diag.splice(0, EhApi.diag.length - 8);
    }
    if (thumbs.length >= 3) {
      hilog.info(0x0000, TAG, 'thumbs[0..2]=%{public}s | %{public}s | %{public}s',
        thumbs[0], thumbs[1], thumbs[2]);
    }
  }

  /**
   * 单个 `#gdt` 项里的缩略图地址。
   *
   * 新版站点不再输出 `<img>`，缩略图是内层 div 的
   * `style="background:url(//ehgt.org/t/xxx.jpg) ..."`；
   * 老版是 `.gdtm img` 的 `data-src`（懒加载，src 常是占位图）。两种都试。
   *
   * 实现是「先收齐所有候选、再按置信分挑一个」（见 thumbUrlOf 内的打分说明）：
   * 按层级顺序取第一个的做法，遇到「外层 div 挂的是全页共用的贴图」时，
   * 20 个 #gdt 项会拿到同一个地址 —— 详情页缩略图网格「每格同一个画面」就是这么来的，
   * 不是下标算错，是 20 条 thumbs 本身就相等。
   */
  /**
   * 从**原始 HTML** 里扫出 #gdt 区段内的缩略图路径（按出现顺序）。
   *
   * 匹配 `/t/<两位>/<两位>/<...>`：这是 EH 缩略图的固定目录形态，
   * 站点换版面、改懒加载属性都动不到它。返回值保持原始形态（可能是 `//ehgt.org/...`
   * 或 `/t/...`），由调用方用 EhUrl.absolute 补全。
   */
  private static thumbUrlsFromRaw(raw: string): string[] {
    const out: string[] = [];
    if (raw.length === 0) {
      return out;
    }
    // 起点：属性写法不保证是 id="gdt"（可能是单引号、也可能只是 class="gt200"）。
    let start: number = -1;
    const anchors: string[] = ['id="gdt"', "id='gdt'", 'class="gt200"', 'gdtm'];
    for (let a = 0; a < anchors.length; a++) {
      const idx: number = raw.indexOf(anchors[a]);
      if (idx >= 0) {
        start = idx;
        break;
      }
    }
    if (start < 0) {
      start = 0;
    }
    // 终点：**不再按 '</table>' 截断**。
    //
    // 新版详情页的缩略图区不一定是 table（可能是 div 网格），页面前部还常有别的表格
    // （登录框、公告、广告位）。一旦第一个 '</table>' 落在缩略图之前，扫到的范围就只剩
    // 开头那一小段 —— 20 个格子于是全部落回「同一张图」。
    // 改成：取到 `id="gd5"`（缩略图区之后的区块）或固定长度上限为止。
    const tail: string = raw.substring(start, Math.min(raw.length, start + 400000));
    let end: number = tail.indexOf('id="gd5"');
    if (end < 0) {
      end = tail.indexOf('id="gd5"'.replace('"', "'"));
    }
    const scope: string = end > 0 ? tail.substring(0, end) : tail;

    const re: RegExp = new RegExp("/t/[0-9a-z]{2}/[0-9a-z]{2}/[^'\")\\s]+", 'gi');
    const found: RegExpMatchArray | null = scope.match(re);
    if (found === null) {
      return out;
    }
    // 按出现顺序去重：同一地址在一页里被写到多次（骨架/LD 数据/懒加载脚本）时，
    // 不去重就会让 20 个槽位被同一个地址填满 —— 那正是「整屏同一张」的形态。
    for (let i = 0; i < found.length; i++) {
      if (out.indexOf(found[i]) < 0) {
        out.push(found[i]);
      }
    }
    return out;
  }

  /**
   * 从原始 HTML 里按「页链接 → 紧随其后的缩略图」配对，返回两个等长数组。
   *
   * 为什么不再分别扫「所有 /s/ 链接」和「所有 /t/ 缩略图」：
   * 那是**两个独立的全局列表**，各自都可能被页面里的杂质（广告、推荐位、脚本里的模板串）
   * 插入条目。两个列表一旦错位，位置 i 的页链接就配到了位置 i 的缩略图 —— 但更糟的情况是
   * 缩略图列表被同一张图的多次出现填满：那正是「一屏 20 格全一样、换一屏变另一张」的形态，
   * 因为每一屏各自被自己那一段杂质污染。
   *
   * 配对法的判据是**位置关系**而不是列表顺序：#gdt 里每一项都是
   * `<a href="/s/…">` 紧跟自己的缩略图地址（style 里的 background:url(/t/…)，或内层 img），
   * 所以在 href 之后的 2000 字符内取第一个 /t/ 地址，配到的就是它自己的缩略图。
   * 杂质即使存在，也只会落在某个 href 的邻域里被跳过（取第一个有效 /t/），不会污染别项。
   */
  private static thumbPairsFromRaw(raw: string): ThumbSlice {
    const out: ThumbSlice = new ThumbSlice();
    if (raw.length === 0) {
      return out;
    }
    const hrefRe: RegExp = new RegExp('/s/[0-9a-z]+/[0-9a-z]+', 'gi');
    const thumbRe: RegExp = new RegExp("/t/[0-9a-z]{2}/[0-9a-z]{2}/[^'\")\\s]+", 'i');
    let m: RegExpExecArray | null = hrefRe.exec(raw);
    while (m !== null) {
      const pagePath: string = m[0];
      const from: number = m.index;
      const window: string = raw.substring(from, Math.min(raw.length, from + 2000));
      const t: RegExpMatchArray | null = window.match(thumbRe);
      if (t !== null && t[0].length > 0) {
        out.urls.push(EhUrl.absolute(pagePath, EhApi.index()));
        out.thumbs.push(EhUrl.absolute(t[0], EhApi.index()));
      }
      m = hrefRe.exec(raw);
    }
    return out;
  }

  /**
   * 从原始 HTML 按顺序取「图床地址」。
   *
   * 站点已经不再用 `ehgt.org/t/xx/yy/…` 这套缩略图路径（真机实测 r=0：整份文档里
   * 一个 `/t/` 都没有），现在的网格项指向 `https://<node>.hath.network/c2/<token>/<gid>-<page>.webp`。
   * 这些地址**每页不同**，可以直接当缩略图源用。
   */
  private static imageUrlsFromRaw(raw: string): string[] {
    const out: string[] = [];
    if (raw.length === 0) {
      return out;
    }
    const re: RegExp = new RegExp("https?://[^\"'\\s]*hath\\.network/[^\"')\\s]+", 'gi');
    const found: RegExpMatchArray | null = raw.match(re);
    if (found === null) {
      return out;
    }
    for (let i = 0; i < found.length; i++) {
      if (out.indexOf(found[i]) < 0) {
        out.push(found[i]);
      }
    }
    return out;
  }

  /**
   * 按「页号」推导缩略图地址（站点只给出一张时用）。
   *
   * 真机实测：一屏 20 个格子里，HTML 只带了**一张**图床地址，其余 19 格是空骨架
   * （i=1、u=1，而 h=20 —— 页链接是齐的）。浏览器的行为是页面加载后由脚本补全，
   * 我们不执行 JS，所以只能按命名规律推：
   *
   *   页链接  …/s/<token>/<gid>-<page>       （page 从 1 开始）
   *   缩略图  https://<node>/c2/<client>/<gid>-<page-1>.webp
   *
   * 唯一那张就是样本：把它的 `<gid>-0.webp` 拆成前缀，再按每格的 page 逐张拼。
   * 同一个会话里 `<node>/c2/<client>` 是稳定的，所以这个推导在实测页面上成立。
   */
  private static thumbUrlsDerived(raw: string, urls: string[]): string[] {
    const out: string[] = [];
    const sample: string[] = EhApi.imageUrlsFromRaw(raw);
    if (sample.length === 0 || urls.length === 0) {
      return out;
    }
    const one: string = sample[0];
    // 拆成「前缀 + 数字 + 扩展名」：…/<gid>-0.webp
    const m: RegExpMatchArray | null = one.match(/^(.*-)\d+\.([a-z0-9]+)$/i);
    if (m === null) {
      return out;
    }
    const prefix: string = m[1];
    const ext: string = m[2];
    for (let i = 0; i < urls.length; i++) {
      // 页链接尾部是 -<page>（1 基），缩略图是 page-1（0 基）
      const pm: RegExpMatchArray | null = urls[i].match(/-(\d+)$/);
      if (pm === null) {
        return [];
      }
      const page: number = parseInt(pm[1], 10);
      if (page <= 0) {
        return [];
      }
      out.push(prefix + (page - 1).toString() + '.' + ext);
    }
    return out;
  }

  /**
   * 从原始 HTML 解析「精灵图 + 子矩形」。
   *
   * 站点现在的详情页把一屏 20 张缩略图拼成一张长条图，每格只给子矩形：
   *
   *   <a href="…/s/<hash>/<gid>-<page>">
   *     <div title="Page 1: 0001.jpg"
   *          style="width:169px;height:300px;background:transparent
   *                 url(https://…/c2/<client>/<gid>-0.webp) -0px 0 no-repeat">
   *
   * 所以 20 格共享同一个 sheet 地址、靠 `-Xpx` 偏移区分，**不是**每格一张图。
   *
   * 用**正则字面量**而不是字符串：字符串里反斜杠要写四层，上一版就因为多写了两个
   * 变成 `width:////s*`，宽高一次都没匹配上（诊断里 tiles 全是 [0/0/0]）。
   */
  static parseThumbTiles(raw: string): ThumbTile[] {
    const out: ThumbTile[] = [];
    if (raw.length === 0) {
      return out;
    }
    const hrefRe: RegExp = /<a href="(https?:\/\/e[-x]?hentai\.org\/s\/[^"]+)"/g;
    const urlRe: RegExp = /url\(\s*['"]?([^'")]+)['"]?\s*\)/;
    const wRe: RegExp = /width:\s*(\d+)px/;
    const hRe: RegExp = /height:\s*(\d+)px/;
    // 偏移必须紧跟在 url(...) 之后：`-169px` 是 background-position，不能乱抓数字。
    // 两段都要取：多行 sheet 的第二行是 `url(...) -0px -300px`，只取 x 会把第二行
    // 全部裁成第一行的内容（整图还会因为「只有一格高」被纵向压扁）。
    const offRe: RegExp = /url\([^)]*\)\s*(-?\d+)px(?:\s+(-?\d+)px)?/;
    let m: RegExpExecArray | null = hrefRe.exec(raw);
    while (m !== null) {
      const page: string = m[1];
      const win: string = raw.substring(m.index, Math.min(raw.length, m.index + 900));
      const um: RegExpMatchArray | null = win.match(urlRe);
      if (um !== null) {
        const wm: RegExpMatchArray | null = win.match(wRe);
        const hm: RegExpMatchArray | null = win.match(hRe);
        const om: RegExpMatchArray | null = win.match(offRe);
        const t: ThumbTile = new ThumbTile();
        t.page = page;
        t.sheet = um[1];
        t.w = wm !== null ? parseInt(wm[1], 10) : 0;
        t.h = hm !== null ? parseInt(hm[1], 10) : 0;
        t.x = om !== null ? Math.abs(parseInt(om[1], 10)) : 0;
        // 第二段可能缺省（单行 sheet 只写 `-169px 0`），缺省按 0 处理
        t.y = om !== null && om[2] !== undefined ? Math.abs(parseInt(om[2], 10)) : 0;
        out.push(t);
      }
      m = hrefRe.exec(raw);
    }
    // 缺宽高的格子继承同 sheet 里第一个有值的（站点只在第一格写 width/height）
    for (let i = 0; i < out.length; i++) {
      if (out[i].w > 0 && out[i].h > 0) {
        continue;
      }
      for (let j = 0; j < out.length; j++) {
        if (out[j].sheet === out[i].sheet && out[j].w > 0 && out[j].h > 0) {
          out[i].w = out[j].w;
          out[i].h = out[j].h;
          break;
        }
      }
    }
    // 整张 sheet 宽 = 同 sheet 里 max(x + w)
    for (let i = 0; i < out.length; i++) {
      let right: number = out[i].x + out[i].w;
      for (let j = 0; j < out.length; j++) {
        if (out[j].sheet === out[i].sheet && out[j].x + out[j].w > right) {
          right = out[j].x + out[j].w;
        }
      }
      out[i].sheetW = right;
    }
    // 整张 sheet 高 = 同 sheet 里 max(y + h)。照 sheetW 的写法，同 sheet 内取最大：
    // 单行 sheet 得到的就是 h（与旧行为一致），多行 sheet 才能拿到真实总高。
    for (let i = 0; i < out.length; i++) {
      let bottom: number = out[i].y + out[i].h;
      for (let j = 0; j < out.length; j++) {
        if (out[j].sheet === out[i].sheet && out[j].y + out[j].h > bottom) {
          bottom = out[j].y + out[j].h;
        }
      }
      out[i].sheetH = bottom;
    }
    return out;
  }

  /** 用页链接里的 token 拼老式缩略图地址（`/t/xx/yy/<token>-250.jpg`），仅作兜底 */
  private static legacyThumbFromPage(pageUrl: string): string {
    const m: RegExpMatchArray | null = pageUrl.match('/s/([0-9a-z]+)/');
    if (m === null) {
      return '';
    }
    const token: string = m[1];
    if (token.length < 4) {
      return '';
    }
    return 'https://ehgt.org/t/' + token.substring(0, 2) + '/' + token.substring(2, 4)
      + '/' + token + '-250.jpg';
  }

  private static thumbUrlOf(anchor: HNode): string {
    // 把所有可能是缩略图的地址**全部收上来**，再按可信度挑一个。
    //
    // 为什么不再「按顺序找到第一个就返回」：
    //   站点不同版面的 div 层级不同，同一个 #gdt 里既有可能是真缩略图（内层 div 背景），
    //   也有可能是**全页共用的装饰/骨架背景**（外层 div）。只要外层那个地址不是
    //   data: 也不是 blank/spacer（比如站点自己的图标贴图、渐变占位 host），
    //   「跳过占位图」的过滤就拦不住它 —— 20 格于是又拿到同一个地址。
    //   上一版正是这样：过滤条件写得对，但候选顺序决定了答案。
    //   现在改成「先收齐、再打分」：EH 真缩略图一定在 /t/<两位十六进制>/ 路径下，
    //   这条特征比层级顺序稳定得多，站点改版面也不会失效。
    const cand: string[] = [];

    const img: HNode | null = anchor.findFirst('img');
    if (img !== null) {
      EhApi.pushThumbCandidate(cand, img.attr('data-src'));
      EhApi.pushThumbCandidate(cand, img.attr('src'));
    }
    // 锚点自己的 style 也要算：某些版面把背景直接写在 <a> 上（没有内层 div），
    // 只找 div 会一条候选都收不到，于是整批回落到同一个兜底地址。
    const selfStyle: string = anchor.attr('style');
    if (selfStyle.length > 0) {
      const sm: RegExpMatchArray | null = selfStyle.match(/url\(\s*['"]?([^'")]+)['"]?\s*\)/);
      if (sm !== null) {
        EhApi.pushThumbCandidate(cand, sm[1]);
      }
    }

    const divs: HNode[] = anchor.find('div');
    for (let i = 0; i < divs.length; i++) {
      const style: string = divs[i].attr('style');
      const m: RegExpMatchArray | null = style.match(/url\(\s*['"]?([^'")]+)['"]?\s*\)/);
      if (m !== null) {
        EhApi.pushThumbCandidate(cand, m[1]);
      }
    }

    let best: string = '';
    let bestScore: number = -100;
    for (let i = 0; i < cand.length; i++) {
      const sc: number = EhApi.thumbScore(cand[i]);
      if (sc > bestScore) {
        bestScore = sc;
        best = cand[i];
      }
    }
    if (best.length === 0) {
      return '';
    }
    return EhUrl.absolute(best, EhApi.index());
  }

  /** 收候选项：只过滤「明确是占位图」和空串，排序交给 thumbScore */
  private static pushThumbCandidate(out: string[], url: string): void {
    if (url.length === 0) {
      return;
    }
    if (EhApi.isPlaceholderImage(url)) {
      return;
    }
    for (let i = 0; i < out.length; i++) {
      if (out[i] === url) {
        return;
      }
    }
    out.push(url);
  }

  /**
   * 缩略图候选的置信分（越大越像真缩略图）。
   *
   * 判据来自 EH 的缩略图路径：`<host>/t/<xx>/<yy>/<hash>-<n>-<w>-<h>.jpg`。
   *   +6  路径里带 `/t/`      —— 站点缩略图目录，几乎不会误伤
   *   +3  以图片扩展名结尾    —— jpg/png/webp
   *   -6  带 /img/ 或 gt.png  —— 站点自己的图标/贴图
   *   -6  svg/gif             —— 图标或动图占位
   * 同分时取**路径更长**的那个：真缩略图带 hash 与尺寸，比站点贴图的路径长。
   */
  private static thumbScore(url: string): number {
    const u: string = url.toLowerCase();
    let sc: number = 0;
    if (u.indexOf('/t/') >= 0) {
      sc += 6;
    }
    if (u.endsWith('.jpg') || u.endsWith('.jpeg') || u.endsWith('.png') || u.endsWith('.webp')) {
      sc += 3;
    }
    if (u.indexOf('/img/') >= 0 || u.indexOf('gt.png') >= 0) {
      sc -= 6;
    }
    if (u.endsWith('.svg') || u.endsWith('.gif')) {
      sc -= 6;
    }
    // 路径长度作为同分时的次序：/t/xx/yy/<hash>-... 明显长于图标地址
    sc += Math.min(3, Math.floor(u.length / 40));
    return sc;
  }

  /**
   * 是否是「占位图」而不是真正的缩略图。
   *
   * 判据只认两类不会误伤的：
   *  - `data:` 内联图 —— 站点拿它当懒加载骨架，同一页里所有项共用同一张；
   *  - 文件名里带 blank / spacer / loading / placeholder / 1x1 的静态占位。
   * 真缩略图走 `ehgt.org/t/<xx>/<yy>/<hash>.jpg`，不会命中这些词。
   */
  private static isPlaceholderImage(url: string): boolean {
    const u: string = url.toLowerCase();
    if (u.startsWith('data:')) {
      return true;
    }
    return u.indexOf('blank') >= 0 || u.indexOf('spacer') >= 0
      || u.indexOf('loading') >= 0 || u.indexOf('placeholder') >= 0 || u.indexOf('1x1') >= 0;
  }

  /**
   * 多页画廊：详情页一次只给 20 张缩略图，剩下的要按 `?p=20/40...` 逐页取。
   * 这里只取**某一页**，让阅读器和详情页网格可以按需补。
   */
  static async loadThumbPageUrlsWithImages(galleryUrl: string, pageIndex: number): Promise<ThumbSlice> {
    const out: ThumbSlice = new ThumbSlice();
    const resp: HttpResp = await Http.get(EhUrl.detailPage(galleryUrl, pageIndex));
    if (resp.code !== 200) {
      return out;
    }
    EhApi.collectThumbLinks(Html.parse(resp.body), out.urls, out.thumbs, resp.body, out.tiles);
    return out;
  }

  /** 只要链接的调用方（阅读器补页、下载器）走这个，保持旧签名不变 */
  static async loadThumbPageUrls(galleryUrl: string, pageIndex: number): Promise<string[]> {
    const slice: ThumbSlice = await EhApi.loadThumbPageUrlsWithImages(galleryUrl, pageIndex);
    return slice.urls;
  }

  static async collectPageUrls(detail: GalleryDetail, onProgress: (loaded: number, total: number) => void): Promise<string[]> {
    const out: string[] = [];
    for (let i = 0; i < detail.pageUrls.length; i++) {
      out.push(detail.pageUrls[i]);
    }
    onProgress(out.length, detail.pageUrls.length * detail.thumbPageCount);
    for (let p = 1; p < detail.thumbPageCount; p++) {
      // p 就是页索引：再乘 20 会跳过 20 屏（原来这里也是错的）
      const urls: string[] = await EhApi.loadThumbPageUrls(detail.gallery.url, p);
      for (let i = 0; i < urls.length; i++) {
        out.push(urls[i]);
      }
      onProgress(out.length, out.length + EhApi.THUMB_PAGE_SIZE * (detail.thumbPageCount - p - 1));
    }
    return out;
  }

  // ------------------------------------------------------------------ 单图页
  /**
   * 取「`/s/` 页 → 图片直链」，**先查持久化映射**（core/Db.ets 的 page_map）。
   *
   * 为什么不直接改 loadImagePage：阅读器主图也要用它，而主图对「直链新鲜度」是零容忍的
   * （拿到过期直链就是一张 403 空图，用户会以为这一页坏了）。所以缓存只在缩略图这条路上开，
   * 主图继续每次走 HTML。这里返回的 ImagePage 与 loadImagePage 完全同构，调用方不用分叉。
   */
  static async imagePageCached(pageUrl: string): Promise<ImagePage> {
    const hit: string = Db.pageImage(pageUrl);
    if (hit.length > 0) {
      const out: ImagePage = new ImagePage();
      out.pageUrl = pageUrl;
      out.index = EhUrl.imageIndex(pageUrl);
      out.imageUrl = hit;
      // 映射里可能存着当次的配额占位图，命中时要还原成 limited，否则会被当成真图去解码
      out.limited = hit === EhConsts.EH_509_IMAGE || hit === EhConsts.EX_509_IMAGE;
      return out;
    }
    return await EhApi.loadImagePage(pageUrl);
  }

  /** 丢弃某一页的映射（直链 403 / 解码失败时由调用方触发自愈） */
  static dropImagePage(pageUrl: string): void {
    Db.dropPageImage(pageUrl);
  }

  static async loadImagePage(pageUrl: string): Promise<ImagePage> {
    const resp: HttpResp = await Http.get(pageUrl, EhApi.index() + '/');
    if (resp.code !== 200) {
      throw new Error('图片页请求失败（' + resp.code.toString() + '）');
    }
    const doc: HNode = Html.parse(resp.body);
    const img: HNode | null = doc.findFirst('#img');
    const out: ImagePage = new ImagePage();
    out.pageUrl = pageUrl;
    out.index = EhUrl.imageIndex(pageUrl);
    if (img === null) {
      // #pane_images 存在但 #img 缺失：通常是图片加载失败的重试页
      throw new Error('这一页没有图片（可能需要重新加载）');
    }
    let src: string = img.attr('src');
    if (src.length === 0) {
      src = img.attr('data-src');
    }
    out.imageUrl = EhUrl.absolute(src, EhApi.index());
    out.limited = out.imageUrl === EhConsts.EH_509_IMAGE || out.imageUrl === EhConsts.EX_509_IMAGE;
    const style: string = img.attr('style');
    const wm: RegExpMatchArray | null = style.match(/width:\s*(\d+)px/);
    const hm: RegExpMatchArray | null = style.match(/height:\s*(\d+)px/);
    out.width = wm === null ? 0 : parseInt(wm[1], 10);
    out.height = hm === null ? 0 : parseInt(hm[1], 10);
    // 回写映射：这是「二次进入同一画廊省掉一整次 HTML 往返」的唯一写入点。
    // 只写非配额页 —— 写进去的是一次性 token，7 天后由 Db 的 TTL 丢掉（见 Db.pageImage）。
    if (!out.limited && out.imageUrl.length > 0) {
      Db.putPageImage(pageUrl, out.imageUrl, out.width, out.height);
    }

    const next: HNode | null = doc.findFirst('#next');
    if (next !== null) {
      out.nextUrl = EhUrl.absolute(next.attr('href'), EhApi.index());
    }
    const prev: HNode | null = doc.findFirst('#prev');
    if (prev !== null) {
      out.prevUrl = EhUrl.absolute(prev.attr('href'), EhApi.index());
    }
    return out;
  }

  // ------------------------------------------------------------------ 登录
  /**
   * 账号密码登录：POST 到论坛的登录接口，成功后 Cookie 罐里就有 ipb_member_id，
   * 再访问 bounce_login.php 拿到 sk（EX 站需要）。
   */
  static async loginPassword(userName: string, password: string): Promise<string> {
    const form: string = 'CookieDate=1&b=&bt=&UserName=' + encodeURIComponent(userName) +
      '&PassWord=' + encodeURIComponent(password) + '&submit=Log me in';
    const resp: HttpResp = await Http.postForm(EhConsts.LOGIN_POST, form, EhConsts.FORUMS + '?act=Login&CODE=00');
    if (resp.body.indexOf('The captcha was not entered correctly') >= 0) {
      return '需要验证码，请到网页端登录后使用 Cookie 登录';
    }
    if (resp.body.indexOf('Username or password') >= 0) {
      return '账号或密码错误';
    }
    if (!Cookies.isLoggedIn()) {
      return '登录失败（没有拿到登录态 Cookie），可能需要验证码或网络异常';
    }
    await EhApi.refreshSession();
    const bad: string = await EhApi.verifyLogin();
    if (bad.length > 0) {
      // 校验没过就把这次写入的 Cookie 清掉：否则界面上仍显示「已登录」，
      // 后面每个请求都要失败一次，用户只会以为应用坏了。
      Cookies.clear();
      return bad;
    }
    return '';
  }

  /** 直接粘贴 Cookie 登录（JHenTai 的 Cookie 登录方式） */
  static async loginByCookie(memberId: string, passHash: string, igneous: string): Promise<string> {
    Cookies.set('ipb_member_id', memberId.trim());
    Cookies.set('ipb_pass_hash', passHash.trim());
    if (igneous.trim().length > 0) {
      Cookies.set('igneous', igneous.trim());
    }
    if (!Cookies.isLoggedIn()) {
      return 'ipb_member_id 不能为空';
    }
    await EhApi.refreshSession();
    const bad: string = await EhApi.verifyLogin();
    if (bad.length > 0) {
      Cookies.clear();
      return bad;
    }
    return '';
  }

  /**
   * 补齐会话 Cookie：sk 由 bounce_login 下发；
   * igneous 由 EX 站自己下发，访问一次站点首页即可（未登录则会拿到删除态）。
   */
  static async refreshSession(): Promise<void> {
    if (!Cookies.isLoggedIn()) {
      return;
    }
    try {
      await Http.get(EhConsts.BOUNCE_LOGIN);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'bounce_login failed');
    }
    try {
      await Http.get(EhConsts.EX_INDEX + '/');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'ex probe failed');
    }
  }

  /**
   * 向站点确认登录态是真的。
   *
   * 为什么必须有这一步：`Cookies.isLoggedIn()` 只检查「本地有没有 ipb_member_id 和
   * ipb_pass_hash 这两个键」—— 随手填两个字符它也为真，于是「随便填也能登录成功」。
   * 站点侧才是唯一裁判：拿一个必须登录才能看的页面（收藏页）去打一次，
   * 未登录会被重定向/回一句 "You are not logged in"。
   *
   * 返回空串表示通过；否则返回可以直接展示给用户的原因。
   */
  static async verifyLogin(): Promise<string> {
    try {
      const resp: HttpResp = await Http.get(EhApi.favBase() + '/favorites.php', EhApi.index() + '/');
      const body: string = resp.body;
      if (body.indexOf('You are not logged in') >= 0 ||
        body.indexOf('You must be logged in') >= 0 ||
        body.indexOf('Sad Panda') >= 0) {
        return '登录未通过站点校验：Cookie 无效或已过期';
      }
      // 收藏页正常会带 "Favorites" 标题；两者都没有说明拿到的不是已登录页面
      if (body.indexOf('favorites') < 0 && body.indexOf('Favorites') < 0) {
        return '登录未通过站点校验：请检查 Cookie 是否正确';
      }
      return '';
    } catch (e) {
      // 网络失败不能当成「Cookie 错」—— 那会把用户正确的 Cookie 清掉
      return '无法连接站点验证登录（网络异常）';
    }
  }

  static async logout(): Promise<void> {
    Cookies.clear();
  }

  // ------------------------------------------------------------------ 收藏
  /**
   * 收藏接口要打的站点。
   *
   * EH 与 EX 共用同一套账号（ipb_member_id / ipb_pass_hash），收藏夹是**账号级**数据，
   * 所以在哪个域写都是同一份结果。唯一的差别是 EX 域必须先有 igneous ——
   * 缺 igneous 时 EX 对一切请求都回 Sad Panda（HTTP 200 + 一张图/一句话），
   * 写操作必然失败。这时退回 e-hentai.org 打同一个接口：结果等价，只是回显页不同。
   */
  private static favBase(): string {
    if (Prefs.site() === Site.EX && !Cookies.hasIgneous()) {
      return EhConsts.EH_INDEX;
    }
    return EhApi.index();
  }

  /**
   * 收藏弹窗地址。
   *
   * 站点没有「收藏态」的 JSON 接口，addfav 这个弹窗既是读入口也是写入口：
   *  - GET  它 → 返回 10 个 favcat 单选框（当前所在目录带 checked）；
   *  - POST 它 → 写收藏（favcat=0..9 加入，favcat=favdel 移除）。
   * gid / token 必须 encode：token 是十六进制串，本身安全，但这里是唯一的拼接口，统一处理。
   */
  private static favPopupUrl(gallery: Gallery): string {
    return EhApi.favBase() + '/gallerypopups.php?gid=' + encodeURIComponent(gallery.gid) +
      '&t=' + encodeURIComponent(gallery.token) + '&act=addfav';
  }

  /**
   * 当前账号把这个画廊放在哪个收藏夹（-1 = 未收藏 / 未登录 / 读取失败）。
   *
   * 判定依据只能来自弹窗 HTML：被 `checked` 的那个 `input[name=favcat]` 就是当前目录；
   * 一个都没选中即未收藏。**不要**拿详情页的「Favorited: N times」判断 ——
   * 那是全站收藏次数，和本账号无关（详情页根本没有本账号的收藏态）。
   *
   * 为什么不抛异常：这是个「顺便把状态刷对」的调用，详情页照常展示，
   * 读失败只意味着按钮先显示未收藏，用户点一下照样能写成功。
   */
  static async favcatOf(gallery: Gallery): Promise<number> {
    if (!Cookies.isLoggedIn() || gallery.gid.length === 0 || gallery.token.length === 0) {
      return -1;
    }
    try {
      const resp: HttpResp = await Http.get(EhApi.favPopupUrl(gallery), gallery.url);
      if (resp.code !== 200 || resp.body.length === 0) {
        return -1;
      }
      const doc: HNode = Html.parse(resp.body);
      const inputs: HNode[] = doc.find('input');
      for (let i = 0; i < inputs.length; i++) {
        if (inputs[i].attr('name') !== 'favcat' || !inputs[i].hasAttr('checked')) {
          continue;
        }
        const n: number = parseInt(inputs[i].attr('value'), 10);
        if (!isNaN(n) && n >= 0 && n <= 9) {
          return n;
        }
      }
      return -1;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'favcatOf failed');
      return -1;
    }
  }

  /**
   * 收藏 / 取消收藏。favcat = 0..9 加入对应收藏夹，-1 表示从收藏夹移除。
   *
   * 请求形态（与 NextE `EhApiService.updateGalleryFavorite` 同一套，nexte-src/shared/src/main/ets/
   * network/EhApiService.ets:203-212）：
   *   POST {host}/gallerypopups.php?gid=<gid>&t=<token>&act=addfav
   *   body: favcat=<0..9|favdel>&update=1&favnote=
   *
   * 注意这里**没有** `apply` 字段：NextE 与 EhViewer 的实测请求体都只有上面三个，
   * 之前那版带的 `apply=Add to Favorites` 是照抄网页按钮的 value，服务端并不认它，
   * 属于「多发了不该发的字段」，去掉更稳。
   *
   * 成功判定：站点成功后 302 回详情页（Http 默认跟随跳转，所以看到的是 200 + 详情页），
   * 失败时最典型的是 200 + 一句 "You must be logged in"（Cookie 过期，站点不用 401），
   * 这两种都是 200，所以必须看正文而不是只看状态码。
   */
  static async addFavorite(gallery: Gallery, favcat: number): Promise<void> {
    if (!Cookies.isLoggedIn()) {
      throw new EhError('login', '请先登录后再收藏');
    }
    if (gallery.gid.length === 0 || gallery.token.length === 0) {
      throw new EhError('fav', '缺少 gid / token，无法收藏');
    }
    const body: string = 'favcat=' + (favcat >= 0 ? favcat.toString() : 'favdel') +
      '&update=1&favnote=';
    const resp: HttpResp = await Http.postForm(EhApi.favPopupUrl(gallery), body, gallery.url);
    if (resp.body.indexOf('You must be logged in') >= 0 ||
      resp.body.indexOf('You are not logged in') >= 0) {
      throw new EhError('login', '登录已失效，请重新登录');
    }
    if (resp.code >= 400) {
      throw new EhError('fav', '收藏失败（HTTP ' + resp.code.toString() + '）');
    }

    // ---- 成功分支的**最后一步**：发一次「收藏已变」信号给媒体库的「收藏」页。
    //
    // 为什么放在 EhApi 而不是详情页：收藏 / 取消收藏（favcat = -1）只有这一条出口，
    // 信号挨着「请求确实成功了」写，才不会出现某个调用点忘了通知、列表停在旧数据的漏更新。
    // 失败路径都在上面的 throw 里走掉了（未登录 / 缺 gid / 登录失效 / 4xx），到此即成功——
    // 站点成功后是 302 回详情页，任何失败文案都已在前面拦掉，所以这里不需要再判一次正文。
    //
    // 为什么用「自增计数」而不是布尔：
    //   接收方是 @StorageProp + @Watch，回调只在**值真的变了**的时候才触发。
    //   布尔量第二次写 true 与上一次同值，不构成变化 —— 连收藏第二部漫画时收藏页
    //   一次通知都收不到，列表就停在上一轮；「先置 false 再置 true」也不可靠，
    //   两次写在同一帧里会被合并成一次赋值。
    //   计数每次 +1 一定构成变化，语义也从「现在是否有收藏变更」变成了
    //   「收藏状态被改过几次」—— 正是消费方需要的事件语义（有几次变更就欠几次刷新）。
    //
    // 键名 'favRevision' 是写方与读方（pages/FavoritesPage.ets 的 @StorageProp）的唯一约定，
    // 改这里必须同步改那边；工程里没有第二个地方用这个键（其余 AppStorage 键见 Prefs / Theme）。
    const favRev: number = AppStorage.get<number>('favRevision') ?? 0;
    AppStorage.setOrCreate<number>('favRevision', favRev + 1);
  }

  // ------------------------------------------------------------------ gdata
  /**
   * api.php 的 gdata：返回结构化元数据（标签/评分/页数）。
   * 只用来兜底 HTML 解析（站点改版时它几乎不会变）。
   */
  static async fillTagsByApi(detail: GalleryDetail): Promise<void> {
    const api: string = EhConsts.api(Prefs.site());
    const body: string = '{"method":"gdata","gidlist":[[' + detail.gallery.gid + ',"' +
      detail.gallery.token + '"]],"namespace":1}';
    try {
      const resp: HttpResp = await Http.postJson(api, body);
      if (resp.code !== 200 || resp.body.length === 0) {
        return;
      }
      const obj: Record<string, Object> = JSON.parse(resp.body) as Record<string, Object>;
      const list: Object[] = obj['gmetadata'] as Object[];
      if (list === undefined || list.length === 0) {
        return;
      }
      const meta: Record<string, Object> = list[0] as Record<string, Object>;
      const titleJpn: string = meta['title_jpn'] as string;
      if (titleJpn !== undefined && titleJpn.length > 0) {
        detail.japTitle = titleJpn;
      }
      const pages: string = meta['filecount'] as string;
      if (pages !== undefined) {
        const v: number = parseInt(pages, 10);
        if (!isNaN(v)) {
          detail.gallery.pages = v;
        }
      }
      const tags: string[] = meta['tags'] as string[];
      if (tags !== undefined) {
        for (let i = 0; i < tags.length; i++) {
          const raw: string = tags[i];
          const colon: number = raw.indexOf(':');
          if (colon < 0) {
            continue;
          }
          const tag: GalleryTag = new GalleryTag();
          tag.ns = raw.substring(0, colon);
          tag.name = raw.substring(colon + 1);
          tag.key = tag.name;
          tag.color = Namespaces.of(tag.ns).color;
          detail.tags.push(tag);
        }
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'gdata fallback failed');
    }
  }

  // ------------------------------------------------------------------ 种子
  /**
   * 种子列表页地址。
   *
   * 接口：GET `<index>/gallerytorrents.php?gid=<gid>&t=<token>`
   * 站点只给 HTML（没有对应的 JSON API），所以这条链路本质是「请求 + 解析表格」。
   * 该页是软限制页：被限流 / IP 被封 / 需要登录（EX）时都是 200 + 一段文字，
   * 这类判断在 Http.throwIfBlocked 里已经统一抛 EhError，调用方只需要处理异常。
   */
  static torrentsUrl(gallery: Gallery): string {
    return EhApi.index() + '/gallerytorrents.php?gid=' + encodeURIComponent(gallery.gid) +
      '&t=' + encodeURIComponent(gallery.token);
  }

  /**
   * 拉取并解析种子列表。
   *
   * 失败怎么呈现：网络层/HTTP 层的问题**抛异常**（由 ToolsPage 显示错误文案），
   * 只有「页面正常返回、确实一个种子都没有」才返回空数组 —— 这样「没有种子」
   * 和「请求/解析失败」在 UI 上是两种文案，不会被静默混成一句「暂无种子」。
   */
  static async loadTorrents(gallery: Gallery): Promise<Torrent[]> {
    if (gallery.gid.length === 0 || gallery.token.length === 0) {
      return [];
    }
    const pageUrl: string = EhApi.torrentsUrl(gallery);
    // Referer 用详情页：种子页本身就要求「从画廊进来」，否则 EX 会返回空白页
    const resp: HttpResp = await Http.get(pageUrl, gallery.url);
    if (resp.code !== 200) {
      throw new EhError('http', '种子页请求失败（' + resp.code.toString() + '）');
    }
    if (resp.body.length === 0) {
      throw new EhError('empty', '种子页返回为空，请稍后重试');
    }
    return EhApi.parseTorrents(resp.body, EhApi.index());
  }

  /**
   * 解析 gallerytorrents.php。
   *
   * 真实版面和 #torrentlist 这种「一个表格多行」完全不同：**每个种子是独立的一段
   * `<form>`**，字段是 `<td><span>Size:</span> 1.20 GiB</td>` 这种「span 当标签、
   * 单元格剩余文字当值」的写法，下载地址在 `a` 的 `onclick`
   * （`document.location='https://e-hentai.org/torrent/<hash>.torrent'`）里，
   * 有些版面干脆没有 href。旧实现按 `#torrentlist tr` + `href 含 .torrent` 找，
   * 两个条件都不成立 → 永远 0 条 → 页面只剩「还没有种子」。
   *
   * 所以这里以 `form` 为行单位（没有 form 的老版面退到 `table`），
   * 先认「这一段里有没有 .torrent 地址」，有才当作一个种子。
   *
   * 注意 `base` 必须是**站点 origin**（`https://e-hentai.org`），不是种子页的完整地址：
   * EhUrl.absolute 是拿 base 直接拼的，传带 `?gid=..` 的地址会拼出
   * `gallerytorrents.php?gid=1&t=x/torrent/...` 这种垃圾 URL。
   */
  static parseTorrents(html: string, base: string): Torrent[] {
    const doc: HNode = Html.parse(html);
    let boxes: HNode[] = doc.find('form');
    if (boxes.length === 0) {
      boxes = doc.find('table');
    }
    const out: Torrent[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < boxes.length; i++) {
      const t: Torrent | null = EhApi.parseTorrentBox(boxes[i], base);
      if (t === null || seen.has(t.url)) {
        continue;
      }
      seen.add(t.url);
      out.push(t);
    }
    // 容器粒度对不上时补漏：页面上有几个 .torrent 链接就该有几条。
    // 典型情况是整页只有一个大 form（容器切错）或版面被改成 div/p（容器为空），
    // 这时把漏掉的链接单独成条，字段向最近的祖先里找 —— 宁可少显示「大小/做种数」，
    // 也不能让用户点不到种子。
    if (out.length < EhApi.countTorrentLinks(doc, base)) {
      EhApi.collectLooseTorrents(doc, base, out, seen);
    }
    return out;
  }

  /** 页面上有几个互不相同的 .torrent 链接 */
  private static countTorrentLinks(doc: HNode, base: string): number {
    const all: HNode[] = doc.descendants();
    const urls: Set<string> = new Set<string>();
    for (let i = 0; i < all.length; i++) {
      let raw: string = all[i].attr('href');
      if (raw.indexOf('.torrent') < 0) {
        raw = EhApi.torrentUrlInScript(all[i].attr('onclick'));
      }
      if (raw.length === 0) {
        continue;
      }
      urls.add(EhUrl.absolute(raw, base));
    }
    return urls.size;
  }

  /** 按「链接」而不是「容器」兜底收集种子（见 parseTorrents 末尾的说明） */
  private static collectLooseTorrents(doc: HNode, base: string, out: Torrent[],
    seen: Set<string>): void {
    const all: HNode[] = doc.descendants();
    for (let i = 0; i < all.length; i++) {
      const el: HNode = all[i];
      const href: string = el.attr('href');
      const onclick: string = el.attr('onclick');
      let raw: string = '';
      if (href.indexOf('.torrent') >= 0) {
        raw = href;
      } else if (onclick.indexOf('.torrent') >= 0) {
        raw = EhApi.torrentUrlInScript(onclick);
      }
      if (raw.length === 0) {
        continue;
      }
      const url: string = EhUrl.absolute(raw, base);
      if (url.length === 0 || seen.has(url)) {
        continue;
      }
      seen.add(url);
      const t: Torrent = new Torrent();
      t.url = url;
      const im: RegExpMatchArray | null = url.match(/\/torrent\/([^\/?'"#]+)\.torrent/);
      t.id = im === null ? '' : im[1];
      const txt: string = el.textContent();
      if (txt.indexOf('.torrent') >= 0 || EhApi.looksLikeName(txt)) {
        t.name = txt;
      } else {
        const seg: string[] = url.split('/');
        t.name = seg.length > 0 ? seg[seg.length - 1] : 'torrent';
      }
      // 字段：向上最多四层找第一个带「标签 td」的祖先
      let cur: HNode | null = el.parent;
      for (let up = 0; up < 4 && cur !== null; up++) {
        const fields: Map<string, string> = EhApi.torrentFieldsIn(cur);
        if (fields.size > 0) {
          t.sizeText = EhApi.pickField(fields, 'size', 'file size');
          t.seeds = EhApi.firstInt(EhApi.pickField(fields, 'seeds', 'seeders'));
          t.peers = EhApi.firstInt(EhApi.pickField(fields, 'peers', 'leechers'));
          t.added = EhApi.pickField(fields, 'posted', 'uploaded');
          break;
        }
        cur = cur.parent;
      }
      out.push(t);
    }
  }

  /** 一个种子段落 → Torrent；没有 .torrent 地址（表头、广告、搜索框）返回 null */
  private static parseTorrentBox(box: HNode, base: string): Torrent | null {
    const url: string = EhApi.torrentUrlIn(box, base);
    if (url.length === 0) {
      return null;
    }
    const t: Torrent = new Torrent();
    t.url = url;
    const im: RegExpMatchArray | null = url.match(/\/torrent\/([^\/?'"#]+)\.torrent/);
    t.id = im === null ? '' : im[1];
    t.name = EhApi.torrentNameIn(box, url);

    const fields: Map<string, string> = EhApi.torrentFieldsIn(box);
    // 主键 + 别名：站点不同版面用过 Seeders/Leechers/Uploaded 这组词
    t.sizeText = EhApi.pickField(fields, 'size', 'file size');
    t.seeds = EhApi.firstInt(EhApi.pickField(fields, 'seeds', 'seeders'));
    t.peers = EhApi.firstInt(EhApi.pickField(fields, 'peers', 'leechers'));
    t.added = EhApi.pickField(fields, 'posted', 'uploaded');

    // 兜底：字段表没认出来（版面换成两列 td 或纯文本）时，从整段文字里捞大小
    if (t.sizeText.length === 0) {
      const sm: RegExpMatchArray | null =
        box.textContent().match(/(\d+(?:\.\d+)?)\s*(B|KB|MB|GB|KiB|MiB|GiB|TiB)/i);
      if (sm !== null) {
        t.sizeText = sm[1] + ' ' + sm[2];
      }
    }
    if (t.name.length === 0) {
      t.name = t.id.length > 0 ? t.id + '.torrent' : 'torrent';
    }
    return t;
  }

  /** 段落里的 .torrent 地址：href → onclick 脚本 → form action，三处都看 */
  private static torrentUrlIn(box: HNode, base: string): string {
    const anchors: HNode[] = box.find('a');
    for (let i = 0; i < anchors.length; i++) {
      const href: string = anchors[i].attr('href');
      if (href.indexOf('.torrent') >= 0) {
        return EhUrl.absolute(href, base);
      }
      const fromScript: string = EhApi.torrentUrlInScript(anchors[i].attr('onclick'));
      if (fromScript.length > 0) {
        return EhUrl.absolute(fromScript, base);
      }
    }
    const action: string = box.attr('action');
    if (action.indexOf('.torrent') >= 0) {
      return EhUrl.absolute(action, base);
    }
    // 有的版面把跳转写在 form 的 onsubmit / 段内任意元素上，最后再扫一遍所有 onclick
    const all: HNode[] = box.descendants();
    for (let i = 0; i < all.length; i++) {
      const fromAttr: string = EhApi.torrentUrlInScript(all[i].attr('onclick'));
      if (fromAttr.length > 0) {
        return EhUrl.absolute(fromAttr, base);
      }
    }
    return '';
  }

  /** 从内联脚本里取 .torrent 地址：`document.location='...'` 或任意带引号的 .torrent 串 */
  private static torrentUrlInScript(script: string): string {
    if (script.length === 0) {
      return '';
    }
    const m: RegExpMatchArray | null = script.match(/document\.location(?:\.href)?\s*=\s*['"]([^'"]+)['"]/);
    if (m !== null) {
      return m[1];
    }
    const m2: RegExpMatchArray | null = script.match(/['"]([^'"]*\.torrent[^'"]*)['"]/);
    return m2 === null ? '' : m2[1];
  }

  /**
   * 种子名。
   *
   * 站点把文件名写在下载链接自己的文字上，所以优先取链接文字；但有些版面的链接文字是
   * 「Download」这类按钮词，或干脆只有图标（无文字），这时按顺序退：
   *   带 .torrent 的链接文字 → 其它非按钮词、非纯大小的链接文字 → 地址路径末段（<hash>.torrent）。
   */
  private static torrentNameIn(box: HNode, url: string): string {
    const anchors: HNode[] = box.find('a');
    let fallback: string = '';
    for (let i = 0; i < anchors.length; i++) {
      const href: string = anchors[i].attr('href');
      const onclick: string = anchors[i].attr('onclick');
      if (href.indexOf('.torrent') < 0 && onclick.indexOf('.torrent') < 0) {
        continue;
      }
      const txt: string = anchors[i].textContent();
      if (txt.indexOf('.torrent') >= 0) {
        return txt;
      }
      if (fallback.length === 0 && EhApi.looksLikeName(txt)) {
        fallback = txt;
      }
    }
    if (fallback.length > 0) {
      return fallback;
    }
    const seg: string[] = url.split('/');
    return seg.length > 0 ? seg[seg.length - 1] : '';
  }

  /** 是不是像「种子名」：非空、不是按钮词、不是纯大小、不是整段说明文字 */
  private static looksLikeName(txt: string): boolean {
    if (txt.length === 0 || txt.length > 160) {
      return false;
    }
    const lower: string = txt.trim().toLowerCase();
    if (lower === 'download' || lower === 'torrent' || lower === 'get' || lower === 'dl') {
      return false;
    }
    if (/^[\d.,\s]*(B|KB|MB|GB|KIB|MIB|GIB|TIB)$/.test(lower)) {
      return false;
    }
    return true;
  }

  /**
   * 段落里的「标签 → 值」。
   *
   * 两种版面都认：
   * 1. `<td><span>Size:</span> 1.2 GiB</td>`（当前版面，同一个 td 里带 span 标签）
   * 2. `<td class="gdt1">Size:</td><td>1.2 GiB</td>`（老版面的两列）
   * key 统一小写、去掉冒号；只收录第一次出现的值（同一段里 Downloads/Posted 可能重复）。
   */
  private static torrentFieldsIn(box: HNode): Map<string, string> {
    const out: Map<string, string> = new Map<string, string>();
    const cells: HNode[] = box.find('td');
    for (let i = 0; i < cells.length; i++) {
      const label: HNode | null = cells[i].findFirst('span');
      if (label === null) {
        continue;
      }
      const rawLabel: string = label.textContent();
      const key: string = EhApi.normalizeLabel(rawLabel);
      if (key.length === 0 || out.has(key)) {
        continue;
      }
      out.set(key, cells[i].textContent().replace(rawLabel, '').trim());
    }
    if (out.size > 0) {
      return out;
    }
    // 两列版面：标签 td 的文字以冒号结尾
    const rows: HNode[] = box.find('tr');
    for (let i = 0; i < rows.length; i++) {
      const tds: HNode[] = rows[i].find('td');
      if (tds.length < 2) {
        continue;
      }
      const first: string = tds[0].textContent();
      if (!first.endsWith(':')) {
        continue;
      }
      const key: string = EhApi.normalizeLabel(first);
      if (key.length > 0 && !out.has(key)) {
        out.set(key, tds[1].textContent());
      }
    }
    return out;
  }

  /** 先取主键，取不到再取别名；都没有返回空串 */
  private static pickField(fields: Map<string, string>, key: string, alias: string): string {
    const v: string | undefined = fields.get(key);
    if (v !== undefined && v.length > 0) {
      return v;
    }
    const a: string | undefined = fields.get(alias);
    return a === undefined ? '' : a;
  }

  /** "Posted:" → "posted"；空/纯符号返回空串 */
  private static normalizeLabel(raw: string): string {
    let s: string = raw.trim();
    if (s.endsWith(':')) {
      s = s.substring(0, s.length - 1);
    }
    return s.trim().toLowerCase();
  }

  private static firstInt(s: string): number {
    const m: RegExpMatchArray | null = s.match(/(\d+)/);
    if (m === null) {
      return 0;
    }
    const v: number = parseInt(m[1], 10);
    return isNaN(v) ? 0 : v;
  }

  /** 站点是否配置为 EX */
  static isEx(): boolean {
    return Prefs.site() === Site.EX;
  }

  // ------------------------------------------------------------------ 评分分布
  /**
   * 评分分布（工具页「评分」卡用）。
   *
   * 接口：GET `<index>/gallerypopups.php?gid=..&t=..&act=stats` —— 和收藏弹窗同一个
   * popup 端点，只换 `act`。返回的是 HTML 表格，没有 JSON 版本，所以只能解析 DOM。
   *
   * 返回值约定（**调用方据此决定画几条**）：
   *   - 10 个元素 → 站点给的是半星十档，下标 0 是最高档（10 = 5 星）；
   *   - 5 个元素  → 站点只给整星五档，下标 0 是 5 星；
   *   - 空数组    → 解析失败 / 未登录 / 非 200 / 网络异常。
   *
   * 为什么失败返回空数组而不是抛异常：这张卡是「补充信息」，评分人数与平均分本来就在
   * 详情里（loadDetail 的 #rating_label / #rating_count）。分布拿不到时 UI 降级成
   * 「只显示平均分 + 人数」，绝不能因为一个附加请求失败就把整页打成错误态或空白。
   * 同理这里不重试：用户退出重进详情页就会重新拉一次，比在这张卡上挂重试按钮更简单。
   */
  static async loadRatingStats(gallery: Gallery): Promise<number[]> {
    if (gallery.gid.length === 0 || gallery.token.length === 0) {
      return [];
    }
    const url: string = EhApi.index() + '/gallerypopups.php?gid=' + encodeURIComponent(gallery.gid) +
      '&t=' + encodeURIComponent(gallery.token) + '&act=stats';
    try {
      // Referer 用详情页：popup 系列端点只接受「从画廊点进来」的请求
      const resp: HttpResp = await Http.get(url, gallery.url);
      if (resp.code !== 200 || resp.body.length === 0) {
        return [];
      }
      return EhApi.parseRatingStats(resp.body);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'load rating stats failed');
      return [];
    }
  }

  /**
   * 解析评分弹窗里的分布表。
   *
   * 站点版面不固定，所以不认 class / id，只认「一行里前两格是 档位 + 人数」这个结构：
   * 档位必须是 1..10 的纯整数（表头、说明行自然被排除），人数取第二格（取不到再退回末格）。
   *
   * 命中档位 < 8（十档表）且 < 4（五档表）时判为「没解析到」，返回空数组 ——
   * 宁可回退到「只显示平均分」，也不要把半张表当全表画出来（缺档的条形会被误读成
   * 「这一档没人评分」，那是错误信息，不是降级）。
   */
  private static parseRatingStats(html: string): number[] {
    const ten: number[] = [];
    for (let i = 0; i < 10; i++) {
      ten.push(-1); // -1 = 该档没出现在表里
    }
    const doc: HNode = Html.parse(html);
    const rows: HNode[] = doc.find('tr');
    for (let i = 0; i < rows.length; i++) {
      const cells: HNode[] = rows[i].find('td');
      if (cells.length < 2) {
        continue;
      }
      const starText: string = cells[0].textContent().trim();
      const sm: RegExpMatchArray | null = starText.match(/^(\d{1,2})$/);
      if (sm === null) {
        continue;
      }
      const star: number = parseInt(sm[1], 10);
      if (isNaN(star) || star < 1 || star > 10) {
        continue;
      }
      const slot: number = 10 - star;
      if (ten[slot] >= 0) {
        continue;
      }
      let countText: string = cells[1].textContent();
      if (countText.match(/\d/) === null && cells.length > 2) {
        countText = cells[cells.length - 1].textContent();
      }
      const cm: RegExpMatchArray | null = countText.match(/([\d,]+)/);
      if (cm === null) {
        continue;
      }
      const n: number = parseInt(cm[1].split(',').join(''), 10);
      if (!isNaN(n) && n >= 0) {
        ten[slot] = n;
      }
    }

    // 十档表：命中至少 8 档才认
    let hitTen: number = 0;
    for (let i = 0; i < 10; i++) {
      if (ten[i] >= 0) {
        hitTen++;
      }
    }
    if (hitTen >= 8) {
      for (let i = 0; i < 10; i++) {
        if (ten[i] < 0) {
          ten[i] = 0;
        }
      }
      return ten;
    }

    // 五档表：把命中项折到 5 个位置（下标 0 = 5 星）；两档都没命中就算解析失败
    const five: number[] = [];
    for (let i = 0; i < 5; i++) {
      five.push(-1);
    }
    for (let i = 0; i < 10; i++) {
      if (ten[i] < 0) {
        continue;
      }
      const star: number = 10 - i;
      if (star >= 1 && star <= 5) {
        five[5 - star] = ten[i];
      }
    }
    let hitFive: number = 0;
    for (let i = 0; i < 5; i++) {
      if (five[i] >= 0) {
        hitFive++;
      }
    }
    if (hitFive < 4) {
      return [];
    }
    for (let i = 0; i < 5; i++) {
      if (five[i] < 0) {
        five[i] = 0;
      }
    }
    return five;
  }

  /**
   * 给画廊打分（1..5 星）。
   *
   * 站点用的是 gallerypopups 的 `act=vote&rating=N`（与收藏同一入口，只换 act 与参数），
   * 成功时同样 302 回详情页，失败时 200 + "You must be logged in" —— 所以必须看正文。
   * 这里只做「提交」：提交后由调用方重新拉一次统计，不在本地推算新的平均分
   * （站点权重不公开，本地算出来的数字会和页面显示对不上）。
   */
  static async rateGallery(gallery: Gallery, stars: number): Promise<void> {
    if (stars < 1 || stars > 5) {
      throw new EhError('rate', '评分只能是 1~5');
    }
    if (!Cookies.isLoggedIn()) {
      throw new EhError('login', '请先登录后再评分');
    }
    const url: string = EhApi.favBase() + '/gallerypopups.php?gid=' +
      encodeURIComponent(gallery.gid) + '&t=' + encodeURIComponent(gallery.token) +
      '&act=vote&rating=' + stars.toString();
    const resp: HttpResp = await Http.get(url, gallery.url);
    if (resp.body.indexOf('You must be logged in') >= 0 ||
      resp.body.indexOf('You are not logged in') >= 0) {
      throw new EhError('login', '登录已失效，请重新登录');
    }
    if (resp.code >= 400) {
      throw new EhError('rate', '评分失败（HTTP ' + resp.code.toString() + '）');
    }
  }
}
