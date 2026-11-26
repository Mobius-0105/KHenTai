import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Prefs } from './Prefs';

export enum ThemeMode {
  AUTO = 0,
  LIGHT = 1,
  DARK = 2
}

/**
 * 主题色板。
 *
 * 配色沿用页面里已有的深色系（#0B0D10 / #14171C / #ECEDEF / #5AA9FF），
 * 这样新页面和已写好的页面看起来是一套东西，不必回头改旧页面。
 *
 * 为什么颜色用方法而不是常量字段导出：
 *  - 页面在 build() 里直接调 Theme.card()，跟随设置实时变化；
 *  - 若导出 const 常量，取值发生在模块加载时，切换主题不会生效。
 *
 * AUTO 模式下读 AppStorage 的 systemDark —— EntryAbility 在
 * onWindowStageCreate / onConfigurationUpdate 里写入，系统切换深浅色会立刻反映。
 */
export class Theme {
  private static readonly KEY: string = 'theme_mode';

  // ---------------------------------------------------------- 深色
  private static readonly D_BG: string = '#0B0D10';
  private static readonly D_CARD: string = '#14171C';
  private static readonly D_TEXT: string = '#ECEDEF';
  private static readonly D_SUB: string = '#9AA0AA';
  private static readonly D_ACCENT: string = '#5AA9FF';
  private static readonly D_LINE: string = '#2A2F37';

  // ---------------------------------------------------------- 浅色
  private static readonly L_BG: string = '#F5F6F8';
  private static readonly L_CARD: string = '#FFFFFF';
  private static readonly L_TEXT: string = '#14171C';
  private static readonly L_SUB: string = '#6C727C';
  private static readonly L_ACCENT: string = '#2F6BD8';
  private static readonly L_LINE: string = '#E3E6EA';

  static mode(): ThemeMode {
    const raw: string = Prefs.str(Theme.KEY, 'auto');
    if (raw === 'dark') {
      return ThemeMode.DARK;
    }
    if (raw === 'light') {
      return ThemeMode.LIGHT;
    }
    return ThemeMode.AUTO;
  }

  static setMode(m: ThemeMode): void {
    let raw: string = 'auto';
    if (m === ThemeMode.DARK) {
      raw = 'dark';
    } else if (m === ThemeMode.LIGHT) {
      raw = 'light';
    }
    Prefs.put(Theme.KEY, raw);
    Theme.refresh();
    // 切主题后立刻反色，否则深色下状态栏是白底黑字、看不清
    Theme.applySystemBar();
  }

  static isDark(): boolean {
    const m: ThemeMode = Theme.mode();
    if (m === ThemeMode.DARK) {
      return true;
    }
    if (m === ThemeMode.LIGHT) {
      return false;
    }
    // 跟随系统：拿不到就当浅色，浅色在任何屏幕上都不会不可读
    const sys: boolean | undefined = AppStorage.get<boolean>('systemDark');
    return sys === undefined ? false : sys;
  }

  static bg(): string {
    return Theme.isDark() ? Theme.D_BG : Theme.L_BG;
  }

  static card(): string {
    return Theme.isDark() ? Theme.D_CARD : Theme.L_CARD;
  }

  static text(): string {
    return Theme.isDark() ? Theme.D_TEXT : Theme.L_TEXT;
  }

  static subText(): string {
    return Theme.isDark() ? Theme.D_SUB : Theme.L_SUB;
  }

  static accent(): string {
    return Theme.isDark() ? Theme.D_ACCENT : Theme.L_ACCENT;
  }

  static line(): string {
    return Theme.isDark() ? Theme.D_LINE : Theme.L_LINE;
  }

  /**
   * 玻璃边缘的「发丝」描边色：顶栏材质下沿与悬浮底栏外圈共用这一处。
   *
   * 为什么不复用 line()：line() 是**实色**分隔线（#2A2F37 / #E3E6EA），画在玻璃上会读成
   * 一条硬边，材质立刻不像材质；玻璃的边缘只能靠「比底色亮一点 / 暗一点」的半透明线勾出来，
   * 所以深浅两个方向都是低 alpha 的本体色反转：深色 25% 白、浅色 12% 黑。
   *
   * 为什么必须抽成方法而不是两处各写一份字面量：顶栏和悬浮底栏会同时出现在首页一屏里，
   * 两处写着同一串字符，改一处忘另一处，两片玻璃就差一档灰 —— 那种「看起来差不多但不齐」
   * 的错位比明显不同更难发现。现在只有一个取值点，同屏必然同源。
   */
  static hairline(): string {
    return Theme.isDark() ? '#40FFFFFF' : '#1F000000';
  }

