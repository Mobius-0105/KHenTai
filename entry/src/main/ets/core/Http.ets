import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Cookies } from './Cookies';
import { EhConsts } from './Consts';
import { EhError } from './Models';

const TAG: string = 'JHenTai.Http';

export class HttpResp {
  code: number = 0;
  body: string = '';
  bytes: ArrayBuffer | null = null;
  location: string = '';
  setCookies: string[] = [];
}

/**
 * 极薄的 HTTP 封装。
 *
 * 只做四件鸿蒙侧必须自己做的事：
 *  1. 对 EH 主站域的请求带上 Cookie（@ohos.net.http 不管 Cookie 罐）；
 *  2. 收到 Set-Cookie 后写回 Cookie 罐；
 *  3. 统一的 UA / Referer / 超时；
 *  4. 把 EH 的“限流页 / 封禁页 / Cloudflare 拦截”翻译成人话。
 *
 * 注意：不使用系统代理设置，也不做域名前置。EX 站在部分网络环境需要代理，
 * 客户端层做不了，README 里已说明。
 */
export class Http {

  /**
   * 从 URL 里取出小写 host（不含端口 / userinfo）。
   *
   * 手写解析而不用正则：这里判错的代价是把 ipb_member_id / ipb_pass_hash / igneous
   * 送到别人家的服务器上。可以拆成三步的写死逻辑比一条容易手滑的正则更可信。
   */
  private static hostOf(url: string): string {
    let s: string = url.trim();
    const scheme: number = s.indexOf('://');
    if (scheme >= 0) {
      s = s.substring(scheme + 3);
    } else if (s.startsWith('//')) {
      s = s.substring(2);
    }
    // authority 到第一个 / ? # 为止
    let end: number = s.length;
    const marks: string[] = ['/', '?', '#'];
    for (let i = 0; i < marks.length; i++) {
      const p: number = s.indexOf(marks[i]);
      if (p >= 0 && p < end) {
        end = p;
      }
    }
    let authority: string = s.substring(0, end);
    // 去掉 userinfo（形如 user:pass@host）
    const at: number = authority.lastIndexOf('@');
    if (at >= 0) {
      authority = authority.substring(at + 1);
    }
    // 去掉端口；IPv6 字面量 [::1] 单独处理（EH 用不到，但别在这里写崩）
    let host: string = authority;
    if (host.startsWith('[')) {
      const rb: number = host.indexOf(']');
      if (rb >= 0) {
        host = host.substring(0, rb + 1);
      }
    } else {
      const colon: number = host.indexOf(':');
      if (colon >= 0) {
        host = host.substring(0, colon);
      }
    }
    host = host.toLowerCase();
    // 末尾的点是 FQDN 写法（a.e-hentai.org.），与不带点等价
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    return host;
  }

  /**
   * host 是否等于 domain 或 domain 的子域。
   *
   * 关键在于「后缀必须带前导点」：拼成 '.' + domain 再做 endsWith，
   * 天然要求分界处就是 '.'，于是
   *   - `evil-e-hentai.org`   → 不以 '.e-hentai.org' 结尾 → 拒绝
   *   - `e-hentai.org.evil.com` → 结尾是 .evil.com → 拒绝
   * 若写成 host.indexOf(domain) >= 0 或 endsWith(domain)，这两种伪造都能过。
   */
  private static isUnder(host: string, domain: string): boolean {
    if (host === domain) {
      return true;
    }
    return host.endsWith('.' + domain) && host.length > domain.length + 1;
  }

  /**
   * 目标 URL 是否属于「应当携带登录 Cookie」的 EH 域。
   *
   * 为什么必须按域过滤：Cookie 罐是扁平的、不区分域（EH 站点与论坛共用一套登录态），
   * 一旦无条件附在请求头上，任何第三方 URL（缩略图 CDN ehgt.org、H@H 图床、
   * GitHub 上的翻译表等）都会收到 ipb_member_id / ipb_pass_hash / igneous，
   * 等于把账号令牌交给第三方域。
   *
   * 白名单只有两个可注册域，其子域全部覆盖：
   *   - e-hentai.org  → api / g / upld / forums 等子域一并放行（登录、收藏、发评都要用）
   *   - exhentai.org  → EX 站及子域
   *
   * 刻意不包含：
   *   - *.hath.network（H@H 图床节点）：只按 Referer 做防盗链校验，不认 Cookie，
   *     附上去纯属白送令牌，且节点是第三方志愿者机器。
   *   - ehgt.org（缩略图 CDN）：公开可读，同样不需要 Cookie。
   *   - 其余任何域（github、镜像等）默认不放行。
   */
  static isAuthHost(url: string): boolean {
    const host: string = Http.hostOf(url);
    if (host.length === 0) {
      return false;
    }
    return Http.isUnder(host, 'e-hentai.org') || Http.isUnder(host, 'exhentai.org');
  }

