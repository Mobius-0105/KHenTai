import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from '../core/AppContext';

const TAG: string = 'KHenTai.ImgCache';
/** 磁盘缓存目录（应用沙箱 cache 下，卸载/清理缓存即回收） */
const DIR: string = 'imgcache';
/** 容量上限：300MB。超过后启动时清到 80%，不再做运行期反复扫盘 */
const LIMIT_BYTES: number = 300 * 1024 * 1024;
const KEEP_RATIO: number = 0.8;

/**
 * 图片磁盘缓存（原始字节，不解码）。
 *
 * 与 JHenTai 的取舍一致：它用 `cached_network_image` 的文件缓存落盘原始字节，
 * 这里做同一件事 —— **存的是 jpg/png 的字节，不是 PixelMap**。
 * PixelMap 无法落盘复用，所以磁盘命中仍然要解码一次（几十毫秒），但省掉了网络往返。
 *
 * 三个必须守住的点（踩过就别再踩）：
 *  1. **键用 /s/ 页 URL，不用图片直链**。图床地址带临时参数（`?nl=…&nm=…`）会过期，
 *     拿它当键第二天全 miss。
 *  2. **先写 .tmp 再 rename**：写到一半被杀进程会留下半张坏图，rename 是原子的，
 *     读的时候永远不会读到半个文件。
 *  3. **容量按大小、淘汰按 mtime**：只数文件个数会在一张 8MB 的长图上失控。
 */
export class ImageDiskCache {
  private static ready: boolean = false;
  private static swept: boolean = false;

  private static dirPath(): string {
    return AppContext.get().cacheDir + '/' + DIR;
  }

  private static ensureDir(): boolean {
    if (ImageDiskCache.ready) {
      return true;
    }
    try {
      const p: string = ImageDiskCache.dirPath();
      if (!fs.accessSync(p)) {
        fs.mkdirSync(p, true);
      }
      ImageDiskCache.ready = true;
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 键 → 文件名：FNV-1a 32 位，够短、分布均匀，不需要引第三方哈希 */
  private static nameOf(key: string): string {
    let h: number = 0x811C9DC5;
    for (let i = 0; i < key.length; i++) {
      h = h ^ key.charCodeAt(i);
      // 乘 16777619 用位移拼，避免 JS 大整数溢出成浮点
      h = (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24)) >>> 0;
    }
    return h.toString(16) + '.img';
  }

  static async get(key: string): Promise<ArrayBuffer | null> {
    if (!ImageDiskCache.ensureDir()) {
      return null;
    }
    const path: string = ImageDiskCache.dirPath() + '/' + ImageDiskCache.nameOf(key);
    try {
      const stat: fs.Stat = await fs.stat(path);
      if (stat.size <= 0) {
        return null;
      }
      const file: fs.File = await fs.open(path, fs.OpenMode.READ_ONLY);
      try {
        const buf: ArrayBuffer = new ArrayBuffer(stat.size);
        // 一次性读满，并**校验实际读到的字节数**。
        //
        // 上一版写成循环 `fs.read(fd, buf, { offset: got, length: ... })` —— 这里搞错了：
        //   options.offset 是**文件内偏移**，不是缓冲区偏移；每次循环都从缓冲区开头覆盖，
        //   尾部留着 0。结果解码出来全是**黑图**，而且比修之前更频繁。
        // 本地文件读一般一次就能读满，所以改成：读一次、核对数量，不足就删缓存重取。
        const n: number = await fs.read(file.fd, buf);
        if (n !== stat.size) {
          try {
            await fs.unlink(path);
          } catch (e) {
          }
          return null;
        }
        return buf;
      } finally {
        await fs.close(file);
      }
    } catch (e) {
      // 不存在、读失败、权限问题都当作 miss：缓存永远不能挡住正常加载
      return null;
    }
  }

  /** 是否已有这页的字节（预取前查一次，避免重复下载） */
  static has(key: string): boolean {
    if (!ImageDiskCache.ensureDir()) {
      return false;
    }
    try {
      return fs.accessSync(ImageDiskCache.dirPath() + '/' + ImageDiskCache.nameOf(key));
    } catch (e) {
      return false;
    }
  }

  /** 删掉某一页的字节缓存（手动重试/确认失败时用，避免反复拿到同一份坏字节） */
  static async remove(key: string): Promise<void> {
    if (!ImageDiskCache.ensureDir()) {
      return;
    }
    try {
      await fs.unlink(ImageDiskCache.dirPath() + '/' + ImageDiskCache.nameOf(key));
    } catch (e) {
    }
  }

  static async put(key: string, bytes: ArrayBuffer): Promise<void> {
    if (bytes.byteLength === 0 || !ImageDiskCache.ensureDir()) {
      return;
    }
    const dir: string = ImageDiskCache.dirPath();
    const name: string = ImageDiskCache.nameOf(key);
    const tmp: string = dir + '/' + name + '.tmp';
    const final: string = dir + '/' + name;
    try {
      const file: fs.File = await fs.open(tmp,
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        await fs.write(file.fd, bytes);
      } finally {
        await fs.close(file);
      }
      await fs.rename(tmp, final);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'write cache failed');
    }
  }

