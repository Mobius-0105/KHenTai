import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { Http } from '../core/Http';
import { ImageDiskCache } from './ImageDiskCache';

/** 阶段一（解析 `/s/` 页）的结果 */
export class ThumbRef {
  /** 图片直链；空串表示没拿到 */
  url: string = '';
  ok: boolean = false;
  /** 站点把配额页（509）当成图片返回了：重试没有意义 */
  limited: boolean = false;
}

/** 队列里的一个格子 */
class ThumbJob {
  index: number = 0;
  /** 0 = 还没拿到直链（等 HTML 闸门），1 = 直链就绪（等图片闸门） */
  phase: number = 0;
  url: string = '';

  constructor(index: number) {
    this.index = index;
  }
}

/**
 * 缩略图的两段式调度器（详情页网格 + 阅读器底部条共用）。
 *
 * 为什么要拆两段并发：
 *  - 阶段一是 `/s/` 页 HTML，打的是 e-hentai 主站，配额（509）非常敏感 → 保守，3 个；
 *  - 阶段二是图片字节，打的是 CDN / H@H 图床，吞吐高、彼此独立 → 可以放宽到 6 个。
 * 合成一个池子时只能取两者的较小值（4），图片阶段的带宽永远吃不饱；分开后
 * 「HTML 排队」和「图片排队」不再互相占坑。
 *
 * 为什么要按优先级取而不是 FIFO：
 * 一屏 20 格是**同时**挂到树上的（Scroll 里的 ForEach 不是懒加载），FIFO 的实际顺序
 * 由 onAppear 的调用顺序决定，滚到第 40 格时排在前面的还是第 1 页 —— 尾部几格要等
 * 前面**全部**跑完才轮到，用户看到的就是「零散几张一直在加载」。这里每次取任务都
 * 重算一次 `prioOf(i)`，所以用户往下滚、优先级立刻跟着变，眼前那几格永远先出图。
 *
 * 超时/取消由调用方管（本类不认识 UI）：`cancel(i)` 只把任务从队列摘掉，
 * 已经在网络里的那次没法真正中断，它的结果回来时会被 onDone/onFail 正常交回。
 */
export class ThumbPipeline {
  private htmlMax: number = 0;
  private imgMax: number = 0;
  private htmlActive: number = 0;
  private imgActive: number = 0;
  /** 排队中的任务（正在跑的不在这里） */
  private jobs: ThumbJob[] = [];
  /** 已受理的页号：排队 + 在跑。调用方用它做去重，我用它防重复入队 */
  private holding: Set<number> = new Set<number>();
  private stopped: boolean = false;

  private prioOf: (i: number) => number = (i: number): number => i;
  private resolveRef: (i: number) => Promise<ThumbRef> =
    (i: number): Promise<ThumbRef> => Promise.resolve(new ThumbRef());
  private loadImage: (i: number, url: string) => Promise<image.PixelMap | null> =
    (i: number, url: string): Promise<image.PixelMap | null> => Promise.resolve(null);
  private onDone: (i: number, pm: image.PixelMap) => void = (i: number, pm: image.PixelMap): void => {
  };
  private onFail: (i: number, reason: string) => void = (i: number, reason: string): void => {
  };

  constructor(htmlMax: number, imgMax: number,
    prioOf: (i: number) => number,
    resolveRef: (i: number) => Promise<ThumbRef>,
    loadImage: (i: number, url: string) => Promise<image.PixelMap | null>,
    onDone: (i: number, pm: image.PixelMap) => void,
    onFail: (i: number, reason: string) => void) {
    this.htmlMax = htmlMax;
    this.imgMax = imgMax;
    this.prioOf = prioOf;
    this.resolveRef = resolveRef;
    this.loadImage = loadImage;
    this.onDone = onDone;
    this.onFail = onFail;
  }

  /** 入队；已在处理中返回 false（调用方不用自己记去重表） */
  request(i: number): boolean {
    if (this.stopped || this.holding.has(i)) {
      return false;
    }
    this.holding.add(i);
    this.jobs.push(new ThumbJob(i));
    this.pump();
    return true;
  }

  /** 撤销一个**还没出结果**的请求（超时兜底用）；在途那次仍会回调 */
  cancel(i: number): void {
    this.holding.delete(i);
    for (let k = this.jobs.length - 1; k >= 0; k--) {
      if (this.jobs[k].index === i) {
        this.jobs.splice(k, 1);
      }
    }
  }

