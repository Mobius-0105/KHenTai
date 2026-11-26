import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppContext } from './AppContext';
import { EhApi } from './EhApi';
import { Gallery, GalleryDetail, ImagePage } from './Models';
import { Prefs } from './Prefs';
import { Http } from './Http';

const TAG: string = 'JHenTai.DL';
/** 「仅 Wi-Fi 下载」开关的偏好键 */
const KEY_WIFI_ONLY: string = 'dl_wifi_only';
/** 单页允许的连续失败次数：超过这个数才把任务标 ERROR */
const MAX_RETRY: number = 3;
/** 等 WiFi 期间给用户看的状态文案 */
const WIFI_WAIT: string = '等待 WiFi';

export enum DlStatus {
  PENDING = 0,
  RUNNING = 1,
  PAUSED = 2,
  DONE = 3,
  ERROR = 4
}

/** 单页抓取结果：成功 / 可重试的失败 / 触发 509 需要暂停 */
enum PageOutcome {
  OK = 0,
  FAIL = 1,
  LIMITED = 2
}

/** 一个下载任务（一个画廊） */
export class DlTask {
  gid: string = '';
  token: string = '';
  title: string = '';
  thumb: string = '';
  category: string = '';
  color: string = '';
  /** 已完成页数 */
  done: number = 0;
  /** 预估总页数（详情页的 pages，可能为 0） */
  total: number = 0;
  status: DlStatus = DlStatus.PENDING;
  error: string = '';
  /** 优先级：0 高 / 1 普通 / 2 低；队列按此升序取任务（同级按 createdAt） */
  priority: number = 1;
  /** 分组名，空串表示未分组 */
  group: string = '';
  /** 当前页连续失败次数，累计超过 MAX_RETRY 才把任务标 ERROR */
  retries: number = 0;
  /** 最近一次单页失败的具体原因（只做展示，不阻塞任务） */
  lastError: string = '';
  createdAt: number = 0;

  key(): string {
    return this.gid + '-' + this.token;
  }

  percent(): number {
    if (this.total <= 0) {
      return this.done > 0 ? 5 : 0;
    }
    return Math.min(100, Math.round(this.done * 100 / this.total));
  }

  statusLabel(): string {
    switch (this.status) {
      case DlStatus.RUNNING:
        return '下载中';
      case DlStatus.PAUSED:
        return '已暂停';
      case DlStatus.DONE:
        return '已完成';
      case DlStatus.ERROR:
        return '出错';
      default:
        return '排队中';
    }
  }

  /** 优先级标签（0/1/2 → 高/普通/低） */
  priorityLabel(): string {
    if (this.priority === 0) {
      return '高优先';
    }
    if (this.priority === 2) {
      return '低优先';
    }
    return '普通';
  }
}

/**
 * 下载器：把画廊逐页落盘，支持断点续传。
 *
 * 设计要点：
 *  1. **以文件是否存在为续传依据**，不额外维护索引表 —— 中断、崩溃、手动删文件都能自愈；
 *  2. 单任务串行、页间留 300ms 间隔：EH 对并发抓图很敏感，宁可慢也不吃 509；
 *  3. 进度变化通过监听器推给 UI，UI 只负责重读列表，不持有任务对象（避免状态不同步）；
 *  4. 目录：`<filesDir>/JHenTai/<gid>-<token>/0001.jpg`，一页一个文件，
 *     阅读器可以直接按目录读本地图，不再走网络。
 *  5. 队列按优先级取任务；「仅 Wi-Fi」开启时非 Wi-Fi 网络下任务停在 PENDING，不报错。
 */
export class Downloader {
  private static tasks: DlTask[] = [];
  private static loaded: boolean = false;
  private static running: boolean = false;
  private static listeners: Array<() => void> = [];
  private static readonly KEY: string = 'download_tasks';
  /** 等 WiFi 时挂起队列，避免 pump 空转重排同一个任务 */
  private static holdQueue: boolean = false;
  /** 网络能力监听只注册一次 */
  private static netWatching: boolean = false;
  /** 网络能力监听句柄（应用生命周期内常驻，不主动反注册） */
  private static netConn: connection.NetConnection | null = null;

