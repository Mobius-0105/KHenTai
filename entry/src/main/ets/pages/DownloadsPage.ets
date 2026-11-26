import { Gallery } from '../core/Models';
import { Theme } from '../core/Theme';
import { DlStatus, DlTask, Downloader } from '../core/Downloader';
import { PageHeader } from '../components/PageHeader';
import { MaterialPlane } from '../components/MaterialPlane';
import { galleryBottomInset } from '../ui/GalleryListView';

/**
 * 页面数值。
 * 工程里还没有 core/Tokens.ets，按 docs/V2-UI-SPEC.md 的令牌表取字面量：
 * SPACE_SM 8 / SPACE_MD 12 / SPACE_LG 16 / RADIUS_CARD 16 / RADIUS_ROUND 999。
 */
const PAGE_PAD: number = 16;
const CARD_GAP: number = 12;
const CARD_RADIUS: number = 16;
const CARD_PAD: number = 12;
const COVER_W: number = 56;
const COVER_H: number = 76;
const COVER_RADIUS: number = 8;
/** 进度条：高 4、圆角 2 */
const BAR_H: number = 4;
/** 批量胶囊定宽：'全部继续' 4 字 @11 号 + 两侧内边距，留一点余量 */
const PILL_W: number = 66;
const PILL_H: number = 32;
const PILL_GAP: number = 8;
const PILL_RADIUS: number = 999;
/**
 * 顶栏批量胶囊的字号与左右内距。
 *
 * 为什么比卡内的 action()（11 号 / 左右 12）更窄：顶栏标题行只有 48，
 * 动作槽本身还固定 32 高（PageHeader.HEADER_ACTION_HEIGHT），
 * 两颗「全部继续 / 全部暂停」并排时若沿用卡内尺寸，会一路顶到标题上去。
 * 11 + 左右 8 让两颗胶囊合计约 128 宽，标题「媒体库」仍有一半以上的宽度。
 */
const HEADER_PILL_FONT: number = 11;
const HEADER_PILL_PAD: number = 8;
/** 仅 Wi-Fi 卡高度 */
const WIFI_CARD_H: number = 56;

/**
 * 下载管理页。
 *
 * 任务列表由 Downloader 持有，这里只做两件事：订阅变化重读列表、把按钮翻译成操作。
 * 进度条不用动画（大列表里每帧重排不值得），直接按百分比画宽度。
 *
 * 卡片右上「更多」或长按卡片可以设置优先级 / 分组、检查更新；
 * 整张卡可点即打开离线阅读器（原来的「阅读」按钮已删，见 taskCard 的注释）。
 *
 * 顶部固定行的归属（谁让位给谁）：
 *   「全部继续 / 全部暂停」不再占内容区一行，统一放进**顶栏右侧的动作区**：
 *   - 独立模式：本页自带 PageHeader，走它的 actions 槽（32 高的槽位，胶囊正好同高）；
 *   - 嵌入模式：本页**没有页头**，顶栏是 LibraryPage 的沉浸材质头，
 *     那两颗胶囊由 LibraryPage 摆进它的标题行（组件是 DlBulkPills，两份顶栏共用同一份视觉）。
 *   于是列表首项只剩「仅 Wi-Fi 卡 56」，它随内容一起滚走，topInset 只让出
 *   「媒体库顶栏 + 呼吸」这一处，不会出现「行在但点不到」。
 */
@Component
export struct DownloadsPage {
  /** 打开阅读器时的出口：把画廊交给上层（离线目录由 ReaderPage 自己找） */
  onOpenLocal: (g: Gallery) => void = (g: Gallery): void => {};
  /**
   * 嵌在「媒体库」的 Tabs 里：页头由外层（LibraryPage 的沉浸材质顶栏）给，
   * 本页不再渲染 PageHeader。默认 false，单独使用时行为不变。
   */
  @Prop embedded: boolean = false;
  /**
   * 媒体库顶栏高度（含状态栏）。
   * 由 LibraryPage 唯一计算后传入 —— 子页不再自己拼一遍，避免两处各算一次后错位。
   */
  @Prop headerHeight: number = 0;

