import { image } from '@kit.ImageKit';

/**
 * 阅读器用的图片内存缓存（LRU）。
 *
 * 为什么需要：阅读器的 `PixelMap` 原本归每个 `ReaderImage` 组件所有，滚出屏幕就
 * `release()` —— 翻回上一页时组件已重建、图也没了，整张重新走一遍「/s/ 页 → 图床
 * 下载 → 解码」。在 H@H 节点上这一趟要几百毫秒到几秒，来回翻两次就很明显。
 *
 * 设计取舍：
 *  - **不设磁盘缓存**：离线阅读已经直接读本地文件，在线重下的代价可以接受；
 *    磁盘缓存要处理 URL 过期、清理策略、磁盘配额，收益却不如内存这一层。
 *  - **容量按张数而不是字节**：一张 1600×2400 解出来约 15MB，12 张 ≈ 180MB，
 *    对这台设备是安全区间；按字节算需要 `getPixelBytesNumber()` 且不同格式差异大，
 *    反而更难估。
 *  - **谁放进来的谁负责**：命中时返回同一对象，组件**不得** release（见 `ReaderImage`）。
 *    被淘汰时由本类 release，保证不泄漏。
 */
export class ImageCache {
  private static readonly CAPACITY: number = 12;
  /** url → PixelMap；用 Map 的插入顺序当 LRU 顺序（命中时先删再插） */
  private static map: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  /**
   * 正在被组件显示的 url。
   *
   * **淘汰必须跳过它们**：阅读器里滚出屏幕的页会 release 掉自己的引用、把所有权交给本缓存，
   * 但屏幕上那一两张仍由缓存持有并绘制。若这时因为预取把容量撑满、把「正在显示的那张」
   * 淘汰掉，release 之后再画就是一张**全黑** —— 这正是「随机某一页全黑」的成因。
   */
  private static pinned: Set<string> = new Set<string>();

  /** 命中返回同一对象（调用方不得 release），未命中返回 null */
  static get(url: string): image.PixelMap | null {
    const hit: image.PixelMap | undefined = ImageCache.map.get(url);
    if (hit === undefined) {
      return null;
    }
    // 命中即「最近使用」：删掉重插，把它挪到 Map 尾部
    ImageCache.map.delete(url);
    ImageCache.map.set(url, hit);
    return hit;
  }

  /** 组件开始显示这一页：把它标记为「不可淘汰」 */
  static pin(url: string): void {
    ImageCache.pinned.add(url);
  }

  /** 组件不再显示这一页 */
  static unpin(url: string): void {
    ImageCache.pinned.delete(url);
  }

  static put(url: string, pm: image.PixelMap): void {
    const old: image.PixelMap | undefined = ImageCache.map.get(url);
    if (old !== undefined) {
      // **正在显示的那张不能被替换**：替换就要 release 旧的，而组件手里拿的正是旧的，
      // 下一帧画在已释放对象上就是全黑。预取与前台加载可能对同一页各解一次，
      // 所以这条路径是常态而不是边角。
      if (ImageCache.pinned.has(url) && old !== pm) {
        pm.release();
        return;
      }
      ImageCache.map.delete(url);
      if (old !== pm) {
        old.release();
      }
    }
    ImageCache.map.set(url, pm);
    ImageCache.trim();
  }

  /** 只把记录摘掉、不 release：用于「缓存里这张已经失效」的场景 */
  static drop(url: string): void {
    ImageCache.map.delete(url);
  }

  /** 是否已经有这张（预取前先查，避免重复请求） */
  static has(url: string): boolean {
    return ImageCache.map.has(url);
  }

  /** 清空（离开阅读器 / 内存紧张时调用），逐个 release 后再丢引用 */
  static clear(): void {
    ImageCache.map.forEach((pm: image.PixelMap) => {
      pm.release();
    });
    ImageCache.map.clear();
    ImageCache.pinned.clear();
  }

  static size(): number {
    return ImageCache.map.size;
  }

  /**
   * 超容量时从最旧的一端淘汰，**跳过正在显示的**。
   *
   * 如果所有条目都被钉住（极端情况：可见页数 > 容量），宁可暂时超出容量也不再淘汰 ——
   * 画面上出现一张黑图，比多占几十 MB 严重得多。
   */
  private static trim(): void {
    if (ImageCache.map.size <= ImageCache.CAPACITY) {
      return;
    }
    const victims: string[] = [];
    ImageCache.map.forEach((pm: image.PixelMap, url: string) => {
      if (victims.length < ImageCache.map.size - ImageCache.CAPACITY && !ImageCache.pinned.has(url)) {
        victims.push(url);
      }
    });
    for (let i = 0; i < victims.length; i++) {
      const pm: image.PixelMap | undefined = ImageCache.map.get(victims[i]);
      ImageCache.map.delete(victims[i]);
      if (pm !== undefined) {
        pm.release();
      }
    }
  }
}
