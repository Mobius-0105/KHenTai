import { EhConsts } from '../core/Consts';
import { Db } from '../core/Db';
import { Gallery } from '../core/Models';
import { HistoryItem, Prefs } from '../core/Prefs';
import { Theme } from '../core/Theme';
import { galleryBottomInset } from '../ui/GalleryListView';

/** 一页 50 条：库里有上限 200，最多翻四页 */
const PAGE: number = 50;

/**
 * 页面数值。
 * 工程里还没有 core/Tokens.ets，按 docs/V2-UI-SPEC.md 的令牌表取字面量：
 * SPACE_MD 12 / SPACE_LG 16 / RADIUS_CARD 16 / RADIUS_ROUND 999。
 */
const PAGE_PAD: number = 16;
const CARD_RADIUS: number = 16;
/** 列表首行与上方顶栏之间的呼吸（改造前是外层容器的 padding top） */
const LIST_TOP_GAP: number = 4;
/** 列表行高，封面 40x40 居中 */
const ROW_H: number = 56;
const COVER_SIZE: number = 40;
const COVER_RADIUS: number = 8;
/** 封面 40 + 间距 12，分隔线从文字起始处开始才像系统列表 */
const DIVIDER_INSET: number = 68;
const DIVIDER_W: number = 0.5;

/**
 * 观看历史。
 *
 * 数据来自本地数据库（core/Db.ets），不联网，所以没有 loading / 错误态，
 * 只有「有记录」和「没有记录」两种画面。
 *
 * 顶栏没有复用 PageHeader：历史页需要「清空」按钮，而 PageHeader 是公共组件，
 * 这段时间有别的地方在改它，这里自己写一行更省事。
 *
 * 列表按鸿蒙分组列表画：整张卡是一段背景，行高 56、行间 0.5 细线（最后一行为止不画）。
 *
 * 嵌入媒体库时的版本：
 *   - 本页不再自己让出顶部，列表整屏高、从屏幕顶端开始铺，滚到材质顶栏背后；
 *   - 顶部让位只由列表的 contentStartOffset 承担（媒体库顶栏高度由 LibraryPage 传入）；
 *   - 「清空」已经**不在列表里**了：它挂在媒体库顶栏右上角（沉浸材质胶囊），这样翻到列表
 *     深处也随时能点到，不会跟着内容滚走；本页只负责把「有没有记录 / 是否已进入确认态」
 *     同步出去，并执行真正的清理（详见下面 storage props 的注释）。
 */
@Component
export struct HistoryPage {
  onOpen: (g: Gallery) => void = (g: Gallery): void => {};
  /**
   * 嵌在「媒体库」的 Tabs 里：标题行由外层（LibraryPage 的沉浸材质顶栏）给，
   * 本页不再画自己的 header。默认 false，单独使用时行为不变。
   */
  @Prop embedded: boolean = false;
  /**
   * 媒体库顶栏高度（含状态栏）。
   * 由 LibraryPage 唯一计算后传入 —— 子页不再自己拼一遍，避免两处各算一次后错位。
   */
  @Prop headerHeight: number = 0;

  @State @Watch('onItemsChanged') private items: HistoryItem[] = [];
  /** 清空是破坏性操作，先点一次「清空」再点「确认」 */
  @State @Watch('onConfirmChanged') private confirmClear: boolean = false;
  /** 库里还有更多（上一页刚好满 50 条） */
  @State private more: boolean = false;

  /**
   * ================= 与媒体库顶栏共用的三个 AppStorage 键 =================
   *
   * 顶栏那颗「清空」胶囊画在 LibraryPage 里，事实和动作却都在本页。ArkUI 是单向数据流，
   * 父组件读不到子组件的 @State、也调不到子组件的私有方法，所以选 AppStorage 当中转：
   *
   *   historyCount    number   记录条数 —— 本页写（items 一变就同步），媒体库读它决定显隐。
   *   historyArmed    boolean  本页的 confirmClear 镜像 —— 媒体库读它把文案切成「确认」。
   *   historyClearReq number   媒体库写、本页读的自增信号 —— 点一下就是 +1，本页 @Watch 收到后
   *                            走 tapClear()，也就是原来那颗按钮的同一段逻辑。
   *
   * 为什么选它而不是 `@Prop onClearReady: (can) => void` 回调（二选一里选了这个）：
   *   1. TabContent 按需创建：用户没进过历史页时本页实例不存在，回调没机会发出，而媒体库需要的
   *      是一个随时可读的「当前有没有记录」；计数在 AppStorage 里，实例没建时是 0，正好不显示。
   *   2. 回调是一次性事件，本页被重建（切主题后材质重建、实例回收）后不会重放；AppStorage 是
   *      持久状态，重建后读到的仍是正确值。
   *   3. 函数只能挂普通成员（@Prop 不收函数签名），父级重建时普通成员不保证重新赋值；
   *      @StorageLink 是声明式的，不存在闭包指到旧实例的问题。
   *   4. 反向信号用「自增计数」而不是「布尔」：布尔置 true 后，第二次点击的值没变就触发不了
   *      @Watch；计数每次都是新值，连点两下（清空 -> 确认）也能分别送达。
   */
  @StorageLink('historyCount') private historyCount: number = 0;
  @StorageLink('historyArmed') private historyArmed: boolean = false;
  @StorageProp('historyClearReq') @Watch('onClearRequest') private clearReq: number = 0;

