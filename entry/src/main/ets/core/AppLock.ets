import { userAuth } from '@kit.UserAuthenticationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Prefs } from './Prefs';

const TAG: string = 'JHenTai.AppLock';

const KEY_ON: string = 'app_lock_enabled';
const KEY_SUPPORTED: string = 'app_lock_supported';

/**
 * 认证结果回调。
 * ArkTS 不允许用对象字面量实现 interface，所以单独写一个 class，
 * 构造时把 resolve 包进去，一次性认证结束后直接回调。
 */
class UnlockCallback implements userAuth.IAuthCallback {
  private done: (ok: boolean) => void;

  constructor(done: (ok: boolean) => void) {
    this.done = done;
  }

  onResult(result: userAuth.UserAuthResult): void {
    // 只有 SUCCESS(12500000) 算通过；FAIL/CANCELED/TIMEOUT 一律交给界面重试
    this.done(result.result === userAuth.UserAuthResultCode.SUCCESS);
  }
}

/**
 * 应用锁。
 *
 * 用系统认证控件（userAuth 的 widget 流程），不需要自己画密码键盘，
 * 指纹 / 人脸 / PIN 由系统弹窗决定，也就自动跟随设备能力。
 *
 * 设计上的两个要点：
 *  1. 绝不能让用户被锁在门外 —— 设备没有任何可用认证方式、或认证根本无法启动时，
 *     直接放行（返回 true），并把 app_lock_supported 记成 no/unknown 供设置页提示；
 *  2. 只做“一次认证” —— 每次进前台由页面调 unlock()，不在 core 层常驻监听。
 */
export class AppLock {
  /** 本次进程内是否已通过认证；退到后台由页面调 lock() 复位 */
  private static unlocked: boolean = false;

  static enabled(): boolean {
    return Prefs.bool(KEY_ON, false);
  }

  static setEnabled(on: boolean): void {
    Prefs.put(KEY_ON, on);
    if (on) {
      // 顺手探测一次能力，设置页据此提示“本机不支持指纹/密码”
      Prefs.put(KEY_SUPPORTED, AppLock.probe());
    } else {
      AppLock.unlocked = false;
      Prefs.put(KEY_SUPPORTED, 'unknown');
    }
  }

  static async unlock(): Promise<boolean> {
    if (AppLock.unlocked) {
      return true;
    }
    if (!AppLock.enabled()) {
      AppLock.unlocked = true;
      return true;
    }
    // 明确判定不支持：放行，否则这个用户永远进不来
    if (AppLock.probe() === 'no') {
      hilog.warn(0x0000, TAG, 'no authenticator available, bypass');
      AppLock.unlocked = true;
      Prefs.put(KEY_SUPPORTED, 'no');
      return true;
    }
    const ok: boolean = await AppLock.auth();
    if (ok) {
      AppLock.unlocked = true;
    }
    return ok;
  }

  static isUnlocked(): boolean {
    return AppLock.unlocked;
  }

  static lock(): void {
    AppLock.unlocked = false;
  }

  // ------------------------------------------------------------ 内部

  /**
   * 能力探测，返回 'yes' / 'no' / 'unknown'。
   *
   * getAvailableStatus 需要 ohos.permission.ACCESS_BIOMETRIC（普通权限），
   * 本工程目前没有在 module.json5 里声明，未声明时会抛 201。
   * 这时不能断言“不支持” —— 只能记 unknown，真正的认证流程仍然尝试，
   * 由 getUserAuthInstance 自己抛 12500005/12500006 来兜底。
   */
  private static probe(): string {
    const types: userAuth.UserAuthType[] = [
      userAuth.UserAuthType.FINGERPRINT,
      userAuth.UserAuthType.FACE,
      userAuth.UserAuthType.PIN
    ];
    let denied: boolean = false;
    for (let i = 0; i < types.length; i++) {
      try {
        userAuth.getAvailableStatus(types[i], userAuth.AuthTrustLevel.ATL2);
        return 'yes';
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        if (err.code === 201) {
          denied = true;
        } else if (err.code === 12500010) {
          // 该类型凭据未录入，继续看下一个
        }
      }
    }
    return denied ? 'unknown' : 'no';
  }

  private static auth(): Promise<boolean> {
    return new Promise<boolean>((resolve: (ok: boolean) => void) => {
      try {
        const param: userAuth.AuthParam = {
          // 不做服务端校验，challenge 留空即可；传空数组是官方文档给的写法
          challenge: new Uint8Array(0),
          authType: [
            userAuth.UserAuthType.FINGERPRINT,
            userAuth.UserAuthType.FACE,
            userAuth.UserAuthType.PIN
          ],
          // ATL2 = 应用登录级别，指纹/PIN 都能满足；ATL3 会把没有 3D 人脸的设备挡掉
          authTrustLevel: userAuth.AuthTrustLevel.ATL2
        };
        const widget: userAuth.WidgetParam = { title: '解锁 JHenTai' };
        const instance: userAuth.UserAuthInstance = userAuth.getUserAuthInstance(param, widget);
        instance.on('result', new UnlockCallback((ok: boolean) => {
          if (ok) {
            Prefs.put(KEY_SUPPORTED, 'yes');
          }
          resolve(ok);
        }));
        instance.start();
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        hilog.warn(0x0000, TAG, 'auth start failed: %{public}d', err.code);
        // 12500005/12500006 类型或等级不支持、12500010 凭据未录入：属于“设备用不了”，必须放行；
        // 201 权限不足同理 —— 认证根本起不来，若判失败用户会永远打不开应用。
        if (err.code === 12500005 || err.code === 12500006 || err.code === 12500010 || err.code === 201) {
          Prefs.put(KEY_SUPPORTED, 'no');
          resolve(true);
        } else {
          resolve(false);
        }
      }
    });
  }
}
