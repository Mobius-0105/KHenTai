import { Prefs } from './Prefs';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'JHenTai.Cookie';
const KEY: string = 'cookies';

/**
 * Cookie 罐。
 *
 * EH 家族（e-hentai.org / exhentai.org / forums.e-hentai.org）共用同一套登录态，
 * 所以这里用一个扁平的 name->value 表，不区分域名 —— 这正好符合 EH 的实际情况：
 *   ipb_member_id / ipb_pass_hash  （论坛登录后下发，站点与论坛共用）
 *   sk                            （e-hentai.org/bounce_login.php 下发，EX 必带）
 *   igneous                       （EX 站鉴权，缺少会直接看到 "Sad Panda"）
 *
 * 图片服务器（h@h）不需要 Cookie，但需要 Referer，见 Http。
 */
export class Cookies {
  private static jar: Map<string, string> = new Map<string, string>();
  private static loaded: boolean = false;

  static load(): void {
    if (Cookies.loaded) {
      return;
    }
    Cookies.loaded = true;
    const raw: string = Prefs.str(KEY, '');
    if (raw.length === 0) {
      return;
    }
    try {
      const obj: Record<string, string> = JSON.parse(raw) as Record<string, string>;
      const keys: string[] = Object.keys(obj);
      for (let i = 0; i < keys.length; i++) {
        Cookies.jar.set(keys[i], obj[keys[i]]);
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'parse cookies failed');
    }
  }

  private static persist(): void {
    const obj: Record<string, string> = {};
    Cookies.jar.forEach((v: string, k: string) => {
      obj[k] = v;
    });
    Prefs.put(KEY, JSON.stringify(obj));
  }

  static get(name: string): string {
    Cookies.load();
    const v: string | undefined = Cookies.jar.get(name);
    return v === undefined ? '' : v;
  }

  static set(name: string, value: string): void {
    Cookies.load();
    if (value.length === 0) {
      Cookies.jar.delete(name);
    } else {
      Cookies.jar.set(name, value);
    }
    Cookies.persist();
  }

  static remove(name: string): void {
    Cookies.load();
    Cookies.jar.delete(name);
    Cookies.persist();
  }

  static clear(): void {
    Cookies.load();
    Cookies.jar.clear();
    Cookies.persist();
  }

  /** 请求头里的 Cookie 字段 */
  static header(): string {
    Cookies.load();
    const parts: string[] = [];
    Cookies.jar.forEach((v: string, k: string) => {
      parts.push(k + '=' + v);
    });
    return parts.join('; ');
  }

  /**
   * 收下响应里的 Set-Cookie。
   * 格式形如 `ipb_member_id=12345; expires=...; path=/; domain=.e-hentai.org; secure`，
   * 只取第一段 name=value；value 为 deleted 表示服务端删除该 Cookie。
   */
  static accept(setCookies: string[]): void {
    Cookies.load();
    let changed: boolean = false;
    for (let i = 0; i < setCookies.length; i++) {
      const line: string = setCookies[i];
      const semi: number = line.indexOf(';');
      const pair: string = (semi < 0 ? line : line.substring(0, semi)).trim();
      const eq: number = pair.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const name: string = pair.substring(0, eq).trim();
      const value: string = pair.substring(eq + 1).trim();
      if (name.length === 0) {
        continue;
      }
      if (value.length === 0 || value === 'deleted') {
        Cookies.jar.delete(name);
      } else {
        Cookies.jar.set(name, value);
      }
      changed = true;
    }
    if (changed) {
      Cookies.persist();
    }
  }

  /** 是否已登录（有 ipb_member_id 视为登录态） */
  static isLoggedIn(): boolean {
    return Cookies.get('ipb_member_id').length > 0;
  }

  /** EX 站需要的 igneous 是否就位 */
  static hasIgneous(): boolean {
    return Cookies.get('igneous').length > 0;
  }

  static summary(): string {
    if (!Cookies.isLoggedIn()) {
      return '未登录';
    }
    const ign: string = Cookies.hasIgneous() ? ' · EX 就绪' : '';
    return '已登录' + ign;
  }
}
