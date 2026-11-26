# V2 UI 规范（事实摘录自 erosTeam/NextE）

> 来源：`erosTeam/NextE`（MIT），main 分支，读取于 2026-11。
> 本文只写**在该仓库源码里读到的**内容，每条结论后标注文件与行号。
> 没有读到的内容一律不写，不推测、不补全。
>
> 已读文件清单（证据范围）：
> - `docs/architecture.md`
> - `AGENTS.md`
> - `entry/src/main/ets/pages/Index.ets`（3167 行，全文）
> - `feature/home/src/main/ets/components/GalleryListBody.ets`（725 行）
> - `feature/home/src/main/ets/viewmodel/GalleryListViewModel.ets`
> - `shared/src/main/ets/components/PullRefreshListScaffold.ets`（169 行）
> - `shared/src/main/ets/components/GalleryGridCard.ets`
> - `shared/src/main/ets/theme/ThemeConstants.ets`（243 行，全文）
> - `shared/src/main/ets/state/BackGuardState.ets`
> - `shared/src/main/ets/utils/BasicDataSource.ets`
>
> 未全仓扫描：仓库共 629 个 `.ets` 文件，上表是抽样。凡标注「本样本内」的结论，
> 意思是"在这 9 个文件里"，不代表全仓。

---

## 0. 硬约束（来自 `AGENTS.md`）

`AGENTS.md`「Hard stops / State Management V2」原文要求：

> `entry/`, `feature/` and `shared/` use V2 state only. Do not add or restore V1 decorators, adapters,
> allowlists, temporary bridges or key-churn refresh workarounds.
> ... run: `node scripts/test_v1_decorator_inventory_contract.mjs` — The result must be `0 file(s)`.

即：NextE 全仓**零 V1 装饰器**，且用脚本机械校验（`0 file(s)` 才算过）。
`docs/architecture.md` 同样写明：

> 所有产品代码使用 State Management V2：`@ComponentV2`、`@ObservedV2`、`@Trace`、`@Local`、`@Param`、
> `@Monitor` 和项目 state holder。不要恢复 V1 decorator、适配器或随机 key 刷新。

---

## 1. V2 装饰器的代码形态

### 1.1 `@Entry` + `@ComponentV2`（顺序：@Entry 在前）

`entry/src/main/ets/pages/Index.ets:665`

```ts
@Entry
@ComponentV2
struct Index {
  @Local private readerLabLaunch: ReaderLabLaunchState = connectReaderLabLaunch()
```

页面根组件也是 `@ComponentV2`，不是 V1 `@Component`。

### 1.2 `@Local`（组件内部可变）

`Index.ets:1299`

```ts
@Local currentTab: number = 0;
```

要点：**`@Local` 可以加 `private`**（`Index.ets:668` 就是 `@Local private ...`），必须有初值。

### 1.3 `@Param` / `@Require @Param`（外部输入，只读）

`shared/src/main/ets/components/PullRefreshListScaffold.ets:13-18`

```ts
  // @Param (not a plain member) because parents pass their own Scroller in by reference.
  @Param scroller: Scroller = new Scroller()
  @Param listSpace: number = ThemeConstants.SPACE_SM - 2
  @Param horizontalPadding: number = ThemeConstants.SPACE_MD
```

`@Require` 用于"父组件必须传"的无默认值参数，两个装饰器写在同一行、`@Require` 在前：

`feature/home/src/main/ets/components/GalleryListBody.ets:59`

```ts
  @Require @Param vm: GalleryListViewModel;
```

`shared/src/main/ets/components/GalleryGridCard.ets:48-50`

```ts
  @Require @Param gallery: EhGallery;
  @Param selected: boolean = false;
  @Param transitionCoverId: string = '';
```

规律：**必填项 `@Require @Param` 无初值；可选项 `@Param` 一律给默认值**（本样本内 100% 遵守）。

### 1.4 `@Event`（回调）

`GalleryListBody.ets:70-71`

```ts
  @Event onDidScroll?: (offset: number, state: ScrollState) => void;
  @Event onUserScroll?: () => void;
```

两种写法并存：可选标记 `?`（`PullRefreshListScaffold.ets:31` 起共 10 个 `@Event`），
或给默认空实现（`Index.ets:633`）：

