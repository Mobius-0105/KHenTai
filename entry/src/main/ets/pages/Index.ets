import { common } from '@kit.AbilityKit';
import { CommonModifier } from '@kit.ArkUI';
import { Db } from '../core/Db';
import { Downloader } from '../core/Downloader';
import { MaterialModifier } from '../core/Material';
import { Motion } from '../core/Motion';
import { DetailBackGate } from '../core/BackGate';
import { Gallery, GalleryDetail } from '../core/Models';
import { Prefs } from '../core/Prefs';
import { Theme } from '../core/Theme';
import { CommentsPage } from './CommentsPage';
import { DetailPage } from './DetailPage';
import { HomePage } from './HomePage';
import { LibraryPage } from './LibraryPage';
import { ReaderPage } from './ReaderPage';
import { SearchPage } from './SearchPage';
import { SettingsPage } from './SettingsPage';
import { TagSetsPage } from './TagSetsPage';
import { ToolsPage } from './ToolsPage';

/** 页面栈层级编号（0 恒为 tab 容器，不出栈） */
const L_TABS: number = 0;
const L_DETAIL: number = 1;
const L_READER: number = 2;
const L_COMMENTS: number = 3;
const L_TOOLS: number = 4;
const L_TAGS: number = 5;

/**
 * 转场几何参数（时长与曲线统一在 core/Motion.ets，这里只留纯几何量）。
 *
 * 为什么几何留在这、时长搬走：这些值描述的是「页面栈长什么样」（左移多少、缩多少、
 * 压多暗），改栈的层级语义时必须和栈逻辑放在一起看；时长/曲线则是跨页面的公共约定。
 */
const UNDER_OFFSET: number = 0.22;
/**
 * 下层缩放系数：**1 = 不缩放**。
 *
 * 原来是 0.98（下层最多缩到 0.98、再下一层 0.96），进二级页时整个下页会轻微内缩 ——
 * 那是 iOS 卡片栈的观感，但配这套「左移 + 压暗」会显得页面在抖（缩 2% 改变的只是
 * 内容边界，位移却由 UNDER_OFFSET 给，两者不同步）。现在只留左移与压暗：
 * 层级感来自「上页推入 + 下页退后并变暗」，不再靠尺寸差。
 * 保留这个常量与 scaleOf() 而不是删调用：将来要恢复缩放只需把 1 改成 0.98。
 */
const UNDER_SCALE: number = 1;
/** 每往下压一层叠 10% 黑；两层到上限 20%，再多内容就看不清了 */
const UNDER_DIM: number = 0.10;

/**
 * 悬浮底栏几何（照参考工程 Han1meViewer `pages/Index.ets:60-75` 的三档宽度）。
 *
 * 为什么宽度是三个固定数而不是 86%：`barFloatingStyle.barWidth` 只收 vp 数值，
 * 系统在布局阶段按设备断点自己从 small / medium / large 里挑一档。
 * 取值是参考工程竖屏那一套（264 / 280 / 296，四等分每格 66~74vp，10 号字放得下），
 * 与原先自绘的「86% 且上限 300」在同一屏宽下只差几个 vp。
 */
const BAR_W_SMALL: number = 264;
const BAR_W_MEDIUM: number = 280;
const BAR_W_LARGE: number = 296;
/** 胶囊高度（vp）：22 图标 + 3 间距 + 10 文字，上下各留 8~9 的呼吸 */
const BAR_HEIGHT: number = 56;
/** 胶囊圆角：高度的一半，两端是正半圆 */
const BAR_RADIUS: number = 30;
/** 胶囊底边到系统导航条的距离（vp） */
const BAR_BOTTOM_GAP: number = 4;

/**
 * 系统 TabBar 的通用属性修饰器：先定形，再挂材质。
 *
 * 这一步是参考工程 `setupMaterialBar()`（`pages/Index.ets:423-434`）的做法：
 * `Tabs.barModifier` 作用在**系统 TabBar 本体**上，而底栏属于系统栏作用域，
 * `systemMaterial` 只有挂在这里才真正参与合成（挂普通 Row 上会被降级成纯染色）。
 *
 * 圆角 / 不裁剪 / 透明底必须在 super 之前设置：父类在材质可用时只写 systemMaterial
 * （保留我们给的形状），不可用时才写回退底色并把系统材质清空。
 * 所以「材质有没有」由 MaterialModifier 一处判断，这里只管形状，不重复那套降级逻辑。
 */
class BarMaterialModifier extends MaterialModifier {
  applyNormalAttribute(instance: CommonAttribute): void {
    instance.borderRadius(BAR_RADIUS).clip(false).backgroundColor(Color.Transparent);
    super.applyNormalAttribute(instance);
  }
}

