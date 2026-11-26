import { hilog } from '@kit.PerformanceAnalysisKit';
import { EhConsts, Site } from '../core/Consts';
import { Http, HttpResp } from '../core/Http';
import { Prefs } from '../core/Prefs';

const TAG: string = 'JHenTai.GalleryMeta';

/**
 * gdata 的返回项。
 *
 * 字段口径来自 JHenTai/lib/src/net/req.dart:383 `requestGalleryMetadatas`：
 *   POST {api}/api.php  {"method":"gdata","gidlist":[[gid,token],...],"namespace":1}
 *   → {"gmetadata":[{"gid":..., "rating":"4.5", "filecount":"120", "tags":["female:x",...]}]}
 *
 * 注意 gid 在**请求 JSON 里必须是 number**（字符串会被 api 判为非法参数），
 * rating 在返回里是**字符串**（可能带小数），filecount 也是字符串。这里统一转好后再交给 UI。
 */
export class GdataItem {
  gid: string = '';
  /** 0 = 无评分 / 解析失败；有效范围 0~5 */
  rating: number = 0;
  /** -1 = 接口没给 filecount（与 Gallery.pages 的 0 区分开） */
  pages: number = -1;
  /** 原始 `ns:name` 标签串；不在这里拆命名空间，交给调用方按 Models 的 GalleryTag 组装 */
  tags: string[] = [];
}

/** 一次 gdata 的输入项：gid + token，都来自画廊 URL */
export interface GalleryRef {
  gid: string;
  token: string;
}

/** EH 的硬限制：gidlist 单次最多 25 条，超过会被拒绝 */
export const GDATA_BATCH_SIZE: number = 25;
/**
 * 两次请求开始之间的最小间隔。
 *
 * EH 的 api.php 规则是 1 req/s，超了直接回 509（本项目已经被这个限流坑过一次）。
 * 留 1000ms 是规则本身的下限，不再压缩。
 */
const MIN_INTERVAL: number = 1000;

/** 下一批最早可以开始的时刻（毫秒时间戳）。模块级 = 全局唯一，所有调用方共用 */
let nextAllowedAt: number = 0;
/**
 * 全局串行闸门。
 *
 * 为什么用「Promise 链」而不是 while/sleep 轮询：每次调用把自己的完成函数挂到链尾，
 * 上一批 finally 时才放行下一批 —— 排队顺序天然等于到达顺序，也不会出现两个请求同时
 * 越过 nextAllowedAt 检查的竞态（并发读同一个时间戳然后一起发出去）。
 */
let queueTail: Promise<void> = Promise.resolve();

/** 按站点选 gdata 地址：EH → api.e-hentai.org，EX → api.exhentai.org（req.dart:383） */
function apiUrl(): string {
  return Prefs.site() === Site.EX ? EhConsts.EX_GDATA_API : EhConsts.EH_API;
}

function pause(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => resolve(), ms);
  });
}

function asNumber(v: Object | undefined): number {
  if (v === undefined || v === null) {
    return 0;
  }
  if (typeof v === 'number') {
    return v as number;
  }
  if (typeof v === 'string') {
    const s: string = (v as string).trim();
    if (s.length === 0) {
      return 0;
    }
    const n: number = parseFloat(s);
    return isNaN(n) ? 0 : n;
  }
  return 0;
}

function asString(v: Object | undefined): string {
  if (v === undefined || v === null) {
    return '';
  }
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'number') {
    return (v as number).toString();
  }
  return '';
}

/**
 * 发一批（≤25）。失败返回 null，绝不抛：调用方是列表的后台补数据，
 * 失败只该让星星继续灰着，不该把异常冒到页面。
 */
async function postBatch(refs: GalleryRef[]): Promise<GdataItem[] | null> {
  const wait: number = nextAllowedAt - Date.now();
  if (wait > 0) {
    await pause(wait);
  }
  // 先占住下一个时间片：从这次请求开始到下一次请求开始至少 MIN_INTERVAL
  nextAllowedAt = Date.now() + MIN_INTERVAL;

  const pairs: string[] = [];
  for (let i = 0; i < refs.length; i++) {
    // gid 必须是 JSON number：先转 int 再 toString，非法 gid 直接跳过
    const gidNum: number = parseInt(refs[i].gid, 10);
    if (isNaN(gidNum) || refs[i].token.length === 0) {
      continue;
    }
    // token 是十六进制串，正常不含引号；这里只做一次防御性清理，避免拼出非法 JSON
    const token: string = refs[i].token.replace(/["\\]/g, '');
    pairs.push('[' + gidNum.toString() + ',"' + token + '"]');
  }
  if (pairs.length === 0) {
    return [];
  }

  const body: string = '{"method":"gdata","gidlist":[' + pairs.join(',') + '],"namespace":1}';
  try {
    const resp: HttpResp = await Http.postJson(apiUrl(), body);
    if (resp.code !== 200 || resp.body.length === 0) {
      hilog.warn(0x0000, TAG, 'gdata http %{public}d', resp.code);
      return null;
    }
    const obj: Record<string, Object> = JSON.parse(resp.body) as Record<string, Object>;
    const list: Object[] = obj['gmetadata'] as Object[];
    if (list === undefined || list === null) {
      // 站点偶发返回 {"error":"..."}：当成失败，下一轮再试
      hilog.warn(0x0000, TAG, 'gdata without gmetadata');
      return null;
    }
    const out: GdataItem[] = [];
    for (let i = 0; i < list.length; i++) {
      const meta: Record<string, Object> = list[i] as Record<string, Object>;
      const item: GdataItem = new GdataItem();
      item.gid = asString(meta['gid']);
      item.rating = Math.max(0, Math.min(5, asNumber(meta['rating'])));
      const filecount: Object | undefined = meta['filecount'];
      item.pages = filecount === undefined ? -1 : asNumber(filecount);
      const rawTags: Object | undefined = meta['tags'];
      if (rawTags !== undefined && rawTags !== null) {
        const tags: string[] = rawTags as string[];
        for (let k = 0; k < tags.length; k++) {
          item.tags.push(tags[k]);
        }
      }
      out.push(item);
    }
    return out;
  } catch (e) {
    hilog.warn(0x0000, TAG, 'gdata request failed');
    return null;
  }
}

/**
 * 批量取评分 / 页数 / 标签。
 *
 * - 超过 25 条会自己切批，批与批之间仍走同一条串行闸门（间隔 ≥1000ms）；
 * - 任何一批失败（网络 / 4xx / 5xx / 非 JSON）立即返回 null，不写半截结果；
 * - 空输入返回空数组（不是失败），调用方不用为「这一页没有待补条目」特判 null。
 */
export async function fetchGdata(list: GalleryRef[]): Promise<GdataItem[] | null> {
  if (list.length === 0) {
    return [];
  }
  // 先入队，再等前一批：queueTail 只会 resolve（见 finally），不会把异常传给后来者
  const prev: Promise<void> = queueTail;
  let release: () => void = () => {};
  queueTail = new Promise<void>((resolve: () => void) => {
    release = resolve;
  });
  await prev;

  const out: GdataItem[] = [];
  try {
    for (let i = 0; i < list.length; i += GDATA_BATCH_SIZE) {
      const chunk: GalleryRef[] = list.slice(i, i + GDATA_BATCH_SIZE);
      const got: GdataItem[] | null = await postBatch(chunk);
      if (got === null) {
        return null;
      }
      for (let k = 0; k < got.length; k++) {
        out.push(got[k]);
      }
    }
    return out;
  } finally {
    release();
  }
}