```ts
  @Event onViewportChanged: () => void = () => {}
```

**注意**：`@Event` 是允许给默认值的 —— 本样本内不存在「@Event 不能带默认值」这条限制，
两种写法都在用。

### 1.5 `@Monitor`（监听）

只用「路径字符串 + 无参回调」这一种形式，本样本内**没有** `IMonitor` 参数用法：

`Index.ets:707`

```ts
  @Monitor('readerEntryVisibility.foreground', 'readerEntrySite.isEx', 'navStackHolder.navigationRevision',
    'securitySettings.locked', 'safeMode.unlocked')
  private onReaderEntryEnvironment(): void {
```

一个 `@Monitor` 可同时监听多个路径（最多 5 个路径本样本内），也能监听嵌套属性
（`xxx.yyy`）。`GalleryListBody.ets:103` 是同类写法：

```ts
  @Monitor('listMode.mode', 'overrideMode')
```

### 1.6 `@Computed`（派生值）

`Index.ets:679`

```ts
  @Computed
  private get readerEntryPhase(): ReaderEntryPhase { return this.readerEntryTransition?.phase ?? 'finished' }
```

派生状态不写进 `@Local`，用 `@Computed` getter 计算。

### 1.7 `@ObservedV2` + `@Trace`（可变模型类）

`shared/src/main/ets/state/BackGuardState.ets:9-18`（全文件）

```ts
@ObservedV2
export class BackGuardState {
  @Trace enabled: boolean = true
}
const BACK_GUARD_STATE_V2_KEY: string = 'v2_backGuard'
export function connectBackGuard(): BackGuardState {
  return AppStorageV2.connect(BackGuardState, BACK_GUARD_STATE_V2_KEY, () => new BackGuardState())!
}
```

`GalleryListViewModel.ets:69-79`

```ts
@ObservedV2
export class GalleryListViewModel {
  // Stable ref; LazyForEach subscribes to its listeners directly, so NOT @Trace.
  dataSource: GalleryCoverPrefetchDataSource = new GalleryCoverPrefetchDataSource()
  @Trace itemCount: number = 0
  @Trace isLoading: boolean = false
```

规律：
- `@ObservedV2` 类里，**需要驱动 UI 的字段才加 `@Trace`**；
- 长列表的 `dataSource` 引用故意**不加** `@Trace`（见 §4）；
- 类外用 `AppStorageV2.connect(Cls, key, () => new Cls())` 拿全局单例，
  组件里用 `@Local xxx = connectXxx()` 持有。

### 1.8 `@Provider` / `@Consumer` —— 本样本内没有使用

在 §0 列出的 9 个文件里 grep `@Provider` / `@Consumer`，命中数为 0。
NextE 的跨层传递走的是**另一个机制**：`AppStorageV2.connect()` 的 holder + 组件用 `@Local` 注入
（§1.7、`Index.ets:1205-1301` 连续 20 多个 `@Local xxx = connectXxx()`）。
`docs/architecture.md` 的说法一致：

> 跨组件状态由明确 owner 的 holder 或命令总线传递。

所以「跨层」在 NextE 里的正确形态是 `AppStorageV2` holder，不是 `@Provider/@Consumer`。
（全仓是否零使用未验证 —— 见文首证据范围说明。）

---

## 2. 页面骨架

### 2.1 根壳：`HdsNavigation` + `HdsTabs`（不是裸 `Navigation`）

`Index.ets:2723-2724`

```ts
        HdsNavigation(this.stack) {
        HdsTabs({ controller: this.tabsController }) {
```

- `HdsNavigation` / `HdsTabs` / `HdsNavDestination` / `HdsNavigationTitleMode` 来自
  `@kit.UIDesignKit`（`Index.ets:10-26`），不是 ArkUI 原生 `Navigation`/`Tabs`。
- 路由表用 `NavPathStack`（`Index.ets:671` `new NavPathStack()`），
  `Index.ets:2836` `.navDestination(this.routerMap)`，`routerMap` 是 `@Builder`（`Index.ets:2199-2201`）：

```ts
  @Builder
  routerMap(name: string, param: Object) {
    if (!SafeModeGate.routeAllowed(name)) {
```

