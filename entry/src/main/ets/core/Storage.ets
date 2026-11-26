import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from './AppContext';

const TAG: string = 'JHenTai.Storage';

/** 缓存分类键（设置页按这三个键取大小、发清理指令） */
export const KEY_DOWNLOAD: string = 'download';
export const KEY_TORRENT: string = 'torrent';
export const KEY_IMAGE: string = 'image';

/**
 * 递归硬上限。
 *
 * 统计的是用户沙箱目录，理论上结构很浅（根/画廊/页号），但外部导入或异常中断都可能
 * 留下奇形怪状的层级；不设上限的话一次误入符号链接或超大目录就会把主线程卡住。
 */
const MAX_DEPTH: number = 4;
const MAX_ENTRIES: number = 20000;

/**
 * 一次统计的时间预算（毫秒）。
 *
 * 条目上限（MAX_ENTRIES）只能约束「扫多少」，约束不了「扫多久」：两万个条目逐个 await，
 * 在慢设备或缓存目录很大时可以拖到几十秒，设置页就一直停在「计算中…」。
 * 到点后立即收手、返回已统计到的部分——部分数字远好过没有数字。
 */
export const SCAN_BUDGET_MS: number = 8000;

/** 单项缓存统计结果 */
export class StorageUsage {
  /** 分类键，取值见 KEY_xxx */
  key: string = '';
  /** 给 UI 直接显示的中文名 */
  label: string = '';
  bytes: number = 0;
  /** 文件数（目录不计） */
  files: number = 0;
}

/** 一次递归遍历的累加器 */
class Tally {
  bytes: number = 0;
  files: number = 0;
  /** 已访问条目数，用来卡 MAX_ENTRIES */
  entries: number = 0;
  /** 到点时间戳（0 = 不限时）；清理走 removeTree 时不设，统计才设 */
  deadline: number = 0;

  /** 是否已经用满预算 */
  expired(): boolean {
    return this.deadline > 0 && Date.now() >= this.deadline;
  }
}

/**
 * 本地缓存统计与清理。
 *
 * 三类缓存各自的真实位置：
 *  1. 下载缓存 —— `filesDir/JHenTai/<gid>-<token>/0001.jpg` 这一堆画廊目录
 *     （Downloader.dirOf()），本类只统计**不含下划线前缀**的子目录，
 *     这样 `_torrent` / `_archive` 不会被重复算进下载里。
 *  2. 种子缓存 —— `filesDir/JHenTai/_torrent/*.torrent`（ToolsPage 保存种子时写这里）。
 *  3. 图片缓存 —— 应用沙箱的 `cacheDir`。ImageLoader 本身只把字节解码成 PixelMap，
 *     从不落盘，真正缓存网络图的是 ArkUI 的 Image 组件，它把数据放在系统托管的
 *     应用缓存目录里，没有更深一层的可枚举路径，所以这里统计/清理 cacheDir 的内容。
 *
 * 所有文件操作都吞异常：统计失败返回 0，清理失败跳过该项继续，
 * 设置页拿到的永远是一个可用的数字，不会因为某个目录权限异常整页报错。
 */
export class Storage {

  /** 下载目录根（Downloader.dirOf 的父目录） */
  static downloadRoot(): string {
    try {
      return AppContext.get().filesDir + '/JHenTai';
    } catch (e) {
      return '';
    }
  }

  /** 种子文件目录（与 ToolsPage 里的 _torrent 保持一致） */
  static torrentDir(): string {
    try {
      return AppContext.get().filesDir + '/JHenTai/_torrent';
    } catch (e) {
      return '';
    }
  }

  /** 图片缓存目录（系统托管的应用缓存区） */
  static imageDir(): string {
    try {
      return AppContext.get().cacheDir;
    } catch (e) {
      return '';
    }
  }

