/**
 * 详情页浮层对「系统返回」的接管点。
 *
 * 为什么需要这张登记表：本工程没有用 Navigation 路由，页面栈是 Index.ets 里一层层
 * `if` 出来的页面（L_TABS / L_DETAIL / L_READER …）。而 `onBackPress` **只对
 * @Entry 装饰的页面生效** —— 挂在普通子组件（DetailPage）上的 onBackPress 永远不会
 * 被系统调用，真正收到返回键的只有 Index。Index 原来只按「栈长 > 1」无脑 pop，
 * 于是详情页打开收藏面板时按返回键，系统直接把详情页退掉、回到首页，面板跟着消失。
 *
 * 做法：详情页挂载时把自己的「先关浮层」处理器登记进来；Index 在 pop 之前先问一次，
 * 处理器返回 true 表示这次返回已经被浮层吃掉（Index 不应再出栈）。详情页销毁时注销，
 * 不留悬空引用。全工程同一时刻只有一个详情页实例，所以一个槽位就够。
 */
export class DetailBackGate {
  private static handler: (() => boolean) | null = null;

  /** 详情页挂载时登记（处理器内部只做「有浮层就关掉并返回 true」这一件事） */
  static register(fn: () => boolean): void {
    DetailBackGate.handler = fn;
  }

  /** 详情页销毁时注销：不清掉的话，下一次返回会调到一个已经不在树上的组件 */
  static unregister(): void {
    DetailBackGate.handler = null;
  }

  /**
   * Index 在出栈前调用。
   *
   * @returns true = 详情页已经处理掉这次返回（关掉了某个浮层），调用方不要再 pop。
   */
  static consume(): boolean {
    const h: (() => boolean) | null = DetailBackGate.handler;
    if (h === null) {
      return false;
    }
    return h();
  }
}