- 自适应：`Index.ets:2846` `.mode(this.rootNavigationMode())`，
  `rootNavigationMode()`（`Index.ets:2189`）在 `NavigationMode.Auto` / `Stack` 之间切。
- 宽屏：`.splitPlaceholder(...)` + `.navBarWidth(320)` + `.minContentWidth(320)`（`Index.ets:2850-2859`）。

### 2.2 标题栏：`titleBar(opts)` 传 `Record<string, Object>`，不是 builder

`Index.ets:2104-2117`

```ts
  private titleBarOpts(): Record<string, Object> {
    const title: Record<string, Object> = { 'mainTitle': this.tabTitle() }
    const content: Record<string, Object> = { 'title': title }
    ...
      content['bottomBuilder'] = this.bottomBuilder(this.sourceBarContent)
      content['menu'] = this.safeMode.restricted() ? this.safeGalleryMenu() : this.searchMenu()
```

- 用**字典而不是强类型字面量**，因为 `bottomBuilder` / `menu` 不在严格 options 接口里
  （`Index.ets:2099` 注释原文说明）。
- 标题下方固定的切换条（源/周期/收藏夹）走 `bottomBuilder`
  （`Index.ets:2088-2097`，`BottomBuilderShowType.DIRECTLY_SHOW`），
  **不是列表里的 item，不跟随滚动**。
- 滚动自动隐藏：`Index.ets:2867` `.dynamicHideTitleBar({ mode: HideMode.SCROLL_UP, ... })`
  + `Index.ets:2873` `.bindToScrollable([this.titleScroller])`。
- 每次 `titleBar` 重建会重挂组件，所以 `ComponentContent` 只建一次并缓存（`Index.ets:1279` 注释）。

### 2.3 内容区

内容由各 feature 页面自己渲染（`HomePage`/`FavoritesPage`/`ToplistPage`/`DownloadQueuePage`/`SettingsPage`），
根壳只给 `TabContent() {} .tabBar(...)`，不插入额外容器（`Index.ets:2725-2799`）。

### 2.4 底部操作区 / 底栏

- 底栏就是 `HdsTabs` 自己的 `.barPosition(BarPosition.End)`（`Index.ets:2803`），
  不是另画的一层组件。
- 悬浮 + 材质：`Index.ets:2802-2815`

```ts
        .barOverlap(true)
        .barFloatingStyle({
          barBottomMargin: ThemeConstants.SPACE_XL,
          adaptToHandedness: true,
          systemMaterialEffect: {
            materialType: ImmersiveMaterialSettings.effect(this.immersiveMaterial.level).materialType,
```

`barBottomMargin: SPACE_XL` = **24vp**，`adaptToHandedness: true`（跟随左右手）。
- 页面级底部按钮区：`ThemeConstants.FOOTER_HEIGHT = 48`、`FLOAT_BAR_HEIGHT = 56`。

---

## 3. 设计令牌（`shared/src/main/ets/theme/ThemeConstants.ets`）

文件头声明这是**唯一**的间距/字号/圆角/颜色来源：

> `components NEVER hardcode pixel sizes, colors, or font sizes.`
> `Prefer HarmonyOS system color tokens ($r('sys.color.*')) so light/dark follow the platform automatically`

### 3.1 颜色（全部是系统令牌或固定 hex，没有自定义品牌 hex）

| 令牌 | 值 |
| --- | --- |
| `BRAND_PRIMARY` | 动态 getter → `ThemeColorSettings.currentColor()`，默认 `$r('sys.color.brand')` |
| `BRAND_ACCENT` | `$r('sys.color.font_secondary')` |
| `TEXT_ON_BRAND` | `$r('app.color.text_on_brand')` |
| `TEXT_PRIMARY` / `SECONDARY` / `TERTIARY` | `$r('sys.color.font_primary')` / `font_secondary` / `font_tertiary` |
| `TEXT_LINK` | `$r('sys.color.font_emphasize')` |
| `BG_PRIMARY` | `$r('sys.color.background_primary')` |
| `BG_SUB` | `$r('sys.color.ohos_id_color_sub_background')` |
| `DIVIDER` | `$r('sys.color.ohos_id_color_list_separator')` |
| `OVERLAY_SCRIM` | `#99000000` |
| `LOCK_OVERLAY_TINT` | `#4D808080`（blur 半径 60） |
| `FROSTED_SURFACE_LIGHT_TINT` / `DARK_TINT` | `#33FFFFFF` / `#33000000` |
| `FROSTED_SURFACE_DARK_BORDER` / `BORDER_WIDTH` | `#33FFFFFF` / `0.5` |
| `FROSTED_SURFACE_BLUR_RADIUS` | `40` |
| `READER_BACKGROUND_BLACK/GRAY/WHITE` | `#FF000000` / `#FF303030` / `#FFFFFFFF` |
| `READER_PAGE_NUMBER_TEXT` / `OUTLINE` | `#99FFFFFF` / `#80000000` |
| `READER_CONTROL_LIGHT_TINT` / `DARK_TINT` | `#26FFFFFF` / `#26000000` |

