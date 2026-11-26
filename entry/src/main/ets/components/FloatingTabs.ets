import { Theme } from '../core/Theme';
import { MaterialPlane } from './MaterialPlane';

/**
 * 顶栏里的分段栏（material 胶囊）。
 *
 * 为什么嵌回顶栏（上一版是浮在内容上的独立层）：
 *  浮层必须走绝对定位（topOffset + zIndex），位置由每个调用页自己算「顶栏 + 8」，
 *  而顶栏本身又是一层压在内容上的材质 —— 两套坐标各算一次，滚动、切 tab、状态栏高度
 *  变化时很容易错开半个像素，视觉上就是顶栏下沿裂了一条缝。
 *  现在把它当成顶栏的第二行：顶栏高度由调用页的 headerHeight() 直接把它算进去，
 *  列表的 topInset 取同一个方法，顶栏画多高、内容就让多少，只有一个数值来源。
 *
 * 选中态为什么改成「一块滑动的胶囊」而不是每项各自变色：
 *  逐项 backgroundColor + 220ms 渐变会同时亮起两块（旧的那块在淡出），中间还有一个
 *  「两块半透明叠着」的过渡帧，看着像两块都选中了。改成**一个**独立色块、用位置动画从
 *  旧项滑到新项之后，任何一帧都只有一个选中块，滑动方向也直接表达「从哪切到哪」。
 *
 * 尺寸（与底栏胶囊同一套语言：高 40、全圆角、选中块 32）：
 *  左右 16 的边距不再由本组件自己扣（扣了会和顶栏行的内边距叠成 32），
 *  本组件 width('100%')，边距交给调用方那一行统一给。
 *
 * 选中块为什么要比「一格」窄（72%）：
 *  块宽等于项宽时，块的左右边界正好压在两个文字的划分线上，4 个 tab 连起来看就是一整条
 *  被切成 4 段的实心方块，选中块和轨道之间没有任何留白，读起来像「这一格被填满了」而不是
 *  「这一格被选中」。取 72% 后每侧各让出 14% 的项宽，块与相邻文字之间有了不贴边的呼吸，
 *  块自己仍然完整包住选中文字（13 号字 2 个汉字约 26vp，项宽 84 时块宽 60.5，留得住）。
 *  之所以用比例而不是固定内缩量：屏幕 320~800vp、还能分屏，固定值在窄屏会挤掉文字、
 *  宽屏又几乎看不出内缩。
 */

/** 胶囊高度：选中块 32 + 上下各 4 的呼吸 */
export const FLOATING_TABS_HEIGHT: number = 40;
/** 胶囊与标题行、与胶囊下方内容之间的间距 */
export const FLOATING_TABS_GAP: number = 8;
/** 选中块高度 */
const ITEM_HEIGHT: number = 32;
/** 选中块与胶囊内壁的间距（只作用在纵向上：横向按项宽比例内缩，见 PILL_W_RATIO） */
const ITEM_PAD: number = 4;
const FONT_ITEM: number = 13;
/** compact（排行时间 chip 那种小胶囊）的字号：同样的 4 等分，字数少、项宽窄，13 会顶边 */
const FONT_ITEM_COMPACT: number = 12;
/**
 * 选中块宽度占单宽的比例。
 *
 * 0.72 是视觉实测值：块左边界不再压在项边界上，左右各留出 14% 项宽的缝，
 * 既让「一个块在滑动」这件事看得清，又不会小到包不住选中文字。
 */
const PILL_W_RATIO: number = 0.72;
const RADIUS_FULL: number = 999;
/**
 * 点按切换时的滑块时长：160。
 *
 * 为什么从 260 降到 160：滑块只是在「跟随一个已经发生的选中变化」，用户手指按下去那一刻
 * 内容已经要切了；再用 260 的缓动慢慢挪，读起来就是「内容先到、滑块后到」。160 与底栏
 * 高亮、搜索页语言色块同一档，点一下的反馈是「立刻落位 + 只看得见最后一小段滑动」。
 *
 * 注意这条时长**只服务点按**：横滑切页的时长见 SLIDE_TRACK_MS。
 */