  /**
   * 顶栏材质的下沿缝：**中性灰**，不是白。
   *
   * 为什么不能沿用 hairline()：hairline 的深色值是「白色 25%」，画在悬浮胶囊四周时读作
   * 「玻璃边缘的高光」，是正确的；但顶栏那条是**通栏 0.5 的横线**，白色叠在浅色材质上
   * 就成了一条发亮白线，和一个悬浮胶囊的环完全是两种视觉语义。
   * 这里给一个真正的灰（alpha + 中性色值），深浅色下都读作「缝」而不是「亮边」。
   */
  /**
   * 浮起控件（返回键 / 悬浮工具条 / 悬浮输入框 / 面板按钮）的**白边**。
   *
   * 为什么固定取白 20%（深浅色同值）：这些控件都压在半透明的沉浸材质上，
   * 白色细边读作「玻璃边缘被灯打亮」；而 Theme.edge()（深色灰、浅色黑）是给
   * 通栏材质下沿用的「缝」，两种语义不能互换 —— 之前把两者绑成一处，浅色下顶栏
   * 就成了一条发亮白线。
   */
  static btnEdge(): string {
    return '#33FFFFFF';
  }

  /**
   * 浮起控件共用的接触阴影：大半径 + 极低透明度。
   *
   * 为什么手写而不是靠材质的 applyShadow：bindSheet / 悬浮层里材质背后没有「下方内容」
   * 可投，系统那条阴影在真机上根本看不见（试过，退回）。系统阴影也没有颜色/半径参数
   * 可调，所以这里给一组等效值 —— 读起来是「脚下一圈淡而散的光晕」而不是硬投影。
   * 所有浮起控件都调这一个方法，保证彼此一致，不再各写一份字面量。
   */
  static floatShadow(): ShadowOptions {
    return { radius: 64, color: '#1A000000', offsetX: 0, offsetY: 12 };
  }

  static edge(): string {
    // 浅色模式一律用黑（半透明）：浅色材质偏亮，只有黑色压得住边，
    // 灰色（之前是 #24909090）在浅底上会被材质亮度冲淡，看起来像没画。
    // 浅色 20% 黑：0.7 的细线加上 20% 黑才压得住浅色玻璃，15% 在亮材质上会淡到像没画。
    return Theme.isDark() ? '#40A8A8A8' : '#33000000';
  }

  /**
   * 把当前深浅状态写进 AppStorage。
   * 页面用 @StorageProp('themeDark') 订阅即可在切换主题时自动重绘，
   * 否则 setMode() 之后页面不会收到任何通知。
   */
  /** 缓存的窗口对象：启动时绑一次，之后切主题直接复用 */
  private static win: window.Window | null = null;

  /**
   * 绑定窗口（Index 启动时调一次）。
   *
   * 状态栏图标颜色不跟随应用主题，必须显式告诉窗口系统：
   * 深色界面要浅色图标（白），浅色界面要深色图标（黑），否则深色模式下一片白底白字看不见。
   */
  static async bindWindow(ctx: common.UIAbilityContext): Promise<void> {
    try {
      Theme.win = await window.getLastWindow(ctx);
      await Theme.applySystemBar();
    } catch (e) {
    }
  }

  /** 按当前主题设置状态栏 / 导航条的前景色（图标与文字），并同步背景色 */
  static async applySystemBar(): Promise<void> {
    const win: window.Window | null = Theme.win;
    if (win === null) {
      return;
    }
    const dark: boolean = Theme.isDark();
    try {
      await win.setWindowSystemBarProperties({
        // 状态栏图标：深色界面用白图标，浅色界面用黑图标
        statusBarContentColor: dark ? '#FFFFFF' : '#000000',
        navigationBarContentColor: dark ? '#FFFFFF' : '#000000',
        // 部分设备只认这个布尔量（系统设置里"状态栏图标反色"），两个都写才稳
        isStatusBarLightIcon: dark,
        isNavigationBarLightIcon: dark,
        // 背景透明：内容会自己铺到状态栏下面（沉浸式），别让系统盖一条实色
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000'
      });
    } catch (e) {
    }
    // 状态栏/导航条图标颜色变了，系统栏高度这类信息也顺手刷新一次
    Theme.refresh();
  }

  static refresh(): void {
    AppStorage.setOrCreate<boolean>('themeDark', Theme.isDark());
  }
}
