import { MaterialSurface } from './MaterialSurface';
import { MaterialPlane } from './MaterialPlane';
import { Theme } from '../core/Theme';
import { Tokens } from '../core/Tokens';

/**
 * 返回键与屏幕左边的距离。
 *
 * 为什么是 12 而不是 4：44 的圆形按钮贴着左边只有一个 4 的缝，圆看起来像被屏幕边缘切掉了一块，
 * 而且标题起点会落在 4+44+8=56 —— 与 16 的卡片左边距对不上，视觉上标题比内容更靠左。
 * 12 之后标题起点是 12+44+8=64，详情页 / 评论页 / 阅读器三处圆形返回都取同一个值，
 * 在这几个页面之间来回跳时返回键不会左右抖动。
 */
const BACK_INSET: number = 12;

/**
 * 页头材质下沿与页面第一块内容之间额外让出的空隙（不含 56 栏本身的留白）。
 *
 * 为什么加在「材质底部」而不是「返回键那一行」里：二级页的内容几乎都是紧接页头下沿开始的
 * （ToolsPage 的 Scroll、TagSetsPage 的卡片、FavoritesPage 独立态的分段器都是 Column 里
 * PageHeader 的下一个兄弟，中间没有 gap）。所以「返回键下沿 → 内容」这段距离完全由页头
 * 高度决定：返回键在 56 的行内已经上下各留 6，行内再挤只会把键顶高、标题跟着跑，材质下沿
 * 却还是贴着内容。把 6 计入页头高度后，键到内容从 6 变成 12，是与评论页 contentStartOffset
 * （headerHeight + 12）同一档的呼吸量。
 *
 * 为什么是 6 而不是 8：56 的栏 + 6 = 62（不含状态栏），仍在 60~64 的页头带内；取 8 会让
 * 页头顶到 64，与详情页 / 阅读器那两处自绘的 56 栏在同一屏里差出一档。6 又是 12 的一半，
 * 与列表首卡 12 的间距形成 1:2 的层级，不会读成「两条一样宽的空带」。
 *
 * **导出**给各页算「内容第一个可用 y」：材质比 headerHeight() 多铺这一条，
 * 页面侧若只按 headerHeight 让位，首卡会贴到玻璃下沿。导出而不是让每页各写一份 6 ——
 * 两份数的后果是改一处另一处不动，表现为「评论页比工具页多贴 6」，很难查。
 */
export const HEADER_BOTTOM_GAP: number = 6;

/**
 * 统一的页头：左返回 + 标题/副标题 + 右侧动作，背景是沉浸材质。
 *
 * 为什么抽出来：原版（Flutter）用的是同一个 AppBar 在每个页面复用；移植版之前每页各写一段
 * Row，导致内边距、字号、返回键尺寸都对不齐。现在所有二级页共用这一个组件，
 * 页头高度、状态栏避让、材质回退只有一处定义。
 *
 * 数值来源：docs/V2-UI-SPEC.md §3.6 TITLE_BAR_HEIGHT(56) / §3.3 FONT_TITLE(16)、FONT_TAG(11)。
 *
 * 用法：
 *   PageHeader({ title: '评论', subtitle: '12 条', prominent: true, onBack: () => this.pop() })
 *   PageHeader({ title: '详情', onBack: () => this.pop() }) { 右侧动作 }
 *
 * 返回键统一是「圆形玻璃包箭头」：44 圆 + 真材质平面 + 24 号箭头居中，点击区 44×44。
 */
@Component
export struct PageHeader {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop showBack: boolean = true;
  /** 标题行高度（不含状态栏）。默认 56，与 SPEC 的 TITLE_BAR_HEIGHT 一致 */
  @Prop barHeight: number = Tokens.TITLE_BAR_HEIGHT;
  /**
   * 大标题模式：标题走 22 中黑（首页/详情页那套层级），副标题 11。
   * 默认关，收藏/下载等沿用 16 号标题，避免一次改全站。
   */
  @Prop prominent: boolean = false;
  onBack: () => void = (): void => {};

  /** 右侧动作槽：不传就是空的 */
  @Builder
  emptyActions() {
  }

  @BuilderParam actions: () => void = this.emptyActions;

  private statusBar(): number {
    const v: number | undefined = AppStorage.get<number>('statusBarHeight');
    return v === undefined ? 0 : v;
  }