/**
 * ## 状态管理 V2 迁移说明（本文件已迁到 V2，子组件仍是 V1）
 *
 * **为什么只改这一个文件**：Index 是 `@Entry` 根组件，它是页面栈的唯一 owner，也是唯一
 * 需要"自己改自己状态"的组件；DetailPage / ReaderPage / HomePage 等子组件这次不动，
 * 所以 V1/V2 混用边界正好落在本文件的 `build()` 里。
 *
 * **装饰器映射（本文件的实际结果）**：
 *  - `@State` → `@Local`：语义一一对应（组件内部可变状态），且 `@Local` 支持 `private` 修饰。
 *  - `@Prop` → `@Param @Require` / `@Param`：本文件是根组件、没有外部输入，所以**一个都没有**。
 *    若将来 Index 被别的页面复用，无默认值的输入写 `@Require @Param`，有默认值的写 `@Param`。
 *  - 回调成员 → `@Event`：同上，根组件没有回调成员，所以也没有 `@Event`。
 *    下面 `DetailPage({ onBack: ... })` 里的回调是 **V1 子组件的普通成员**，不是 `@Event`，
 *    所以调用点保持原样 —— 这是本次迁移"行为完全不变"的关键。
 *
 * **V1 子组件从 V2 父组件收值为什么安全**：本工程的子组件把入参声明为**普通成员**
 * （见 `DetailPage.ets:30-36` 的 `gallery: Gallery` / `onBack: () => void`，没有 `@Prop`）。
 * 普通成员只在构造时初始化一次，V1 父组件和 V2 父组件在这件事上行为完全相同。
 * 反过来说，如果将来把子组件改成 `@ComponentV2`，`@Param` 才是只读的，
 * 那时它内部就不能再直接改入参对象的属性 —— 现在没有这个风险。
 *
 * **`@StorageProp` / `@StorageLink` 在 V2 里不可用**（它们是 V1 装饰器，出现在
 * `@ComponentV2` 里会直接编译失败）。本文件原本就没用它们，情况是：
 *  - `AppStorage.get<number>('navBarHeight')`（`navBar()` 方法）：这是**普通静态 API**，
 *    不是装饰器，V2 里照常可调用。它本来就**不具响应性**（V1 下也不是 `@StorageProp`，
 *    所以窗口内导航栏高度变化时这个值不会主动刷新）—— 迁移前后行为一致，不需要补 `@Monitor`。
 *  - `Theme.bg()` / `Theme.text()` 等：`core/Theme.ets` 是静态方法 + `Prefs` + `AppStorage.get`，
 *    同样非响应式，V2 的 `build()` 里当普通函数调用即可，行为不变。
 *  - 若以后真需要"AppStorage 变了就重绘"，V2 的正确写法是
 *    `@Local` 承接一份快照 + `AppStorageV2.connect()` holder，或显式调 `@Monitor` 监听；
 *    不要试图把 `@StorageProp` 加回来。
 *
 * **本文件内禁止再出现**：`@State` / `@Prop` / `@Link` / `@Provide` / `@Consume` /
 * `@Watch` / `@StorageProp` / `@StorageLink` / `@Observed` / `@ObjectLink`。
 * 混用不会"部分生效"，是编译期报错。
 *
 * ---
 *
 * 应用外壳。
 *
 * 两块「沉浸材质 + 动效」是从 Han1meViewer-HarmonyOS 学来的：
 *
 * 1. **悬浮沉浸材质底栏**：Tabs 的 `barModifier` 挂 `systemMaterial`，再用 `barFloatingStyle`
 *    收成悬浮胶囊。底栏属于系统栏作用域，材质真正参与合成（普通组件上的 systemMaterial
 *    可能被降级成纯染色）。材质不可用时 barModifier 自己回退成「实底 + 厚模糊」。
 *
 * 2. **推拉式页面转场**：push 时新页从右侧屏外滑入（350ms / cubicBezier(0.2,0,0,1)），
 *    被压住的页面同步左移 22%、缩到 0.98 并轻微压暗，形成纵深；pop 反向
 *    （350ms / cubicBezier(0.3,0,0.2,1)）。**刻意不做整页透明度淡变** ——
 *    两页叠加时任何 alpha < 1 都会让下层页面透出来，观感就是「背景透明、上一页残留」。
 *    所以「变暗」是另叠一层自绘黑纱（只动黑纱自己的 alpha），不是压整个页面的 alpha。
 *
 * 页面栈用显式四层 if 而不是 ForEach：谁什么时候挂载、谁在上、谁吃点击都一眼看清，
 * 也不会出现列表 key 变化导致页面重建的坑。
 */
@Entry
@ComponentV2
struct Index {
  @Local private ready: boolean = false;
  @Local private ageOk: boolean = false;
  /** 门禁页按钮是否处于按下态：-1 未按、1 = 18+ 页按钮、2 = 解锁按钮（用于 0.97 回弹） */
  @Local private pressGate: number = -1;