  @State private tasks: DlTask[] = [];
  /** 仅 Wi-Fi 下载（持久化在 Prefs 的 dl_wifi_only） */
  @State private wifiOn: boolean = false;
  /** 设置面板是否展开 */
  @State private showSheet: boolean = false;
  /** 面板正在编辑的任务 key */
  @State private editKey: string = '';
  @State private editTitle: string = '';
  @State private editPriority: number = 1;
  @State private editGroup: string = '';
  @State private toast: string = '';
  private toastTimer: number = -1;
  private listener: () => void = (): void => {
    this.reload();
  };

  aboutToAppear(): void {
    Downloader.init();
    Downloader.onChange(this.listener);
    this.wifiOn = Downloader.wifiOnly();
    this.reload();
  }

  aboutToDisappear(): void {
    Downloader.offChange(this.listener);
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  private reload(): void {
    // 重新取一次数组，触发 @State 刷新
    const list: DlTask[] = Downloader.list();
    const copy: DlTask[] = [];
    for (let i = 0; i < list.length; i++) {
      copy.push(list[i]);
    }
    this.tasks = copy;
  }

  private showToast(text: string): void {
    this.toast = text;
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout(() => {
      this.toast = '';
      this.toastTimer = -1;
    }, 2200);
  }

  private toGallery(t: DlTask): Gallery {
    const g: Gallery = new Gallery();
    g.gid = t.gid;
    g.token = t.token;
    g.title = t.title;
    g.url = 'https://e-hentai.org/g/' + t.gid + '/' + t.token + '/';
    g.thumbUrl = t.thumb;
    g.categoryLabel = t.category;
    g.categoryColor = t.color;
    g.pages = t.total;
    return g;
  }

  /**
   * 列表顶部让位 = 媒体库顶栏（传入）+ 首行呼吸。
   *
   * 仅 Wi-Fi 卡是列表**首项**（随内容滚走），不单独占让位量；
   * 独立模式下页头在流里，列表不需要再让。
   */
  private listTopInset(): number {
    return this.embedded ? this.headerHeight + CARD_GAP : 0;
  }

  /** 媒体库顶栏「回到顶部」：LibraryPage 自增 tick，本页监听后把列表滚回顶部 */
  @StorageProp('libraryTopTick') @Watch('onTopTick') private libraryTopTick: number = 0;
  private listScroller: Scroller = new Scroller();
  /**
   * 不缓存「已上报」的本地布尔：媒体库切段时 LibraryPage 会把 libraryScrollY 归零，
   * 而本页列表还停在原处，本地缓存会认为「报过了」而永不再报 ——
   * 切回来顶栏的回顶钮就消失。改成与 AppStorage 现值比较，只写需要变化的那一次。
   */
  /**
   * 子按钮被点过：卡片根的 onClick 看到它就跳过本次。
   *
   * ArkTS 的 `ClickEvent` 上没有 `stopPropagation()`（编译期直接报 “不存在该属性”），
   * 所以不能用事件冒泡阻断，改成「子按钮先立标记，卡片根消费一次」。
   * 必须在卡片根里同步清零，否则下一次真正的整卡点击会被吞掉。
   */
  private childTapped: boolean = false;
  /**
   * 待确认删除的任务 key（'' = 没有）。
   *
   * 删除会连带清掉沙箱里的文件（`remove(key, true)`），不可恢复，点一下就执行太轻。
   * 沿用工具页那套内联确认：第一次点把文案换成「确认删除?」，同一条再点才真删，
   * 3 秒不动复位。做成按 key 的而不是布尔：列表里有多张卡，布尔会让所有卡同时进入确认态。
   */
  @State private pendingDeleteKey: string = '';
  private pendingDeleteTimer: number = -1;

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
    if ((AppStorage.get<number>('libraryScrollY2') ?? 0) !== want) {
      AppStorage.setOrCreate<number>('libraryScrollY2', want);
    }
    // 顶栏发丝线：内容是否已经顶到顶栏下沿（0.5 容差）。单独一条通道 —— 上面那组值
    // 被量化成 481/0，表达不了「离顶部 1vp」；只在布尔翻转时写，避免逐帧重绘顶栏。
    const hair: boolean = y > 0.5;
    if ((AppStorage.get<boolean>('libraryHair2') ?? false) !== hair) {
      AppStorage.setOrCreate<boolean>('libraryHair2', hair);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        if (this.embedded) {
          // 嵌入：整屏内容，没有外层 top padding —— 列表从屏幕顶端开始铺，
          // 卡片才能滚到媒体库材质顶栏背后（顶栏由 LibraryPage 叠在上面）。
          if (this.tasks.length === 0) {
            // 空态没有可滚动内容：Wi-Fi 卡 + 提示块按流布局，
            // 顶部让出顶栏高度（这里不是列表，所以用 padding 而不是 contentStartOffset）
            Column() {
              Column() {
                this.wifiCard()
              }
              .width('100%')
              .padding({ left: PAGE_PAD, right: PAGE_PAD })

              this.emptyBlock()
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ top: this.headerHeight + CARD_GAP })
          } else {
            this.taskList()
          }
        } else {
          // 独立：页头在正常布局流里，行为与改造前一致
          PageHeader({
            title: '下载',
            subtitle: '已完成 ' + this.doneCount().toString() + ' / ' + this.tasks.length.toString(),
            showBack: false
          }) {
            // 顶栏右侧动作槽：PageHeader 的动作槽固定 32 高，DlBulkPills 里的胶囊也是 32，
            // 正好落在槽里，不会把 56 的标题行顶满。
            DlBulkPills()
          }

          // 仅 Wi-Fi 下载：鸿蒙设置式的单行卡，开关在右侧
          Column() {
            this.wifiCard()
          }
          .width('100%')
          .padding({ left: PAGE_PAD, right: PAGE_PAD })
          .margin({ top: CARD_GAP, bottom: CARD_GAP })

          if (this.tasks.length === 0) {
            this.emptyBlock()
          } else {
            this.taskList()
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg())
      .bindSheet(this.showSheet, this.settingsSheet(), {
        height: 360,
        dragBar: true,
        showClose: false,
        backgroundColor: Theme.card()
      })

      if (this.toast.length > 0) {
        Text(this.toast)
          .fontSize(12)
          .fontColor(Theme.bg())
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(PILL_RADIUS)
          .backgroundColor(Theme.text())
          .margin({ bottom: 24 })
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 任务列表。
   *
   * 嵌入模式只剩一行固定内容进列表头部：仅 Wi-Fi 卡 56（批量操作行已提到本页
   * 之外的媒体库顶栏，见文件头注释），所以列表首项就是 Wi-Fi 卡，任务卡直接接在它后面，
   * 中间不会留出一段原来是按钮行的空白。
   * 独立模式页头与 Wi-Fi 卡都在流内，列表里只放任务卡。
   */
  @Builder
  private taskList() {
    List({ space: CARD_GAP, scroller: this.listScroller }) {
      // 首项：仅 Wi-Fi 卡（嵌入时随内容滚走）
      if (this.embedded) {
        ListItem() {
          this.wifiCard()
        }
      }

      ForEach(this.tasks, (t: DlTask) => {
        ListItem() {
          this.taskCard(t)
        }
      }, (t: DlTask) => t.key() + '|' + t.status.toString() + '|' + t.done.toString() +
        '|' + t.total.toString() + '|' + t.priority.toString() + '|' + t.retries.toString() +
        '|' + t.group + '|' + t.error + '|' + t.lastError)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
    // 顶部让位交给 contentStartOffset：它只挪内容起点，列表视口仍是整屏高，
    // 卡片才能从顶栏背后滚过去；写在 padding 上会把视口截短，材质背后就永远是底色。
    .contentStartOffset(this.listTopInset())
    // 底部让位同理：只在内容末尾补留白，卡片能正常从底栏下面穿过去。
    .contentEndOffset(galleryBottomInset())
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
    .scrollBar(BarState.Off)
  }

  /** 仅 Wi-Fi 下载卡：独立模式放流内、嵌入模式当列表首项，两处共用同一份 */
  @Builder
  private wifiCard() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('仅 Wi-Fi 下载').fontSize(13).fontColor(Theme.text())
        Text(this.wifiWaiting() ? '有任务在等待 Wi-Fi' : '移动网络下不开始新任务')
          .fontSize(11)
          .fontColor(Theme.subText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.wifiOn })
        .selectedColor(Theme.accent())
        .onChange((v: boolean) => {
          this.wifiOn = v;
          Downloader.setWifiOnly(v);
          this.showToast(v ? '仅 Wi-Fi 下载：已开启' : '仅 Wi-Fi 下载：已关闭');
        })
    }
    .width('100%')
    .height(WIFI_CARD_H)
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    .backgroundColor(Theme.card())
    .borderRadius(CARD_RADIUS)
  }

  /** 空态：嵌入与独立共用，底部避开悬浮底栏 */
  @Builder
  private emptyBlock() {
    Column({ space: 8 }) {
      Text('还没有下载任务').fontSize(14).fontColor(Theme.subText())
      Text('在画廊详情页点「下载」即可离线保存整本')
        .fontSize(11)
        .fontColor(Theme.subText())
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    // 空态的居中块也要避开悬浮底栏：用统一口径而不是写死的 80
    .padding({ bottom: galleryBottomInset() })
  }

  private doneCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].status === DlStatus.DONE) {
        n++;
      }
    }
    return n;
  }

  private wifiWaiting(): boolean {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].status === DlStatus.PENDING && this.tasks[i].error === '等待 WiFi') {
        return true;
      }
    }
    return false;
  }

  /** 打开设置面板：把当前任务值拷进编辑态；优先级点了立即生效，分组在「完成」时落库 */
  private openSheet(t: DlTask): void {
    this.editKey = t.key();
    this.editTitle = t.title;
    this.editPriority = t.priority;
    this.editGroup = t.group;
    this.showSheet = true;
  }

  private closeSheet(): void {
    if (this.editKey.length > 0) {
      Downloader.setGroup(this.editKey, this.editGroup);
    }
    this.showSheet = false;
  }

  // ------------------------------------------------------------ 卡片
  @Builder
  private taskCard(t: DlTask) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Image(t.thumb)
          .width(COVER_W)
          .height(COVER_H)
          .objectFit(ImageFit.Cover)
          .borderRadius(COVER_RADIUS)
          .backgroundColor(Theme.line())

        Column({ space: 4 }) {
          Text(t.title)
            .fontSize(13)
            .fontColor(Theme.text())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(t.statusLabel() + ' · ' + t.done.toString() + ' / ' +
            (t.total > 0 ? t.total.toString() : '?') + ' 页')
            .fontSize(11)
            .fontColor(t.status === DlStatus.ERROR ? Theme.text() : Theme.subText())
            .fontWeight(t.status === DlStatus.ERROR ? FontWeight.Medium : FontWeight.Normal)
            .maxLines(1)
            .width('100%')
          // 优先级 / 分组 / 重试次数
          Row({ space: 6 }) {
            this.tag(t.priorityLabel())
            if (t.group.length > 0) {
              this.tag(t.group)
            }
            if (t.retries > 0) {
              this.tag('重试 ' + t.retries.toString() + ' 次')
            }
          }
          .width('100%')
          if (t.lastError.length > 0 && t.status !== DlStatus.DONE) {
            Text(t.lastError)
              .fontSize(11)
              .fontColor(Theme.subText())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 「更多」入口：长按卡片同样能打开，这里给个显式按钮方便发现。
        // 它在整卡点击区里，必须先阻断冒泡 —— 否则点「⋯」会连带触发卡片根的 onClick 跳进阅读页。
        Text('⋯')
          .fontSize(16)
          .fontColor(Theme.subText())
          .padding({ left: 6, right: 2, top: 2, bottom: 2 })
          .onClick(() => {
            // 子按钮先立标记，卡片根的 onClick 消费一次后清零（见 childTapped 的注释）
            this.childTapped = true;
            this.openSheet(t);
          })
      }
      .width('100%')
      .gesture(LongPressGesture().onAction((event: GestureEvent) => {
        this.openSheet(t);
      }))

      if (t.error.length > 0) {
        Text(t.error)
          .fontSize(11)
          .fontColor(Theme.subText())
          .maxLines(2)
          .width('100%')
      }

      // 进度：高 4、圆角 2，底色是细线色，前景按状态取主色/次要色
      Stack({ alignContent: Alignment.Start }) {
        Column().width('100%').height(BAR_H).borderRadius(BAR_H / 2).backgroundColor(Theme.line())
        Column()
          .width(t.percent().toString() + '%')
          .height(BAR_H)
          .borderRadius(BAR_H / 2)
          .backgroundColor(t.status === DlStatus.DONE ? Theme.subText() : Theme.accent())
      }
      .width('100%')
      .height(BAR_H)

      // 这一行在整卡点击区**里面**：每个按钮都在 action() 里自己 stopPropagation，
      // 所以点「暂停 / 继续 / 检查更新 / 删除」不会连带跳进阅读页。
      Row({ space: PILL_GAP }) {
        if (t.status === DlStatus.RUNNING || t.status === DlStatus.PENDING) {
          this.action('暂停', () => {
            Downloader.pause(t.key());
          })
        } else if (t.status === DlStatus.PAUSED || t.status === DlStatus.ERROR) {
          this.action('继续', () => {
            Downloader.resume(t.key());
          })
        }
        // 原来的「阅读」按钮已删除：它的落点放大成整张卡（见下方根节点的 onClick）
        this.action('检查更新', () => {
          this.checkUpdate(t);
        })
        Blank()
        // 删除按钮**不走 action(label, ...)**：@Builder 的值参数在 build 时求值，
        // 状态变了不会重新算 —— 表现就是「第一次点，文案没变」。
        // 这里把 Text 直接写在卡片里，label 从 `this.pendingDeleteKey` 现读，
        // 状态一变这块就重绘。
        Text(this.pendingDeleteKey === t.key() ? '确认删除?' : '删除')
          .height(PILL_H)
          .fontSize(11)
          .fontColor(this.pendingDeleteKey === t.key() ? Theme.accent() : Theme.subText())
          .textAlign(TextAlign.Center)
          .padding({ left: 12, right: 12 })
          .borderRadius(PILL_RADIUS)
          .backgroundColor(Theme.line())
          .onClick(() => {
            this.childTapped = true;
            if (this.pendingDeleteKey === t.key()) {
              this.clearPendingDelete();
              this.pendingDeleteKey = '';
              Downloader.remove(t.key(), true);
              return;
            }
            this.pendingDeleteKey = t.key();
            this.clearPendingDelete();
            this.pendingDeleteTimer = setTimeout(() => {
              this.pendingDeleteKey = '';
              this.pendingDeleteTimer = -1;
            }, 3000);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(CARD_PAD)
    .borderRadius(CARD_RADIUS)
    .backgroundColor(Theme.card())
    // 整卡可点：卡片展示的就是这一本书，点标题 / 封面 / 进度条这些空白处时，
    // 用户预期与点「阅读」一致 —— 打开它。按钮只剩暂停/继续/删除这类需要精确命中的
    // 动作，占了底部一小条，剩下的整块面积不该是死的。
    // 按下反馈不能省：整卡可点却没有任何视觉变化时，用户不知道自己到底点没点上，
    // 尤其在列表里滑动一段后手指刚落下的那一瞬。
    .stateStyles({ pressed: this.cardPressed })
    // 与原来的「阅读」按钮共用 openReader 这一个入口，不复制那段跳转逻辑
    .onClick(() => {
      // 子按钮（暂停/继续/删除/⋯）刚被点过：这次是冒泡上来的同一击，直接吞掉。
      // 必须清标记，否则下一次真正的整卡点击会被误吞（点了没反应）。
      if (this.childTapped) {
        this.childTapped = false;
        return;
      }
      this.openReader(t);
    })
  }

  /** 整卡按下：只降透明度、不换底色 —— 换底色在深浅主题下都会闪一下 */
  @Styles
  cardPressed() {
    .opacity(0.85)
  }

  /** 清掉删除确认的定时器（确认执行、切卡、组件销毁时都要调） */
  private clearPendingDelete(): void {
    if (this.pendingDeleteTimer >= 0) {
      clearTimeout(this.pendingDeleteTimer);
      this.pendingDeleteTimer = -1;
    }
  }

  /**
   * 打开离线阅读器：整卡点击与（已删除的）「阅读」按钮共用这一个入口。
   *
   * 为什么保留 done > 0 这道判断：原来那颗「阅读」按钮只在 done > 0 时才出现，
   * 一页都没落盘时打开阅读器会退到在线阅读，与「点本地下载卡」的预期不符。
   * 这是原按钮自带的显示条件，不是新加的业务判断。
   */
  private openReader(t: DlTask): void {
    if (t.done <= 0) {
      return;
    }
    this.onOpenLocal(this.toGallery(t));
  }

  private async checkUpdate(t: DlTask): Promise<void> {
    const msg: string = await Downloader.checkUpdate(t.key());
    this.showToast(msg);
  }

  // ------------------------------------------------------------ 设置面板
  @Builder
  private settingsSheet() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('任务设置')
          .fontSize(14)
          .fontColor(Theme.text())
        Blank()
        Text('完成')
          .fontSize(12)
          .fontColor(Theme.accent())
          .height(28)
          .textAlign(TextAlign.Center)
          .padding({ left: 12, right: 12 })
          .borderRadius(PILL_RADIUS)
          .backgroundColor(Theme.line())
          .onClick(() => {
            this.closeSheet();
          })
      }
      .width('100%')

      Text(this.editTitle)
        .fontSize(11)
        .fontColor(Theme.subText())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Text('优先级（数字小的先下载）')
        .fontSize(11)
        .fontColor(Theme.subText())
        .width('100%')

      Row({ space: PILL_GAP }) {
        this.priorityChip('高优先', 0)
        this.priorityChip('普通', 1)
        this.priorityChip('低优先', 2)
      }
      .width('100%')

      Text('分组')
        .fontSize(11)
        .fontColor(Theme.subText())
        .width('100%')

      TextInput({ text: this.editGroup, placeholder: '输入分组名，留空即不分组' })
        .fontSize(12)
        .fontColor(Theme.text())
        .placeholderColor(Theme.subText())
        .backgroundColor(Theme.line())
        .borderRadius(8)
        .height(36)
        .width('100%')
        .onChange((v: string) => {
          this.editGroup = v;
        })

      if (Downloader.groups().length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(Downloader.groups(), (g: string) => {
            Text(g)
              .fontSize(11)
              .fontColor(Theme.subText())
              .height(28)
              .textAlign(TextAlign.Center)
              .padding({ left: 12, right: 12 })
              .margin({ right: PILL_GAP, bottom: PILL_GAP })
              .borderRadius(PILL_RADIUS)
              .backgroundColor(Theme.line())
              .onClick(() => {
                this.editGroup = g;
              })
          }, (g: string) => g)
        }
        .width('100%')
      }

      Row({ space: PILL_GAP }) {
        this.action('清除分组', () => {
          this.editGroup = '';
          if (this.editKey.length > 0) {
            Downloader.setGroup(this.editKey, '');
          }
        })
        Blank()
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 })
  }

  @Builder
  private priorityChip(label: string, value: number) {
    Text(label)
      .height(PILL_H)
      .fontSize(12)
      .fontColor(this.editPriority === value ? Color.White : Theme.subText())
      .textAlign(TextAlign.Center)
      .padding({ left: 14, right: 14 })
      .borderRadius(PILL_RADIUS)
      .backgroundColor(this.editPriority === value ? Theme.accent() : Theme.line())
      .onClick(() => {
        this.editPriority = value;
        if (this.editKey.length > 0) {
          Downloader.setPriority(this.editKey, value);
        }
      })
  }

  /** 卡片上的小标签 */
  @Builder
  private tag(label: string) {
    Text(label)
      .fontSize(10)
      .fontColor(Theme.subText())
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .borderRadius(6)
      .backgroundColor(Theme.line())
  }

  /** 卡片内的操作：32 高小胶囊 */
  @Builder
  private action(label: string, onTap: () => void) {
    Text(label)
      .height(PILL_H)
      .fontSize(11)
      .fontColor(Theme.subText())
      .textAlign(TextAlign.Center)
      .padding({ left: 12, right: 12 })
      .borderRadius(PILL_RADIUS)
      .backgroundColor(Theme.line())
      // 卡片根节点现在整块可点（点开阅读器），这一行按钮在它的命中区里面，
      // 所以**每个**按钮都要自己阻断冒泡：不阻断的话，点「暂停」会先暂停、
      // 紧接着又因为冒泡触发根节点的 onClick 一路跳进阅读页。
      // 放在这一处而不是逐个按钮写：暂停/继续/检查更新/删除 全走这个 builder，
      // 将来再加按钮也自动带上这层保护。设置面板里的按钮同样走它 ——
      // 那里没有外层点击，多一次 stopPropagation 无副作用。
      .onClick(() => {
        // 同上：不走事件冒泡（ClickEvent 没有 stopPropagation），改用标记
        this.childTapped = true;
        onTap();
      })
  }
}