  aboutToAppear(): void {
    // 上一次实例可能在「已进入确认态」时被销毁，AppStorage 里的 armed 会留成 true；
    // 新实例的 confirmClear 一定是 false，这里先对齐一次，避免顶栏一进来就显示「确认」。
    this.historyArmed = this.confirmClear;
    this.reload();
  }

  /**
   * items 一变就同步条数。
   * 用 @Watch 挂在 items 上而不是在 reload/loadMore/remove/clearAll 里各写一行：
   * 以后再加删除路径（比如「清空某一天」）也不会漏掉同步 —— 漏一次就是「清空后按钮还在」。
   */
  private onItemsChanged(): void {
    this.historyCount = this.items.length;
  }

  /** confirmClear 镜像给顶栏，让胶囊在「清空 / 确认」之间切换；真正的状态仍只在本页 */
  private onConfirmChanged(): void {
    this.historyArmed = this.confirmClear;
  }

  /**
   * 媒体库顶栏胶囊的点击落点（@Watch 收到自增信号后调进来）。
   * 语义与列表里那颗按钮完全一致：第一下进入确认态，第二下才真清。
   */
  private onClearRequest(): void {
    this.tapClear();
  }

  /** 「清空 / 确认」的唯一实现：独立页头的按钮和媒体库顶栏的胶囊都走这里 */
  private tapClear(): void {
    if (this.items.length === 0) {
      this.confirmClear = false;
      return;
    }
    if (this.confirmClear) {
      this.clearAll();
    } else {
      this.confirmClear = true;
    }
  }

  private reload(): void {
    const page: HistoryItem[] = Db.history(PAGE, 0);
    this.items = page;
    this.more = page.length >= PAGE;
  }

  private loadMore(): void {
    if (!this.more) {
      return;
    }
    const page: HistoryItem[] = Db.history(PAGE, this.items.length);
    if (page.length === 0) {
      this.more = false;
      return;
    }
    this.items = this.items.concat(page);
    this.more = page.length >= PAGE;
  }