const SLIDE_TAP_MS: number = 160;
/**
 * 横滑切页时的滑块时长：100。
 *
 * 为什么不是 0：上一版为了「和页面同步」把这条分支改成直接赋值（pillX = target，无插值），
 * 结果成了「旧块硬切消失、新块硬切出现」—— 0 秒里块没有任何中间坐标，眼睛看到的不是
 * 一次移动，而是两帧闪烁。100ms 的 Smooth 只留一小段位移，块是「被带过去」的，
 * 途中始终只有一个块、而不是一灭一亮。
 *
 * 为什么不是 160（和点按同档）：横滑时页面本身已经在动，滑块只是跟随；再花 160 就成了
 * 「内容到了、块还在半路」，比点按更明显地滞后。100 短到几乎贴住页面滑动，
 * 又长到能看见方向。
 */
const SLIDE_TRACK_MS: number = 100;
/**
 * 「跨度过大就直落」的阈值：1.5 个项宽。
 *
 * 相邻切一格的距离正好是 1 个项宽，所以 ≤1.5 一定是一次正常的「换一格」。
 * 超过它只可能来自外部重置 / 首帧落位 / 调用方一次跳多项 —— 这种距离插值会让块横穿
 * 整条轨道从一端扫到另一端，中间还压过好几个没选中的文字，比硬切更难看，因此直接落位。
 */
const SLIDE_JUMP_ITEMS: number = 1.5;
/**
 * 文字颜色渐变：与**点按**滑块同档 160。
 *
 * 原来是 220（比滑块略短，先变色再落位）；滑块改成 160 之后若字色仍是 220，视觉上是
 * 「块已经到了、字还在慢慢亮」，反而像掉帧。点按的反馈应该是一件事：块到位、字亮起。
 * 横滑时滑块是 100，字色仍留 160：60 的差在这么短的距离里看不出来，
 * 而压到 100 会让字色变化快到像瞬间换色。
 */
const ANIM_FG_MS: number = 160;
/**
 * 判定「这次选中变化是点按还是横滑」的时间窗（毫秒）。
 *
 * 点按路径全部在本组件内部起头：onClick 记下时间戳 → 调用方 onSelect 改选中值 →
 * @Prop 回灌 → @Watch 触发，整条链在同一轮事件里走完（实测间隔远小于 50ms）。
 * 横滑路径由调用方的 Tabs.onChange 驱动，与上一次点按毫无时间关系。
 * 取 400 是给主线程忙（列表取数、材质重建）留余量；标记用完即清，所以哪怕点完之后
 * 隔很久才滑，也不会被误判成点按。
 */
const TAP_WINDOW_MS: number = 400;

@Component
export struct FloatingTabs {
  /** 分段文案：调用方按原有顺序给，本组件不增删项 */
  @Prop items: string[] = [];
  /**
   * 当前选中下标，与内层 Tabs 的 index 同源。
   *
   * 需要 @Watch：色块的位置动画必须在「值变了」的那一刻用 animateTo 包住一次状态写入，
   * 光靠 .position 跟着 @Prop 重算，ArkUI 只会把新坐标直接摆上去（没有过渡）。
   */
  @Prop @Watch('onSelectedChanged') selected: number = 0;
  /**
   * 紧凑模式：字号 13 → 12，其余尺寸（高 40、块 32、72% 块宽）完全一致。
   *
   * 给排行页那行「日/月/年/总」用：它是同一套分段语言（材质胶囊 + 一个滑动块），
   * 只是文案短、容器窄（168vp 分 4 格），13 号字在 42vp 的格里会顶到边缘。
   * 只缩字号、不缩高度，是为了让它和 tab 胶囊仍然共处一条视觉基线。
   */
  @Prop compact: boolean = false;
  /**
   * 是否由本组件自己给轨道描一圈边（MaterialPlane 的 `edge: true`）。
   *
   * 默认 true，保持既有调用点不变。**调用方在外部另加白边时必须传 false**：
   * 两条边完全同界，半透明白压在 15% 黑上会混成偏灰的一圈，比纯白暗一档 ——
   * 真机上读作「边缘发脏」，而不是「一条更亮的边」。
   * 首页与媒体库顶部改成白边（Theme.btnEdge）之后都传了 false。
   */
  @Prop edgeRing: boolean = true;
  /**
   * 点选回调。
   *
   * 用普通成员而不是 @Prop：@Prop 只接值类型，函数会被当成不可观测属性，
   * 且 ArkTS 的 @Prop 不接受函数签名，编译期就报错。
   */
  onSelect: (i: number) => void = (i: number): void => {};

