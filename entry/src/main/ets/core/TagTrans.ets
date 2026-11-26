import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Http, HttpResp } from './Http';
import { AppContext } from './AppContext';
import { Prefs } from './Prefs';

const TAG: string = 'JHenTai.TagTrans';

/**
 * EhTagTranslation 的 release 产物（纯文本 JSON，约 4 MB）。
 *
 * ## 根因记录（「标签库无法下载」就是这个地址）
 * 这里原先是：
 *   raw.githubusercontent.com/EhTagTranslation/Database/releases/latest/download/db.text.json
 * 但 **raw.githubusercontent.com 只服务仓库里的文件，不服务 release 资产**，实测该地址
 * 恒定 404（Content-Length: 14，正文 `404: Not Found`）。于是 download() 在
 * `res.code !== 200` 处直接 return false，用户点「更新数据库」只会看到
 * 「正在下载最新标签库…」→「更新失败（检查网络）」，标签库永远下不下来。
 * release 资产的正确入口在 github.com 上（302 → release-assets.githubusercontent.com），
 * 实测 200 且 Content-Length 约 4.29 MB，正文结构与本文件 parse() 的预期一致
 * （`data[].namespace` + `data[].data{key:{name}}`）。
 */
const URL: string = 'https://github.com/EhTagTranslation/Database/releases/latest/download/db.text.json';
const FILE_NAME: string = 'tagtrans.json';
/** 小于这个长度的响应一定是错误页 / 空响应，不值得去 JSON.parse */
const MIN_LEN: number = 1000;

/**
 * 「标签库已变」的全局重绘信号。
 *
 * ## 为什么需要它
 * `TagTrans.version` 是**普通静态字段**，改它不会让任何组件重绘；而列表卡片是首帧渲染完
 * 才异步载入标签库的。没有信号的话，用户第一次进首页看到的永远是英文，直到切页重建。
 *
 * 做成 AppStorage 里的单调计数（与 `favRevision` 同一套写法）而不是每个页面各自维护
 * @State：首页 / 搜索 / 收藏共用 GalleryListView 一处挂载，搜索页的以图搜图结果又是
 * 直接拿 GalleryCard 铺的 —— 计数器放全局，卡片自己 @Prop 收一个值就能覆盖全部入口，
 * 页面不需要各自接一条回调链。
 *
 * 写入点只有两处：
 *  1. `sync()`：列表页首帧（ensureLoaded 前后各一次）—— 覆盖 App 冷启动；
 *  2. 设置页切换「标签翻译」开关时 `bump()` —— 覆盖「从设置页返回列表立刻生效」。
 */
export class TagTransTick {
  static readonly KEY: string = 'tagTransTick';

  /** 自增一次：所有订阅了这个键的组件下一页重绘 */
  static bump(): void {
    const cur: number = AppStorage.get<number>(TagTransTick.KEY) ?? 0;
    AppStorage.setOrCreate<number>(TagTransTick.KEY, cur + 1);
  }

  /**
   * 列表页的唯一挂载点。
   *
   * 先 bump 一次再 await：从设置页返回时开关可能刚被改过，卡片要按**当前** Prefs
   * 重算一次文案；加载完成后再 bump 一次，把「首帧英文 → 载入后中文」补齐。
   */
  static sync(): void {
    TagTransTick.bump();
    TagTrans.ensureLoaded().then((_ok: boolean) => {
      // 失败也 bump：translate 会回落英文，但开关状态本身可能变了，重绘一次总没坏处
      TagTransTick.bump();
    });
  }

  /** 设置页切换开关后调用：不等加载，先把列表按新开关重算（译文没有就回落原文） */
  static settingsChanged(): void {
    TagTransTick.bump();
    if (Prefs.bool('tag_trans', false)) {
      // 用户刚打开翻译：顺手把库拉起来，加载完成后再 bump 一次（见 sync 的说明）
      TagTransTick.sync();
    }
  }
}

/**
 * 标签中文翻译。
 *
 * 数据源是 EhTagTranslation 的 db.text.json：
 *   {"data":[{"namespace":"female","data":{"stockings":{"name":"长袜","intro":""}}}]}
 *
 * 为什么用「内存 Map + 本地文件缓存」：
 *  - 翻译要跟着标签列表同步渲染，必须是同步查询，所以解析结果常驻内存；
 *  - 文件几十 MB，每次启动都重新下载不可接受，所以落盘后只解析本地文件；
 *  - JSON 体积大，解析耗时明显，用 pending 把并发调用合并成一次，避免首页多组件同时触发。
 *
 * 任何失败都不抛异常：翻译只是锦上添花，坏了就当没有，绝不能影响列表渲染。
 */