  /**
   * 统计三类缓存。返回顺序固定：下载 / 种子 / 图片，调用方可以按下标直接用。
   * 单个分类出错只会让那一项变成 0，不影响其它两项。
   *
   * @param onPartial 每统计完一类就回调一次（只含已完成的项）。
   *                  慢目录不会拖住前面的数字，UI 可以先显示先出来的部分。
   * @param budgetMs  总预算，默认 SCAN_BUDGET_MS。超时后没收的那类按 0 返回，
   *                  不会让 Promise 永远悬着。
   */
  static async scan(onPartial?: (list: StorageUsage[]) => void,
    budgetMs: number = SCAN_BUDGET_MS): Promise<StorageUsage[]> {
    const list: StorageUsage[] = [];
    const deadline: number = budgetMs > 0 ? Date.now() + budgetMs : 0;

    const download: StorageUsage = new StorageUsage();
    download.key = KEY_DOWNLOAD;
    download.label = '下载缓存';
    if (Storage.downloadRoot().length > 0) {
      try {
        const acc: Tally = new Tally();
        acc.deadline = deadline;
        await Storage.tallyDownload(download, acc);
      } catch (e) {
        hilog.warn(0x0000, TAG, 'scan download failed');
      }
    }
    list.push(download);
    if (onPartial !== undefined) {
      onPartial(list.slice());
    }

    const torrent: StorageUsage = new StorageUsage();
    torrent.key = KEY_TORRENT;
    torrent.label = '种子缓存';
    if (Storage.torrentDir().length > 0) {
      try {
        const acc: Tally = new Tally();
        acc.deadline = deadline;
        await Storage.tallyTree(Storage.torrentDir(), 0, acc);
        torrent.bytes = acc.bytes;
        torrent.files = acc.files;
      } catch (e) {
        hilog.warn(0x0000, TAG, 'scan torrent failed');
      }
    }
    list.push(torrent);
    if (onPartial !== undefined) {
      onPartial(list.slice());
    }

    const image: StorageUsage = new StorageUsage();
    image.key = KEY_IMAGE;
    image.label = '图片缓存';
    if (Storage.imageDir().length > 0) {
      try {
        const acc: Tally = new Tally();
        acc.deadline = deadline;
        await Storage.tallyChildren(Storage.imageDir(), acc);
        image.bytes = acc.bytes;
        image.files = acc.files;
      } catch (e) {
        hilog.warn(0x0000, TAG, 'scan image failed');
      }
    }
    list.push(image);
    if (onPartial !== undefined) {
      onPartial(list.slice());
    }

    return list;
  }

  /**
   * 清理某一类缓存，返回释放的字节数。
   *
   * 只删内容、保留目录本身（`_torrent`、`cacheDir` 都可能被别处按路径引用，
   * 目录留着最省事；下载用的画廊目录则连目录一起删，等同「清空已下载」）。
   * 未知键直接返回 0，不抛异常。
   */
  static async clear(key: string): Promise<number> {
    const acc: Tally = new Tally();
    try {
      if (key === KEY_DOWNLOAD) {
        await Storage.clearDownload(acc);
      } else if (key === KEY_TORRENT) {
        const dir: string = Storage.torrentDir();
        if (dir.length > 0) {
          await Storage.clearChildren(dir, acc);
        }
      } else if (key === KEY_IMAGE) {
        const dir: string = Storage.imageDir();
        if (dir.length > 0) {
          await Storage.clearChildren(dir, acc);
        }
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'clear failed');
    }
    return acc.bytes;
  }

