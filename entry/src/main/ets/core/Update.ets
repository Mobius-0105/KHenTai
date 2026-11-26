import { hilog } from '@kit.PerformanceAnalysisKit';
import { Http, HttpResp } from './Http';

const TAG: string = 'JHenTai.Update';

/**
 * 仓库固定为 Mobius-0105/KHenTai 的 latest release。
 *
 * 为什么不用 releases 列表再自己挑：latest 已经是 GitHub 侧按「非 draft / 非
 * prerelease 的最新一条」算好的，列表还要处理分页与排序，取一个够用。
 */
const LATEST_URL: string = 'https://api.github.com/repos/Mobius-0105/KHenTai/releases/latest';
/**
 * UA 必填：GitHub API 对没有 User-Agent 的请求直接 403，
 * 带上项目名也方便仓库侧在流量里认出这是本客户端。
 */
const UA: string = 'KHenTai-HarmonyOS';
/**
 * 弹窗正文上限。
 *
 * Release body 常是几千字的 Markdown（多语言 changelog + 一堆列表），
 * 整段塞进 AlertDialog 会把「去下载」按钮顶出屏幕外，用户反而没法点。
 * 800 字大约是一屏半的正文，够看清改了什么。
 */
const BODY_MAX: number = 800;

/** 检查失败的种类：私有仓库未授权 */
export const UPDATE_PRIVATE: string = 'private';
/** 检查失败的种类：断网 / 超时 / 响应不是合法 Release */
export const UPDATE_NETWORK: string = 'network';

/**
 * 检查失败的载体。
 *
 * 必须 extends Error：ArkTS 的 `throw` 只接受 Error 及其子类（arkts-limited-throw），
 * 抛普通对象过不了编译。message 只进日志，用户看到的文案由 kind 决定。
 */
export class UpdateError extends Error {
  kind: string = UPDATE_NETWORK;

  constructor(kind: string, message: string) {
    super(message);
    this.kind = kind;
  }
}

/** 远端的最新版本（只在比当前版本新时才会被返回） */
export class UpdateInfo {
  /** 去掉 v 前缀的版本号，例如 1.34.0，与 app.json5 的 versionName 同形 */
  version: string = '';
  /** 更新说明，已按 BODY_MAX 截断 */
  body: string = '';
  /** 优先 .hap 资源直链，其次 Release 页面；都可能为空 */
  url: string = '';
}

/**
 * 检查更新。
 *
 * 三条出口，调用方据此决定提示：
 *  - 返回 UpdateInfo → 有新版本；
 *  - 返回 null      → 已是最新（远端版本 <= 当前版本）；
 *  - 抛 UpdateError → 检查本身失败（区分私有仓库 / 网络）。
 *
 * 之所以把「已是最新」做成 null 而不是失败：它是最常见的正常结果，
 * 不该走异常路径。
 */
export class Update {
  static async checkLatest(current: string): Promise<UpdateInfo | null> {
    const headers: Record<string, string> = {
      'Accept': 'application/vnd.github+json',
      'User-Agent': UA
    };
    let resp: HttpResp;
    try {
      resp = await Http.getJson(LATEST_URL, headers);
    } catch (e) {
      // Http.request 把 DNS 失败、超时、断网统一收敛成 EhError('network')，
      // 这里不再区分底层原因 —— 对用户来说都是「网络不行，重试」。
      hilog.warn(0x0000, TAG, 'check failed: request error');
      throw new UpdateError(UPDATE_NETWORK, 'request failed');
    }
    // 404 是私有仓库未授权时的固定表现：GitHub 不会告诉你「这是私有仓库」，
    // 只会当作资源不存在，所以这一条必须单独回，否则会被当成网络故障。
    if (resp.code === 404) {
      throw new UpdateError(UPDATE_PRIVATE, 'repo not public');
    }
    if (resp.code !== 200 || resp.body.length === 0) {
      // 403（限流）/ 5xx / 空体都归到「稍后重试」
      hilog.warn(0x0000, TAG, 'check failed: http %{public}d', resp.code);
      throw new UpdateError(UPDATE_NETWORK, 'http ' + resp.code.toString());
    }

    const info: UpdateInfo | null = Update.parse(resp.body);
    if (info === null) {
      // 200 但解析不出 tag_name：多半是网关塞回来的 HTML 错误页
      hilog.warn(0x0000, TAG, 'check failed: bad payload');
      throw new UpdateError(UPDATE_NETWORK, 'bad payload');
    }
    return Update.compareVersion(info.version, current) > 0 ? info : null;
  }

