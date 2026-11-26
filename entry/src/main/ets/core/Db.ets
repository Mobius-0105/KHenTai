import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HistoryItem, Prefs } from './Prefs';

const TAG: string = 'JHenTai.Db';
/** 数据库文件名。与原版一致：历史/本地收藏都落这一张库 */
const DB_NAME: string = 'jhentai.db';

/**
 * 表结构：两张表字段完全一致，只是语义不同（history = 看过的，local_fav = 想再看）。
 * ts 用毫秒时间戳，排序/分页都靠它；gid 做主键，重复浏览走 REPLACE 覆盖旧行。
 */
const SQL_HISTORY: string = 'CREATE TABLE IF NOT EXISTS history (' +
  'gid TEXT PRIMARY KEY, token TEXT, title TEXT, thumb TEXT, ' +
  'category TEXT, color TEXT, ts INTEGER)';

const SQL_FAV: string = 'CREATE TABLE IF NOT EXISTS local_fav (' +
  'gid TEXT PRIMARY KEY, token TEXT, title TEXT, thumb TEXT, ' +
  'category TEXT, color TEXT, ts INTEGER)';

const SQL_IDX_HISTORY: string = 'CREATE INDEX IF NOT EXISTS idx_history_ts ON history (ts)';
const SQL_IDX_FAV: string = 'CREATE INDEX IF NOT EXISTS idx_fav_ts ON local_fav (ts)';

/**
 * 图片页映射表：`/s/` 页地址 → 图片直链。
 *
 * 这是详情页/阅读器底部条的**最大一笔省**：一格里本来要「HTML 往返 + 图片往返」两次，
 * 有了这张表，第二次进同一本画廊就只剩图片往返（而且字节多半也在 ImageDiskCache 里）。
 *
 * 为什么不放 preferences：一本 1000 页的画廊就是 1000 条，preferences 每次 flush 都要把
 * 整个 JSON 重写一遍，写放大太狠；而且这里天然是「按主键覆盖 + 按时间淘汰」的表语义。
 */
const SQL_PAGE_MAP: string = 'CREATE TABLE IF NOT EXISTS page_map (' +
  'page_key TEXT PRIMARY KEY, image_url TEXT, w INTEGER, h INTEGER, ts INTEGER)';
/** 按 ts 淘汰要用到，查询侧也有 ORDER BY ts，没索引会整表扫 */
const SQL_IDX_PAGE_MAP: string = 'CREATE INDEX IF NOT EXISTS idx_page_map_ts ON page_map (ts)';

/**
 * 画廊元数据缓存（gdata 的补充结果）。
 *
 * 为什么单独一张表：列表页的评分只能来自 gdata（HTML 里没有数字，见 EhApi.parseRow），
 * 而 gdata 被 EH 限制成 1 req/s，一次列表 25 条就要排 1 秒起。缓存命中时**同步**返回，
 * 首屏直接就是有星的状态，不用再等网络。
 *
 * 字段只存「能复用且不会变坏」的两项：rating / pages。tags 不缓存 —— 它体积大、
 * 而且列表 HTML 已有标签时要优先保留 HTML 的 name（翻译要用），缓存反而会造成覆盖。
 */
const SQL_GALLERY_META: string = 'CREATE TABLE IF NOT EXISTS gallery_meta (' +
  'gid TEXT PRIMARY KEY, rating REAL, pages INTEGER, ts INTEGER)';
const SQL_IDX_GALLERY_META: string = 'CREATE INDEX IF NOT EXISTS idx_gallery_meta_ts ON gallery_meta (ts)';

/**
 * 元数据有效期：30 天。
 *
 * 评分是慢变量（一个画廊的分数不会天天变），30 天足够省掉绝大部分 gdata 请求；
 * 过期条目在**读取时**当场删除，与 page_map 同一套「读时淘汰」，不挂后台任务。
 */
const META_TTL: number = 30 * 24 * 60 * 60 * 1000;
/** 缓存条数上限：正常使用一年也就几万条，这里兜个底，防止长期累积把内存镜像撑大 */
const META_CAP: number = 20000;