  /** 字节数 → 人类可读；0 或异常一律显示 0 B */
  static formatSize(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes <= 0) {
      return '0 B';
    }
    const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
    let value: number = bytes;
    let i: number = 0;
    while (value >= 1024 && i < units.length - 1) {
      value = value / 1024;
      i++;
    }
    if (i === 0) {
      return Math.round(value).toString() + ' B';
    }
    return value.toFixed(1) + ' ' + units[i];
  }

  // ------------------------------------------------------------ 统计

  /** 下载缓存：逐个画廊目录累加，跳过 `_` 前缀（那些属于种子/归档） */
  private static async tallyDownload(u: StorageUsage, acc: Tally): Promise<void> {
    const root: string = Storage.downloadRoot();
    const names: string[] = await Storage.children(root);
    for (let i = 0; i < names.length; i++) {
      if (acc.entries >= MAX_ENTRIES || acc.expired()) {
        break;
      }
      if (names[i].startsWith('_')) {
        continue;
      }
      acc.entries++;
      await Storage.tallyTree(root + '/' + names[i], 1, acc);
    }
    u.bytes = acc.bytes;
    u.files = acc.files;
  }

  /** 只统计某个目录的内容（不把目录本身当一层） */
  private static async tallyChildren(dir: string, acc: Tally): Promise<void> {
    const names: string[] = await Storage.children(dir);
    for (let i = 0; i < names.length; i++) {
      if (acc.entries >= MAX_ENTRIES || acc.expired()) {
        return;
      }
      acc.entries++;
      await Storage.tallyTree(dir + '/' + names[i], 1, acc);
    }
  }

  /**
   * 递归统计：depth 从 0 起算，超过 MAX_DEPTH 就停；条目数或时间预算用完也会提前退出。
   * 每一次 stat / listFile 都单独兜异常，单个坏条目不影响其余部分。
   */
  private static async tallyTree(target: string, depth: number, acc: Tally): Promise<void> {
    if (depth > MAX_DEPTH || acc.entries >= MAX_ENTRIES || acc.expired()) {
      return;
    }
    let st: fileIo.Stat | null = null;
    try {
      st = await fileIo.stat(target);
    } catch (e) {
      return;
    }
    if (st === null) {
      return;
    }
    if (!st.isDirectory()) {
      acc.files++;
      acc.bytes += st.size;
      return;
    }
    const names: string[] = await Storage.children(target);
    for (let i = 0; i < names.length; i++) {
      if (acc.entries >= MAX_ENTRIES || acc.expired()) {
        return;
      }
      acc.entries++;
      await Storage.tallyTree(target + '/' + names[i], depth + 1, acc);
    }
  }

  // ------------------------------------------------------------ 清理

  /** 下载缓存：删掉每个画廊目录（整目录递归删），下划线目录保持不动 */
  private static async clearDownload(acc: Tally): Promise<void> {
    const root: string = Storage.downloadRoot();
    const names: string[] = await Storage.children(root);
    for (let i = 0; i < names.length; i++) {
      if (acc.entries >= MAX_ENTRIES) {
        return;
      }
      if (names[i].startsWith('_')) {
        continue;
      }
      acc.entries++;
      await Storage.removeTree(root + '/' + names[i], 1, acc);
    }
  }

  /** 清空目录内容，目录本身保留 */
  private static async clearChildren(dir: string, acc: Tally): Promise<void> {
    const names: string[] = await Storage.children(dir);
    for (let i = 0; i < names.length; i++) {
      if (acc.entries >= MAX_ENTRIES) {
        return;
      }
      acc.entries++;
      await Storage.removeTree(dir + '/' + names[i], 1, acc);
    }
  }

  /**
   * 递归删除并把删掉的文件大小累加进 acc。
   * 先 stat 拿大小再删：删完就查不到 size 了，返回值要用来告诉用户释放了多少。
   */
  private static async removeTree(target: string, depth: number, acc: Tally): Promise<void> {
    if (depth > MAX_DEPTH || acc.entries >= MAX_ENTRIES) {
      return;
    }
    let st: fileIo.Stat | null = null;
    try {
      st = await fileIo.stat(target);
    } catch (e) {
      return;
    }
    if (st === null) {
      return;
    }
    if (!st.isDirectory()) {
      const size: number = st.size;
      try {
        await fileIo.unlink(target);
        acc.files++;
        acc.bytes += size;
      } catch (e) {
        hilog.warn(0x0000, TAG, 'unlink failed');
      }
      return;
    }
    const names: string[] = await Storage.children(target);
    for (let i = 0; i < names.length; i++) {
      if (acc.entries >= MAX_ENTRIES) {
        break;
      }
      acc.entries++;
      await Storage.removeTree(target + '/' + names[i], depth + 1, acc);
    }
    try {
      await fileIo.rmdir(target);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'rmdir failed');
    }
  }

  /** 列目录：不存在、不是目录、没权限都返回空数组 */
  private static async children(dir: string): Promise<string[]> {
    try {
      if (!(await fileIo.access(dir))) {
        return [];
      }
      return await fileIo.listFile(dir);
    } catch (e) {
      return [];
    }
  }
}