  /**
   * 主题订阅位：Theme.accent()/subText() 读的是 Prefs（不可观测），
   * 只有订阅 Theme.refresh() 写入的 'themeDark'，切主题时本组件才会被标记重绘。
   */
  @StorageProp('themeDark') private themeDark: boolean = false;

  /**
   * 轨道实测宽度（onAreaChange 写入）。
   *
   * 为什么不写死：顶栏左右各 16、屏幕 320~800vp、还能分屏/旋转，单宽只能由总宽除项数得到；
   * 写死一个数在别的宽度上不是留缝就是溢出。
   */
  @State private trackW: number = 0;
  /**
   * 滑动块的 x 坐标（vp，从胶囊左内壁起算）。
   *
   * 单独存成 @State 而不是每次现算 selected * 单宽：只有「状态写入被 animateTo 包住」时
   * 位置才会做插值动画；直接在 build 里算，属性变化是瞬时的，看不到滑动。
   */
  @State private pillX: number = 0;
  /**
   * 最近一次「点按」的时间戳（0 = 没点过）。
   *
   * 本组件拿不到调用方 Tabs 的滑动进度，也无法从 @Prop 上区分「谁改了 selected」，
   * 但两种来源的**起点**不同：点按一定先经过本组件的 onClick（在下面记时间戳），
   * 横滑则完全由调用方 Tabs 的 onChange 驱动、本组件没被碰过。所以在 onSelectedChanged
   * 里看「刚刚有没有点过我」就能区分，不需要改动调用方。
   * 用完立刻清零：它是「这一次变化」的标记，不是持续状态。
   */
  private tapAt: number = 0;

  /** 单宽 = 实测总宽 / 项数（这是**格的宽**，选中块比它窄，见 pillW） */
  private itemW(): number {
    const n: number = this.items.length;
    return n > 0 ? this.trackW / n : 0;
  }

  /** 选中块宽 = 单宽 × 72%（左右各留 14% 单宽，块不再和项边界重合） */
  private pillW(): number {
    return this.itemW() * PILL_W_RATIO;
  }

  /**
   * 选中块目标 x：先落到项的左边界，再向右让出「格宽 - 块宽」的一半。
   *
   * 这样块永远以项中心为轴对称内缩：换项时块中心走的仍然是 itemW 的整数倍，
   * 滑动距离和文字移动距离一致，不会出现「块滑得比文字快/慢」的错觉。
   */
  private targetX(): number {
    const iw: number = this.itemW();
    if (iw <= 0) {
      return 0;
    }
    return this.selected * iw + (iw - iw * PILL_W_RATIO) / 2;
  }