const COLS: string = 'gid, token, title, thumb, category, color, ts';

/**
 * 映射在内存里的保留条数。
 *
 * 4000 条 ≈ 4 本千页画廊的「最近浏览」，JS 侧约 1MB 内；再多对命中率没有实质帮助，
 * 只是白占内存。超出的按「最久没写」淘汰（内存 + 库一起删）。
 */
const PAGE_MAP_CAP: number = 4000;
/**
 * 映射有效期：7 天。
 *
 * 图床直链带一次性 token（`?nl=…&nm=…`），放久了必然 403。7 天是「够用」和「必然失效」
 * 之间的折中：过期条目在**读取时**丢弃，不依赖后台任务去清。
 */
const PAGE_MAP_TTL: number = 7 * 24 * 60 * 60 * 1000;

/** 旧 preferences JSON 里的一行：这些字段在历史版本里增删过，所以全部按可选处理 */
interface LegacyRow {
  gid?: string;
  token?: string;
  title?: string;
  thumb?: string;
  category?: string;
  color?: string;
  time?: number;
}

/** 一条「页地址 → 图片直链」映射（内存镜像，不含 page_key —— 它是 Map 的键） */
class PageImage {
  url: string = '';
  w: number = 0;
  h: number = 0;
  /** 写入时间（毫秒）：TTL 判定 + 淘汰排序都用它 */
  ts: number = 0;
}

/** 一条画廊元数据（内存镜像，gid 是 Map 的键，所以不重复存） */
export class GalleryMetaRow {
  rating: number = 0;
  pages: number = -1;
  /** 写入时间（毫秒）：TTL 判定与容量淘汰都用它 */
  ts: number = 0;
}

/**
 * 浏览历史 / 本地收藏的关系型存储。
 *
 * 为什么要有内存缓存：Prefs 里的 `History.list()` / `LocalFav.has()` 是同步调用
 * （详情页 build 期间就要同步判断收藏态），而 relationalStore 全是异步。
 * 所以启动时把整张表读进内存（历史最多 200 条、收藏量级更小），
 * 读走内存、写先改内存再异步落库——UI 行为与原来的 preferences JSON 完全一致。
 *
 * 失败策略：所有 DB 操作都 catch 降级。数据库打不开时读返回空、写直接丢弃，
 * 绝不把异常抛给页面（历史丢了可以再点一次，崩掉不行）。
 */
export class Db {
  private static store: relationalStore.RdbStore | null = null;
  /** 历史的内存镜像，按 ts 倒序 */
  private static hist: HistoryItem[] = [];
  /** 本地收藏的内存镜像，按 ts 倒序 */
  private static favs: HistoryItem[] = [];
  /**
   * 图片页映射的内存镜像（键 = `/s/` 页地址）。
   *
   * 必须是同步可读的：详情页 build / onAppear 里就要立刻判断「这一格能不能跳过 HTML」，
   * 而 relationalStore 全异步。所以注入点只有两处 —— 启动时整表灌一次、写入时就地更新。
   * Map 的迭代顺序 = 插入顺序，淘汰最旧的直接从 keys().next() 拿，不需要额外排序。
   */
  private static pageMap: Map<string, PageImage> = new Map<string, PageImage>();
  /** 画廊元数据的内存镜像（键 = gid）：列表首屏要同步读评分，所以必须常驻 */
  private static metaMap: Map<string, GalleryMetaRow> = new Map<string, GalleryMetaRow>();
  private static inited: boolean = false;
  /** 历史保留上限，与原 Prefs 版本一致 */
  static readonly HISTORY_LIMIT: number = 200;