  /**
   * 按 x.y.z 逐段比数字。
   *
   * 为什么不能用字符串比较：'1.10.0' < '1.9.0' 在字典序下成立，而版本号里
   * 10 比 9 新 —— 用字符串比会让每次小版本更新都被判成「已是最新」。
   *
   * 缺段按 0 补（1.2 == 1.2.0），非数字段取数字前缀（0-beta → 0），
   * 因此 'v1.34.0' 这类 tag 只要先剥掉 v 就能直接比。
   */
  static compareVersion(a: string, b: string): number {
    const pa: string[] = a.trim().split('.');
    const pb: string[] = b.trim().split('.');
    const n: number = Math.max(pa.length, pb.length);
    for (let i = 0; i < n; i++) {
      const x: number = i < pa.length ? Update.seg(pa[i]) : 0;
      const y: number = i < pb.length ? Update.seg(pb[i]) : 0;
      if (x !== y) {
        return x > y ? 1 : -1;
      }
    }
    return 0;
  }

  /**
   * 单段转数字。
   *
   * 用 parseInt 而不是 Number()：Number('0-beta') 是 NaN，而 NaN 参与的比较
   * 全部为 false，会让 compareVersion 走进「相等」分支，把 beta 判成正式版。
   */
  private static seg(s: string): number {
    const v: number = parseInt(s.trim(), 10);
    return Number.isNaN(v) ? 0 : v;
  }

  /**
   * 解析 Release JSON。
   *
   * 用 Record 逐层取值而不是定义镜像类：GitHub 的字段名（html_url / tag_name）
   * 不符合工程命名习惯，定义类要么改字段名要么加注解，反而多一层映射；
   * 而且字段随时可能缺省（body 可以为 null），逐层判型最省事。
   */
  private static parse(text: string): UpdateInfo | null {
    try {
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;

      const tagRaw: Object | undefined = root['tag_name'];
      if (tagRaw === undefined || typeof tagRaw !== 'string') {
        return null;
      }
      const version: string = Update.stripV(tagRaw as string);
      if (version.length === 0) {
        return null;
      }

      const info: UpdateInfo = new UpdateInfo();
      info.version = version;

      const bodyRaw: Object | undefined = root['body'];
      if (bodyRaw !== undefined && typeof bodyRaw === 'string' && (bodyRaw as string).trim().length > 0) {
        info.body = Update.clip(bodyRaw as string);
      } else {
        // body: null 是 Release 的合法取值（发布时没填说明）
        info.body = '该版本没有填写更新说明。';
      }
      info.url = Update.pickUrl(root);
      return info;
    } catch (e) {
      return null;
    }
  }

  /**
   * 下载地址：优先 .hap 资源直链（点开就能下到能装的包），其次 Release 页面。
   *
   * 只认 .hap：Release 里可能同时挂 zip、apk、源码包，随便取第一个资源会把人
   * 引到一个装不上的文件上。没有 .hap 就退回 html_url，至少能自己找。
   */
  private static pickUrl(root: Record<string, Object>): string {
    const assetsRaw: Object | undefined = root['assets'];
    if (assetsRaw !== undefined && assetsRaw !== null) {
      const assets: Object[] = assetsRaw as Object[];
      for (let i = 0; i < assets.length; i++) {
        const asset: Record<string, Object> = assets[i] as Record<string, Object>;
        const nameRaw: Object | undefined = asset['name'];
        if (nameRaw === undefined || typeof nameRaw !== 'string') {
          continue;
        }
        if (!(nameRaw as string).toLowerCase().endsWith('.hap')) {
          continue;
        }
        const dlRaw: Object | undefined = asset['browser_download_url'];
        if (dlRaw !== undefined && typeof dlRaw === 'string' && (dlRaw as string).length > 0) {
          return dlRaw as string;
        }
      }
    }
    const htmlRaw: Object | undefined = root['html_url'];
    return htmlRaw !== undefined && typeof htmlRaw === 'string' ? htmlRaw as string : '';
  }

  /**
   * tag_name 形如 v1.34.0，剥掉前缀 v 与空白后才是能和 versionName 直接比的那一段。
   * 大小写都认（有些仓库用 V1.34.0）。
   */
  private static stripV(tag: string): string {
    let s: string = tag.trim();
    if (s.length > 0 && (s.charAt(0) === 'v' || s.charAt(0) === 'V')) {
      s = s.substring(1);
    }
    return s.trim();
  }

  /** 截到 BODY_MAX 字：剪断处补省略号，免得让人以为说明就到这儿为止 */
  private static clip(s: string): string {
    const t: string = s.trim();
    return t.length > BODY_MAX ? t.substring(0, BODY_MAX) + '…' : t;
  }
}