  /**
   * 页头占用的总高度（含状态栏与底部让位）。
   *
   * 材质面、行高、发丝线位置都必须走这一个算式：高度分三处各写一遍，
   * 加了 HEADER_BOTTOM_GAP 之后只要漏一处，就会出现「材质比行高矮一条」或
   * 「发丝线画在内容中间」。
   */
  private surfaceHeight(): number {
    return this.statusBar() + this.barHeight + HEADER_BOTTOM_GAP;
  }

  build() {
    MaterialSurface({ surfaceHeight: this.surfaceHeight(), kind: 'header' }) {
      Row({ space: Tokens.SPACE_SM }) {
        if (this.showBack) {
          // 圆形玻璃返回键：底层是 MaterialPlane 的真材质圆（与首页顶栏同一套 header 配方），
          // 上层放 24 号箭头（fontColor 必须传数组）。材质不可用时 MaterialPlane 自己回退成
          // 「半透明底 + 厚模糊」，再加 0.6vp 描边，保证任何情况下都读得出这是个圆。
          Stack({ alignContent: Alignment.Center }) {
            // 必须给确定高度（planeHeight），Navigation title 作用域按它创建
            MaterialPlane({ kind: 'header', radius: 999, planeHeight: Tokens.TOUCH_MIN })
            // 圆环描边：只做视觉边界，不吃点击
            Row()
              .width(Tokens.TOUCH_MIN)
              .height(Tokens.TOUCH_MIN)
              .borderRadius(999)
              // 为什么统一走 Theme.btnEdge()：返回键、详情页工具条、评论输入框都压在同一层沉浸材质上，
              // 白 20% 的细边读作「玻璃边缘被灯打亮」；以前这里按深浅色各写一份字面量，和另外两处就对不齐。
              // 宽度保持 0.6（这个 44 的圆比工具条小一档，0.7 在圆上会显粗）。
              .border({ width: 0.6, color: Theme.btnEdge() })
              .hitTestBehavior(HitTestMode.None)
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(Tokens.FONT_H1)
              .fontColor([Theme.text()])
          }
          .width(Tokens.TOUCH_MIN)
          .height(Tokens.TOUCH_MIN)
          // 阴影挂在 Stack 这一层（返回键的最外层，不被 clip）：材质层 MaterialPlane 内部自己按 radius
          // 裁材质，这里若给 Stack 加 clip(true) 会把 0.6 描边削掉半条，所以只用 borderRadius 定阴影轮廓。
          // 数值统一走 Theme.floatShadow()，与详情页工具条、评论输入框是同一档接触阴影。
          .borderRadius(999)
          .shadow(Theme.floatShadow())
          .onClick(() => this.onBack())
        }

        Column({ space: this.prominent ? 1 : Tokens.SPACE_XS }) {
          Text(this.title)
            .fontSize(this.prominent ? Tokens.FONT_H2 : Tokens.FONT_TITLE)
            .fontWeight(FontWeight.Medium)
            .lineHeight(this.prominent ? 28 : Tokens.LINE_TITLE)
            .fontColor(Theme.text())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(Tokens.FONT_TAG)
              .fontColor(Theme.subText())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 动作槽固定 32 高：56 的栏里若放 46 高的按钮会顶满上下留白，
        // 32 才能和 16 号标题的视觉重心对齐。页面传进来的按钮请自行保持 32 高。
        Row({ space: Tokens.SPACE_XS }) {
          this.actions()
        }
        .height(Tokens.HEADER_ACTION_HEIGHT)
      }
      .width('100%')
      // 高度含状态栏与底部让位：上面那段 padding 让出状态栏，下面 6 让给「返回键 → 内容」的空隙，
      // 中间剩下的正好是 barHeight 的内容区，返回键在这 56 里仍然上下各 6，视觉重心不动。
      .height(this.surfaceHeight())
      .alignItems(VerticalAlign.Center)
      .padding({
        // 12（BACK_INSET）+ 44（返回盒子）+ 8（Row 间距）= 64，标题从这个位置起排；
        // 该值与详情页、评论页的返回位置保持一致（评论页复用的就是这个组件）。
        left: this.showBack ? BACK_INSET : Tokens.SPACE_LG,
        right: Tokens.SPACE_LG,
        top: this.statusBar(),
        bottom: HEADER_BOTTOM_GAP
      })
    }
  }
}
