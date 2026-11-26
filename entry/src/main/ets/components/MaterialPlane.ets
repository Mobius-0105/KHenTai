import { CommonModifier } from '@kit.ArkUI';
import { Material, MaterialKind } from '../core/Material';
import { Theme } from '../core/Theme';

/**
 * 玻璃描边宽度（vp）。
 *
 * 导出成常量而不是各调用点写一份字面量：顶栏的胶囊、选中块、按钮会同时出现在一屏里，
 * 只要有一处写了别的数，那一条边就会比旁边粗/细半档 —— 这种「差不多但不齐」最难发现。
 * 0.7 而不是 0.6：浅色模式的 edge() 只有 15% 黑，0.6 的画在浅底玻璃上几乎读不出来，
 * 0.7 才是一条能看清的黑边（深色模式同理，只是不刺眼）。
 */
export const MATERIAL_EDGE_WIDTH: number = 0.7;

/**
 * 真正的「系统沉浸材质」平面。
 *
 * 这段是照抄 Han1meViewer `components/common/MaterialSurface.ets` 的 `materialHost()`
 * （该工程已在真机上验证过材质能出来），关键点两条：
 *
 *  1. **必须放进系统栏作用域**：材质 Row 不是直接挂在页面上，而是塞进一个**空的
 *     `Navigation` 的 title builder**。`systemMaterial` 只在系统栏（标题栏/TabBar）里
 *     才会真正参与合成，挂在普通 Row 上会被降级成纯染色——这就是之前"看不到材质"的原因。
 *  2. `hideTitleBar(false)`（默认）+ `title({builder, height})` 让这个作用域真实存在且尺寸可控；
 *     宿主 Navigation 自身透明、圆角裁切，`title` 的 options 里把系统自带的材质清空
 *     （`systemMaterial: Material.empty()`），只留我们自己那层。
 *
 * 降级：`Material.usable()` 为假时，Row 退成「半透明底 + backgroundEffect」，仍然是一块玻璃，
 * 只是没有系统的光感。
 */
@Component
export struct MaterialPlane {
  kind: MaterialKind = 'tabbar';
  /** 圆角要与承载它的容器一致，否则材质边缘会露出直角 */
  radius: number = 0;
  /** 必须有确定高度：Navigation title 作用域要按这个高度创建 */
  planeHeight: number = 64;
  /**
   * 是否在材质外沿画一圈描边（0.7 vp，色取 Theme.edge()）。
   *
   * 为什么默认 false：这个组件在整站有十几处调用，多数是「一整条顶栏 / 一整块面板」那种
   * 大面积玻璃 —— 它们靠自身与底色的明暗差就已经分层，再描一圈边会被读成卡片边框，
   * 反而破坏了材质的悬浮感；而且一旦默认开，所有历史调用点都会在没人注意的情况下一起变样。
   * 只有**浮在内容上的一小块**（顶栏的分段胶囊、选中块、筛选/清空/搜索按钮、分类胶囊）
   * 才需要边：浅色模式下那块玻璃几乎和背景同色，不描边就看不出边界在哪。所以由调用点显式传 true。
   */
  @Prop edge: boolean = false;

  /**
   * 强制深色玻璃（不看主题）。
   *
   * 有些页面底色恒为深色（阅读器的 #0B0D10）：浅色主题下系统材质会染成近白，
   * 白字压上去对比度掉一半。这里跳过系统材质，直接用深色底 + 厚模糊，
   * 观感是「手机上那块深色玻璃」，与 Bika 阅读器的沉浸材质同一路。
   */
  @Prop dark: boolean = false;

  /** 主题切换必须重建：materialColor 在创建材质实例时就固化了，不是响应式属性 */
  @StorageProp('themeDark') @Watch('onThemeChanged') themeDark: boolean = false;
  @State private rev: number = 0;
  private md: CommonModifier = new CommonModifier();

  aboutToAppear(): void {
    this.rebuild();
  }

  onThemeChanged(): void {
    this.rebuild();
    this.rev = this.rev + 1;
  }