  static init(): void {
    if (Downloader.loaded) {
      return;
    }
    Downloader.loaded = true;
    const raw: string = Prefs.str(Downloader.KEY, '');
    if (raw.length === 0) {
      return;
    }
    try {
      const arr: DlTask[] = JSON.parse(raw) as DlTask[];
      for (let i = 0; i < arr.length; i++) {
        const t: DlTask = Downloader.normalize(arr[i]);
        // 上次进程被杀时停在 RUNNING 的任务，重启后视为暂停
        if (t.status === DlStatus.RUNNING) {
          t.status = DlStatus.PAUSED;
        }
        Downloader.tasks.push(t);
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'load tasks failed');
    }
  }

  /**
   * 把磁盘上的旧任务补齐成完整对象。
   *
   * 老版本的存档里没有 priority/group/retries/lastError，直接 JSON.parse 出来是
   * undefined，不补默认值后面比大小、拼文案都会出问题，所以逐字段重建。
   */
  private static normalize(src: DlTask): DlTask {
    const t: DlTask = new DlTask();
    t.gid = typeof src.gid === 'string' ? src.gid : '';
    t.token = typeof src.token === 'string' ? src.token : '';
    t.title = typeof src.title === 'string' ? src.title : '';
    t.thumb = typeof src.thumb === 'string' ? src.thumb : '';
    t.category = typeof src.category === 'string' ? src.category : '';
    t.color = typeof src.color === 'string' ? src.color : '';
    t.done = typeof src.done === 'number' ? src.done : 0;
    t.total = typeof src.total === 'number' ? src.total : 0;
    t.status = typeof src.status === 'number' ? src.status : DlStatus.PENDING;
    t.error = typeof src.error === 'string' ? src.error : '';
    t.priority = typeof src.priority === 'number' ? src.priority : 1;
    t.group = typeof src.group === 'string' ? src.group : '';
    t.retries = typeof src.retries === 'number' ? src.retries : 0;
    t.lastError = typeof src.lastError === 'string' ? src.lastError : '';
    t.createdAt = typeof src.createdAt === 'number' ? src.createdAt : 0;
    return t;
  }

  private static persist(): void {
    Prefs.put(Downloader.KEY, JSON.stringify(Downloader.tasks));
  }

  static onChange(cb: () => void): void {
    Downloader.listeners.push(cb);
  }

  static offChange(cb: () => void): void {
    const out: Array<() => void> = [];
    for (let i = 0; i < Downloader.listeners.length; i++) {
      if (Downloader.listeners[i] !== cb) {
        out.push(Downloader.listeners[i]);
      }
    }
    Downloader.listeners = out;
  }

  private static notify(): void {
    for (let i = 0; i < Downloader.listeners.length; i++) {
      Downloader.listeners[i]();
    }
  }

  static list(): DlTask[] {
    Downloader.init();
    return Downloader.tasks;
  }

  static find(gid: string, token: string): DlTask | null {
    Downloader.init();
    for (let i = 0; i < Downloader.tasks.length; i++) {
      if (Downloader.tasks[i].gid === gid && Downloader.tasks[i].token === token) {
        return Downloader.tasks[i];
      }
    }
    return null;
  }

  static dirOf(gid: string, token: string): string {
    return AppContext.get().filesDir + '/JHenTai/' + gid + '-' + token;
  }

  /** 已落盘页数（用于显示/续传） */
  static localCount(gid: string, token: string): number {
    const dir: string = Downloader.dirOf(gid, token);
    try {
      if (!fileIo.accessSync(dir)) {
        return 0;
      }
      const names: string[] = fileIo.listFileSync(dir);
      let n: number = 0;
      for (let i = 0; i < names.length; i++) {
        if (names[i].endsWith('.jpg')) {
          n++;
        }
      }
      return n;
    } catch (e) {
      return 0;
    }
  }

  /** 本地页路径列表（按序号排序），阅读器用它离线读 */
  static localPages(gid: string, token: string): string[] {
    const dir: string = Downloader.dirOf(gid, token);
    const out: string[] = [];
    try {
      if (!fileIo.accessSync(dir)) {
        return out;
      }
      const names: string[] = fileIo.listFileSync(dir);
      const jpgs: string[] = [];
      for (let i = 0; i < names.length; i++) {
        if (names[i].endsWith('.jpg')) {
          jpgs.push(names[i]);
        }
      }
      jpgs.sort();
      for (let i = 0; i < jpgs.length; i++) {
        out.push(dir + '/' + jpgs[i]);
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'list local failed');
    }
    return out;
  }

