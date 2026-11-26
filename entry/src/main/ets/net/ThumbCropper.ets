import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Http } from '../core/Http';
import { ImageDiskCache } from './ImageDiskCache';

const TAG: string = 'KHenTai.Crop';

/**
 * 同时进行的解码数上限。
 *
 * 直接照搬 Ehviewer_OHOS 的 `MAX_ACTIVE_PREVIEW_CROPS = 4`（`PreviewThumbnailCache.ets:19`）：
 * 一屏 20 格同时挂载，不设闸门就是 20 个 ImageSource 同时解码同一张大图，内存峰值会把
 * 图床返回的那张 sheet（2000px 级）解成 20 份 RGBA —— 4 个槽位既够快也不会炸。
 */
const MAX_ACTIVE: number = 4;

/** 已占用的槽位数 */
let active: number = 0;
/** 排队等槽位的任务（先来先到，不做优先级：格子级优先级已由 DetailPage 的 pagePrio 决定） */
const WAITERS: Array<() => void> = [];

/**
 * 同一张 sheet 的在途下载。
 *
 * 一屏 20 格共用一张 sheet，若每格各自 `Http.getBytes` 就是 20 次同一个 URL 的往返
 * （Ehviewer_OHOS 靠「先把整张图落盘再裁」天然避开这件事，`ptc.ets:61`）。
 * 这里用一个 Promise 表做去重：第 1 格负责下载，其余 19 格 await 同一个 Promise。
 */
const INFLIGHT: Map<string, Promise<ArrayBuffer | null>> = new Map<string, Promise<ArrayBuffer | null>>();

/**
 * 已解析的 ImageSource（带引用计数）。
 *
 * 为什么留这一层：20 格裁的是同一份字节，若每格都 `createImageSource(bytes)`，
 * 同一个 1~2MB 的容器要被解析 20 遍。Ehviewer_OHOS 用 `acquireImageSource` 复用同一个
 * ImageSource（`ptc.ets:74`），这里照做；refs 归零后不立刻销毁，留几张热源给下一屏。
 */
class HeldSource {
  src: image.ImageSource | null = null;
  /** 图的真实像素宽（getImageInfo 一次，后面 20 格共用） */
  w: number = 0;
  /** 图的真实像素高 */
  h: number = 0;
  /** 正在使用它的 crop 数；> 0 时禁止淘汰 */
  refs: number = 0;
}

const SOURCES: Map<string, HeldSource> = new Map<string, HeldSource>();
/** 保留几张已解析的 sheet（一屏通常 1~2 张，多留两张给「上一屏」） */
const SOURCE_KEEP: number = 4;

/**
 * 把 sprite sheet 的一块子矩形裁成独立小图（像素级裁切，不涉及任何缩放换算）。
 *
 * 与旧版 CSS `backgroundImage` 方案的根本区别：这里给解码器的是一块**像素矩形**
 * （`desiredRegion`），坐标系就是 sheet 自己的像素坐标系，所以不存在
 * 「CSS 尺寸 → vp」这一步换算，任何长宽比都不可能被拉伸/压扁。
 * 出处：Ehviewer_OHOS `net/PreviewThumbnailCache.ets:81-98`。
 */
export class ThumbCropper {
  static async crop(sheet: string, x: number, y: number, w: number, h: number,
    referer: string): Promise<image.PixelMap | null> {
    if (sheet.length === 0 || w <= 0 || h <= 0) {
      return null;
    }
    await ThumbCropper.acquireSlot();
    try {
      const bytes: ArrayBuffer | null = await ThumbCropper.sheetBytes(sheet, referer);
      if (bytes === null) {
        return null;
      }
      const held: HeldSource | null = await ThumbCropper.acquireSource(sheet, bytes);
      if (held === null || held.src === null) {
        // 容器都解析不了 ⇒ 多半是磁盘上那份字节坏了：清掉，下一轮重下
        await ImageDiskCache.remove(sheet);
        return null;
      }
      try {
        // desiredRegion 越界会让 createPixelMap 直接抛错，所以先夹到图内。
        // 站点声明的 CSS px 与图床实际像素偶有 1~2px 偏差（还有整格缺失的脏数据），
        // 不夹一次的话，最右边/最下边那一列会稳定失败（表现为「最后几格一直转圈」）。
        const left: number = Math.max(0, Math.min(Math.round(x), held.w - 1));
        const top: number = Math.max(0, Math.min(Math.round(y), held.h - 1));
        const width: number = Math.max(1, Math.min(Math.round(w), held.w - left));
        const height: number = Math.max(1, Math.min(Math.round(h), held.h - top));
        const options: image.DecodingOptions = {
          desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
          desiredRegion: {
            x: left,
            y: top,
            size: { width: width, height: height }
          },
          // CROP_FIRST：先裁再解，不能反过来 —— 否则先把整张 sheet 解成 PixelMap 再裁，
          // 一张 2000×1500 的图每格都要占一份全图内存
          cropAndScaleStrategy: image.CropAndScaleStrategy.CROP_FIRST,
          index: 0
        };
        return await held.src.createPixelMap(options);
      } finally {
        ThumbCropper.releaseSource(sheet);
      }
    } catch (e) {
      // 单个格子裁失败不是灾难：调用方会退回逐页真图（比例一定对）
      hilog.warn(0x0000, TAG, 'crop failed %{public}s: %{public}s', sheet, String(e));
      return null;
    } finally {
      ThumbCropper.releaseSlot();
    }
  }