  private rebuild(): void {
    const m: CommonModifier = new CommonModifier();
    m.borderRadius(this.radius).clip(this.radius > 0).backgroundColor(Color.Transparent);
    if (this.dark) {
      // 深色玻璃 = **系统材质 + 一层深色染色**，不是「换成普通模糊」。
      //
      // 上一版直接跳到 backgroundEffect，得到的就是一块磨砂板：没有材质的光感与边缘高光。
      // 系统材质本身会按主题染色（浅色主题偏白），所以要保留它、再盖一层深色 tint 压回来
      // —— Bika 阅读器的深色胶囊也是这个做法（系统材质 + immersiveCapsuleTint）。
      m.backgroundColor(Color.Transparent);
      if (Material.usable()) {
        try {
          m.systemMaterial(Material.create(this.kind));
        } catch (e) {
          m.backgroundColor('#CC101215');
          m.backgroundEffect({ radius: 30, saturation: 1.6, brightness: 0.72 });
        }
      } else {
        m.backgroundColor('#CC101215');
        m.backgroundEffect({ radius: 30, saturation: 1.6, brightness: 0.72 });
      }
      this.md = m;
      return;
    }
    if (Material.usable()) {
      m.systemMaterial(Material.create(this.kind));
    } else {
      // 没有系统材质时的等效玻璃：半透明底 + 模糊/饱和/亮度
      m.backgroundColor(Material.fallbackTint(this.kind));
      m.backgroundEffect({
        radius: 30,
        saturation: 1.8,
        brightness: Theme.isDark() ? 0.85 : 1.08
      });
    }
    this.md = m;
  }

  @Builder
  materialRow() {
    Row()
      .width('100%')
      .height(this.planeHeight)
      .borderRadius(this.radius)
      .attributeModifier(this.md)
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no-hide-descendants')
  }

  /**
   * 描边层：只有一圈 border，没有底（背景全透，材质从它下面透出来）。
   *
   * 单独一层而不是直接给材质那层加 border，是因为材质层必须 `clip(radius > 0)`（不裁圆角，
   * 方角的材质会从胶囊两端露出来），而 border 画在同一个被裁的节点上时，描边外侧那一圈
   * 正好压在裁切路径上被削掉 —— 0.7 的发丝线被削掉一半就基本等于没画。
   * 这一层不参与裁切，也不吃点击（hitTest 交给上层的文字/按钮）。
   */
  @Builder
  edgeRing() {
    Row()
      .width('100%')
      .height(this.planeHeight)
      .borderRadius(this.radius)
      .border({ width: MATERIAL_EDGE_WIDTH, color: Theme.edge() })
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no-hide-descendants')
  }

  build() {
    ForEach([this.rev], (r: number) => {
      // 外层 Stack 只做一件事：给描边找一个不被裁切的落点（见 edgeRing 的说明）。
      // 宽高与材质层完全一致，不引入任何新的尺寸来源 —— 父级宽度的解析方式与之前
      // 「Navigation 直接 width('100%')」时完全相同，只是中间多套了一层同尺寸容器。
      Stack() {
        Navigation() {
        }
        .width('100%')
        .height(this.planeHeight)
        .backgroundColor(Color.Transparent)
        .borderRadius(this.radius)
        .clip(this.radius > 0)
        .mode(NavigationMode.Stack)
        .hideBackButton(true)
        .hideToolBar(true)
        .title({ builder: this.materialRow, height: this.planeHeight }, {
          barStyle: BarStyle.STACK,
          backgroundColor: Color.Transparent,
          backgroundBlurStyle: BlurStyle.NONE,
          systemMaterial: Material.empty()
        })
        if (this.dark) {
          // 深色染色压在系统材质上：55% 的深色，浅色主题下的白玻璃也能压成阅读器那种黑玻璃
          // （35% 时实机偏灰，像蒙了一层雾）
          Row()
            .width('100%')
            .height(this.planeHeight)
            .borderRadius(this.radius)
            .backgroundColor('#8C14171C')
            .hitTestBehavior(HitTestMode.None)
            .accessibilityLevel('no-hide-descendants')
        }
        if (this.edge) {
          this.edgeRing()
        }
      }
      .width('100%')
      .height(this.planeHeight)
    }, (r: number) => 'plane-' + r.toString())
  }
}