  /**
   * 启动后清一次超容（只跑一次/进程）。
   *
   * 放在后台跑：扫几千个文件、stat 一遍要几十毫秒，不能挡首屏。
   * 清到 80% 而不是刚好 300MB：否则下次多存一张又要立刻再清一遍。
   */
  static sweepIfNeeded(): void {
    if (ImageDiskCache.swept || !ImageDiskCache.ensureDir()) {
      return;
    }
    ImageDiskCache.swept = true;
    ImageDiskCache.sweep();
  }

  private static async sweep(): Promise<void> {
    const dir: string = ImageDiskCache.dirPath();
    try {
      const names: string[] = await fs.listFile(dir);
      const entries: number[][] = [];
      let total: number = 0;
      for (let i = 0; i < names.length; i++) {
        const path: string = dir + '/' + names[i];
        if (names[i].endsWith('.tmp')) {
          // 上次写到一半留下的残片，直接删
          try {
            await fs.unlink(path);
          } catch (e) {
          }
          continue;
        }
        try {
          const st: fs.Stat = await fs.stat(path);
          total += st.size;
          entries.push([st.mtime * 1000, i]);
        } catch (e) {
        }
      }
      if (total <= LIMIT_BYTES) {
        return;
      }
      entries.sort((a: number[], b: number[]): number => a[0] - b[0]);
      let remain: number = total;
      const target: number = LIMIT_BYTES * KEEP_RATIO;
      for (let i = 0; i < entries.length && remain > target; i++) {
        const name: string = names[entries[i][1]];
        const path: string = dir + '/' + name;
        try {
          const st: fs.Stat = await fs.stat(path);
          await fs.unlink(path);
          remain -= st.size;
        } catch (e) {
        }
      }
      hilog.info(0x0000, TAG, 'swept image cache');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'sweep failed');
    }
  }

  /** 当前占用（设置页展示用；扫盘较重，只在用户点开时算） */
  static async sizeBytes(): Promise<number> {
    if (!ImageDiskCache.ensureDir()) {
      return 0;
    }
    const dir: string = ImageDiskCache.dirPath();
    let total: number = 0;
    try {
      const names: string[] = await fs.listFile(dir);
      for (let i = 0; i < names.length; i++) {
        try {
          const st: fs.Stat = await fs.stat(dir + '/' + names[i]);
          total += st.size;
        } catch (e) {
        }
      }
    } catch (e) {
      return 0;
    }
    return total;
  }

  static async clear(): Promise<void> {
    if (!ImageDiskCache.ensureDir()) {
      return;
    }
    const dir: string = ImageDiskCache.dirPath();
    try {
      const names: string[] = await fs.listFile(dir);
      for (let i = 0; i < names.length; i++) {
        try {
          await fs.unlink(dir + '/' + names[i]);
        } catch (e) {
        }
      }
    } catch (e) {
    }
  }
}