  /** 取 sheet 字节：内存去重 → 磁盘缓存 → 网络（成功即落盘） */
  private static sheetBytes(sheet: string, referer: string): Promise<ArrayBuffer | null> {
    const hit: Promise<ArrayBuffer | null> | undefined = INFLIGHT.get(sheet);
    if (hit !== undefined) {
      return hit;
    }
    const task: Promise<ArrayBuffer | null> = ThumbCropper.fetchSheet(sheet, referer);
    INFLIGHT.set(sheet, task);
    return task;
  }

  private static async fetchSheet(sheet: string, referer: string): Promise<ArrayBuffer | null> {
    try {
      const cached: ArrayBuffer | null = await ImageDiskCache.get(sheet);
      if (cached !== null && cached.byteLength > 0) {
        return cached;
      }
      const bytes: ArrayBuffer | null = await Http.getBytes(sheet, referer);
      if (bytes !== null && bytes.byteLength > 0) {
        // 键就是 sheet 地址：整张 sheet 只下一次，后两屏再进来直接命中
        await ImageDiskCache.put(sheet, bytes);
        return bytes;
      }
      return null;
    } finally {
      INFLIGHT.delete(sheet);
    }
  }

  private static async acquireSource(sheet: string, bytes: ArrayBuffer): Promise<HeldSource | null> {
    const cached: HeldSource | undefined = SOURCES.get(sheet);
    if (cached !== undefined && cached.src !== null && cached.w > 0) {
      // 命中：重新插入到 Map 尾部，等价于「最近使用」，淘汰时先淘汰最久没用的
      SOURCES.delete(sheet);
      SOURCES.set(sheet, cached);
      cached.refs = cached.refs + 1;
      return cached;
    }
    try {
      const src: image.ImageSource = image.createImageSource(bytes);
      const info: image.ImageInfo = await src.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0) {
        await src.release();
        return null;
      }
      const held: HeldSource = new HeldSource();
      held.src = src;
      held.w = info.size.width;
      held.h = info.size.height;
      held.refs = 1;
      SOURCES.set(sheet, held);
      ThumbCropper.trimSources();
      return held;
    } catch (e) {
      return null;
    }
  }

  private static releaseSource(sheet: string): void {
    const held: HeldSource | undefined = SOURCES.get(sheet);
    if (held === undefined) {
      return;
    }
    held.refs = Math.max(0, held.refs - 1);
  }

  /** 只淘汰「没人用、且不是最近几张」的源；正在解码的那张 refs > 0，绝不动 */
  private static trimSources(): void {
    while (SOURCES.size > SOURCE_KEEP) {
      let victim: string = '';
      SOURCES.forEach((held: HeldSource, key: string) => {
        if (victim.length === 0 && held.refs === 0) {
          victim = key;
        }
      });
      if (victim.length === 0) {
        return;
      }
      const held: HeldSource | undefined = SOURCES.get(victim);
      SOURCES.delete(victim);
      if (held !== undefined && held.src !== null) {
        const src: image.ImageSource = held.src;
        held.src = null;
        src.release().catch(() => {
        });
      }
    }
  }

  /** 槽位闸门：满了就排队，release 时把槽位直接转交给队首（active 不减，避免多算一个） */
  private static acquireSlot(): Promise<void> {
    if (active < MAX_ACTIVE) {
      active = active + 1;
      return Promise.resolve();
    }
    return new Promise<void>((resolve: (value: void | PromiseLike<void>) => void) => {
      WAITERS.push(() => {
        active = active + 1;
        resolve();
      });
    });
  }

  private static releaseSlot(): void {
    const next: (() => void) | undefined = WAITERS.shift();
    if (next !== undefined) {
      // 槽位转交：先减掉自己这一份，next 内部会再加回来（语义上等价于直接给下一个）
      active = Math.max(0, active - 1);
      next();
      return;
    }
    active = Math.max(0, active - 1);
  }
}