export class TagTrans {
  /** key = namespace + ':' + key，例如 female:stockings */
  private static map: Map<string, string> = new Map<string, string>();
  private static ready: boolean = false;
  /** 每次加载成功 +1：页面用它做 @Watch 触发重绘（否则首帧渲染完再加载完，界面不会更新） */
  static version: number = 0;
  /** 正在进行的加载，用来合并并发调用 */
  private static pending: Promise<boolean> | null = null;

  static isReady(): boolean {
    return TagTrans.ready;
  }

  /**
   * 是否跟随界面语言做翻译。
   *
   * 界面设成英文时，把标签名换成中文反而是噪音（原版也是同一条规则：
   * 非中文界面不套用中文标签库）。返回 false 时 translate() 直接给空串，
   * 调用方本来就把空串当「没有译文」，表现就是回落成英文原文。
   */
  static followLanguage(): boolean {
    return Prefs.str('lang', 'zh') !== 'en';
  }

  static async ensureLoaded(): Promise<boolean> {
    if (TagTrans.ready) {
      return true;
    }
    const running: Promise<boolean> | null = TagTrans.pending;
    if (running !== null) {
      return running;
    }
    const task: Promise<boolean> = TagTrans.loadOrDownload();
    TagTrans.pending = task;
    const ok: boolean = await task;
    TagTrans.pending = null;
    return ok;
  }

  /** 未命中返回空串（调用方据此判断“没有翻译”），不返回 key，避免把英文原文当译文显示 */
  static translate(ns: string, key: string): string {
    // 界面语言不是中文：不翻译，直接当「没有译文」，省掉一次 Map 查找也省得混杂
    if (!TagTrans.followLanguage()) {
      return '';
    }
    // 规范化后再查：站点给的 key 与标签库的 key 常有三种差异，任一种都会让「明明有译文
    // 却显示英文」——这不是缺数据，是同一个标签被当成了两个：
    //   1. 大小写（`Stockings` vs `stockings`）
    //   2. 下划线 vs 空格（`sole_male` vs `sole male`）
    //   3. 首尾/连续空白
    // 库里存的是小写 + 空格形式，所以查询侧统一往那个形式靠。
    const nsKey: string = ns.trim().toLowerCase();
    const norm: string = TagTrans.normalizeKey(key);
    const hit: string | undefined = TagTrans.map.get(nsKey + ':' + norm);
    if (hit !== undefined) {
      return hit;
    }
    // 再退一步：完全不规范化的原样查（万一库里就有带下划线的条目）
    const raw: string | undefined = TagTrans.map.get(nsKey + ':' + key.trim().toLowerCase());
    return raw === undefined ? '' : raw;
  }

  /** 把 key 归一到「小写 + 空格分隔」：`Sole_Male` → `sole male` */
  private static normalizeKey(key: string): string {
    return key.trim().toLowerCase().split('_').join(' ').replace(/\s+/g, ' ');
  }

  /** 强制重新下载并覆盖缓存；失败时旧内存数据已被清空，下次 ensureLoaded 会重试 */
  static async update(): Promise<boolean> {
    TagTrans.map = new Map<string, string>();
    TagTrans.ready = false;
    return TagTrans.download(TagTrans.cachePath());
  }

  static clear(): void {
    TagTrans.map.clear();
    TagTrans.ready = false;
    TagTrans.pending = null;
  }

  // ------------------------------------------------------------ 内部

  private static async loadOrDownload(): Promise<boolean> {
    const path: string = TagTrans.cachePath();
    if (path.length > 0 && TagTrans.parseFile(path)) {
      return true;
    }
    return TagTrans.download(path);
  }

  private static cachePath(): string {
    try {
      return AppContext.get().filesDir + '/' + FILE_NAME;
    } catch (e) {
      // AppContext 还没初始化（极早期调用）：不做缓存，仅走网络
      return '';
    }
  }