  @Local private tab: number = 0;
  /** 页面栈：0 是 tab 容器，push 进来的层按顺序追加 */
  @Local private stack: number[] = [L_TABS];
  /** 正在进/出的层级；-1 表示没有 */
  @Local private animId: number = -1;
  /** 1 = 完全就位，0 = 完全在右侧屏外 */
  @Local private animProgress: number = 1;
  /**
   * 系统 TabBar 的当前高度（vp）：BAR_HEIGHT = 显示，0 = 整条收掉。
   *
   * 为什么是 @Local 而不是 @State：本文件已迁到 @ComponentV2，V1 的 @State 在这里是
   * 编译期错误，@Local 是它在 V2 里的一一对应（见文件头「状态管理 V2 迁移说明」）。
   *
   * 为什么底栏用「动高度」而不是「挪位置 / 改透明度」：系统栏属于系统作用域，宽高由
   * Tabs 的 barHeight 决定，改这个值系统才会真正重排悬浮胶囊；opacity / translate 作用
   * 不到系统栏本体上，栏会原地不动。0 高度在系统语义里等于「没有这一条」。
   */
  @Local private barH: number = BAR_HEIGHT;
  @Local private winW: number = 0;
  /** 宽屏（≥840vp）时 tab 栏挪到左侧竖排 */
  @Local private wide: boolean = false;

  @Local private current: Gallery = new Gallery();
  @Local private readerDetail: GalleryDetail = new GalleryDetail();
  @Local private readerLocal: string[] = [];
  /** 阅读器起始页（0 基）：详情页点缩略图时由页面传入 */
  @Local private readerStart: number = 0;
  @Local private activeDetail: GalleryDetail = new GalleryDetail();
  /**
   * 详情页点标签后要灌进搜索页的关键词。
   *
   * 只作为「SearchPage 首次创建时」的初值（TabContent 懒创建，那一刻初值就是对的）；
   * 页面已存在时的再次注入靠下面 injectSeq 写 AppStorage 触发（V1 子组件 + V2 父组件的
   * @Prop 同步不可靠，AppStorage 是本工程既有的跨版本通道）。
   */
  @Local private searchKeyword: string = '';
  /** 注入序号：普通成员，没有任何 UI 直接读它，只用来写 AppStorage 敲门 */
  private injectSeq: number = 0;