  /**
   * 选中下标变化：动色块位置，字色由每个 Text 自己的 .animation(160) 负责。
   *
   * 两种来源、两种时长，外加一个「跨度过大」的例外：
   *  - 点按（本次 onClick 记过 tapAt）：160ms，让「从哪格切到哪格」看得清楚；
   *  - 横滑切页（调用方 Tabs.onChange 驱动 selected，本组件没被点过）：100ms，
   *    不是 0 —— 0 就是上一版的「硬切消失 + 硬切出现」，也不是 160 —— 那样会明显
   *    滞后于正在滑动的页面（理由见常量注释）；
   *  - 跨度 > 1.5 个项宽（外部重置 / 首帧落位 / 一次跳多项）：无论来源都**直接落位**，
   *    这种距离插值会横穿整条轨道，比硬切更难看。
   */
  private onSelectedChanged(): void {
    const fromTap: boolean = this.tapAt > 0 && Date.now() - this.tapAt <= TAP_WINDOW_MS;
    this.tapAt = 0;
    const target: number = this.targetX();
    const iw: number = this.itemW();
    // iw 还没量到（首帧）时 target 恒为 0，等同于「直接落位」，交给下面的赋值分支
    if (iw > 0 && Math.abs(target - this.pillX) > iw * SLIDE_JUMP_ITEMS) {
      this.pillX = target;
      return;
    }
    const ms: number = fromTap ? SLIDE_TAP_MS : SLIDE_TRACK_MS;
    animateTo({ duration: ms, curve: Curve.Smooth }, () => {
      this.pillX = target;
    });
  }

  /**
   * 轨道宽度变化（首帧布局 / 旋转 / 分屏）：重算单宽并把块**直接**摆到目标位置。
   *
   * 这里刻意不用 animateTo：宽度变化不是「用户切换」，让块从旧坐标滑过来会被误解成一次
   * 切换；首帧更会看到块从左边缘窜到中间。
   */
  private relayout(w: number): void {
    this.trackW = w;
    this.pillX = this.targetX();
  }

  /**
   * 选中块底色：accent（蓝）。
   *
   * 为什么把底色反过来（原来是 card 底 + accent 字）：
   *  1) 浅色下 card 是纯白、轨道本身也是浅玻璃，块几乎融进轨道，只靠字色变蓝来提示选中，
   *     远看像「这行字被高亮了」而不是「这一格被选中」；换成 accent 实底后块是一个明确的色块，
   *     选中位置在 4 个 tab 里一眼可辨。
   *  2) 蓝底 + 白字的对比度比「白底 + 蓝字」更高（浅色 #2F6BD8 / 白 ≈ 5.9:1，
   *     而白底上的蓝字要受材质半透影响，实际对比会再掉一截），13 号小字更吃这个差别。
   *  3) 与搜索页的语言/范围选择器、收藏页的分类 chip 统一成「accent 底 + 白字」一套选中语言。
   * 两个分支同值，只为建立 themeDark 依赖。
   */
  private pillBg(): ResourceColor {
    if (this.themeDark) {
      return Theme.accent();
    }
    return Theme.accent();
  }

  /**
   * 分段文字色：选中白、未选中 subText。
   *
   * 选中态跟着滑块改成白字（滑块已是 accent 蓝底，蓝底上再写蓝字会立刻糊成一片）。
   * 返回 ResourceColor 而不是 string：Color.White 是枚举，不是 '#RRGGBB' 字符串。
   * 两个分支同值，只为建立 themeDark 依赖。
   */
  private chipFg(i: number): ResourceColor {
    if (this.themeDark) {
      return this.selected === i ? Color.White : Theme.subText();
    }
    return this.selected === i ? Color.White : Theme.subText();
  }

  /** 项字号：compact 时小一号，其它尺寸不变 */
  private itemFont(): number {
    return this.compact ? FONT_ITEM_COMPACT : FONT_ITEM;
  }

