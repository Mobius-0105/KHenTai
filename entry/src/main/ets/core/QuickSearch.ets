import { EhApi } from './EhApi';
import { Prefs } from './Prefs';

/**
 * 一条快捷搜索：key 是按钮文字，url 是点下去直接加载的地址。
 *
 * 为什么存 url 而不是存关键词：快捷搜索里既有「收藏夹 / 观看记录」这种固定页，
 * 也有「3 星以上」这种带 EH 高级语法的查询。统一成最终 URL 后，
 * 搜索页执行快捷搜索的路径就只有「把 url 交给列表」一条，不需要再分词拼参数。
 */
export class QuickSearchItem {
  key: string = '';
  url: string = '';

  constructor(key: string, url: string) {
    this.key = key;
    this.url = url;
  }
}

/**
 * 快捷搜索（对应 JHenTai 原版搜索页顶部那一排快捷入口）。
 *
 * 存储格式：Prefs 里 key = 'quick_searches'，值是一个 JSON 字符串数组，
 * 每项 `{"key":"...","url":"..."}`。不用对象字面量构造 —— ArkTS 不允许
 * 用字面量直接当类实例，所以写入前都先 new QuickSearchItem。
 */
export class QuickSearch {
  private static readonly KEY: string = 'quick_searches';
  private static readonly LIMIT: number = 20;

  /**
   * 预置项。只在用户从没动过快捷搜索时返回（存储值为空串）。
   *
   * 用静态方法而不是常量数组：里面的域名由当前站点设置决定，
   * 用户在设置里切到 EX 站之后再首次进入搜索页，预置项就是 exhentai 的地址。
   *
   * 原版的 "Same Uploader / 同一上传者" 需要「当前画廊的 uploader」这个上下文，
   * 搜索页没有画廊对象，做不成静态预置项，所以这里换成几个全局可用的筛选。
   */
  static defaults(): QuickSearchItem[] {
    const out: QuickSearchItem[] = [];
    out.push(new QuickSearchItem('收藏夹', EhApi.favUrl(0, 0)));
    out.push(new QuickSearchItem('观看记录', EhApi.watchedUrl(0)));
    out.push(new QuickSearchItem('热门', EhApi.popularUrl(0)));
    out.push(new QuickSearchItem('3星以上', EhApi.searchUrl('rating:>=3', 0)));
    out.push(new QuickSearchItem('4星以上', EhApi.searchUrl('rating:>=4', 0)));
    out.push(new QuickSearchItem('中文翻译', EhApi.searchUrl('language:chinese$', 0)));
    out.push(new QuickSearchItem('日文原版', EhApi.searchUrl('language:japanese$', 0)));
    return out;
  }

  /**
   * 读取。
   *
   * '' 与 '[]' 必须区分：前者是「从没写过」，返回预置项且**不落盘**；
   * 后者是「用户把最后一条也删了」，返回空。若把两者都当空处理，
   * 用户删光之后预置项会在下次进页面时又冒出来。
   */
  static list(): QuickSearchItem[] {
    const raw: string = Prefs.str(QuickSearch.KEY, '');
    if (raw.length === 0) {
      return QuickSearch.defaults();
    }
    let arr: QuickSearchItem[] = [];
    try {
      arr = JSON.parse(raw) as QuickSearchItem[];
    } catch (e) {
      // 存储被写坏（手改、旧版本格式）时当作空，不让搜索页崩掉
      return [];
    }
    if (arr === null || arr === undefined) {
      return [];
    }
    const out: QuickSearchItem[] = [];
    for (let i = 0; i < arr.length; i++) {
      const it: QuickSearchItem = arr[i];
      if (it === null || it === undefined) {
        continue;
      }
      if (typeof it.key !== 'string' || typeof it.url !== 'string') {
        continue;
      }
      if (it.key.length > 0 && it.url.length > 0) {
        out.push(new QuickSearchItem(it.key, it.url));
      }
    }
    return out;
  }

  /** 新增（按 key 去重，新的排最前）。首次新增会把当前预置项一起落盘 */
  static add(item: QuickSearchItem): void {
    const key: string = item.key.trim();
    const url: string = item.url.trim();
    if (key.length === 0 || url.length === 0) {
      return;
    }
    const cur: QuickSearchItem[] = QuickSearch.list();
    const out: QuickSearchItem[] = [];
    out.push(new QuickSearchItem(key, url));
    for (let i = 0; i < cur.length; i++) {
      if (cur[i].key !== key && out.length < QuickSearch.LIMIT) {
        out.push(cur[i]);
      }
    }
    Prefs.put(QuickSearch.KEY, JSON.stringify(out));
  }

  /** 删除一条；删到空也要写 '[]'，否则会被当成「未初始化」而复活预置项 */
  static remove(key: string): void {
    const cur: QuickSearchItem[] = QuickSearch.list();
    const out: QuickSearchItem[] = [];
    for (let i = 0; i < cur.length; i++) {
      if (cur[i].key !== key) {
        out.push(cur[i]);
      }
    }
    Prefs.put(QuickSearch.KEY, JSON.stringify(out));
  }
}