  private static buildHeader(url: string, referer: string): Record<string, string> {
    const h: Record<string, string> = {};
    h['User-Agent'] = EhConsts.USER_AGENT;
    h['Accept'] = 'text/html,application/xhtml+xml,image/*;q=0.8,*/*;q=0.5';
    h['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8';
    // 只在 EH 主站域附 Cookie；不通过就干脆不设这个头
    //（空 `Cookie:` 头会被部分服务端当成异常请求，比不带头更糟）
    if (Http.isAuthHost(url)) {
      const cookie: string = Cookies.header();
      if (cookie.length > 0) {
        h['Cookie'] = cookie;
      }
    }
    if (referer.length > 0) {
      h['Referer'] = referer;
    }
    return h;
  }

  static async get(url: string, referer: string = ''): Promise<HttpResp> {
    return Http.request(url, http.RequestMethod.GET, Http.buildHeader(url, referer), '');
  }

  static async postForm(url: string, form: string, referer: string = ''): Promise<HttpResp> {
    const header: Record<string, string> = Http.buildHeader(url, referer);
    header['Content-Type'] = 'application/x-www-form-urlencoded';
    return Http.request(url, http.RequestMethod.POST, header, form);
  }

  static async postJson(url: string, body: string): Promise<HttpResp> {
    const header: Record<string, string> = Http.buildHeader(url, '');
    header['Content-Type'] = 'application/json';
    return Http.request(url, http.RequestMethod.POST, header, body);
  }

  /**
   * 带自定义请求头的 GET（返回原始 HttpResp，非 200 也不抛）。
   *
   * 为什么不直接用 get()：get() 的 buildHeader 写死了 EH 的 UA 与 Accept，
   * 而 GitHub API 要求专用 UA（缺 UA 直接 403）和 application/vnd.github+json，
   * 若沿用 EH 的 UA 会被当成普通浏览器抓取，随包附带的 EH Cookie 更不该去第三方域
   * （isAuthHost 已经挡住，但 UA 也必须换）。
   *
   * 这里只透传调用方给的头，一个都不额外注入 —— 调用方看得见自己发了什么，
   * 排查 404/403 时才不用猜是不是被中间层加了头。
   */
  static async getJson(url: string, headers: Record<string, string>): Promise<HttpResp> {
    return Http.request(url, http.RequestMethod.GET, headers, '');
  }

  /** 图片下载：返回原始字节 */
  static async getBytes(url: string, referer: string = ''): Promise<ArrayBuffer | null> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const res: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: Http.buildHeader(url, referer),
        connectTimeout: 20000,
        readTimeout: 40000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      Http.collectCookies(res);
      if (res.responseCode !== 200) {
        return null;
      }
      const r: string | Object | ArrayBuffer = res.result;
      if (r instanceof ArrayBuffer) {
        return r;
      }
      return null;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(0x0000, TAG, 'image failed %{public}s: %{public}d', url, err.code);
      return null;
    } finally {
      req.destroy();
    }
  }

  private static async request(
    url: string,
    method: http.RequestMethod,
    header: Record<string, string>,
    body: string
  ): Promise<HttpResp> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: header,
        connectTimeout: 20000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING
      };
      if (body.length > 0) {
        options.extraData = body;
      }
      const res: http.HttpResponse = await req.request(url, options);
      const out: HttpResp = new HttpResp();
      out.code = res.responseCode;
      Http.collectCookies(res);
      out.setCookies = Http.cookiesOf(res);
      const h: Record<string, string> = res.header as Record<string, string>;
      const loc: string | undefined = h['location'];
      out.location = loc === undefined ? '' : loc;
      const r: string | Object | ArrayBuffer = res.result;
      out.body = typeof r === 'string' ? r : '';
      Http.throwIfBlocked(out);
      return out;
    } catch (e) {
      if (e instanceof EhError) {
        throw e;
      }
      const err: BusinessError = e as BusinessError;
      hilog.error(0x0000, TAG, 'request failed %{public}s: code=%{public}d', url, err.code);
      throw new EhError('network', '网络请求失败（' + err.code.toString() + '），请检查网络或代理');
    } finally {
      req.destroy();
    }
  }

  private static cookiesOf(res: http.HttpResponse): string[] {
    const h: Record<string, Object> = res.header as Record<string, Object>;
    const raw: Object | undefined = h['set-cookie'];
    if (raw === undefined || raw === null) {
      return [];
    }
    if (typeof raw === 'string') {
      return [raw as string];
    }
    try {
      const arr: string[] = raw as string[];
      return arr;
    } catch (e) {
      return [];
    }
  }

  private static collectCookies(res: http.HttpResponse): void {
    const list: string[] = Http.cookiesOf(res);
    if (list.length > 0) {
      Cookies.accept(list);
    }
  }

  /** EH 的三种“软错误”都是 200 + 一段文字，只能靠正文识别 */
  private static throwIfBlocked(res: HttpResp): void {
    const body: string = res.body;
    if (body.length === 0) {
      return;
    }
    if (body.startsWith('Your IP address') || body.startsWith('This IP address')) {
      throw new EhError('banned', '当前 IP 被站点封禁（可在设置里切换站点或更换网络）');
    }
    if (body.startsWith('You have exceeded your image') || body.indexOf('You are opening pages too fast') >= 0) {
      throw new EhError('limit', '请求过于频繁，已被站点限流，请稍后再试');
    }
    if (body.indexOf('Page load has been aborted due to a fatal error') >= 0) {
      throw new EhError('server', '站点返回了致命错误页，请重试');
    }
    if (body.indexOf('Just a moment...') >= 0 && res.code === 403) {
      throw new EhError('cloudflare', '被 Cloudflare 拦截，请稍后重试或更换网络');
    }
  }
}