/**
 * 下载批量操作的两颗小胶囊：全部继续 / 全部暂停。
 *
 * 为什么从 DownloadsPage 的 @Builder 抽成独立 struct：
 * 它要挂在**两个不同的顶栏**上 ——
 *   1) 独立模式：DownloadsPage 自己的 PageHeader 动作槽（槽高 32，胶囊正好同高）；
 *   2) 嵌入模式：下载页自己没有页头，顶栏是 LibraryPage 的沉浸材质头，
 *      只有 LibraryPage 那边能把按钮摆进标题行右侧。
 * 两处各写一份 @Builder 的话，字号 / 内距 / 主色改一处就会漂一档。
 *
 * 为什么自己订阅 Downloader：TabContent 是按需创建的，用户没进过「下载」段时
 * DownloadsPage 实例并不存在；把可用性判断收在组件内部，顶栏按钮就不会因为
 * 「父页还没建」而消失或点了没反应。
 *
 * 可用性口径与搬走前完全一致（不是新判断）：
 *   - 一个任务都没有时整行不出现（原来那一行渲染的条件就是 tasks.length > 0）；
 *   - 只有存在「暂停 / 出错」的任务时才出现「全部继续」（原 hasResumable()）。
 * 注意这里是**不出现**而不是置灰：与原来的做法一致，置灰需要额外的禁用态样式。
 */
