import { common } from '@kit.AbilityKit';

/**
 * 全局 context 持有者。
 *
 * 原来的 Android 版到处传 Context；鸿蒙上 UIAbilityContext 在页面里也能通过
 * `this.getUIContext().getHostContext()` 拿到，但 Prefs / 保存路径 / 相册导出都要用，
 * 集中一份更省事，也避免每处都写一次类型断言。
 */
export class AppContext {
  private static ctx: common.UIAbilityContext | null = null;

  static init(context: common.UIAbilityContext): void {
    AppContext.ctx = context;
  }

  static get(): common.UIAbilityContext {
    const c: common.UIAbilityContext | null = AppContext.ctx;
    if (c === null) {
      throw new Error('AppContext 未初始化');
    }
    return c;
  }

  /** 兜底：某些场景（例如预览器热重载）拿不到 init 过的 context 时，用页面 context 补上 */
  static ensure(context: common.UIAbilityContext): void {
    if (AppContext.ctx === null) {
      AppContext.ctx = context;
    }
  }
}