  /** 页面销毁：丢掉队列，在途结果由 onDone 里释放 */
  stop(): void {
    this.stopped = true;
    this.jobs = [];
    this.holding.clear();
  }

  /** 已受理但还没出结果的页数（诊断用） */
  pending(): number {
    return this.holding.size;
  }

  /**
   * 这一格是不是**还在排队**（一次网络都没发出去）。
   *
   * 调用方的超时兜底要靠它区分两种「没结果」：还在排队（不是这一格的问题，
   * 再给一窗时间）vs 已经发出去了却没回来（该判失败，让用户能重试）。
   */
  isQueued(i: number): boolean {
    for (let k = 0; k < this.jobs.length; k++) {
      if (this.jobs[k].index === i) {
        return true;
      }
    }
    return false;
  }

  /**
   * 补坑：两个池子**分别**补，互不占位。
   *
   * 先补图片阶段再补 HTML 阶段：已拿到直链的离出图只差一步，不该被「还要多跑一次
   * HTML 的新任务」插队。
   */
  private pump(): void {
    if (this.stopped) {
      return;
    }
    while (this.imgActive < this.imgMax) {
      const j: ThumbJob | null = this.take(1);
      if (j === null) {
        break;
      }
      this.runImage(j);
    }
    while (this.htmlActive < this.htmlMax) {
      const j: ThumbJob | null = this.take(0);
      if (j === null) {
        break;
      }
      this.runHtml(j);
    }
  }

  /** 取这一阶段里优先级最高的任务（prio 小者优先；同分取入队早的） */
  private take(phase: number): ThumbJob | null {
    let best: number = -1;
    let bestPrio: number = 0;
    for (let k = 0; k < this.jobs.length; k++) {
      if (this.jobs[k].phase !== phase) {
        continue;
      }
      const p: number = this.prioOf(this.jobs[k].index);
      if (best < 0 || p < bestPrio) {
        best = k;
        bestPrio = p;
      }
    }
    if (best < 0) {
      return null;
    }
    const job: ThumbJob = this.jobs[best];
    this.jobs.splice(best, 1);
    return job;
  }

  private async runHtml(job: ThumbJob): Promise<void> {
    // 先占坑再 await：这样 pump 的 while 不会在同一个微任务里重复放行
    this.htmlActive = this.htmlActive + 1;
    const i: number = job.index;
    let url: string = '';
    let ok: boolean = false;
    let limited: boolean = false;
    try {
      const r: ThumbRef = await this.resolveRef(i);
      url = r.url;
      ok = r.ok && url.length > 0;
      limited = r.limited;
    } catch (e) {
      ok = false;
    }
    this.htmlActive = this.htmlActive - 1;
    if (this.stopped) {
      return;
    }
    if (!ok) {
      this.holding.delete(i);
      this.onFail(i, limited ? 'quota' : 'html');
      this.pump();
      return;
    }
    job.url = url;
    job.phase = 1;
    this.jobs.push(job);
    this.pump();
  }

  private async runImage(job: ThumbJob): Promise<void> {
    this.imgActive = this.imgActive + 1;
    const i: number = job.index;
    let pm: image.PixelMap | null = null;
    try {
      pm = await this.loadImage(i, job.url);
    } catch (e) {
      pm = null;
    }
    this.imgActive = this.imgActive - 1;
    if (this.stopped) {
      // 页面已经走了：这张图没人要，立刻还回去（ImageLoader 不持有任何图）
      if (pm !== null) {
        try {
          pm.release();
        } catch (e) {
        }
      }
      return;
    }
    this.holding.delete(i);
    if (pm === null) {
      this.onFail(i, 'image');
      this.pump();
      return;
    }
    this.onDone(i, pm);
    this.pump();
  }
}

/**
 * 大图加载：必须走自己的 HTTP 栈。
 *
 * h@h 图床会校验 `Referer`（必须是这张图所在的 `/s/` 页面），ArkUI 的
 * `Image('https://...')` 无法带 Referer，所以只能自己取字节、自己解码成 PixelMap。
 *
 * 生命周期由**调用方**负责：谁拿到的 PixelMap 谁 release。
 * 不给全局 LRU 缓存 —— 阅读器里每张图归它自己的 ListItem 所有，
 * 列表滚出屏幕时自动释放，比全局缓存更容易保证不释放正在显示的对象。
 */
export class ImageLoader {