  /**
   * 系统 TabBar 的修饰器：圆角 30 / 不裁剪 / 透明底 + 沉浸材质；
   * 材质不可用时 MaterialModifier 自己退成「实底 + 厚模糊」，底栏不会变成透明条。
   */
  private barModifier: CommonModifier = new BarMaterialModifier('tabbar', true);
  /**
   * 只用于「代码里主动切页」（详情页点标签、媒体库跳设置）。
   * 用户点底栏不经过它：系统 TabBar 自己改 index，再从 onChange 同步回 this.tab。
   */
  private tabsCtrl: TabsController = new TabsController();

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    Prefs.init(ctx).then(() => {
      // 历史 / 本地收藏改存关系型库：开库 + 建表 + 迁移旧 JSON 在这里一次性做完
      return Db.init(ctx);
    }).then(() => {
      // 主题状态要在任何页面 build 之前写进 AppStorage，否则首帧取不到
      Theme.refresh();
      Theme.bindWindow(ctx);
      this.ageOk = Prefs.bool('age_ok', false);
      this.ready = true;
    }).catch(() => {
      this.ready = true;
    });
  }

  onBackPress(): boolean {
    // 详情层在最上面时，先问它有没有浮层要关（收藏面板 / 标签面板）。
    //
    // 为什么不是让 DetailPage 自己实现 onBackPress：那个回调**只对 @Entry 页面生效**，
    // 本工程的详情页是这里 stack 里的一层普通 @Component，系统根本不会回调它。
    // 返回键只会进到本方法，所以「浮层优先」必须在这里判，具体交给 DetailBackGate
    // （详情页挂载时把处理器登记进去，见 core/BackGate.ets）。
    if (this.stack[this.stack.length - 1] === L_DETAIL && DetailBackGate.consume()) {
      return true;
    }
    if (this.stack.length > 1) {
      this.pop();
      return true;
    }
    return false;
  }

  // ------------------------------------------------------------------ 页面栈
  private depthOf(layer: number): number {
    const index: number = this.stack.indexOf(layer);
    if (index < 0) {
      return 0;
    }
    return this.stack.length - 1 - index;
  }

  private isTop(layer: number): boolean {
    return this.depthOf(layer) === 0;
  }

  /**
   * 「让位」进度：0 = 完全就位，1 = 让出一层，2 = 让出两层（上限）。
   *
   * 为什么不直接按 depth 算位移：depth 在 `push()` 那一瞬间就变了，而那一刻的属性变化
   * 不在任何 animateTo 里 —— 纯按 depth 算，下层页会在 push 的第一帧直接跳到 -22%，
   * pop 结束、栈真正缩短时再瞬间跳回 0，两头都是硬闪。
   * 现在 depth 只决定「要让出几层」，animProgress 决定「让到了几成」，下层页就跟着
   * 上层页在同一个动画里连续走完，push/pop 两端都不闪。
   */
  private underFactor(layer: number): number {
    const depth: number = this.depthOf(layer);
    if (depth <= 0) {
      return 0;
    }
    // depth = 2 的那层在上一层让位时已经退过一格，所以起点是 1 而不是 0
    const raw: number = Math.min(depth, 2) - 1 + this.animProgress;
    return Math.max(0, Math.min(raw, 2));
  }

  /** 位移：进出中的那层自己从右侧屏外滑到就位（或反向），其余层按让位进度左移 */
  private xOf(layer: number): number {
    if (layer === this.animId) {
      return (1 - this.animProgress) * this.winW;
    }
    return -this.winW * UNDER_OFFSET * this.underFactor(layer);
  }

  /** 缩放：下层缩到 0.98（再下一层 0.96）；进出中的那层保持 1，避免推到一半大小还在变 */
  private scaleOf(layer: number): number {
    if (layer === this.animId) {
      return 1;
    }
    return 1 - (1 - UNDER_SCALE) * this.underFactor(layer);
  }

  /**
   * 压暗量（0 ~ 0.2）：被压住的页整体变暗，「上层浮起来」的层级感主要靠它。
   *
   * 只作用在自绘黑纱上、绝不动整页 alpha：两页叠加时 alpha < 1 会让下层页透出来，
   * 这正是本文件一直避免的坑。压暗量跟着让位进度走，pop 时会随位移一起还原。
   */
  private shadeOf(layer: number): number {
    return UNDER_DIM * this.underFactor(layer);
  }

  private push(layer: number): void {
    if (this.stack.indexOf(layer) >= 0) {
      return;
    }
    this.animId = layer;
    this.animProgress = 0;
    this.stack = this.stack.concat([layer]);
  }

  /** 新层首次布局完成后才开始播进入动画（首帧必须已在屏外，否则会先闪一下完整页面） */
  private onLayerAppear(layer: number): void {
    if (layer !== this.animId || this.animProgress >= 1) {
      return;
    }
    // 进场用 openCurve：起步快、尾巴长，页面滑到位后还要"沉"一下才停住，
    // 这是鸿蒙原生页面推入的手感；换标准曲线会明显"塑料"。
    // 底栏收起塞在同一个 animateTo 里：底栏和页面是「一次推入」的两半，
    // 各自一段动画（哪怕时长写一样）会因起播帧不同而错拍 —— 观感就是页面已经推完、
    // 底栏还在慢慢缩。同一闭包 + 同一时长同一曲线，才能保证两边是同一个进度。
    // 这里不区分「第几层二级页」：已经在二级层里（barH 已是 0）时再赋 0 没有副作用。
    Motion.animate(this.getUIContext(), Motion.DETAIL, Motion.openCurve, () => {
      this.animProgress = 1;
      this.barH = 0;
    });
  }

  private pop(): void {
    const top: number = this.stack[this.stack.length - 1];
    if (top === L_TABS) {
      return;
    }
    this.animId = top;
    // 出场用 closeCurve：比进场曲线略缓起步，避免页面向右"窜"出去
    // 底栏展开同理塞进同一段动画，和页面收回同进度。
    // 只有「退出到 tab 容器」（栈长 2 → 1）才长回 BAR_HEIGHT；中间层弹出
    // （如 阅读器 → 详情，栈长 4→3 / 3→2）必须保持 0，否则底栏会在二级页里闪一下再消失。
    Motion.animate(this.getUIContext(), Motion.DETAIL, Motion.closeCurve, () => {
      this.animProgress = 0;
      this.barH = this.stack.length > 2 ? 0 : BAR_HEIGHT;
    });
    // 动画结束后再真正出栈，避免页面在滑出途中被销毁。
    // +10 是给最后一帧留的余量：定时器和渲染帧不一定同拍，正好等于时长会截断收尾。
    setTimeout(() => {
      this.stack = this.stack.slice(0, this.stack.length - 1);
      this.animId = -1;
      this.animProgress = 1;
      if (top === L_READER) {
        this.readerLocal = [];
        this.readerStart = 0;
      }
    }, Motion.DETAIL + 10);
  }

  // ------------------------------------------------------------------ 详情页 → 搜索页
  /**
   * 详情页点标签：切到搜索 tab 并用该标签（精确搜索词）重查。
   *
   * 三步都要做：① 记下关键词（SearchPage 尚未创建时它直接成为 @Prop 初值）；
   * ② 序号 +1 写 AppStorage（SearchPage 已存在时靠它的 @Watch 触发）；
   * ③ 切 tab 并出栈详情页 —— 用户在详情层，不 pop 掉的话切 tab 是看不见的。
   *
   * 顺序上先切 tab 再 pop：pop 有 350ms 出场动画，期间下层已经是搜索 tab，
   * 滑完之后直接看到结果，不会先闪一下别的 tab。
   */
  private gotoSearchByTag(q: string): void {
    const k: string = q.trim();
    if (k.length === 0) {
      return;
    }
    this.searchKeyword = k;
    this.injectSeq = this.injectSeq + 1;
    AppStorage.setOrCreate<string>('searchInjectKeyword', k);
    AppStorage.setOrCreate<number>('searchInjectSeq', this.injectSeq);
    this.tab = 1;
    this.tabsCtrl.changeIndex(1);
    if (this.stack.length > 1) {
      if (this.animId >= 0) {
        // 详情页还在进出动画里又被点了标签：pop() 的出栈是延时切片，连点两次会切两次，
        // 把 tabs 那层也切掉（整屏空白）。动画中就硬收栈到 tabs，宁可少一段出场动画。
        this.stack = [L_TABS];
        this.animId = -1;
        this.animProgress = 1;
        // 栈是硬收的，底栏也必须硬还原：这条路径不走 pop() 里那段 animateTo，
        // 不在这里补一句 barH 会永远停在 0（回到主 Tab 后底栏彻底消失，只能重启恢复）。
        this.barH = BAR_HEIGHT;
      } else {
        this.pop();
      }
    }
  }

  // ------------------------------------------------------------------ 详情页 → 账号
  /**
   * 详情页收藏面板里的「去登录」：切到设置 tab 并把详情页出栈。
   *
   * 顺序与 gotoSearchByTag 相同（先切 tab 再 pop），理由也相同：详情页是压在
   * tab 容器之上的一层，不 pop 掉的话切 tab 用户看不见。设置页里「账号」那张卡
   * 就是现成的登录入口（账号密码 / Cookie 两种），不需要新开登录页。
   */
  private gotoAccount(): void {
    this.tab = 3;
    this.tabsCtrl.changeIndex(3);
    if (this.stack.length > 1) {
      if (this.animId >= 0) {
        this.stack = [L_TABS];
        this.animId = -1;
        this.animProgress = 1;
        this.barH = BAR_HEIGHT;
      } else {
        this.pop();
      }
    }
  }

  // ------------------------------------------------------------------ UI
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.ready) {
        this.splash()
      } else if (!this.ageOk) {
        this.disclaimer()
      } else {
        // ---- 层 0：tab 容器（四 tab + 系统沉浸材质悬浮底栏）
        Stack({ alignContent: Alignment.Bottom }) {
          Column() {
            this.tabShell()
          }
          .width('100%')
          .height('100%')

          // 底栏不再是一个独立浮层：它已经是 tabShell 里 Tabs 的系统 TabBar 本体
          // （barModifier 定形 + barFloatingStyle 悬浮 + barOverlap 让内容从栏后穿过）。
          // 所以这里只剩黑纱，且必须最后画（Stack 里越靠后越在上），否则压不到底栏。
          this.shade(L_TABS)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.bg())
        .translate({ x: this.xOf(L_TABS) })
        .scale({ x: this.scaleOf(L_TABS), y: this.scaleOf(L_TABS) })
        .hitTestBehavior(this.isTop(L_TABS) ? HitTestMode.Default : HitTestMode.None)

        // ---- 层 1：详情
        if (this.stack.indexOf(L_DETAIL) >= 0) {
          Stack({ alignContent: Alignment.TopStart }) {
            DetailPage({
              gallery: this.current,
              onBack: () => {
                this.pop();
              },
              onRead: (d: GalleryDetail, startPage: number) => {
                this.readerDetail = d;
                this.readerLocal = [];
                this.readerStart = startPage;
                this.push(L_READER);
              },
              onComments: (d: GalleryDetail) => {
                this.activeDetail = d;
                this.push(L_COMMENTS);
              },
              onTools: (d: GalleryDetail) => {
                this.activeDetail = d;
                this.push(L_TOOLS);
              },
              onSearchTag: (q: string) => {
                this.gotoSearchByTag(q);
              },
              onGotoLogin: () => {
                this.gotoAccount();
              }
            })
            this.shade(L_DETAIL)
          }
          .width('100%')
          .height('100%')
          .backgroundColor(Theme.bg())
          .translate({ x: this.xOf(L_DETAIL) })
          .scale({ x: this.scaleOf(L_DETAIL), y: this.scaleOf(L_DETAIL) })
          .hitTestBehavior(this.isTop(L_DETAIL) ? HitTestMode.Default : HitTestMode.None)
          .onAppear(() => {
            this.onLayerAppear(L_DETAIL);
          })
        }

        // ---- 层 2：阅读器
        if (this.stack.indexOf(L_READER) >= 0) {
          Stack({ alignContent: Alignment.TopStart }) {
            ReaderPage({
              gallery: this.current,
              detail: this.readerDetail,
              localPages: this.readerLocal,
              startPage: this.readerStart,
              onBack: () => {
                this.pop();
              }
            })
            this.shade(L_READER)
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#0B0D10')
          .translate({ x: this.xOf(L_READER) })
          .scale({ x: this.scaleOf(L_READER), y: this.scaleOf(L_READER) })
          .hitTestBehavior(this.isTop(L_READER) ? HitTestMode.Default : HitTestMode.None)
          .onAppear(() => {
            this.onLayerAppear(L_READER);
          })
        }

        // ---- 层 3：评论
        if (this.stack.indexOf(L_COMMENTS) >= 0) {
          Stack({ alignContent: Alignment.TopStart }) {
            CommentsPage({
              gallery: this.current,
              detail: this.activeDetail,
              onBack: () => {
                this.pop();
              }
            })
            this.shade(L_COMMENTS)
          }
          .width('100%')
          .height('100%')
          .backgroundColor(Theme.bg())
          .translate({ x: this.xOf(L_COMMENTS) })
          .scale({ x: this.scaleOf(L_COMMENTS), y: this.scaleOf(L_COMMENTS) })
          .hitTestBehavior(this.isTop(L_COMMENTS) ? HitTestMode.Default : HitTestMode.None)
          .onAppear(() => {
            this.onLayerAppear(L_COMMENTS);
          })
        }

        // ---- 层 4：归档 / 种子
        if (this.stack.indexOf(L_TOOLS) >= 0) {
          Stack({ alignContent: Alignment.TopStart }) {
            ToolsPage({
              detail: this.activeDetail,
              onBack: () => {
                this.pop();
              },
              // 「相似画廊」要真的跳到搜索页并带上关键词：工具页自己写 AppStorage 只是
              // 第二通道（SearchPage 从未创建时那条会排队但不生效），这里给真回调。
              onSearch: (q: string) => {
                this.gotoSearchByTag(q);
              }
            })
            this.shade(L_TOOLS)
          }
          .width('100%')
          .height('100%')
          .backgroundColor(Theme.bg())
          .translate({ x: this.xOf(L_TOOLS) })
          .scale({ x: this.scaleOf(L_TOOLS), y: this.scaleOf(L_TOOLS) })
          .hitTestBehavior(this.isTop(L_TOOLS) ? HitTestMode.Default : HitTestMode.None)
          .onAppear(() => {
            this.onLayerAppear(L_TOOLS);
          })
        }

        // ---- 层 5：标签集 / 观看标签
        if (this.stack.indexOf(L_TAGS) >= 0) {
          Stack({ alignContent: Alignment.TopStart }) {
            TagSetsPage({
              onBack: () => {
                this.pop();
              }
            })
            this.shade(L_TAGS)
          }
          .width('100%')
          .height('100%')
          .backgroundColor(Theme.bg())
          .translate({ x: this.xOf(L_TAGS) })
          .scale({ x: this.scaleOf(L_TAGS), y: this.scaleOf(L_TAGS) })
          .hitTestBehavior(this.isTop(L_TAGS) ? HitTestMode.Default : HitTestMode.None)
          .onAppear(() => {
            this.onLayerAppear(L_TAGS);
          })
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const w: number = Number(newArea.width);
      if (w > 0) {
        this.winW = w;
        this.wide = w >= 840;
      }
    })
  }

  /**
   * 四 tab 外壳：内容 + 系统沉浸材质悬浮底栏。
   *
   * 底栏不是自绘的：它就是下面这个 Tabs 的**系统 TabBar 本体**，靠三个系统能力变成悬浮胶囊 ——
   *  1. `barModifier`（见 BarMaterialModifier）：圆角 30 / 透明底 / 不裁剪 + systemMaterial；
   *  2. `.barHeight(barH)`：栏的真实高度（56 显示 / 0 收起）；
   *  3. `.barFloatingStyle(...)`：三档宽度 + 底边距 navBarHeight + 4，收成悬浮胶囊；
   *  4. `.barOverlap(true)`：内容延伸到栏后，列表能滚到胶囊下面，材质才有东西可模糊。
   * 选中态与切换也交给系统：点哪一项由 TabBar 自己改 index，onChange 同步回 this.tab；
   * 每一项的外观（图标 / 文案 / 选中色）仍由 tabItem() 负责，和自绘时一模一样。
   */
  @Builder
  private tabShell() {
    Tabs({
      barPosition: BarPosition.End,
      index: this.tab,
      controller: this.tabsCtrl,
      barModifier: this.barModifier
    }) {
      TabContent() {
        HomePage({
          onOpen: (g: Gallery) => {
            this.current = g;
            this.push(L_DETAIL);
          }
        })
      }
      .tabBar(this.tabItem(0, '首页'))

      TabContent() {
        SearchPage({
          // 详情页点标签 → gotoSearchByTag() 写入，search tab 首次创建时按它直接搜
          initialKeyword: this.searchKeyword,
          onOpen: (g: Gallery) => {
            this.current = g;
            this.push(L_DETAIL);
          }
        })
      }
      .tabBar(this.tabItem(1, '搜索'))

      TabContent() {
        LibraryPage({
          onOpen: (g: Gallery) => {
            this.current = g;
            this.push(L_DETAIL);
          },
          onOpenLocal: (g: Gallery) => {
            this.current = g;
            this.readerLocal = Downloader.localPages(g.gid, g.token);
            this.readerDetail = new GalleryDetail();
            this.push(L_READER);
          },
          onGotoSettings: () => {
            this.tab = 3;
            this.tabsCtrl.changeIndex(3);
          },
          // 存档页空态里的「去首页看看」：切回首页 tab。
          // 必须由 Index 提供 —— 媒体库自己改不了外层 Tabs 的 index。
          onGotoHome: () => {
            this.tab = 0;
            this.tabsCtrl.changeIndex(0);
          }
        })
      }
      .tabBar(this.tabItem(2, '媒体库'))

      TabContent() {
        SettingsPage({
          onOpenTagSets: () => {
            this.push(L_TAGS);
          }
        })
      }
      .tabBar(this.tabItem(3, '设置'))
    }
    // 底栏不做滑动切换：手势留给页面内的段/模式切换，避免两层横向手势打架。
    // （原先底栏那套左右拖切 tab 的 PanGesture 随自绘胶囊一起去掉了 —— 系统 TabBar
    //  不接受挂在栏体上的自定义手势，而要求里保留的交互只有「点按切页」。）
    .scrollable(false)
    // 0 = 瞬时切换，页面内容不做滑动过渡。
    // animationDuration > 0 时 Tabs 走「横向滑动 + 旧页销毁 → 新页新建」，
    // 而 V1 子组件重建的第一帧是白底再填内容，观感就是切 tab 闪一下。
    // 选中图标 / 文字颜色的 220ms 属性动画不在这里，仍然保留 —— 切页是「瞬间到位 + 柔和高亮」。
    .animationDuration(0)
    // 栏的真实高度：56 是「图标 24 + 3 间距 + 文字 10」上下各留 8~9 的高度。
    // 置 0 会整条隐藏 —— 现在正是靠这一点做二级页的退场（不再被上层页面硬盖住）。
    // 高度由 @Local barH 承载，变化**只在页面栈那两处 animateTo 里**发生，
    // 所以收起 / 展开与推入 / 弹出是同一段动画（见 onLayerAppear / pop）。
    .barHeight(this.barH)
    // 内容延伸到栏后：栏浮起来之后，列表最后一屏仍能从胶囊下面穿过去
    .barOverlap(true)
    // 悬浮样式：宽度三档 / 侧边距 0 / 底边距 navBarHeight + 4 + 收掉系统蒙层
    .barFloatingStyle(this.floatBarStyle())
    // 整条 Tabs 透明（参考工程同款）：TabBar 区域不能压一层系统默认底色，
    // 否则材质背后是一块纯色板，玻璃透不出内容。栏本体自己的底色由 barModifier 设成全透明。
    .backgroundColor(Color.Transparent)
    .onChange((index: number) => {
      // 用户点栏、或代码 changeIndex 之后都会走到这里：单一入口同步 this.tab
      this.tab = index;
    })
    .width('100%')
    .height('100%')
  }

  /**
   * 系统悬浮栏的样式（参考工程 `pages/Index.ets:771-782` 的 barFloatingStyle 原样搬过来）：
   *  - `barWidth`：三档固定宽度，由系统按设备断点自己选小 / 中 / 大，
   *    不接受百分比（传 '86%' 解析成 0，栏会消失）；
   *  - `barSideMargin: 0`：宽度已经算好了，左右不再额外留边，胶囊由系统居中；
   *  - `barBottomMargin`：navBarHeight + 4，抬到系统导航条上方 4vp（与自绘时的位置一致）；
   *  - `maskColor: Color.Transparent` + `maskHeight: 0`：系统悬浮样式会在栏底铺一层浅色蒙层，
   *    这两个参数只是尽量收掉它。
   *
   * 材质不在这里传 `systemMaterial`：本工程走的是参考工程的 barModifier 路线（栏本体挂材质），
   * 两条路同时开会撞车。barModifier 还额外带「材质不可用 → 实底 + 厚模糊」的降级，
   * 所以低算力 / 旧系统上栏也不会变成一条透明条。
   */
  private floatBarStyle(): FloatingTabBarStyle {
    const style: FloatingTabBarStyle = {
      barWidth: {
        smallBarWidth: BAR_W_SMALL,
        mediumBarWidth: BAR_W_MEDIUM,
        largeBarWidth: BAR_W_LARGE
      },
      barSideMargin: 0,
      // barHeight 收到 0 时这里**故意不跟着归零**：悬浮栏不占布局高度（barOverlap(true) 下
      // 内容本来就整屏铺到栏后），barBottomMargin 只决定「那条栏离底边多远」，
      // 栏高 0 时它无处可画，不会在内容底部留出空白条。
      // 反过来做条件归零会在动画最后一帧改一次 layout，得不偿失。
      barBottomMargin: this.navBar() + BAR_BOTTOM_GAP,
      maskColor: Color.Transparent,
      maskHeight: 0
    };
    return style;
  }

  private navBar(): number {
    const v: number | undefined = AppStorage.get<number>('navBarHeight');
    return v === undefined ? 0 : v;
  }

  /**
   * 底栏图标：按「未选中 / 选中」两套符号名做映射，调用点不再散落条件判断。
   *
   * 选中态换成填充变体（_fill），比只染色更容易一眼看出当前页；
   * 唯一例外是搜索：`magnifyingglass` 没有 fill 变体，选中/未选中都用线性符号，
   * 靠颜色 + 微放大区分。这里的 `$r` 必须写字面量，不能用变量拼资源名。
   */
  private tabIcon(index: number, on: boolean): Resource {
    switch (index) {
      case 0:
        return on ? $r('sys.symbol.house_fill') : $r('sys.symbol.house');
      case 1:
        // 搜索没有 _fill 变体，两态共用一个符号
        return $r('sys.symbol.magnifyingglass');
      case 2:
        return on ? $r('sys.symbol.square_fill_grid_2x2') : $r('sys.symbol.square_grid_2x2');
      default:
        return on ? $r('sys.symbol.gearshape_fill') : $r('sys.symbol.gearshape');
    }
  }

  @Builder
  private tabItem(index: number, label: string) {
    // ===== 单项：无底色块，只靠「填充图标 + 强调色 + 轻微放大」表达选中 =====
    // 选中态现在由系统 TabBar 承载（点哪一项由系统改 index），所以这一层**不再挂 onClick**：
    // 自己再调一次 changeIndex 会在系统已经切完之后重复触发一次切换。
    // 之前照抄参考工程的 chipTint 底色（深 #26282D / 浅 #F2FFFFFF），在真机上读起来
    // 像一块贴上去的方块，和胶囊材质不融。保持纯净方案：
    //   选中 → 填充图标 + Theme.accent() + 文字 Medium + scale 1.06
    //   未选中 → 线性图标 + Theme.subText() + 文字 Normal + scale 1.0
    // 尺寸照参考工程的 BarItem：宽高 100% 由系统按栏高（56）分格，内容居中，
    // 不再写死 44 —— 写死会让这一格和系统栏之间留出上下两道空档。
    Column() {
      SymbolGlyph(this.tabIcon(index, this.tab === index))
        // 图标 24vp，与参考工程 Image 尺寸一致
        .fontSize(24)
        .fontColor([this.tab === index ? Theme.accent() : Theme.subText()])
        // 1.06 是"看得出放大、但不夸张"的幅度；1.08 在 24vp 上会显得图标跳一下
        .scale({ x: this.tab === index ? 1.06 : 1.0, y: this.tab === index ? 1.06 : 1.0 })
        .animation({ duration: 220, curve: Curve.Smooth })

      Text(label)
        .fontSize(10)
        .fontColor(this.tab === index ? Theme.accent() : Theme.subText())
        // 字重也承担一部分选中反馈：Medium 比加粗克制，10vp 下不会糊成一团
        .fontWeight(this.tab === index ? FontWeight.Medium : FontWeight.Normal)
        .maxLines(1)
        .margin({ top: 3 })
        .animation({ duration: 220, curve: Curve.EaseOut })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Color.Transparent)
  }

  /**
   * 压暗黑纱：被上层盖住时，在**自身内容之上**叠一层纯黑，只动这层黑的 alpha。
   *
   * 为什么不用 `.brightness()`：它会把整棵子树拎进离屏图层再做颜色矩阵，而底栏那层
   * systemMaterial 是系统合成的外部材质，进了离屏图层之后背景取景会失效（材质退成一块
   * 死色）。为什么不用整层 `.opacity()`：alpha < 1 会让下层页透出来，正是本文件一直
   * 避免的观感问题。叠黑只影响这一层的显示结果，不碰任何子节点的材质与透明度。
   *
   * `hitTestBehavior(None)` 必须要有：黑纱是全屏节点，默认行为会吃掉上层页面的所有触摸。
   */
  @Builder
  private shade(layer: number) {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      .opacity(this.shadeOf(layer))
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no-hide-descendants')
  }

  @Builder
  private splash() {
    Column({ space: 8 }) {
      Text('KHenTai').fontSize(22).fontWeight(FontWeight.Medium).fontColor(Theme.text())
      Text('E-Hentai / ExHentai 客户端').fontSize(11).fontColor(Theme.subText())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private disclaimer() {
    Column({ space: 16 }) {
      Text('18+').fontSize(40).fontWeight(FontWeight.Bold).fontColor('#FF8A8A')
      Text('内容提示').fontSize(16).fontColor(Theme.text())
      Text('本应用是 E-Hentai / ExHentai 的第三方客户端，画廊内容全部由这两个站点提供，' +
        '可能包含成人内容。请确认你已达到所在地区的法定成年年龄，并遵守当地法律法规与站点规则。')
        .fontSize(12)
        .fontColor(Theme.subText())
        .lineHeight(20)
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })
      Text('本应用不提供、不存储、不分发任何内容，仅作为浏览器使用。')
        .fontSize(11)
        .fontColor(Theme.subText())
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })
      Text('我已成年，继续')
        .fontSize(14)
        .fontColor(Color.White)
        .width(220)
        .height(44)
        .textAlign(TextAlign.Center)
        .borderRadius(12)
        .backgroundColor('#2F6BD8')
        .margin({ top: 8 })
        // 与锁屏按钮同一套回弹：0.97 是"按得下去"的最小可见幅度，0.95 会像在缩小
        .scale({ x: this.pressGate === 1 ? 0.97 : 1, y: this.pressGate === 1 ? 0.97 : 1 })
        .animation({ duration: Motion.DONE_DELAY, curve: Motion.standard })
        .onTouch((ev: TouchEvent) => {
          if (ev.type === TouchType.Down) {
            this.pressGate = 1;
          } else if (ev.type === TouchType.Up || ev.type === TouchType.Cancel) {
            this.pressGate = -1;
          }
        })
        .onClick(() => {
          Prefs.put('age_ok', true);
          this.ageOk = true;
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    // 首次启动的确认页淡入，避免"白屏突然变成一大段文字"
    .transition(TransitionEffect.OPACITY.animation({ duration: Motion.GATE_IN, curve: Motion.standard }))
  }
}