  /**
   * 打开数据库 + 建表 + 灌内存缓存 + 迁移旧 preferences JSON。
   * 多次调用只生效一次；失败也会置 inited，避免每次读写都重试开库。
   */
  static async init(ctx: common.UIAbilityContext): Promise<void> {
    if (Db.inited) {
      return;
    }
    Db.inited = true;
    try {
      const cfg: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const s: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, cfg);
      await s.executeSql(SQL_HISTORY);
      await s.executeSql(SQL_FAV);
      await s.executeSql(SQL_IDX_HISTORY);
      await s.executeSql(SQL_IDX_FAV);
      Db.store = s;
      await Db.reloadCache();
      await Db.migrateLegacy();
      // 映射表单独一段 try：它只是「加速用的可丢数据」，建表/读表失败不能让历史也一起失效
      try {
        await s.executeSql(SQL_PAGE_MAP);
        await s.executeSql(SQL_IDX_PAGE_MAP);
        await Db.loadPageMap();
        await Db.purgePageMap();
      } catch (e) {
        hilog.warn(0x0000, TAG, 'page_map init failed: %{public}s', JSON.stringify(e));
      }
      // 元数据缓存同理：只是「省 gdata 请求」的加速层，失败不能影响历史/收藏
      try {
        await s.executeSql(SQL_GALLERY_META);
        await s.executeSql(SQL_IDX_GALLERY_META);
        await Db.loadGalleryMeta();
        await Db.purgeGalleryMeta();
      } catch (e) {
        hilog.warn(0x0000, TAG, 'gallery_meta init failed: %{public}s', JSON.stringify(e));
      }
    } catch (e) {
      Db.store = null;
      hilog.error(0x0000, TAG, 'init failed: %{public}s', JSON.stringify(e));
    }
  }

  static ready(): boolean {
    return Db.store !== null;
  }

  // ------------------------------------------------------------------ 历史
  /** 按时间倒序取一段历史（同步读内存） */
  static history(limit: number, offset: number): HistoryItem[] {
    const start: number = offset < 0 ? 0 : offset;
    if (start >= Db.hist.length) {
      return [];
    }
    const end: number = limit <= 0 ? Db.hist.length : start + limit;
    return Db.hist.slice(start, Math.min(end, Db.hist.length));
  }

  /** 记一条浏览历史：同 gid 覆盖，超出上限的旧记录淘汰 */
  static addHistory(item: HistoryItem): void {
    if (item.gid.length === 0) {
      return;
    }
    if (item.time <= 0) {
      item.time = Date.now();
    }
    const next: HistoryItem[] = [item];
    for (let i = 0; i < Db.hist.length; i++) {
      if (Db.hist[i].gid !== item.gid && next.length < Db.HISTORY_LIMIT) {
        next.push(Db.hist[i]);
      }
    }
    Db.hist = next;
    Db.insertRow('history', item);
    Db.trimHistory();
  }

  static deleteHistory(gid: string): void {
    const kept: HistoryItem[] = [];
    for (let i = 0; i < Db.hist.length; i++) {
      if (Db.hist[i].gid !== gid) {
        kept.push(Db.hist[i]);
      }
    }
    Db.hist = kept;
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return;
    }
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('history');
    p.equalTo('gid', gid);
    s.delete(p).catch((err: Error) => {
      hilog.warn(0x0000, TAG, 'delete history failed: %{public}s', err.message);
    });
  }

  static clearHistory(): void {
    Db.hist = [];
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return;
    }
    s.executeSql('DELETE FROM history').catch((err: Error) => {
      hilog.warn(0x0000, TAG, 'clear history failed: %{public}s', err.message);
    });
  }

  // ------------------------------------------------------------- 本地收藏
  static favList(): HistoryItem[] {
    return Db.favs.slice(0);
  }

  static isFav(gid: string): boolean {
    for (let i = 0; i < Db.favs.length; i++) {
      if (Db.favs[i].gid === gid) {
        return true;
      }
    }
    return false;
  }

  /** 切换收藏，返回切换后的状态（true = 现在是收藏） */
  static favToggle(item: HistoryItem): boolean {
    if (item.gid.length === 0) {
      return false;
    }
    let hit: boolean = false;
    const kept: HistoryItem[] = [];
    for (let i = 0; i < Db.favs.length; i++) {
      if (Db.favs[i].gid === item.gid) {
        hit = true;
      } else {
        kept.push(Db.favs[i]);
      }
    }
    if (hit) {
      Db.favs = kept;
      const s: relationalStore.RdbStore | null = Db.store;
      if (s !== null) {
        const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('local_fav');
        p.equalTo('gid', item.gid);
        s.delete(p).catch((err: Error) => {
          hilog.warn(0x0000, TAG, 'unfav failed: %{public}s', err.message);
        });
      }
      return false;
    }
    if (item.time <= 0) {
      item.time = Date.now();
    }
    const next: HistoryItem[] = [item];
    for (let i = 0; i < kept.length; i++) {
      next.push(kept[i]);
    }
    Db.favs = next;
    Db.insertRow('local_fav', item);
    return true;
  }

  // ---------------------------------------------------------- 图片页映射缓存
  /**
   * 查某一页的图片直链（同步读内存）；未命中 / 已过期返回空串。
   *
   * 过期就**当场丢掉**（内存 + 库），不做后台清扫：读取方只有详情页和阅读器底部条，
   * 一次读取顺带删一行的代价可以忽略，却省掉了一个后台任务和它的时序问题。
   */
  static pageImage(pageUrl: string): string {
    const e: PageImage | undefined = Db.pageMap.get(pageUrl);
    if (e === undefined) {
      return '';
    }
    if (Date.now() - e.ts > PAGE_MAP_TTL) {
      Db.dropPageImage(pageUrl);
      return '';
    }
    return e.url;
  }

  /** 记一条映射：内存立刻生效，库异步覆盖（同 key 走 REPLACE） */
  static putPageImage(pageUrl: string, imageUrl: string, w: number, h: number): void {
    if (pageUrl.length === 0 || imageUrl.length === 0) {
      return;
    }
    const e: PageImage = new PageImage();
    e.url = imageUrl;
    e.w = w;
    e.h = h;
    e.ts = Date.now();
    // 先删再设：让这一条回到 Map 的尾部（= 最新），淘汰时被先丢掉的才是真的最旧
    Db.pageMap.delete(pageUrl);
    Db.pageMap.set(pageUrl, e);
    Db.trimPageMap();
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return;
    }
    const v: relationalStore.ValuesBucket = {
      'page_key': pageUrl,
      'image_url': imageUrl,
      'w': w,
      'h': h,
      'ts': e.ts
    };
    s.insert('page_map', v, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE).catch((err: Error) => {
      hilog.warn(0x0000, TAG, 'put page_map failed: %{public}s', err.message);
    });
  }

  /**
   * 删一条映射（图片直链失效时的自愈入口）。
   *
   * 只删映射不删字节缓存：字节缓存是按同一把键存的，调用方要清字节得自己调
   * ImageDiskCache.remove —— 大多数失效只是直链 token 过期，字节本身还是好的。
   */
  static dropPageImage(pageUrl: string): void {
    if (pageUrl.length === 0) {
      return;
    }
    Db.pageMap.delete(pageUrl);
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return;
    }
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('page_map');
    p.equalTo('page_key', pageUrl);
    s.delete(p).catch((err: Error) => {
      hilog.warn(0x0000, TAG, 'drop page_map failed: %{public}s', err.message);
    });
  }

  /** 当前映射条数（设置页/诊断用，同步） */
  static pageMapSize(): number {
    return Db.pageMap.size;
  }

  private static async loadPageMap(): Promise<void> {
    Db.pageMap.clear();
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return;
    }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql: string = 'SELECT page_key, image_url, w, h, ts FROM page_map ORDER BY ts DESC LIMIT ?';
      const args: Array<relationalStore.ValueType> = [PAGE_MAP_CAP];
      rs = await s.querySql(sql, args);
      const keys: string[] = [];
      const rows: PageImage[] = [];
      while (rs.goToNextRow()) {
        const e: PageImage = new PageImage();
        keys.push(rs.getString(rs.getColumnIndex('page_key')));
        e.url = rs.getString(rs.getColumnIndex('image_url'));
        e.w = rs.getLong(rs.getColumnIndex('w'));
        e.h = rs.getLong(rs.getColumnIndex('h'));
        e.ts = rs.getLong(rs.getColumnIndex('ts'));
        rows.push(e);
      }
      // 库是倒序取的，反过来灌才让 Map 的插入顺序 = 从旧到新（淘汰从头删）
      for (let i = rows.length - 1; i >= 0; i--) {
        if (keys[i].length > 0 && rows[i].url.length > 0) {
          Db.pageMap.set(keys[i], rows[i]);
        }
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'load page_map failed: %{public}s', JSON.stringify(e));
    }
    if (rs !== null) {
      rs.close();
    }
  }

  /** 启动清一次过期行：不指望「读时丢弃」把几万条旧行也读一遍 */
  private static async purgePageMap(): Promise<void> {
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return;
    }
    const sql: string = 'DELETE FROM page_map WHERE ts < ?';
    const args: Array<relationalStore.ValueType> = [Date.now() - PAGE_MAP_TTL];
    try {
      await s.executeSql(sql, args);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'purge page_map failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 超容量时丢最旧的（内存 + 库），与历史表 trimHistory 同一套思路 */
  private static trimPageMap(): void {
    const s: relationalStore.RdbStore | null = Db.store;
    while (Db.pageMap.size > PAGE_MAP_CAP) {
      const oldest: string | undefined = Db.pageMap.keys().next().value;
      if (oldest === undefined) {
        return;
      }
      Db.pageMap.delete(oldest);
      if (s !== null) {
        const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('page_map');
        p.equalTo('page_key', oldest);
        s.delete(p).catch((err: Error) => {
          hilog.warn(0x0000, TAG, 'trim page_map failed: %{public}s', err.message);
        });
      }
    }
  }

  // ------------------------------------------------------------ 画廊元数据缓存
  /**
   * 查一条 gdata 元数据（同步读内存）；未命中 / 已过期返回 null。
   *
   * 过期**当场删**（内存 + 库），理由与 pageImage 相同：读方就在列表首屏，
   * 一次读取删一行的代价可以忽略，却省掉后台清扫任务的时序问题。
   */
  static galleryMeta(gid: string): GalleryMetaRow | null {
    if (gid.length === 0) {
      return null;
    }
    const e: GalleryMetaRow | undefined = Db.metaMap.get(gid);
    if (e === undefined) {
      return null;
    }
    if (Date.now() - e.ts > META_TTL) {
      Db.dropGalleryMeta(gid);
      return null;
    }
    return e;
  }

  /** 写一条元数据：内存立刻生效，库异步覆盖（同 gid 走 REPLACE） */
  static putGalleryMeta(gid: string, rating: number, pages: number): void {
    if (gid.length === 0) {
      return;
    }
    const e: GalleryMetaRow = new GalleryMetaRow();
    e.rating = rating;
    e.pages = pages;
    e.ts = Date.now();
    // 先删再设：让它回到 Map 尾部（= 最新），容量淘汰时被丢掉的才是真最旧
    Db.metaMap.delete(gid);
    Db.metaMap.set(gid, e);
    Db.trimGalleryMeta();
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return;
    }
    const v: relationalStore.ValuesBucket = {
      'gid': gid,
      'rating': rating,
      'pages': pages,
      'ts': e.ts
    };
    s.insert('gallery_meta', v, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE)
      .catch((err: Error) => {
        hilog.warn(0x0000, TAG, 'put gallery_meta failed: %{public}s', err.message);
      });
  }

  static dropGalleryMeta(gid: string): void {
    Db.metaMap.delete(gid);
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return;
    }
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('gallery_meta');
    p.equalTo('gid', gid);
    s.delete(p).catch((err: Error) => {
      hilog.warn(0x0000, TAG, 'drop gallery_meta failed: %{public}s', err.message);
    });
  }

  private static async loadGalleryMeta(): Promise<void> {
    Db.metaMap.clear();
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return;
    }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql: string = 'SELECT gid, rating, pages, ts FROM gallery_meta ORDER BY ts DESC LIMIT ?';
      const args: Array<relationalStore.ValueType> = [META_CAP];
      rs = await s.querySql(sql, args);
      const keys: string[] = [];
      const rows: GalleryMetaRow[] = [];
      while (rs.goToNextRow()) {
        const e: GalleryMetaRow = new GalleryMetaRow();
        keys.push(rs.getString(rs.getColumnIndex('gid')));
        e.rating = rs.getDouble(rs.getColumnIndex('rating'));
        e.pages = rs.getLong(rs.getColumnIndex('pages'));
        e.ts = rs.getLong(rs.getColumnIndex('ts'));
        rows.push(e);
      }
      // 库是倒序取的，反过来灌才让 Map 插入顺序 = 从旧到新（淘汰从头删）
      for (let i = rows.length - 1; i >= 0; i--) {
        if (keys[i].length > 0) {
          Db.metaMap.set(keys[i], rows[i]);
        }
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'load gallery_meta failed: %{public}s', JSON.stringify(e));
    }
    if (rs !== null) {
      rs.close();
    }
  }

  /** 启动清一次过期行：与 purgePageMap 同一个理由，别指望读时淘汰能覆盖全部旧行 */
  private static async purgeGalleryMeta(): Promise<void> {
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return;
    }
    const sql: string = 'DELETE FROM gallery_meta WHERE ts < ?';
    const args: Array<relationalStore.ValueType> = [Date.now() - META_TTL];
    try {
      await s.executeSql(sql, args);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'purge gallery_meta failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 超容量时丢最旧的（内存 + 库），与 trimPageMap 同一套思路 */
  private static trimGalleryMeta(): void {
    const s: relationalStore.RdbStore | null = Db.store;
    while (Db.metaMap.size > META_CAP) {
      const oldest: string | undefined = Db.metaMap.keys().next().value;
      if (oldest === undefined) {
        return;
      }
      Db.metaMap.delete(oldest);
      if (s !== null) {
        const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('gallery_meta');
        p.equalTo('gid', oldest);
        s.delete(p).catch((err: Error) => {
          hilog.warn(0x0000, TAG, 'trim gallery_meta failed: %{public}s', err.message);
        });
      }
    }
  }

  // ------------------------------------------------------------------ 内部
  private static async reloadCache(): Promise<void> {
    Db.hist = await Db.load('history', Db.HISTORY_LIMIT);
    Db.favs = await Db.load('local_fav', Db.HISTORY_LIMIT);
  }

  /** 读整张表（倒序）。查询失败返回空数组，调用方不用判 null */
  private static async load(table: string, limit: number): Promise<HistoryItem[]> {
    const out: HistoryItem[] = [];
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return out;
    }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql: string = 'SELECT ' + COLS + ' FROM ' + table + ' ORDER BY ts DESC LIMIT ?';
      const args: Array<relationalStore.ValueType> = [limit];
      rs = await s.querySql(sql, args);
      while (rs.goToNextRow()) {
        out.push(Db.readRow(rs));
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'load %{public}s failed: %{public}s', table, JSON.stringify(e));
    }
    if (rs !== null) {
      rs.close();
    }
    return out;
  }

  private static readRow(rs: relationalStore.ResultSet): HistoryItem {
    const item: HistoryItem = new HistoryItem();
    item.gid = rs.getString(rs.getColumnIndex('gid'));
    item.token = rs.getString(rs.getColumnIndex('token'));
    item.title = rs.getString(rs.getColumnIndex('title'));
    item.thumb = rs.getString(rs.getColumnIndex('thumb'));
    item.category = rs.getString(rs.getColumnIndex('category'));
    item.color = rs.getString(rs.getColumnIndex('color'));
    item.time = rs.getLong(rs.getColumnIndex('ts'));
    return item;
  }

  /** 写一行（主键冲突直接覆盖）。异步失败只记日志 */
  private static insertRow(table: string, item: HistoryItem): void {
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return;
    }
    const v: relationalStore.ValuesBucket = {
      'gid': item.gid,
      'token': item.token,
      'title': item.title,
      'thumb': item.thumb,
      'category': item.category,
      'color': item.color,
      'ts': item.time
    };
    s.insert(table, v, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE).catch((err: Error) => {
      hilog.warn(0x0000, TAG, 'insert %{public}s failed: %{public}s', table, err.message);
    });
  }

  /** 超出上限的历史在库侧删掉，避免库无限长（内存里已经截断过了） */
  private static trimHistory(): void {
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return;
    }
    const sql: string = 'DELETE FROM history WHERE gid NOT IN ' +
      '(SELECT gid FROM history ORDER BY ts DESC LIMIT ?)';
    const args: Array<relationalStore.ValueType> = [Db.HISTORY_LIMIT];
    s.executeSql(sql, args).catch((err: Error) => {
      hilog.warn(0x0000, TAG, 'trim history failed: %{public}s', err.message);
    });
  }

  /**
   * 一次性迁移：旧版本把历史和本地收藏存成 preferences 里的 JSON 字符串。
   * 只在库里没有任何数据时导入，导入完把旧 key 清空，之后不再触发。
   */
  private static async migrateLegacy(): Promise<void> {
    let changed: boolean = false;
    if (Db.hist.length === 0) {
      const raw: string = Prefs.str('history', '');
      if (raw.length > 0) {
        const arr: HistoryItem[] = Db.parseLegacy(raw);
        for (let i = 0; i < arr.length; i++) {
          await Db.putAwait('history', arr[i]);
        }
        Prefs.put('history', '');
        changed = arr.length > 0;
      }
    }
    if (Db.favs.length === 0) {
      const raw: string = Prefs.str('local_fav', '');
      if (raw.length > 0) {
        const arr: HistoryItem[] = Db.parseLegacy(raw);
        for (let i = 0; i < arr.length; i++) {
          await Db.putAwait('local_fav', arr[i]);
        }
        Prefs.put('local_fav', '');
        changed = changed || arr.length > 0;
      }
    }
    if (changed) {
      await Db.reloadCache();
      hilog.info(0x0000, TAG, 'legacy prefs migrated: history=%{public}d fav=%{public}d',
        Db.hist.length, Db.favs.length);
    }
  }

  /** 旧 JSON -> HistoryItem[]。解析失败/字段缺失都退化成空串，不让脏数据阻断迁移 */
  private static parseLegacy(raw: string): HistoryItem[] {
    const out: HistoryItem[] = [];
    try {
      const arr: LegacyRow[] = JSON.parse(raw) as LegacyRow[];
      const now: number = Date.now();
      for (let i = 0; i < arr.length; i++) {
        const row: LegacyRow = arr[i];
        const gid: string = row.gid === undefined ? '' : row.gid;
        if (gid.length === 0) {
          continue;
        }
        const item: HistoryItem = new HistoryItem();
        item.gid = gid;
        item.token = row.token === undefined ? '' : row.token;
        item.title = row.title === undefined ? '' : row.title;
        item.thumb = row.thumb === undefined ? '' : row.thumb;
        item.category = row.category === undefined ? '' : row.category;
        item.color = row.color === undefined ? '' : row.color;
        // 老数据没有时间戳：按数组顺序递减补一个，保证迁移后顺序不变
        item.time = row.time === undefined || row.time <= 0 ? now - i * 1000 : row.time;
        out.push(item);
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'parse legacy failed: %{public}s', JSON.stringify(e));
    }
    return out;
  }

  /** 迁移专用：等这条 insert 真正落库，避免后面的 reloadCache 读不到 */
  private static async putAwait(table: string, item: HistoryItem): Promise<void> {
    const s: relationalStore.RdbStore | null = Db.store;
    if (s === null) {
      return;
    }
    const v: relationalStore.ValuesBucket = {
      'gid': item.gid,
      'token': item.token,
      'title': item.title,
      'thumb': item.thumb,
      'category': item.category,
      'color': item.color,
      'ts': item.time
    };
    try {
      await s.insert(table, v, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'migrate row failed: %{public}s', JSON.stringify(e));
    }
  }
}
