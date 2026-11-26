import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Site } from './Consts';
import { Db } from './Db';

const TAG: string = 'JHenTai.Prefs';
const STORE: string = 'jhentai';

/**
 * 偏好存储。
 *
 * 鸿蒙的 preferences 全异步，而 UI 到处要同步读配置，所以「一次性 load 到内存 +
 * 异步落盘」：读永远同步，写立刻返回，flush 失败只记日志（丢一次设置不该弹错）。
 */
export class Prefs {
  private static store: preferences.Preferences | null = null;
  private static nums: Map<string, number> = new Map<string, number>();
  private static strs: Map<string, string> = new Map<string, string>();
  private static bools: Map<string, boolean> = new Map<string, boolean>();
  private static ready: boolean = false;

  static async init(ctx: common.UIAbilityContext): Promise<void> {
    if (Prefs.ready) {
      return;
    }
    try {
      Prefs.store = await preferences.getPreferences(ctx, STORE);
      const all: preferences.ValueType = await Prefs.store.getAll();
      const obj: Record<string, preferences.ValueType> = all as Record<string, preferences.ValueType>;
      const keys: string[] = Object.keys(obj);
      for (let i = 0; i < keys.length; i++) {
        const k: string = keys[i];
        const v: preferences.ValueType = obj[k];
        if (typeof v === 'number') {
          Prefs.nums.set(k, v);
        } else if (typeof v === 'boolean') {
          Prefs.bools.set(k, v);
        } else if (typeof v === 'string') {
          Prefs.strs.set(k, v);
        }
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'init failed: %{public}s', JSON.stringify(e));
    }
    Prefs.ready = true;
  }

  static num(key: string, def: number): number {
    const v: number | undefined = Prefs.nums.get(key);
    return v === undefined ? def : v;
  }

  static str(key: string, def: string): string {
    const v: string | undefined = Prefs.strs.get(key);
    return v === undefined ? def : v;
  }

  static bool(key: string, def: boolean): boolean {
    const v: boolean | undefined = Prefs.bools.get(key);
    return v === undefined ? def : v;
  }

  static put(key: string, value: number | string | boolean): void {
    if (typeof value === 'number') {
      Prefs.nums.set(key, value);
    } else if (typeof value === 'boolean') {
      Prefs.bools.set(key, value);
    } else {
      Prefs.strs.set(key, value);
    }
    const s: preferences.Preferences | null = Prefs.store;
    if (s === null) {
      return;
    }
    s.put(key, value).then(() => s.flush()).catch((err: Error) => {
      hilog.warn(0x0000, TAG, 'flush failed: %{public}s', err.message);
    });
  }

  // ------------------------------------------------------------ 站点
  static site(): Site {
    return Prefs.str('site', 'EH') === 'EX' ? Site.EX : Site.EH;
  }

  static setSite(site: Site): void {
    Prefs.put('site', site === Site.EX ? 'EX' : 'EH');
  }

  static columns(): number {
    return Prefs.num('list_columns', 2);
  }

  static setColumns(n: number): void {
    Prefs.put('list_columns', n);
  }

  static listStyle(): string {
    // 默认 compact：这是移植版最初的观感，用户已经看过；其余三种是可选
    return Prefs.str('list_style', 'compact');
  }

  static setListStyle(s: string): void {
    Prefs.put('list_style', s);
    // 列表页用 @StorageProp('listStyle') 订阅，切 tab 回来就能立刻换样式
    AppStorage.setOrCreate<string>('listStyle', s);
  }
}

/**
 * 本地历史记录（最近浏览的画廊）。
 *
 * 数据本身已经搬到关系型库（见 core/Db.ets），这里保留原来的同步 API：
 * DetailPage、设置页等调用点不用改一行，读的是 Db 的内存镜像。
 * 库还没打开时 Db 返回空数组/丢弃写入，所以这里不会抛异常。
 */
export class HistoryItem {
  gid: string = '';
  token: string = '';
  title: string = '';
  thumb: string = '';
  category: string = '';
  color: string = '';
  time: number = 0;
}

export class History {
  private static readonly LIMIT: number = 200;

  static list(): HistoryItem[] {
    return Db.history(History.LIMIT, 0);
  }

  static push(item: HistoryItem): void {
    Db.addHistory(item);
  }

  static clear(): void {
    Db.clearHistory();
  }
}

/** 本地收藏（服务端收藏夹之外的“稍后再看”） */
export class LocalFav {
  static list(): HistoryItem[] {
    return Db.favList();
  }

  static has(gid: string): boolean {
    return Db.isFav(gid);
  }

  static toggle(item: HistoryItem): boolean {
    return Db.favToggle(item);
  }
}

/** 搜索历史 */
export class SearchHistory {
  private static readonly KEY: string = 'search_history';
  private static readonly LIMIT: number = 30;

  static list(): string[] {
    const raw: string = Prefs.str(SearchHistory.KEY, '');
    if (raw.length === 0) {
      return [];
    }
    try {
      return JSON.parse(raw) as string[];
    } catch (e) {
      return [];
    }
  }

  static push(keyword: string): void {
    const k: string = keyword.trim();
    if (k.length === 0) {
      return;
    }
    const list: string[] = SearchHistory.list();
    const out: string[] = [k];
    for (let i = 0; i < list.length; i++) {
      if (list[i] !== k && out.length < SearchHistory.LIMIT) {
        out.push(list[i]);
      }
    }
    Prefs.put(SearchHistory.KEY, JSON.stringify(out));
  }

  static clear(): void {
    Prefs.put(SearchHistory.KEY, '');
  }
}
