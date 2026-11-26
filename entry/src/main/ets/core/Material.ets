import { CommonModifier, uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Theme } from './Theme';

/**
 * HarmonyOS 7.0（API 26）沉浸材质（system material）封装。
 *
 * 参考 `Han1meViewer-HarmonyOS/common/Material.ets` 的用法，按本工程的色板重写：
 *
 *  1. 组件级材质：应用在 module.json5 里把 metadata「ohos.arkui.UIMaterial.state」设为 enable 后，
 *     普通组件显式挂 `uiMaterial.ImmersiveMaterial` 即可由系统合成玻璃（带光感/按算力自适应）。
 *     挂属性的方式用 `CommonModifier` 子类（`.attributeModifier(...)`），这样「材质 / 回退实底」
 *     的选择逻辑只写一处，多个页面共用同一套降级规则。
 *  2. 底栏有更直接的入口：`Tabs.barFloatingStyle({ systemMaterial })`，
 *     系统栏作用域内的材质才是真正参与合成的沉浸材质（这条比普通组件更可靠）。
 *  3. 任何一步不可用都必须能回退到「实底 + 厚模糊」，否则会出现透明无底板的顶栏。
 *
 * 三个坑（都是参考项目踩过的）：
 *  - 深色主题不能用白色染色，否则顶栏/面板会发白；深色用黑 alpha（压暗玻璃）。
 *  - `materialColor` 在创建实例的一刻固化，不是响应式属性；主题切换后必须**重建材质实例**。
 *  - 低算力设备（SMOOTH 档）材质会退化成「底色 + 描边」，染色 alpha 要更高才可读。
 */
export type MaterialKind = 'header' | 'tabbar' | 'panel';

export class Material {
  private static checked: boolean = false;
  private static available: boolean = false;
  private static levelChecked: boolean = false;
  private static levelValue: uiMaterial.MaterialLevel = uiMaterial.MaterialLevel.EXQUISITE;

  /** 当前设备是否支持沉浸材质（API 26+ 且系统能力可用） */
  static supported(): boolean {
    if (Material.checked) {
      return Material.available;
    }
    Material.checked = true;
    try {
      Material.available = deviceInfo.apiAvailable('26.0.0') && uiMaterial.isImmersiveMaterialSupported();
    } catch (e) {
      Material.available = false;
    }
    return Material.available;
  }

  /** 设置里切换开关/系统变更后重新探测 */
  static refresh(): boolean {
    Material.checked = false;
    return Material.supported();
  }

  /**
   * 能否真正渲染系统材质：API 26+、系统支持、且应用没被配置成 DISABLE。
   * 应用级状态来自 entry/module.json5 的 metadata「ohos.arkui.UIMaterial.state」。
   */
  static usable(): boolean {
    if (!Material.supported()) {
      return false;
    }
    try {
      return uiMaterial.getMaterialInfo().state !== uiMaterial.MaterialState.DISABLE;
    } catch (e) {
      return false;
    }
  }

  /** 清空组件上可能残留的材质（从「有材质」切到「回退实底」时必须调用） */
  static empty(): uiMaterial.Material | undefined {
    try {
      return uiMaterial.Material.empty;
    } catch (e) {
      return undefined;
    }
  }

  /** 设备算力档：决定材质通透度（EXQUISITE 高 / GENTLE 中 / SMOOTH 低） */
  static level(): uiMaterial.MaterialLevel {
    if (Material.levelChecked) {
      return Material.levelValue;
    }
    Material.levelChecked = true;
    try {
      Material.levelValue = uiMaterial.getGlobalMaterialLevel();
    } catch (e) {
      Material.levelValue = uiMaterial.MaterialLevel.EXQUISITE;
    }
    return Material.levelValue;
  }

  /** 算力档越低，越需要一层更实的底色兜住文字 */
  private static tintByLevel(exquisite: string, gentle: string, smooth: string): string {
    const level: uiMaterial.MaterialLevel = Material.level();
    if (level === uiMaterial.MaterialLevel.GENTLE) {
      return gentle;
    }
    if (level === uiMaterial.MaterialLevel.SMOOTH) {
      return smooth;
    }
    return exquisite;
  }