  private static parseFile(path: string): boolean {
    try {
      if (!fs.accessSync(path)) {
        return false;
      }
      const text: string = fs.readTextSync(path);
      if (text.length < MIN_LEN) {
        return false;
      }
      return TagTrans.parse(text);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'read cache failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  private static async download(cachePath: string): Promise<boolean> {
    try {
      const res: HttpResp = await TagTrans.fetchRelease(URL);
      if (res.code !== 200) {
        hilog.warn(0x0000, TAG, 'download http %{public}d', res.code);
        return false;
      }
      const text: string = res.body;
      // 长度先卡一道：错误页只有几百字节，直接丢给 JSON.parse 只会白费时间
      if (text.length < MIN_LEN) {
        hilog.warn(0x0000, TAG, 'download too short: %{public}d', text.length);
        return false;
      }
      if (!TagTrans.parse(text)) {
        return false;
      }
      TagTrans.save(cachePath, text);
      return true;
    } catch (e) {
      // Http.get 失败会抛 EhError，这里一并吞掉
      hilog.warn(0x0000, TAG, 'download failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /**
   * 取 release 资产。
   *
   * releases/latest/download/<asset> 一定是「302 → release-assets.githubusercontent.com」
   * 的两跳跳转：系统 http 默认会跟随，但个别网络环境下会被中间设备截成裸 302，
   * 那时 download() 只认 200 就会误判成失败。这里手工兜一跳，成本极低，也能让
   * 「换镜像 / 换 CDN」时同样有效（只要对方给 Location）。
   */
  private static async fetchRelease(url: string): Promise<HttpResp> {
    const res: HttpResp = await Http.get(url);
    const code: number = res.code;
    const isRedirect: boolean = code === 301 || code === 302 || code === 303 || code === 307 || code === 308;
    if (isRedirect && res.location.indexOf('http') === 0) {
      hilog.info(0x0000, TAG, 'follow redirect %{public}d', code);
      return Http.get(res.location);
    }
    return res;
  }

  private static save(path: string, text: string): void {
    if (path.length === 0) {
      return;
    }
    try {
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'write cache failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 解析成扁平 Map。
   * 用 Record 逐层取值而不是定义类：db.text.json 的键名就是 name / namespace / data，
   * 定义类反而要迁就字段名（name 在 ArkTS 里也容易撞名），逐层断言更直白。
   */
  private static parse(text: string): boolean {
    try {
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const rawList: Object | undefined = root['data'];
      if (rawList === undefined || rawList === null) {
        return false;
      }
      const list: Object[] = rawList as Object[];
      const out: Map<string, string> = new Map<string, string>();
      for (let i = 0; i < list.length; i++) {
        const nsObj: Record<string, Object> = list[i] as Record<string, Object>;
        // JSON 里字段可能缺省，统一先取 Object 再判型，避免把 undefined 当成字符串用
        const nsRaw: Object | undefined = nsObj['namespace'];
        if (nsRaw === undefined || typeof nsRaw !== 'string') {
          continue;
        }
        const ns: string = nsRaw as string;
        if (ns.length === 0) {
          continue;
        }
        const bodyRaw: Object | undefined = nsObj['data'];
        if (bodyRaw === undefined || bodyRaw === null) {
          continue;
        }
        const body: Record<string, Object> = bodyRaw as Record<string, Object>;
        const keys: string[] = Object.keys(body);
        for (let j = 0; j < keys.length; j++) {
          const k: string = keys[j];
          const itemRaw: Object | undefined = body[k];
          if (itemRaw === undefined || itemRaw === null) {
            continue;
          }
          const item: Record<string, Object> = itemRaw as Record<string, Object>;
          const labelRaw: Object | undefined = item['name'];
          if (labelRaw === undefined || typeof labelRaw !== 'string') {
            continue;
          }
          const label: string = labelRaw as string;
          if (label.length > 0) {
            // 入库也走同一套归一：查询侧与库侧必须用同一个键形，否则又会出现
            // 「有译文但查不到」——这正是「有些标签还是英文」的一半原因。
            out.set(ns.trim().toLowerCase() + ':' + TagTrans.normalizeKey(k), label);
          }
        }
      }
      if (out.size === 0) {
        return false;
      }
      TagTrans.map = out;
      TagTrans.ready = true;
      TagTrans.version = TagTrans.version + 1;
      hilog.info(0x0000, TAG, 'loaded %{public}d tags', out.size);
      return true;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'parse failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }
}