（`EhSemanticColors` 里的 EH 域配色 —— 分类色、标签命名空间色、favcat 槽位色 —— 不在
`ThemeConstants` 内，文件头注释明确把它们排除在外。）

### 3.2 间距 `SPACE_*`（vp）

`XS 4` / `SM 8` / `MD 12` / `LG 16` / `XL 24` / `XXL 32`

### 3.3 字号 `FONT_SIZE_*`（fp）

`TINY 10` / `TAG 11` / `CAPTION 12` / `META 13` / `BODY 14` / `LIST_ITEM 13` /
`TITLE 16` / `HEADING 18` / `H2 22` / `H1 24` / `DISPLAY 28`

行高：`LINE_HEIGHT_TITLE 22` / `LINE_HEIGHT_BODY 20`

### 3.4 图标尺寸 `SYMBOL_SIZE_*`

`TINY 12` / `COMPACT 14` / `ACTION 18` / `CONTROL 20` / `ROW 22` / `STANDARD 24` /
`PROMINENT 28` / `FEATURE 30` / `LARGE 32` / `HERO 36`

### 3.5 圆角 `RADIUS_*` 与专用圆角

`RADIUS_SM 4` / `RADIUS_MD 22` / `RADIUS_CARD 24` / `RADIUS_ROUND 999` /
`LIST_TAG_RADIUS 6` / `CHIP_RADIUS 8` / `THUMB_RADIUS 8` / `DETAIL_COVER_RADIUS 16` /
`LIST_ROW_RADIUS 19` / `GALLERY_GRID_CARD_RADIUS 16` / `COMMENT_BADGE_RADIUS 9` /
`COMMENT_QUOTE_RADIUS 8`

同心圆角规则（`ThemeConstants.ets:172` 注释）：

```ts
  // Inner cover radius follows the concentric-corner rule: outer radius minus the cover inset.
  static readonly DOWNLOAD_TASK_COVER_RADIUS: number =
    ThemeConstants.DOWNLOAD_TASK_CARD_RADIUS - ThemeConstants.DOWNLOAD_TASK_CARD_PADDING
```

→ 内层圆角 = 外层圆角 − 内边距（24 − 8 = 16）。

### 3.6 关键尺寸（vp）

| 令牌 | 值 |
| --- | --- |
| `TITLE_BAR_HEIGHT` | 56 |
| `FLOAT_BAR_HEIGHT` | 56 |
| `FOOTER_HEIGHT` | 48 |
| `BUTTON_HEIGHT` | 46 |
| `SEARCH_FIELD_HEIGHT` | 40 |
| `ACTION_HEIGHT` | 36 |
| `TEXT_ACTION_HEIGHT` | 40 |
| `TEXT_ACTION_MIN_WIDTH` | 120 |
| `DETAIL_ACTION_CHIP_HEIGHT` | 28 |
| `LOADING_SIZE` / `_SMALL` / `_LARGE` | 32 / 24 / 40 |
| `INDICATOR_SIZE` | 28 |
| `LIST_CARD_FIXED_HEIGHT` | 204 |
| `LIST_CARD_WIDE_COVER_WIDTH` | 142.8 |
| `LIST_CARD_COVER_ASPECT` | 0.71 |
| `PREVIEW_THUMB_MIN_W` | 90 |
| `GALLERY_GRID_MIN_W` | 106 |
| `GALLERY_WATERFALL_MIN_W` | 160 |
| `GALLERY_COVER_WALL_MIN_W` | 120 |
| `GALLERY_GRID_GAP` | 6 |
| `GALLERY_COL_MIN_W_FLOOR` / `CEIL` | 80 / 300 |
| `TABLET_PRIMARY_PANE_WIDTH` / `MIN` | 320 / 320 |
| `TABLET_DETAIL_MIN_WIDTH` | 320 |
| `GALLERY_DETAIL_SPLIT_MIN_WIDTH` | 720 |
| `SYSTEM_SYMBOL_GRID_MIN_WIDTH` / `CARD_HEIGHT` / `GLYPH_SIZE` | 112 / 112 / 36 |
| `DOWNLOAD_TASK_COVER_WIDTH` / `HEIGHT` | 78 / 110 |
| `THUMB_ASPECT` | 1.414 |