  private remove(gid: string): void {
    Db.deleteHistory(gid);
    const kept: HistoryItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].gid !== gid) {
        kept.push(this.items[i]);
      }
    }
    this.items = kept;
  }

  private clearAll(): void {
    Db.clearHistory();
    this.items = [];
    this.more = false;
    this.confirmClear = false;
  }

  /** 历史条目 -> 列表卡片用的 Gallery（详情页只认 gid/token 和展示字段） */
  private toGallery(it: HistoryItem): Gallery {
    const g: Gallery = new Gallery();
    g.gid = it.gid;
    g.token = it.token;
    g.title = it.title;
    g.thumbUrl = it.thumb;
    g.categoryLabel = it.category.length > 0 ? it.category : '其他';
    g.categoryColor = it.color.length > 0 ? it.color : '#8E8E93';
    g.url = EhConsts.index(Prefs.site()) + '/g/' + it.gid + '/' + it.token + '/';
    return g;
  }

  private pad(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }

  /** 时间列：当天只显示时分，同年省略年份 */
  private timeText(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts);
    const now: Date = new Date();
    const hm: string = this.pad(d.getHours()) + ':' + this.pad(d.getMinutes());
    const sameDay: boolean = d.getFullYear() === now.getFullYear() &&
      d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
    if (sameDay) {
      return '今天 ' + hm;
    }
    const md: string = this.pad(d.getMonth() + 1) + '-' + this.pad(d.getDate());
    if (d.getFullYear() === now.getFullYear()) {
      return md + ' ' + hm;
    }
    return d.getFullYear().toString() + '-' + md;
  }

  /**
   * 「清空 / 确认清空 / 取消」按钮组 —— 现在只给**独立使用**时的页头用。
   * 嵌入媒体库后这条动作已经提到顶栏胶囊，但逻辑不分叉：两边最终都调 tapClear()。
   */
  @Builder
  private clearActions() {
    if (this.items.length > 0) {
      Text(this.confirmClear ? '确认清空' : '清空')
        .fontSize(12)
        .fontColor(this.confirmClear ? Color.White : Theme.subText())
        .height(28)
        .textAlign(TextAlign.Center)
        .padding({ left: 12, right: 12 })
        .borderRadius(999)
        .backgroundColor(this.confirmClear ? Theme.accent() : Theme.card())
        .onClick(() => {
          this.tapClear();
        })
      if (this.confirmClear) {
        Text('取消')
          .fontSize(12)
          .fontColor(Theme.subText())
          .height(28)
          .textAlign(TextAlign.Center)
          .padding({ left: 12, right: 12 })
          .borderRadius(999)
          .backgroundColor(Theme.card())
          .onClick(() => {
            this.confirmClear = false;
          })
      }
    }
  }

  @Builder
  private header() {
    Row({ space: 8 }) {
      Text('观看历史')
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text())
      Blank()
      this.clearActions()
    }
    .width('100%')
    .height(52)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
    .alignItems(VerticalAlign.Center)
  }

  /** 行：封面 40x40 + 单行标题 + 分类/时间；右侧删除按钮保持独立，不触发打开详情 */
  @Builder
  private row(it: HistoryItem, showDivider: boolean) {
    Column() {
      Row({ space: 12 }) {
        Row({ space: 12 }) {
          Stack({ alignContent: Alignment.Center }) {
            if (it.thumb.length > 0) {
              Image(it.thumb)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
            } else {
              Text(it.category.substring(0, 2))
                .fontSize(11)
                .fontColor(Theme.subText())
            }
          }
          .width(COVER_SIZE)
          .height(COVER_SIZE)
          .borderRadius(COVER_RADIUS)
          .clip(true)
          .backgroundColor(Theme.line())

          Column({ space: 2 }) {
            Text(it.title.length > 0 ? it.title : it.gid)
              .fontSize(13)
              .fontColor(Theme.text())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            Row({ space: 6 }) {
              Text(it.category.length > 0 ? it.category : '其他')
                .fontSize(11)
                .fontColor(Theme.subText())
                .maxLines(1)
              Text(this.timeText(it.time))
                .fontSize(11)
                .fontColor(Theme.subText())
                .layoutWeight(1)
                .maxLines(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.onOpen(this.toGallery(it));
        })

        Text('删除')
          .fontSize(11)
          .fontColor(Theme.subText())
          .height(28)
          .textAlign(TextAlign.Center)
          .padding({ left: 12, right: 12 })
          .borderRadius(999)
          .backgroundColor(Theme.line())
          .onClick(() => {
            this.remove(it.gid);
          })
      }
      .width('100%')
      .height(ROW_H)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      if (showDivider) {
        Divider()
          .strokeWidth(DIVIDER_W)
          .color(Theme.line())
          .margin({ left: DIVIDER_INSET, right: 16 })
      }
    }
    .width('100%')
  }

  /**
   * 列表顶部让位：
   *   嵌入 = 媒体库顶栏（传入）+ 首行呼吸 —— 首项就是第一条记录（清空已移到顶栏，不占位）；
   *   独立 = 0（标题行在正常布局流里，容器另给 4 的呼吸）。
   */
  private listTopInset(): number {
    return this.embedded ? this.headerHeight + LIST_TOP_GAP : 0;
  }

  /** 媒体库顶栏「回到顶部」：LibraryPage 自增 tick，本页监听后把列表滚回顶部 */
  @StorageProp('libraryTopTick') @Watch('onTopTick') private libraryTopTick: number = 0;
  private listScroller: Scroller = new Scroller();
  /**
   * 不缓存「已上报」的本地布尔：媒体库切段时 LibraryPage 会把 libraryScrollY 归零，
   * 而本页列表还停在原处，本地缓存会认为「报过了」而永不再报 ——
   * 切回来顶栏的回顶钮就消失。改成与 AppStorage 现值比较，只写需要变化的那一次。
   */

  private onTopTick(): void {
    this.listScroller.scrollTo({ xOffset: 0, yOffset: 0,
      animation: { duration: 260, curve: Curve.Smooth } });
  }

  /**
   * 上报滚动位置给媒体库顶栏（读 `libraryScrollY` 决定回顶钮显隐）。
   * 只在跨过阈值时写一次：滚动是每帧回调，逐帧写 AppStorage 会连带顶栏材质一起重绘。
   */
  private reportLibraryScroll(): void {
    const y: number = Math.abs(this.listScroller.currentOffset().yOffset);
    const want: number = y > 480 ? 481 : 0;
    if ((AppStorage.get<number>('libraryScrollY3') ?? 0) !== want) {
      AppStorage.setOrCreate<number>('libraryScrollY3', want);
    }
    // 顶栏发丝线：内容是否已经顶到顶栏下沿（0.5 容差）。单独一条通道 —— 上面那组值
    // 被量化成 481/0，表达不了「离顶部 1vp」；只在布尔翻转时写，避免逐帧重绘顶栏。
    const hair: boolean = y > 0.5;
    if ((AppStorage.get<boolean>('libraryHair3') ?? false) !== hair) {
      AppStorage.setOrCreate<boolean>('libraryHair3', hair);
    }
  }

  build() {
    Column() {
      // 独立使用时带自己的标题行（页头右侧有清空按钮）；嵌入媒体库时标题在 LibraryPage 的固定顶栏里
      if (!this.embedded) {
        this.header()
      }

      if (this.items.length === 0) {
        Column({ space: 10 }) {
          Text('还没有浏览记录').fontSize(14).fontColor(Theme.subText())
          Text('从首页或搜索页打开一个画廊，就会记在这里')
            .fontSize(11)
            .fontColor(Theme.subText())
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        // 空态居中块避开悬浮底栏，口径与列表一致（原来写死 80，三段式导航下会短一截）
        .padding({ bottom: galleryBottomInset() })
      } else {
        Column() {
          List({ space: 0, scroller: this.listScroller }) {
            ForEach(this.items, (it: HistoryItem, idx: number) => {
              ListItem() {
                this.row(it, idx < this.items.length - 1)
              }
            }, (it: HistoryItem) => it.gid + it.time.toString())

            if (this.more) {
              ListItem() {
                Row() {
                  Text('继续下滑加载更多').fontSize(11).fontColor(Theme.subText())
                }
                .width('100%')
                .height(44)
                .justifyContent(FlexAlign.Center)
              }
            }
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor(Theme.card())
          // 嵌入时这张「卡」从屏幕顶端就开始了：圆角会正好开在屏幕两角、
          // 在材质背后露出两个缺口，所以嵌入式给 0；独立时保持原来的 16。
          .borderRadius(this.embedded ? 0 : CARD_RADIUS)
          .clip(true)
          // 顶部让位交给 contentStartOffset：它只挪内容起点，列表视口仍是整屏高，
          // 行才能滚到材质顶栏背后；写成容器 padding 会把视口截短，顶栏背后永远是底色。
          .contentStartOffset(this.listTopInset())
          // 底部让位只能补在内容末尾：写在容器 padding 上会把列表视口整体截短，
          // 滚动中途每一行都在底栏上沿被硬切，最后一行的「加载更多」也压不上去。
          .contentEndOffset(galleryBottomInset())
          .scrollBar(BarState.Off)
          .cachedCount(4)
          .onScrollIndex((start: number, end: number) => {
            if (end >= this.items.length - 3) {
              this.loadMore();
            }
          })
          // 上报滚动位置给媒体库顶栏（回顶钮显隐）
          .onDidScroll(() => {
            this.reportLibraryScroll();
          })
          // 重新可见时补报：切段会把 libraryScrollY 归零，而列表仍停在原处，
          // 没有滚动事件就不会重报 —— 切回来回顶钮会消失。
          .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, ratio: number) => {
            if (isVisible) {
              this.reportLibraryScroll();
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        // 嵌入时列表从屏幕顶端开始（顶部让位在 contentStartOffset 里），
        // 独立时保留 4 的呼吸（标题行紧挨着第一行会显得挤）
        .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.embedded ? 0 : LIST_TOP_GAP })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg())
    // tab 容器会一直保留页面实例，aboutToAppear 只跑一次；
    // 切回本 tab 时重新读一次库，否则刚看过的画廊不会出现在列表里
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, ratio: number) => {
      if (isVisible && ratio > 0) {
        this.reload();
      } else {
        // 切走/被详情页盖住就撤销待确认。
        // 顶栏胶囊只有一个入口（第二下即确认），离开再回来若还停在「确认」，那一触就是
        // 破坏性操作；这里只复位旗标，清理动作本身（clearAll）一点没动。
        this.confirmClear = false;
      }
    })
  }
}
