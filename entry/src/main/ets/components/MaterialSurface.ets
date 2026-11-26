import { CommonModifier } from '@kit.ArkUI';
import { Material, MaterialKind, MaterialModifier } from '../core/Material';
import { Theme } from '../core/Theme';
import { MaterialPlane } from './MaterialPlane';

/**
 * 顶栏「沉浸材质」宿主。
 *
 * 结构（自下而上，对应参考项目 MaterialSurface 的层次）：
 *   1. backdropBlur 模糊底：任何设备、材质被关闭时都有玻璃观感；
 *   2. 材质层 / 回退实底：材质可用时由系统合成，否则用「回退底色 + 厚模糊」；
 *   3. 中性染色：深色压暗、浅色提亮，不叠白色高光；
 *   4. 发丝分割线：0.5vp，作为「材质到这里结束」的边界，**始终绘制**（回到 1.32.7 的逻辑）；
 *   5. 内容层（标题/按钮）：只有这一层吃点击，其它层 hitTestBehavior None。
 *
 * 为什么内容要**压在列表上**才有意义：顶栏若在布局上占位（列表从顶栏下面开始），
 * 背后没有内容可模糊，材质什么都看不见。所以用法是把本组件放进 Stack，
 * 列表加 `padding({ top: 高度 })` 滚到它下面。
 *
 * 深浅色切换：材质实例里的 materialColor 是创建时固化的，所以要监听 themeDark 重建。
 */
@Component
export struct MaterialSurface {
  /** 顶栏高度（状态栏高度由调用方自己加进去） */
  surfaceHeight: number = 56;
  /** 圆角：通栏顶栏 0，悬浮卡 20 */
  radius: number = 0;
  /**
   * 材质下沿的 0.5vp 发丝分割线。
   *
   * **默认不画**：它只在「内容确实顶到了顶栏下沿」时才有意义 —— 常显的那条线在列表
   * 还在顶部、下面就是大片空白时，只是一条没来由的灰线。所以由调用方按滚动位置自己决定
   * （HomePage / SearchPage / LibraryPage 传 topHairline，其余页面不传＝不画）。
   *
   * 必须是 @Prop 而不是普通成员：普通成员只在构造时取一次值，父级后来把 false 改成 true
   * 不会同步进来（ArkTS V1 的常规变量不做父→子更新），线就永远不会出现。
   */
  /** 配方：顶栏 header / 悬浮面板 panel / 底栏 tabbar */
  kind: MaterialKind = 'header';
  @BuilderParam content: () => void;

  @StorageProp('themeDark') @Watch('onThemeChanged') themeDark: boolean = false;
  /** 材质版本号：参与 ForEach key，切换深浅色时整块重建材质宿主 */
  @State private revision: number = 0;
  private modifier: CommonModifier = new MaterialModifier('header', true);

  aboutToAppear(): void {
    this.rebuild();
  }

  onThemeChanged(): void {
    this.rebuild();
    this.revision = this.revision + 1;
  }

  private rebuild(): void {
    // 材质与挂载表面绑定，不能跨表面复用：每次重建都新建一个 modifier
    this.modifier = new MaterialModifier(this.kind, Material.usable());
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 层 1：模糊底
      Row()
        .width('100%')
        .height(this.surfaceHeight)
        .borderRadius(this.radius)
        .backgroundEffect({ radius: 24, saturation: 1.8, brightness: Theme.isDark() ? 0.85 : 1.08 })
        .hitTestBehavior(HitTestMode.None)

      // 层 2：系统材质（走 Navigation title 作用域，见 MaterialPlane）
      MaterialPlane({ kind: 'header', radius: this.radius, planeHeight: this.surfaceHeight })

      // 层 3：中性染色
      Row()
        .width('100%')
        .height(this.surfaceHeight)
        .borderRadius(this.radius)
        .backgroundColor(Theme.isDark() ? '#12000000' : '#0DFFFFFF')
        .hitTestBehavior(HitTestMode.None)

      // 层 4：发丝线
      // 颜色取 Theme.edge()（中性灰）：这里是一条通栏横线，用 hairline 的「白色 25%」
      // 会读成一条发亮白线；悬浮胶囊用它才是对的（环＝高光）。两者语义不同，故分开取色。
      Row()
        .width('100%')
        .height(0.5)
        .position({ x: 0, y: this.surfaceHeight - 0.5 })
        .backgroundColor(Theme.edge())
        .hitTestBehavior(HitTestMode.None)

      // 层 5：内容
      Column() {
        this.content()
      }
      .width('100%')
      .height(this.surfaceHeight)
    }
    .width('100%')
    .height(this.surfaceHeight)
  }
}