### 3.7 动效时长与曲线

`ThemeConstants.ets:240-242`

```ts
  static readonly ANIM_DURATION: number = 400
  static readonly ANIM_STATE_RESET_MS: number = 420
  static readonly ANIM_DONE_DELAY_MS: number = 200
```

页面转场（`Index.ets:170-172`，这是「详情页推入」那套，不是令牌）：

```ts
const GALLERY_DETAIL_TRANSITION_DURATION_MS: number = 350
const GALLERY_DETAIL_OPEN_CURVE: curves.ICurve = curves.cubicBezierCurve(0.2, 0, 0, 1)
const GALLERY_DETAIL_CLOSE_CURVE: curves.ICurve = curves.cubicBezierCurve(0.3, 0, 0.2, 1)
```

Tab 切换：`Index.ets:2806` `.animationDuration(0)` —— **切 tab 不加动画**（与我们工程的 220ms 不同，
是刻意差异，不是遗漏）。

---

## 4. 列表组件：`LazyForEach` + `IDataSource` 虚拟化 + `reuse`

### 4.1 用 `LazyForEach`，不用 `ForEach` / `Repeat`

`GalleryListBody.ets:361-385`

```ts
          LazyForEach(
            this.vm.dataSource,
            (g: EhGallery, index: number) => {
              GridItem() {
                GalleryGridCard({ gallery: g, ... })
                  .reuse({ reuseId: () => galleryGridReuseId(g) })
              }
              .onAppear(() => { this.onGalleryAppear(index) })
            },
            (g: EhGallery) => g.renderKey(),
          )
```

三件套：`dataSource` + item 构建函数（第二参带 `index`）+ **稳定 key 函数**（`renderKey()`，
不是数组下标）。行节点复用用 `.reuse({ reuseId: ... })`。

`Index.ets`（3167 行）与 `GalleryListBody.ets`（725 行）内均无 `Repeat`。

### 4.2 数据源：稳定引用、不进 `@Trace`

`BasicDataSource.ets:8-30`（文件头注释是关键）

```ts
/**
 * Generic LazyForEach data source (V2Next pattern). Held as a STABLE reference on the
 * ViewModel and kept OUT of @Trace — LazyForEach subscribes to its DataChangeListeners
 * directly, so a @Trace array (re-rendered via ForEach) is the wrong tool for long lists.
 * The ViewModel mirrors `totalCount()` into a separate @Trace `itemCount` so @ComponentV2
 * build() re-evaluates the loading→list branch.
 */
export class BasicDataSource<T> implements IDataSource {
  totalCount(): number { return this.items.length }
  getData(index: number): T { return this.items[index] }
```

→ **长列表不能用 `@Trace` 数组**；用 `IDataSource` + `DataChangeListener` 通知，
另外用一个 `@Trace itemCount` 让 `build()` 的「加载中 / 列表」分支能切换。

增量更新用 `DataOperationType`，而不是整表重载（`BasicDataSource.ets:47` 起有
`notifyDatasetChange([{ type: DataOperationType.RELOAD }])`，`notifyAdded(start, items)` 等）。

### 4.3 骨架组件把「滚动/分页/回到顶部」收进可复用壳

`PullRefreshListScaffold.ets:70` `List({ space: this.listSpace, scroller: this.scroller })`，
通过 `@Event onReachEnd` / `canStartBottomRefresh` / `onScrollIndex` / `onContentWidth`
把分页与量测交给页面（`PullRefreshListScaffold.ets:31-40`）。