  static enqueue(detail: GalleryDetail): DlTask {
    Downloader.init();
    const g = detail.gallery;
    const exist: DlTask | null = Downloader.find(g.gid, g.token);
    if (exist !== null) {
      if (exist.status === DlStatus.PAUSED || exist.status === DlStatus.ERROR) {
        exist.status = DlStatus.PENDING;
        exist.error = '';
        exist.retries = 0;
        Downloader.persist();
        Downloader.notify();
        Downloader.pump();
      }
      return exist;
    }
    const t: DlTask = new DlTask();
    t.gid = g.gid;
    t.token = g.token;
    t.title = g.title;
    t.thumb = g.thumbUrl;
    t.category = g.categoryLabel;
    t.color = g.categoryColor;
    t.total = g.pages;
    t.createdAt = Date.now();
    t.done = Downloader.localCount(g.gid, g.token);
    Downloader.tasks.unshift(t);
    Downloader.persist();
    Downloader.notify();
    Downloader.pump();
    return t;
  }

  static pause(key: string): void {
    const t: DlTask | null = Downloader.byKey(key);
    if (t !== null && (t.status === DlStatus.RUNNING || t.status === DlStatus.PENDING)) {
      t.status = DlStatus.PAUSED;
      Downloader.persist();
      Downloader.notify();
    }
  }

  /** 继续：重试次数一并清零（否则接着上一次的失败数很容易直接判死） */
  static resume(key: string): void {
    const t: DlTask | null = Downloader.byKey(key);
    if (t !== null) {
      t.status = DlStatus.PENDING;
      t.error = '';
      t.retries = 0;
      t.lastError = '';
      Downloader.persist();
      Downloader.notify();
      Downloader.pump();
    }
  }

  /** 全部暂停（只动在跑/排队的任务） */
  static pauseAll(): void {
    Downloader.init();
    let changed: boolean = false;
    for (let i = 0; i < Downloader.tasks.length; i++) {
      const t: DlTask = Downloader.tasks[i];
      if (t.status === DlStatus.RUNNING || t.status === DlStatus.PENDING) {
        t.status = DlStatus.PAUSED;
        // 「等待 WiFi」不算错误，手动暂停后不该继续显示
        if (t.error === WIFI_WAIT) {
          t.error = '';
        }
        changed = true;
      }
    }
    if (changed) {
      Downloader.persist();
      Downloader.notify();
    }
  }

  /** 全部继续（暂停/出错的都重新排队，并清掉重试计数） */
  static resumeAll(): void {
    Downloader.init();
    let changed: boolean = false;
    for (let i = 0; i < Downloader.tasks.length; i++) {
      const t: DlTask = Downloader.tasks[i];
      if (t.status === DlStatus.PAUSED || t.status === DlStatus.ERROR) {
        t.status = DlStatus.PENDING;
        t.error = '';
        t.retries = 0;
        t.lastError = '';
        changed = true;
      }
    }
    if (changed) {
      Downloader.persist();
      Downloader.notify();
      Downloader.pump();
    }
  }

  /** 设置优先级（0 高 / 1 普通 / 2 低） */
  static setPriority(key: string, priority: number): void {
    const t: DlTask | null = Downloader.byKey(key);
    if (t === null || t.priority === priority) {
      return;
    }
    t.priority = priority;
    Downloader.persist();
    Downloader.notify();
    Downloader.pump();
  }

  /** 设置分组名（空串 = 未分组） */
  static setGroup(key: string, group: string): void {
    const t: DlTask | null = Downloader.byKey(key);
    if (t === null) {
      return;
    }
    t.group = group.trim();
    Downloader.persist();
    Downloader.notify();
  }

  /** 现有分组名（给设置面板做快捷选项），按出现顺序去重 */
  static groups(): string[] {
    Downloader.init();
    const out: string[] = [];
    for (let i = 0; i < Downloader.tasks.length; i++) {
      const g: string = Downloader.tasks[i].group;
      if (g.length > 0 && out.indexOf(g) < 0) {
        out.push(g);
      }
    }
    return out;
  }

  /** 删除任务；deleteFiles=true 时把已下好的图也删掉 */
  static remove(key: string, deleteFiles: boolean): void {
    Downloader.init();
    const keep: DlTask[] = [];
    let target: DlTask | null = null;
    for (let i = 0; i < Downloader.tasks.length; i++) {
      if (Downloader.tasks[i].key() === key) {
        target = Downloader.tasks[i];
      } else {
        keep.push(Downloader.tasks[i]);
      }
    }
    Downloader.tasks = keep;
    Downloader.persist();
    if (deleteFiles && target !== null) {
      Downloader.deleteDir(Downloader.dirOf(target.gid, target.token));
    }
    Downloader.notify();
  }