  /**
   * 单个分段块。
   *
   * 只收下标（数字），文案与选中态都从 this 读：@Builder 的值参数不会随父状态更新，
   * 传 label/selected 这类值会让高亮停在旧项上。
   *
   * 选中底不在这里画（底色由那一个滑动块承担），这一层只剩字色/字重 —— 少了每项的
   * 背景切换，也就没有「新旧两块同时淡入淡出」的中间帧。
   */
  @Builder
  private item(index: number) {
    Text(this.items[index])
      .layoutWeight(1)
      .height(ITEM_HEIGHT)
      .fontSize(this.itemFont())
      .fontColor(this.chipFg(index))
      .fontWeight(this.selected === index ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .animation({ duration: ANIM_FG_MS, curve: Curve.Smooth })
      .onClick(() => {
        // 同项重复点击不回调：避免调用方多做一次 changeIndex + 重新取数
        if (this.selected !== index) {
          // 先盖戳再回调：@Watch 会在 selected 回灌时读它，判断这次变化是点按而非横滑
          this.tapAt = Date.now();
          this.onSelect(index);
        }
      })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 胶囊底：真材质（kind 'tabbar'）；材质不可用时 MaterialPlane 自己退回实底 + 厚模糊。
      // 这里是**真实布局节点**，不是 .background(builder) 里的绘制指令 —— 材质作用域
      // 只有在参与布局时才会被创建，塞进 background 会整块消失（真机上验证过）。
      // edge 由 edgeRing 控制：分段胶囊是浮在内容上的一小块玻璃，浅色下不描边就看不出
      // 轨道边界；但调用方若已在外面加了白边，这里必须关掉（否则两条边同界、混成灰线）。
      MaterialPlane({ kind: 'tabbar', radius: RADIUS_FULL, planeHeight: FLOATING_TABS_HEIGHT, edge: this.edgeRing })

      // 滑动选中块：整个分段栏只有这一块底色。
      // 宽 = 单宽 × 72%、x = 选中下标 × 单宽 + 半个「格宽 - 块宽」、y 固定 4。
      // 层级靠 Stack 顺序：它在文字**之前**声明，所以永远压在文字下面。
      //
      // 块**不画自己的边**：块整个落在胶囊轨道内部，离轨道内壁不足 1vp，
      // 之前那条 0.7 的 edge() 描边和轨道自己的边并排成两条几乎重合的细线，
      // 真机上读作「边缘发脏 / 双线错位」，而不是「一块实心块压在上面」。
      // 块的轮廓交给两样东西就够了：比轨道更实、且有色相的 accent() 底色 + 材质自身的高光。
      Row()
        .width(this.pillW())
        .height(ITEM_HEIGHT)
        .borderRadius(RADIUS_FULL)
        .backgroundColor(this.pillBg())
        .position({ x: this.pillX, y: ITEM_PAD })
        // 不吃点击：点在块上也要落到上层的 Text（Text 才有 onSelect）
        .hitTestBehavior(HitTestMode.None)

      Row() {
        ForEach(this.items, (label: string, i: number) => {
          this.item(i)
        }, (label: string, i: number) => 'ft-' + i.toString())
      }
      .width('100%')
      .height(FLOATING_TABS_HEIGHT)
      // 只留纵向 4：横向单宽按总宽等分，块的横向内缩由 PILL_W_RATIO 从块宽里让，
      // 不能再被内边距缩掉（缩了就变成「格宽 - 2×pad」再乘 72%，两个量缠在一起）
      .padding({ top: ITEM_PAD, bottom: ITEM_PAD })
      .alignItems(VerticalAlign.Center)
      // 双保险：即使以后有人把文字行挪到块前面，文字也仍然在上
      .zIndex(1)
    }
    .width('100%')
    .height(FLOATING_TABS_HEIGHT)
    .borderRadius(RADIUS_FULL)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // Area.width 是 Length（string | number），统一转成 vp 数值再比较
      const w: number = parseFloat(newValue.width.toString());
      if (!isNaN(w) && Math.abs(w - this.trackW) > 0.5) {
        this.relayout(w);
      }
    })
  }
}