@Component
export struct DlBulkPills {
  @State private hasTasks: boolean = false;
  @State private resumable: boolean = false;

  private listener: () => void = (): void => {
    this.sync();
  };

  aboutToAppear(): void {
    Downloader.onChange(this.listener);
    this.sync();
  }

  aboutToDisappear(): void {
    Downloader.offChange(this.listener);
  }

  /** 从 Downloader 取一次快照，算出两颗胶囊的显示条件 */
  private sync(): void {
    const list: DlTask[] = Downloader.list();
    this.hasTasks = list.length > 0;
    let can: boolean = false;
    for (let i = 0; i < list.length; i++) {
      const s: DlStatus = list[i].status;
      if (s === DlStatus.PAUSED || s === DlStatus.ERROR) {
        can = true;
        break;
      }
    }
    this.resumable = can;
  }

  build() {
    Row({ space: PILL_GAP }) {
      // 两颗都是**系统沉浸材质**（MaterialPlane + edge: true 给白描边）。
      //
      // 宽度钉死在 66：文字固定 4 个汉字、字号固定，定宽既不会挤，也不可能被
      // MaterialPlane 内部的 width('100%') 反向撑成整行 —— 宽度只有一个来源。
      // （上一版为了让宽度正确，把材质换成了 backgroundEffect，观感就散了；
      //   这次换回材质，靠定宽解决依赖环。）
      if (this.resumable) {
        Stack({ alignContent: Alignment.Center }) {
          MaterialPlane({ kind: 'header', radius: PILL_RADIUS, planeHeight: PILL_H })
          Text('全部继续')
            .height(PILL_H)
            .fontSize(HEADER_PILL_FONT)
            .fontColor(Theme.accent())
            .textAlign(TextAlign.Center)
            .onClick(() => {
              Downloader.resumeAll();
            })
        }
        .width(PILL_W)
        .height(PILL_H)
        .borderRadius(PILL_RADIUS)
        // 白色描边：材质自带的 edge 取的是 Theme.edge()（浅色下是 15% 黑），
        // 这里要的是「玻璃上的一圈白线」，直接用 btnEdge。
        .border({ width: 0.7, color: Theme.btnEdge() })
        .shadow(Theme.floatShadow())
        // if 增删节点本身没有过渡，不挂 transition 会「凭空跳出」
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ y: -4 }))
          .animation({ duration: 160, curve: Curve.Smooth }))
      }
      Stack({ alignContent: Alignment.Center }) {
        MaterialPlane({ kind: 'header', radius: PILL_RADIUS, planeHeight: PILL_H })
        Text('全部暂停')
          .height(PILL_H)
          .fontSize(HEADER_PILL_FONT)
          .fontColor(Theme.subText())
          .textAlign(TextAlign.Center)
          .onClick(() => {
            Downloader.pauseAll();
          })
      }
      .width(PILL_W)
      .height(PILL_H)
      .borderRadius(PILL_RADIUS)
      .border({ width: 0.7, color: Theme.btnEdge() })
      .shadow(Theme.floatShadow())
    }
    // 无任务时整行收起：Visibility.None 不占位，顶栏右侧不会留一段空的槽
    .visibility(this.hasTasks ? Visibility.Visible : Visibility.None)
  }
}