  /** 从沙箱文件解码（离线阅读/下载完成后用） */
  static async loadFile(path: string): Promise<image.PixelMap | null> {
    let source: image.ImageSource | null = null;
    try {
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        source = image.createImageSource(file.fd);
        const info: image.ImageInfo = await source.getImageInfo();
        if (info.size.width <= 0) {
          return null;
        }
        return await source.createPixelMap(ImageLoader.decodeOptions(info));
      } finally {
        if (source !== null) {
          source.release();
          source = null;
        }
        fileIo.closeSync(file);
      }
    } catch (e) {
      return null;
    }
  }

  /** 长边超过 2048 就降采样：手机上再大也看不出，能省一半以上内存 */
  private static decodeOptions(info: image.ImageInfo): image.DecodingOptions {
    const longSide: number = Math.max(info.size.width, info.size.height);
    const opts: image.DecodingOptions = { editable: false };
    if (longSide > 2048) {
      const scale: number = 2048 / longSide;
      opts.desiredSize = {
        width: Math.max(1, Math.round(info.size.width * scale)),
        height: Math.max(1, Math.round(info.size.height * scale))
      };
    }
    return opts;
  }

  /**
   * 预取：只把字节写进磁盘缓存，**不解码、不占内存**。
   *
   * 对齐 JHenTai 的做法：它预取的是「能被图片库复用的缓存条目」，而不是自己拿着一张
   * 解码结果到处传。我们这边一旦把 PixelMap 传出去，就得自己管它的生命周期
   * （谁在用、什么时候能 release）—— 之前那批黑图就是管漏了。
   * 只落盘字节，显示时各组件自己解码、自己释放，所有权天然清晰。
   */
  static async prefetchToDisk(pageUrl: string, imageUrl: string): Promise<void> {
    if (ImageDiskCache.has(pageUrl)) {
      return;
    }
    const bytes: ArrayBuffer | null = await Http.getBytes(imageUrl, pageUrl);
    if (bytes !== null && bytes.byteLength > 0) {
      await ImageDiskCache.put(pageUrl, bytes);
    }
  }

  /**
   * 加载一张**小尺寸**缩略图（阅读器底部条用）。
   *
   * 解码时就把尺寸压到 160×240 以内：底部条一格才 76 vp 宽，按原图解码等于
   * 每格白占几十 MB。JHenTai 的底部条也是先解析出图片地址、再按容器尺寸取缩略图。
   */
  static async loadThumb(pageUrl: string, imageUrl: string): Promise<image.PixelMap | null> {
    const bytes: ArrayBuffer | null = await ImageDiskCache.get(pageUrl);
    let data: ArrayBuffer | null = bytes;
    if (data === null) {
      data = await Http.getBytes(imageUrl, pageUrl);
      if (data !== null && data.byteLength > 0) {
        ImageDiskCache.put(pageUrl, data);
      }
    }
    if (data === null || data.byteLength === 0) {
      return null;
    }
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(data);
      const info: image.ImageInfo = await source.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0) {
        return null;
      }
      const longSide: number = Math.max(info.size.width, info.size.height);
      const cap: number = 240;
      const opts: image.DecodingOptions = { editable: false };
      if (longSide > cap) {
        const k: number = cap / longSide;
        opts.desiredSize = {
          width: Math.max(1, Math.round(info.size.width * k)),
          height: Math.max(1, Math.round(info.size.height * k))
        };
      }
      return await source.createPixelMap(opts);
    } catch (e) {
      return null;
    } finally {
      if (source !== null) {
        source.release();
      }
    }
  }

  static async load(url: string, referer: string): Promise<image.PixelMap | null> {
    // 磁盘缓存的键用 **/s/ 页地址**（referer），不用图片直链：
    // 图床直链带 `?nl=…&nm=…` 之类的临时参数，用它当键第二天就全 miss。
    const key: string = referer.length > 0 ? referer : url;
    let bytes: ArrayBuffer | null = await ImageDiskCache.get(key);
    if (bytes === null) {
      bytes = await Http.getBytes(url, referer);
      if (bytes !== null && bytes.byteLength > 0) {
        // 落盘不阻塞返回：解码先用这份内存里的字节，写盘失败也不影响本次显示
        ImageDiskCache.put(key, bytes);
      }
    }
    if (bytes === null || bytes.byteLength === 0) {
      return null;
    }
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(bytes);
      const info: image.ImageInfo = await source.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0) {
        return null;
      }
      return await source.createPixelMap(ImageLoader.decodeOptions(info));
    } catch (e) {
      return null;
    } finally {
      if (source !== null) {
        source.release();
      }
    }
  }
}