  // ------------------------------------------------------------ 网络 / 偏好
  /** 「仅 Wi-Fi 下载」是否开启 */
  static wifiOnly(): boolean {
    return Prefs.bool(KEY_WIFI_ONLY, false);
  }

  /** 切换「仅 Wi-Fi 下载」；关闭时立刻唤醒因等 WiFi 而排队的任务 */
  static setWifiOnly(on: boolean): void {
    Prefs.put(KEY_WIFI_ONLY, on);
    if (!on && Downloader.holdQueue) {
      Downloader.holdQueue = false;
      Downloader.clearWifiWait();
      Downloader.pump();
    }
    Downloader.notify();
  }

  /**
   * 当前默认网络是否为 Wi-Fi。
   *
   * 用 `getDefaultNetSync()` 拿默认网络句柄，再用 `getNetCapabilitiesSync()` 读承载类型；
   * netId 为 0 表示没有默认网络。任何异常（如未授予 GET_NETWORK_INFO）一律放行：
   * 宁可照常下载，也不要因为查不到网络把队列卡死。
   */
  static isWifi(): boolean {
    try {
      const handle: connection.NetHandle = connection.getDefaultNetSync();
      if (handle.netId === 0) {
        return false;
      }
      const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(handle);
      return caps.bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) >= 0;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'wifi check failed');
      return true;
    }
  }

  /** 注册网络能力变化监听：Wi-Fi 回来时自动把挂起的队列放行 */
  private static watchNetwork(): void {
    if (Downloader.netWatching) {
      return;
    }
    Downloader.netWatching = true;
    try {
      // connection 模块本身没有 on()：先 createNetConnection() 拿到连接对象，
      // 再 on('netCapabilitiesChange') + register() 才会真正开始投递事件。
      const conn: connection.NetConnection = connection.createNetConnection();
      Downloader.netConn = conn;
      conn.on('netCapabilitiesChange', (info: connection.NetCapabilityInfo) => {
        Downloader.onNetChanged();
      });
      conn.register((err: BusinessError) => {
        if (err) {
          hilog.warn(0x0000, TAG, 'register net listener failed');
        }
      });
    } catch (e) {
      hilog.warn(0x0000, TAG, 'watch network failed');
    }
  }

  private static onNetChanged(): void {
    if (!Downloader.holdQueue || !Downloader.wifiOnly() || !Downloader.isWifi()) {
      return;
    }
    Downloader.holdQueue = false;
    Downloader.clearWifiWait();
    Downloader.pump();
  }

  /** 把「等待 WiFi」的提示清掉（Wi-Fi 恢复或开关关闭时） */
  private static clearWifiWait(): void {
    let changed: boolean = false;
    for (let i = 0; i < Downloader.tasks.length; i++) {
      const t: DlTask = Downloader.tasks[i];
      if (t.status === DlStatus.PENDING && t.error === WIFI_WAIT) {
        t.error = '';
        changed = true;
      }
    }
    if (changed) {
      Downloader.persist();
      Downloader.notify();
    }
  }

  // ------------------------------------------------------------ 检查更新
  /**
   * 检查更新：重新请求详情页首屏，拿到最新的总页数。
   * 比本地 total 大就扩容，并把已完成的任务重新排回队列继续补（对齐原版行为）。
   * 返回一句给 UI 直接展示的文案。
   */
  static async checkUpdate(key: string): Promise<string> {
    const t: DlTask | null = Downloader.byKey(key);
    if (t === null) {
      return '任务不存在';
    }
    const g: Gallery = new Gallery();
    g.gid = t.gid;
    g.token = t.token;
    g.title = t.title;
    g.thumbUrl = t.thumb;
    g.url = 'https://' + Downloader.host() + '/g/' + t.gid + '/' + t.token + '/';
    try {
      const d: GalleryDetail = await EhApi.loadDetail(g);
      const latest: number = d.gallery.pages;
      if (latest > t.total) {
        t.total = latest;
        t.error = '';
        t.lastError = '';
        t.retries = 0;
        if (t.status === DlStatus.DONE) {
          t.status = DlStatus.PENDING;
        }
        Downloader.persist();
        Downloader.notify();
        Downloader.pump();
        return '发现新页面，已更新为 ' + latest.toString() + ' 页';
      }
      t.lastError = '';
      Downloader.persist();
      Downloader.notify();
      return latest > 0 ? '已是最新（' + latest.toString() + ' 页）' : '已是最新';
    } catch (e) {
      t.lastError = '检查更新失败';
      Downloader.notify();
      return '检查更新失败（网络或登录问题）';
    }
  }

  private static byKey(key: string): DlTask | null {
    Downloader.init();
    for (let i = 0; i < Downloader.tasks.length; i++) {
      if (Downloader.tasks[i].key() === key) {
        return Downloader.tasks[i];
      }
    }
    return null;
  }

  private static deleteDir(dir: string): void {
    try {
      if (fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'rmdir failed');
    }
  }

  /** 按优先级取下一个待下载任务：priority 升序，同级按 createdAt 升序（先来先跑） */
  private static pickNext(): DlTask | null {
    let best: DlTask | null = null;
    for (let i = 0; i < Downloader.tasks.length; i++) {
      const t: DlTask = Downloader.tasks[i];
      if (t.status !== DlStatus.PENDING) {
        continue;
      }
      if (best === null) {
        best = t;
        continue;
      }
      if (t.priority < best.priority ||
        (t.priority === best.priority && t.createdAt < best.createdAt)) {
        best = t;
      }
    }
    return best;
  }

  /** 队列推进：一次只跑一个任务，跑完再取下一个 */
  private static pump(): void {
    if (Downloader.running) {
      return;
    }
    // 之前因为等 WiFi 挂起：网络恢复了就放行，没恢复就继续等（不空转）
    if (Downloader.holdQueue) {
      if (Downloader.wifiOnly() && !Downloader.isWifi()) {
        return;
      }
      Downloader.holdQueue = false;
      Downloader.clearWifiWait();
    }
    const next: DlTask | null = Downloader.pickNext();
    if (next === null) {
      return;
    }
    Downloader.running = true;
    Downloader.run(next).then(() => {
      Downloader.running = false;
      if (!Downloader.holdQueue) {
        Downloader.pump();
      }
    }).catch(() => {
      Downloader.running = false;
    });
  }

  private static async run(task: DlTask): Promise<void> {
    // 仅 Wi-Fi：不在 Wi-Fi 上就别开始，任务留在排队态等网络，不算失败
    if (Downloader.wifiOnly() && !Downloader.isWifi()) {
      Downloader.waitWifi(task);
      return;
    }

    task.status = DlStatus.RUNNING;
    task.error = '';
    Downloader.persist();
    Downloader.notify();

    const dir: string = Downloader.dirOf(task.gid, task.token);
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
    } catch (e) {
      task.status = DlStatus.ERROR;
      task.error = '无法创建下载目录';
      Downloader.persist();
      Downloader.notify();
      return;
    }

    // 先补齐所有单图页链接（详情页一次只给 20 个）
    const urls: string[] = await Downloader.collectUrls(task);
    if (urls.length === 0) {
      task.status = DlStatus.ERROR;
      task.error = '没有拿到页面列表（可能被限流）';
      Downloader.persist();
      Downloader.notify();
      return;
    }
    if (task.total < urls.length) {
      task.total = urls.length;
    }
    Downloader.persist();
    Downloader.notify();

    let i: number = 0;
    while (i < urls.length) {
      // 每页都检查一次状态：暂停是即时生效的
      if (task.status !== DlStatus.RUNNING) {
        Downloader.persist();
        Downloader.notify();
        return;
      }
      // 下载途中掉出 Wi-Fi：停在排队态等网络，不消耗重试次数
      if (Downloader.wifiOnly() && !Downloader.isWifi()) {
        Downloader.waitWifi(task);
        return;
      }
      const name: string = Downloader.pageName(i);
      const path: string = dir + '/' + name;
      if (Downloader.existsNonEmpty(path)) {
        i++;
        continue;
      }
      const r: PageOutcome = await Downloader.fetchPage(task, urls[i], path, i);
      if (r === PageOutcome.LIMITED) {
        task.status = DlStatus.PAUSED;
        task.error = '触发浏览上限（509），登录后可继续，稍后再试';
        Downloader.persist();
        Downloader.notify();
        return;
      }
      if (r === PageOutcome.OK) {
        // 成功一页就把失败计数清掉：重试是「连续失败」语义
        task.retries = 0;
        task.lastError = '';
        task.done = Downloader.localCount(task.gid, task.token);
        if (i % 3 === 0 || task.done === task.total) {
          Downloader.persist();
          Downloader.notify();
        }
        i++;
      } else {
        task.retries = task.retries + 1;
        task.done = Downloader.localCount(task.gid, task.token);
        if (task.retries > MAX_RETRY) {
          task.status = DlStatus.ERROR;
          task.error = '连续 ' + task.retries.toString() + ' 次下载失败，请稍后继续';
          Downloader.persist();
          Downloader.notify();
          return;
        }
        // 还没超过上限：留在同一页再试，卡片上能看到重试次数
        Downloader.persist();
        Downloader.notify();
      }
      // 页间节流：EH 对高频抓图会直接返回 509
      await Downloader.sleep(300);
    }

    task.done = Downloader.localCount(task.gid, task.token);
    task.status = DlStatus.DONE;
    task.retries = 0;
    Downloader.persist();
    Downloader.notify();
  }

  /** 停在排队态等 Wi-Fi，并挂起队列直到网络变化 */
  private static waitWifi(task: DlTask): void {
    task.status = DlStatus.PENDING;
    task.error = WIFI_WAIT;
    Downloader.holdQueue = true;
    Downloader.watchNetwork();
    Downloader.persist();
    Downloader.notify();
  }

  /** 抓单页并落盘；不抛异常，失败原因写进 task.lastError */
  private static async fetchPage(task: DlTask, pageUrl: string, path: string,
    index: number): Promise<PageOutcome> {
    try {
      const page: ImagePage = await EhApi.loadImagePage(pageUrl);
      if (page.limited) {
        return PageOutcome.LIMITED;
      }
      const bytes: ArrayBuffer | null = await Http.getBytes(page.imageUrl, pageUrl);
      if (bytes === null || bytes.byteLength === 0) {
        task.lastError = '第 ' + (index + 1).toString() + ' 页下载失败';
        hilog.warn(0x0000, TAG, 'page %{public}d failed', index);
        return PageOutcome.FAIL;
      }
      if (!Downloader.writeFile(path, bytes)) {
        task.lastError = '第 ' + (index + 1).toString() + ' 页写入失败';
        return PageOutcome.FAIL;
      }
      return PageOutcome.OK;
    } catch (e) {
      task.lastError = '第 ' + (index + 1).toString() + ' 页请求异常';
      hilog.warn(0x0000, TAG, 'page %{public}d error', index);
      return PageOutcome.FAIL;
    }
  }

  private static async collectUrls(task: DlTask): Promise<string[]> {
    const urls: string[] = [];
    try {
      const first: string[] = await EhApi.loadThumbPageUrls(
        'https://' + Downloader.host() + '/g/' + task.gid + '/' + task.token + '/', 0);
      for (let i = 0; i < first.length; i++) {
        urls.push(first[i]);
      }
      // 这里是**页索引**：1 就是第二屏（每屏 20 张），不是图片偏移
      let pageIndex: number = 1;
      while (first.length > 0 && urls.length < task.total * 2 && pageIndex < 1000) {
        if (task.status !== DlStatus.RUNNING) {
          return urls;
        }
        const more: string[] = await EhApi.loadThumbPageUrls(
          'https://' + Downloader.host() + '/g/' + task.gid + '/' + task.token + '/', pageIndex);
        if (more.length === 0) {
          break;
        }
        for (let i = 0; i < more.length; i++) {
          // 同一屏被站点重复下发时不要去重失败：urls 的顺序就是页序，重复会整体错位
          if (urls.indexOf(more[i]) < 0) {
            urls.push(more[i]);
          }
        }
        pageIndex++;
        if (task.total > 0 && urls.length >= task.total) {
          break;
        }
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'collect urls failed');
    }
    return urls;
  }

  private static host(): string {
    return EhApi.isEx() ? 'exhentai.org' : 'e-hentai.org';
  }

  private static pageName(index: number): string {
    let s: string = (index + 1).toString();
    while (s.length < 4) {
      s = '0' + s;
    }
    return s + '.jpg';
  }

  private static existsNonEmpty(path: string): boolean {
    try {
      if (!fileIo.accessSync(path)) {
        return false;
      }
      const st: fileIo.Stat = fileIo.statSync(path);
      return st.size > 1024;
    } catch (e) {
      return false;
    }
  }

  private static writeFile(path: string, data: ArrayBuffer): boolean {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE |
        fileIo.OpenMode.TRUNC);
      const total: number = data.byteLength;
      let written: number = 0;
      while (written < total) {
        const n: number = fileIo.writeSync(file.fd, data.slice(written));
        if (n <= 0) {
          break;
        }
        written += n;
      }
      return written === total;
    } catch (e) {
      hilog.error(0x0000, TAG, 'write failed');
      return false;
    } finally {
      if (file !== null) {
        fileIo.closeSync(file);
      }
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}