  /**
   * 底栏染色：底栏压在页面底上，深色用 5% 白（保持通透），浅色用 7% 白。
   * 这是参考项目验证过的「让底栏不显得比页面更沉」的取值。
   */
  static tabBarMaterial(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      materialColor: Theme.isDark() ? '#0DFFFFFF' : '#12FFFFFF',
      colorInvert: false,
      applyShadow: true,
      interactive: true,
      lightEffect: { color: Theme.accent() }
    });
  }

  /**
   * 顶栏染色：深色用黑（压暗玻璃，否则顶栏发白）、浅色用白。
   * 越厚的材质染色越淡，保证文字可读。
   */
  static headerMaterial(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: Material.tintByLevel(
        Theme.isDark() ? '#1A000000' : '#1FFFFFFF',
        Theme.isDark() ? '#33000000' : '#33FFFFFF',
        Theme.isDark() ? '#66000000' : '#66FFFFFF'),
      colorInvert: false,
      applyShadow: false,
      interactive: true,
      lightEffect: { color: Theme.accent() }
    });
  }

  /** 面板（弹层底板 / 悬浮卡）染色：比顶栏更实一档 */
  static panelMaterial(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      materialColor: Material.tintByLevel(
        Theme.isDark() ? '#26000000' : '#2EFFFFFF',
        Theme.isDark() ? '#40000000' : '#40FFFFFF',
        Theme.isDark() ? '#73000000' : '#73FFFFFF'),
      colorInvert: false,
      applyShadow: true,
      interactive: true,
      lightEffect: { color: Theme.accent() }
    });
  }

  static create(kind: MaterialKind): uiMaterial.ImmersiveMaterial {
    if (kind === 'tabbar') {
      return Material.tabBarMaterial();
    }
    return kind === 'panel' ? Material.panelMaterial() : Material.headerMaterial();
  }

  /**
   * 材质不可用时的回退底色（毛玻璃）。
   *
   * 关键：alpha 必须够低（深色 ~45%、浅色 ~55%），否则会把下面那层 backdropBlur 完全挡住，
   * 看起来就是一块实色板 —— 之前的 90% 不透明就是"没有玻璃感"的直接原因。
   * 深色用深色底 + 低 alpha（压暗玻璃），浅色用白色底（提亮），两边都不能用对面的色相。
   */
  static fallbackTint(kind: MaterialKind): string {
    if (kind === 'tabbar') {
      return Theme.isDark() ? '#7313161B' : '#8CFFFFFF';
    }
    if (kind === 'panel') {
      return Theme.isDark() ? '#8013161B' : '#99FFFFFF';
    }
    return Theme.isDark() ? '#8C14171C' : '#B3FFFFFF';
  }

  /** 算力档文案（设置页诊断用） */
  static levelLabel(): string {
    const level: uiMaterial.MaterialLevel = Material.level();
    if (level === uiMaterial.MaterialLevel.GENTLE) {
      return '中（GENTLE，材质会略厚）';
    }
    if (level === uiMaterial.MaterialLevel.SMOOTH) {
      return '低（SMOOTH，材质退化为底色+描边）';
    }
    return '高（EXQUISITE，完整玻璃与光感）';
  }

  /** 调试用状态文案（设置页展示） */
  static stateLabel(): string {
    if (!Material.supported()) {
      return '本机不支持沉浸材质';
    }
    try {
      const state: number = uiMaterial.getMaterialInfo().state as number;
      if (state === 1) {
        return '沉浸材质已开启';
      }
      if (state === 2) {
        return '沉浸材质已被禁用';
      }
    } catch (e) {
      return '沉浸材质状态未知';
    }
    return '沉浸材质：系统默认';
  }
}

/**
 * 把「材质 / 回退」挂到普通组件上的通用属性修饰器。
 *
 * 用途：给顶栏、悬浮卡这类**没有系统栏作用域**的组件铺一层沉浸材质；
 * 不可用时自动退化成「回退底色 + 厚模糊」，任何设备上都不会出现透明无底板。
 *
 * 注意：材质对象与挂载表面绑定，不能跨表面复用 —— 每次重建都要 new 一个 modifier。
 */
export class MaterialModifier extends CommonModifier {
  private kind: MaterialKind;
  /** 名字不能叫 enabled：会与 CommonAttribute 的通用属性同名冲突 */
  private useMaterial: boolean;

  constructor(kind: MaterialKind, enabled: boolean) {
    super();
    this.kind = kind;
    this.useMaterial = enabled;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    if (this.useMaterial && Material.usable()) {
      try {
        instance.systemMaterial(Material.create(this.kind));
        return;
      } catch (e) {
        // 个别环境创建材质会抛错：落到下面的实底回退
      }
    }
    const empty: uiMaterial.Material | undefined = Material.empty();
    if (empty !== undefined) {
      instance.systemMaterial(empty);
    }
    instance.backgroundColor(Material.fallbackTint(this.kind));
    // 真玻璃靠 backgroundEffect：它比 backgroundBlurStyle 多两个关键参数——
    //  saturation 提高后底下的封面颜色会「透上来」，brightness 控制整体明度。
    //  只有 blur 没有 saturation 时观感是「蒙灰」，这就是之前不像材质的原因之一。
    try {
      instance.backgroundEffect({
        radius: this.kind === 'header' ? 24 : 30,
        saturation: 1.8,
        brightness: Theme.isDark() ? 0.85 : 1.08
      });
    } catch (e) {
      // 个别设备不支持 backgroundEffect：退回基础模糊，至少不透明
      instance.backgroundBlurStyle(this.kind === 'header' ? BlurStyle.COMPONENT_THICK : BlurStyle.COMPONENT_THIN);
    }
  }
}
