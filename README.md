# JHenTai · HarmonyOS

**E-Hentai / ExHentai 客户端的 HarmonyOS NEXT（ArkTS）移植版。**

上游项目：[jiangtian616/JHenTai](https://github.com/jiangtian616/JHenTai)（Flutter，Apache-2.0，
5.8k star，支持 Android / iOS / Windows / macOS / Linux）。本工程用 **ArkTS 原生重写**，
不是 Flutter 打包，也不含任何 Dart 代码。

- 规模：31 个 `.ets`，约 7270 行，**零第三方依赖**
- 编译目标：HarmonyOS API 26（DevEco 7.x），`BUILD SUCCESSFUL`，0 error
- 当前版本：**1.1.0**（versionCode 1000100）
- 产物：`dist/JHenTai-HarmonyOS-v1.1.0-api26-unsigned.hap`（由 `build.ps1` 按版本号命名）
- 解析层单测：**92 条断言全绿**（HTML 解析 30 + 页面解析 37 + 评论/种子 25）

> ⚠️ 内容提示：画廊内容全部由 E-Hentai / ExHentai 提供，可能包含成人内容。
> 首次启动有 18+ 确认。本应用不提供、不存储、不分发任何内容，仅作为浏览器使用。

---

## 1. 为什么不是「把 Flutter 项目编译成鸿蒙」

理论上可以把 Flutter 项目接到 HarmonyOS（华为的 flutter_flutter 分支），但这个项目依赖
`drift`（sqlite3 原生）、`extended_image`、`file_picker`、`path_provider`、
`permission_handler` 等一批**需要 OHOS 原生实现**的插件，逐一对齐工作量比写一个客户端还大，
而且本机没有 Flutter OHOS 工具链，无法验证。

所以选择原生重写：只保留可验证的核心链路，代码可读、可改、可继续扩展。

---

## 2. 功能

### 浏览与搜索

| 功能 | 说明 |
|---|---|
| 首页 | 最新（首页分页）、热门（`/popular`）、**排行**（日/月/年/总榜）、**观看**（watched） |
| 翻页 | 跟站点自己的 `next` 链接翻页，不自己算页码；下拉刷新、滚动到底自动加载 |
| 搜索 | 支持 EH 全部高级语法（`artist:`、`female:xxx$`、`-language:`、引号短语），搜索历史 |
| **以图搜图** | 选本地图片上传到 `image_lookup.php`（multipart），结果复用列表卡片展示 |
| 列表卡片 | 封面 / 标题 / 分类（按 EH 分类配色）/ 页数 / 评分 / 上传者 / 发布时间 / 已删除标记 |

### 详情与阅读

| 功能 | 说明 |
|---|---|
| 详情 | 标题、日文标题、分类、页数、大小、语言、上传者、发布时间、评分与人数、收藏数、可见性 |
| 标签 | 按命名空间分组着色；**点击可投票（可信/有误）或加入观看列表**；支持中文翻译显示 |
| 阅读器 | 三种模式：**连续滚动 / 横向单页 / 双栏翻页**；点击切换控件、滑块跳页 |
| 大画廊 | 页面索引**边读边补**（详情页只给 20 张，其余按 `?p=20/40…` 追加），上千页也能立刻开始读 |
| **离线阅读** | 下载完成的画廊直接从沙箱读图，不联网 |
| 图片加载 | 自己下载（h@h 校验 `Referer`），长边 2048 解码省内存，PixelMap 归每页所有、滚出即释放 |

### 下载与归档

| 功能 | 说明 |
|---|---|
| **整本下载** | 逐页落盘到 `<filesDir>/JHenTai/<gid>-<token>/0001.jpg`；单任务串行 + 页间 300ms 节流（避免 509） |
| **断点续传** | 以「文件是否存在且非空」为续传依据，中断/崩溃/手动删文件都能自愈；暂停即时生效 |
| 下载管理 | 独立 tab：进度条、暂停/继续/删除、已完成计数、一键全部暂停 |
| **归档下载** | 请求 `archiver.php`（原始档/压缩档）→ 拿链接 → **流式下载**（`requestInStream`）→ `zlib.decompressFile` 解压到沙箱 |
| **种子** | `gallerytorrents.php` 列表（名字/大小/做种/连接/时间），点击把 `.torrent` 存到沙箱 |

### 账户与站点

| 功能 | 说明 |
|---|---|
| 登录 | ① 账号密码（论坛接口）② Cookie 登录（`ipb_member_id` / `ipb_pass_hash` / `igneous`） |
| 会话补齐 | 登录后自动访问 `bounce_login.php` 取 `sk`，并探一次 EX 站尝试取 `igneous` |
| 站点切换 | E-Hentai ↔ ExHentai，缺 `igneous` 时明确提示 |
| 收藏 | 服务端 10 个收藏目录浏览、详情页加入/取消；另有本地「存档」 |
| **评论** | 列表（用户名/分数/时间/内容）、发表评论、**对评论投赞成/反对** |
| **标签投票** | API 方式投票（`taggallery`），依赖详情页里的 `apikey/apiuid` |
| 历史 | 最近浏览 200 条 |

### 外观与安全

| 功能 | 说明 |
|---|---|
| 主题 | 跟随系统 / 浅色 / 深色，切换即时生效（页面通过 `@StorageProp('themeDark')` 重绘） |
| 平板布局 | 宽度 ≥ 840vp 时 tab 栏自动挪到左侧竖排（原版 tablet/desktop 布局的最小可用版） |
| **应用锁** | 指纹 / 锁屏密码解锁；设备不支持生物识别时降级为直接通过并在设置里提示 |
| 标签翻译 | EhTagTranslation 数据库（约 10MB，首次下载到沙箱缓存），开关 + 手动更新/清除 |
| **沉浸材质** | API 26 的 `systemMaterial`：悬浮底栏 + 首页顶栏；不可用时自动退化为「实底 + 厚模糊」 |
| **页面转场** | 推拉式：新页从右侧滑入、下层页左移 22% 并缩到 0.98（320ms / FastOutSlowIn），不做整页淡变 |

### 仍未实现（2 项，附原因）

| 项 | 为什么没做 |
|---|---|
| **多语言（原版 20+ 语言）** | 需要先把 10 个页面里约 300 条文案抽成 key，再补 20 套翻译。只做「导航英文、正文中文」的半成品比不做更糟，所以这一项**整体留空**，界面为中文。I18n 字典骨架写过一版，为避免死代码已删除。 |
| **域名前置（domain fronting）** | 需要「连 IP + 覆盖 Host 头 + 正确 SNI」。HarmonyOS 的 `@ohos.net.http` 不允许自定义 SNI，用 IP 连接 HTTPS 会直接握不上手；要实现只能用 native socket + TLS，代价与风险都远超收益。EX 站请用系统代理。 |

---

## 3. 目录

```
entry/src/main/ets/
├─ parse/Html.ets            ★ 容错 HTML 解析器 + CSS 选择器子集
├─ core/
│  ├─ Consts.ets             站点 URL、分类/命名空间配色、收藏夹名
│  ├─ Models.ets             Gallery / GalleryDetail / ImagePage / EhUrl
│  ├─ Http.ets               @ohos.net.http 封装：UA、Cookie、Referer、限流/封禁识别
│  ├─ Cookies.ets            Cookie 罐（ipb_member_id / ipb_pass_hash / sk / igneous）
│  ├─ EhApi.ets              ★ 列表/详情/单图页解析、登录、收藏、gdata 兜底
│  ├─ Comments.ets           评论解析 + 发表 + 投票 + apikey/apiuid 解析
│  ├─ TagVote.ets            标签投票 / 加入观看
│  ├─ Torrents.ets           种子列表解析
│  ├─ Archive.ets            归档申请 / 流式下载 / zlib 解压
│  ├─ ImageSearch.ets        以图搜图（multipart 上传）
│  ├─ Downloader.ets         ★ 下载队列 + 断点续传 + 本地页索引
│  ├─ TagTrans.ets           EhTagTranslation 缓存与查询
│  ├─ Theme.ets / AppLock.ets / Prefs.ets / AppContext.ets
├─ net/ImageLoader.ets       带 Referer 的大图 / 本地图解码
├─ ui/                       GalleryCard（卡片+标签胶囊）、GalleryListView（通用分页列表）
├─ pages/
│  ├─ Index.ets              18+ 确认 / 应用锁 → 五 tab + 页面栈（详情/阅读/评论/工具）
│  ├─ HomePage / SearchPage / FavoritesPage / DownloadsPage / SettingsPage
│  ├─ DetailPage.ets         详情 + 收藏面板 + 标签投票面板
│  ├─ ReaderPage.ets         阅读器（三种模式 + 离线）
│  ├─ CommentsPage.ets       评论列表 / 发表 / 投票
│  └─ ToolsPage.ets          归档 + 种子
└─ entryability/EntryAbility.ets
```

---

## 4. 编译

### DevEco Studio（真机推荐）

1. 安装 **DevEco Studio 7.x**（含 HarmonyOS SDK 26）；
2. 打开本目录 → Sync；
3. Project Structure → Signing Configs → 勾选 *Automatically generate signature*；
4. 选 `entry` 运行。

### 命令行（本工程实际验证的路径）

```powershell
set DEVECO_SDK_HOME=<clt>\sdk
set OHOS_BASE_SDK_HOME=<clt>\sdk\default\openharmony
set JAVA_HOME=<jdk17>
<clt>\bin\hvigorw.bat --mode module -p product=api26 -p module=entry@default assembleHap --no-daemon
```

`build-profile.json5` 有两个 product：`default`（runtimeOS=HarmonyOS，真机/上架）与 `api26`
（runtimeOS=OpenHarmony，无 HarmonyOS SDK 时的命令行验证），编译同一份源码。

本机验证（2026-11）：ArkTS 编译 0 error；HAP 打包通过；**真机未验证**。

---

## 5. 解析层：选择器从哪来、怎么验证

E-Hentai 只提供 HTML，没有完整的列表 API，所以解析器是这套移植的地基。

**选择器来源**：上游把解析委托给 `lib/src/utils/eh_spider_parser.dart`（DOM 查找而非 CSS）。
本移植把它翻译成等价 CSS 选择器，并把两处脆弱写法换成更稳的规则：

| 数据 | 规则 |
|---|---|
| 列表行 | `.itg.gltc tr` / `.itg.gltm tr` / `.itg.glte tr` / `.itg.gld > div` 依次降级 |
| 详情链接 | 行内第一个 `href` 含 `/g/` 的 `<a>` |
| 标题 / 页数 | `.glink`；行文本 `/(\d+)\s*pages?/i` |
| 评分 | `.ir` 的 `background-position:-Xpx -Ypx`（x 每 16px 少一星，y≥21 半星） |
| 详情元信息 | `#gdd tr` 里按 `.gdt1` 的**标签文本**（Parent/Visible/Language/File Size/Length/Favorited）匹配，不依赖行号 |
| 标签 | `#taglist div`，`id` 形如 `female:stockings`，`class` 含 `gt/gtl/gtw`，颜色取 `style` |
| 缩略图页 | `#gdt a` 中 `href` 含 `/s/` 的链接；总图数取 `of N images` |
| 单图页 | `#img[src]`，翻页 `#next` / `#prev` |
| 分页 | `#unext` / `#uprev`，回退 `.gtb` 里文本为 `>` 的链接 |
| 评论 | `#cdiv .c1`，id 可能在 `.c1` 自身或内部锚点；正文取第一个 `.c6`；分数在 `.c5` |
| 种子 | 行内必须有 `.torrent` 链接；名字取「最长且非纯数字/大小」的那一格 |
| 软错误 | 正文前缀 `Your IP address`（封禁）/ `opening pages too fast`（限流）/ `fatal error` |

**验证方式**：解析器不依赖 ArkUI，直接用 `node --experimental-strip-types` 跑单测：

```
HTML 解析 / 选择器        30 条   （实体解码、属性含 '>'、未闭合标签、注释、nth-child…）
EH 页面 → 数据模型        37 条   （列表字段、详情元信息、标签、分页、URL 归一化…）
评论 / 种子              25 条   （apikey、评论字段与投票态、种子列定位、空页面不崩）
```

这套测试在开发中**真的抓出过两个 bug**：评论 id 挂在 `.c1` 自身时拿不到、种子名取到了序号列。
两者都已修。标签解析失败时还会自动退到 `api.php` 的 `gdata`（原版没有的兜底）。

---

## 6. 登录、站点与网络

| 场景 | 说明 |
|---|---|
| 只看 E-Hentai | 不需要登录 |
| 收藏 / 评论 / 投票 / 限额 | 需要登录。推荐 **Cookie 登录**：浏览器登录后复制 `ipb_member_id`、`ipb_pass_hash` |
| ExHentai | 额外需要 `igneous`；应用会自动尝试获取，取不到时设置页明确提示 |
| 网络 | **不走系统代理**。EX 站在部分网络需要代理，属系统/路由器层面配置 |

---

## 7. 沉浸材质与动效

这一块是照着 `Han1meViewer-HarmonyOS`（同目录另一工程）的材质/动画体系移植的，只保留了与本工程
相关的部分，并按本工程的色板重写。

### 材质（`core/Material.ets` + `components/MaterialSurface.ets`）

| 做法 | 说明 |
|---|---|
| 应用级开关 | `entry/module.json5` 加 metadata `ohos.arkui.UIMaterial.state = enable`。不加这一项，`getMaterialInfo().state` 停在 DEFAULT，材质不会真正参与合成 |
| 能力探测 | `deviceInfo.apiAvailable('26.0.0')` + `uiMaterial.isImmersiveMaterialSupported()` + `getMaterialInfo().state !== DISABLE`，三者都满足才用材质 |
| 底栏 | `Tabs(barModifier: MaterialModifier)` + `barFloatingStyle({ systemMaterial })` —— 底栏是系统栏作用域，这里传的材质是真合成的 |
| 顶栏 | 普通组件没有系统栏作用域，用 `CommonModifier.applyNormalAttribute` 里 `instance.systemMaterial(...)` 手动挂；首页顶栏改成**压在列表上**（列表 `topInset` 让位），才有内容可透出 |
| 回退阶梯 | 材质不可用 → `backgroundColor(回退底色) + backgroundBlurStyle(COMPONENT_THICK/THIN)`；切回材质时先 `systemMaterial(Material.empty)` 清残留 |
| 染色 | 深色用**黑** alpha（压暗玻璃，否则顶栏发白）、浅色用白；算力档越低（GENTLE / SMOOTH）染色越重，保证低端机文字可读 |

三个坑（都写在 `Material.ets` 注释里）：
1. `materialColor` 在创建实例时固化，**不是响应式属性** —— 切深浅色必须重建材质实例
   （`MaterialSurface` 监听 `themeDark` 并 bump revision 让材质宿主整块重建）；
2. `MaterialModifier` 的成员不能叫 `enabled`（与 `CommonAttribute` 同名冲突，编译报
   「Property 'enabled' is not assignable to the same property in base type」）；
3. 材质对象与挂载表面绑定，**不能跨表面复用**，每次重建都要 new 一个 modifier。

### 动效

| 动效 | 参数 / 做法 |
|---|---|
| 页面 push/pop | 新页 `translateX 100% → 0`；被压住的页 `0 → -22%` + `1 → 0.98`；320ms / `Curve.FastOutSlowIn`；**只有位移和缩放，没有整页透明度**（淡变会让下层页面透出来） |
| 入场时机 | push 时先让新层以「屏外」状态挂载，`onAppear` 里再 `animateTo` 归位；否则首帧会先完整闪一下 |
| 出栈时机 | pop 先播动画，`setTimeout(320+10ms)` 之后再真正出栈，避免页面在滑出途中被销毁 |
| 命中隔离 | 非栈顶层的容器 `.hitTestBehavior(HitTestMode.None)`，被盖住的页面不会偷点击 |
| 底栏切换 | 选中项文字 1.04 倍、指示条 4 → 14 宽，180/220ms，`FastOutSlowIn` |
| 卡片 | 按压 0.97 回弹（`onTouch` + `.scale` + `.animation`，不改布局）；入场 `opacity 0→1`、`translateY 8→0`，220ms |

### 还没做的（同一模式可平移）

详情 / 评论 / 工具页的顶栏目前仍是**实底**，没有做成压列表的材质顶栏。改法与首页一致：
把 header 换成 `MaterialSurface`、把滚动容器的顶部内边距设为顶栏高度（约 10 行/页）。
阅读器保持纯黑（漫画阅读不适合叠材质）。

## 8. 与 Flutter 原版的差异

1. **没有本地数据库**：历史/下载任务/搜索历史用 preferences 存 JSON（历史上限 200 条）。
   原版用 drift(SQLite)，支持海量记录与复杂查询。
2. **下载是「逐页抓图」**：不做原版的多线程分片、优先级、分组、检查更新；归档是单独一条链路。
3. **标签翻译需手动开启**：首次要下载约 10MB 数据库。
4. **评论/标签投票依赖页面里的 apikey**：站点若改了变量名就只剩只读能力（不会崩）。
5. **列表统一单列卡片**（原版有 minimal/compact/extended/thumbnail 四种）。
6. **详情页不显示缩略图网格**：直接「开始阅读」，阅读器里边读边补索引。

---

## 9. 已知限制 / 真机待验证

- **真机未验证**：只验证到「编译器 + 解析单测」。上机建议顺序：
  1. 首页四种模式能否加载；
  2. 详情字段与标签；
  3. 阅读器图片能否显示（h@h 的 Referer 校验是这一步的关键）；
  4. Cookie 登录后收藏夹 / 评论 / 投票；
  5. 下载一本 → 断网 → 从下载页进阅读器（验证离线）；
  6. 归档（需要 GP/配额）与种子；
  7. 应用锁与主题切换。
- **归档依赖站点配额**：没有 GP 会返回明确的失败文案；H@H 生成需要等待，首次可能拿到空链接。
- **下载是串行的**：刻意如此（EH 对高频抓图会 509）。一本 300 页的漫画大约需要几分钟。
- **评论发表后不回显**：站点不返回新评论，重新进详情页才能看到（不做假乐观更新）。
- **图片仍无磁盘缓存**：除下载过的画廊外，重复阅读会重新下载。
- **材质只在真机上才能确认**：预览器与部分设备不支持沉浸材质，会走「实底 + 厚模糊」回退路径；
  上机时请对照：底栏是否为半透明胶囊、首页顶栏是否透出下方封面。

## 10. 可以继续加

图片磁盘缓存 → 下载优先级/分组 → 列表多布局 → 标签翻译自动跟随语言 → 平板真正的双栏（列表+详情）→ 分享/导出。

---

## 11. v1.1.0 变更与真机测试指引

### 本版新增

| 项 | 内容 |
|---|---|
| 沉浸材质 | `core/Material.ets` + `components/MaterialSurface.ets`；`module.json5` 开启 `ohos.arkui.UIMaterial.state=enable` |
| 悬浮材质底栏 | `Tabs(barModifier)` + `barFloatingStyle({ systemMaterial })`，不可用时自动退化为「实底 + 厚模糊」 |
| 首页材质顶栏 | 顶栏压在列表上（`GalleryListView.topInset`），封面从底下滚过才有材质可透 |
| 推拉转场 | push/pop 320ms `FastOutSlowIn`：新页从右滑入、下层左移 22% 缩到 0.98；**不做整页淡变** |
| 卡片动效 | 按压 0.97 回弹、入场淡入上移 |
| 设置页诊断 | 显示 `沉浸材质 / 系统 API / 材质算力档 / 窗口尺寸`，方便手机上一眼看出材质有没有生效 |
| 构建产物 | `build.ps1` 按 `AppScope/app.json5` 的版本号命名到 `dist/` |

### v1.1.1（本版）

| 项 | 内容 |
|---|---|
| **详情页悬浮材质操作栏** | 「开始阅读 / 下载 / 收藏 / 更多」从滚动内容里搬到屏幕底部的悬浮材质栏（`panel` 配方），滚动内容底部留白 150vp 让位 |
| 悬浮栏配方 | `MaterialSurface` 增加 `kind` 参数（header / panel / tabbar），三种配方共用同一套回退逻辑 |
| 版本化产物 | `dist/JHenTai-HarmonyOS-v1.1.1-api26-unsigned.hap` |

### v1.2.0（本版：页头统一）

| 项 | 内容 |
|---|---|
| `components/PageHeader.ets` | 统一页头：左返回 + 标题/副标题 + 右侧动作槽，背景是沉浸材质（`header` 配方） |
| 已接入 | 下载 / 收藏（无返回，右侧「全部暂停」）/ 评论（副标题显示条数与登录态）/ 归档·种子 |
| 仍是自定义页头 | 首页（含模式切换 chips）、搜索（含输入框）、详情（含「存档」按钮）——这三处的内容是页面专属控件，套统一框体反而更僵 |
| 状态栏避让 | 高度、状态栏 padding、材质回退只在 PageHeader 里定义一次，不再每页各写一套 |

### 距离「完全对齐原版」还差什么

原版是一个 5.8k star、迭代 4 年的 Flutter 工程（约 200 个 Dart 文件）。按可验证的顺序，剩下的部分拆成三批：

**A. 交互/布局对齐（纯 UI，风险低）**
- 列表 4 种样式：minimal / compact / extended / thumbnail（原版可切换）
- 详情页缩略图网格（现在直接「开始阅读」）
- 平板双栏：列表 + 详情同屏（现在只是把 tab 栏移到左侧）
- 阅读器：双页合并、右起左翻、点击区域分区（现在三种模式 + 点击切换控件）

**B. 功能对齐（需要更多接口/存储）**
- 下载：优先级、分组、仅 WiFi、失败重试、检查画廊更新
- 本地库：SQLite（`relationalStore`）替代 preferences JSON，支持海量历史与检索
- 标签：标签集（tagset）、观看/隐藏标签管理、标签翻译自动跟随语言
- 站点：域名前置（需 native socket + TLS，`@ohos.net.http` 不支持自定义 SNI）
- 应用：多语言（原版 20+ 语言，需先抽约 300 条文案）、指纹锁已有、快捷搜索、批量下载

**C. 鸿蒙化（本版已起步）**
- 沉浸材质：底栏 / 首页顶栏 / 详情悬浮栏 / 4 个二级页页头已接入
- 待做：搜索页与设置页的页头、评论输入条与阅读器控制条的悬浮化、深色下的对比度微调

每批都按「改一页 → 编译 → 出包 → 真机确认」推进，不会一次性大改。下一批先做 A（列表 4 样式 + 详情缩略图网格），因为这两项在手机上最容易被感知。

### 产物与安装

```
dist/JHenTai-HarmonyOS-v1.1.0-api26-unsigned.hap    # 命令行构建（OpenHarmony product）
```

> 命令行产物是**未签名**的，手机上装不了。真机测试请二选一：
> 1. DevEco Studio 打开工程 → Project Structure → Signing Configs 勾选自动签名 → Run；
> 2. 或在本机配置好证书后执行 `.\build.ps1 -Product default`（`default` 是 runtimeOS=HarmonyOS 的 product）。

### 上机逐项检查（把不符合的条目告诉我）

| 检查点 | 期望 | 不符合说明什么 |
|---|---|---|
| 底栏 | 悬浮胶囊、能透出下方封面 | 完全不透明 → 材质没生效（看诊断区）；透明且没底板 → 回退层没画出来 |
| 首页顶栏 | 半透明，封面滚动时从底下透出 | 不透 → 走了实底回退；内容被顶栏截断 → `topInset` 需要加高 |
| 深色下的顶栏/底栏 | 深灰玻璃、不发白 | 发白 → 染色色相用错（深色必须用黑 alpha） |
| 系统切浅色 | 顶栏/底栏即时变亮，不用重启 | 不变 → 材质实例没重建 |
| 点卡片进详情 | 新页从右滑入，列表页左移缩小 | 无动画 → 楼层 `onAppear` 没触发；页面直接跳变 → 检查栈状态 |
| 详情里点「阅读」 | 阅读器从右滑入，返回时滑出 | 同上 |
| 快速连点卡片 | 只推入一层 | 叠两层 → push 去重失效 |
| 列表滚动 | 卡片依次淡入、不卡顿 | 卡顿 → 入场动画在长列表上偏重，可关掉 |

诊断区若显示「本机不支持沉浸材质」或「材质已被禁用」，那么底栏与顶栏会一直是模糊回退样式，
这是设备/系统层面的限制，不是布局问题。