网格用 `PullRefreshGridScaffold`、瀑布流用 `PullRefreshWaterFlowScaffold`（同目录），
`GalleryListBody` 按 `ListMode` 在 LIST / GRID / WATERFALL / SIMPLE 之间切渲染器，
**切模式只换渲染器，不重新请求**（`GalleryListBody.ets:65` 注释）。

### 4.4 列数由宽度推导，不写死

`ThemeConstants.ets:213` 注释：列数由 pane 宽度与 `PREVIEW_THUMB_MIN_W` 推导，
`so narrow panes stay readable and wider panes scale up — never a hardcoded column count`。

---

## 5. 迁移时最容易踩的坑

1. **`@Param` 只读 —— 改对象属性不会刷新，且改不动**
   `@Param` 是外部输入，子组件内不能赋值。想改就往上传 `@Event`，或在父组件里换引用。
   本仓里 `@Param gallery` 配 `@Event` 回调而不是就地改。
2. **`@Param` 给默认值时，`@Require` 必须去掉**
   必填写 `@Require @Param x: T;`（无初值），可选写 `@Param x: T = 默认值;`。
   `@Require` 和默认值同时出现是自相矛盾的写法。
3. **`@Local` 修饰的普通 class 实例，内部属性变化不触发刷新**
   要么该类是 `@ObservedV2` + 字段 `@Trace`，要么整体换引用。
   `GalleryListViewModel` 的 `dataSource` 就故意不加 `@Trace`（`GalleryListViewModel.ets:73`）。
4. **长列表别用 `@Trace` 数组 + `ForEach`**
   `BasicDataSource.ets` 头注释直说这是 `the wrong tool for long lists`。
5. **`@Monitor` 的路径要写全，且只能监听可观察字段**
   监听 `a.b` 要求 `a` 是 `@ObservedV2`/`@Trace` 的对象；监听普通成员的值变化不会有回调。
6. **`@Event` 与 `@Param` 容易混**
   回调一律 `@Event`（可 `?` 可选，也可给空实现默认值，两种都合法）；
   把回调写成 `@Param` 也能跑，但语义错，且父组件换函数时行为不同。
7. **`@Entry` 写在 `@ComponentV2` 之前**（`Index.ets:665-666`），顺序反了报错。
8. **V1/V2 不能同一个 struct 内混用**
   `@ComponentV2` 里出现 `@State/@Prop/@Link/@Provide/@Consume/@Watch/@StorageProp/@StorageLink/@Observed/@ObjectLink`
   都会被编译器拒绝。NextE 用脚本卡这条（`AGENTS.md` 的 inventory contract）。
9. **`AppStorage` 的静态 API 仍可用，被禁的只是 V1 装饰器**
   不能用的是 `@StorageProp`/`@StorageLink`（V1 装饰器）；
   `AppStorage.get<T>(key)` / `AppStorage.setOrCreate<T>(key, v)` 是普通 API，
   在 `@ComponentV2` 里调用没有任何问题（NextE `Index.ets:457` 就是
   `AppStorage.get<number>('navBarHeight')`，只是它**不是响应式的** —— 想让 UI 跟随，得自己用
   `@Local` 承接并 `@Monitor`/回调更新，或换 `AppStorageV2.connect()` holder）。
10. **`titleBar` 的 options 用 `Record<string, Object>`**
    写成强类型字面量会因 `bottomBuilder`/`menu` 不在接口里而编译失败（`Index.ets:2099` 注释）。
11. **`ComponentContent` 必须缓存，不能在 `titleBar()` 里新建**
    `Index.ets:1279` 注释：每次重建会重新挂载组件。
12. **转场曲线阈值是「空间进度」不是「时间」**
    `Index.ets:173-184` 反复强调 crossfade 阈值描述的是空间窗口进度，改曲线不会移动淡出时刻，
    需要先用二分反解时间（`galleryDetailTimeAtProgress`，`Index.ets:187`）。
13. **两层页面叠加时不要加整页 alpha**
    透明度 < 1 会让下层透出来 —— 这正是我们工程 `Index.ets` 注释里已有的结论，NextE 的
    `Index.ets:2718` 也是用 clip 把源列表留在开合裁剪区之外，而不是靠透明度。
