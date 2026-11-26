import { EhApi } from '../core/EhApi';
import { Cookies } from '../core/Cookies';
import { Site } from '../core/Consts';
import { History, Prefs, SearchHistory } from '../core/Prefs';
import { Theme, ThemeMode } from '../core/Theme';
import { TagTrans, TagTransTick } from '../core/TagTrans';
import { Material } from '../core/Material';
import { KEY_DOWNLOAD, KEY_IMAGE, KEY_TORRENT, Storage, StorageUsage } from '../core/Storage';
import { ListStyles } from '../ui/GalleryCard';
import { MaterialSurface } from '../components/MaterialSurface';
import { deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { UPDATE_PRIVATE, Update, UpdateError, UpdateInfo } from '../core/Update';

/**
 * 页面数值。
 *
 * 工程里还没有 core/Tokens.ets，所以按 docs/V2-UI-SPEC.md 的令牌表取字面量：
 * SPACE_SM 8 / SPACE_MD 12 / SPACE_LG 16 / RADIUS_CARD 16 / RADIUS_ROUND 999。
 * 出令牌文件后这些常量应改成引用，避免两处各写一套。
 */
const PAGE_PAD: number = 16;
const CARD_GAP: number = 12;
const CARD_RADIUS: number = 16;
/**
 * 卡片描边宽度（vp）。
 *
 * 0.5 在真机上几乎看不见（尤其深色主题下 Theme.line() 只有 8% 白），
 * 等于没有描边；1.0 是「看得见但不抢内容」的档位，和输入框那类 0.5~0.8 的
 * 内部控制线拉开层级 —— 卡片的边是**块与块的边界**，不是行内的细分隔。
 */
const CARD_EDGE: number = 1;
const ROW_H: number = 56;
const PILL_H: number = 32;
const PILL_GAP: number = 8;
const PILL_RADIUS: number = 999;
const DIVIDER_W: number = 0.5;
/** 悬浮胶囊底栏会盖住页面底部，留出这段空白 */
const BOTTOM_PAD: number = 80;
/**
 * 标题行 48（TITLE_BAR_HEIGHT）/ 大标题 22（FONT_SIZE_H2）。
 *
 * 为什么从 56 收到 48：原来那 56 要装「标题 22 + 版本号副标题 11」两行；副标题删掉后
 * 只剩一行 22 号字，再留 56 就是标题上下各空 17，顶栏看着发虚。48 仍能让单行标题居中。
 */
const BAR_ROW_HEIGHT: number = 48;
const FONT_TITLE: number = 22;
/**
 * 危险操作红字。
 *
 * 主题色板里没有「危险色」，而清理缓存是不可撤销操作，必须用一眼能识别的红，
 * 所以这里单独给一个字面量（不放进 Theme，避免色板继续膨胀）。
 */
const DANGER_TEXT: string = '#FF8A8A';
/** 二次确认的有效窗口：3 秒内不再点就自动还原 */
const CONFIRM_MS: number = 3000;
/** 存储管理卡片的行顺序：下载 / 种子 / 图片，与 Storage.scan() 的返回顺序一致 */
const STORE_KEYS: string[] = [KEY_DOWNLOAD, KEY_TORRENT, KEY_IMAGE];
/** 行标题与 STORE_KEYS 同序，写死在常量里，避免 @Builder 再收一个 label 参数 */
const STORE_LABELS: string[] = ['下载缓存', '种子缓存', '图片缓存'];
const STORE_PENDING: string = '计算中…';
/** 统计失败或超时未回的占位：宁可显示「—」也不能永远停在「计算中…」 */
const STORE_UNKNOWN: string = '—';
/**
 * 「数据」卡片的两行：键名只在本文件内部用来区分待确认目标，行标题与键同序，
 * 写死在常量里同样是为了让 @Builder 不必再收一个文案参数。
 */
const DATA_KEYS: string[] = ['search', 'history'];
const DATA_LABELS: string[] = ['清空搜索历史', '清空浏览记录'];
/**
 * 胶囊选项的分组编号。
 *
 * 为什么不让 pill() 直接收 `selected: boolean`：@Builder 的值参数只在创建时求值一次，
 * 父组件 @State 变化不会重新传进去，选中态会永远停在首次渲染的那一帧。
 * 所以 pill() 只收「组别 + 下标」这类不会变的常量，选中与否在 builder 体内读 this.xxx。
 */
const PILL_SITE: number = 0;
const PILL_LOGIN: number = 1;
const PILL_THEME: number = 2;
/**
 * Cookie 登录表单：三格字段（会员 ID / 密码散列 / igneous）。
 *
 * 文案与键同序、写死在常量里，理由同 PILL_* —— @Builder 只收下标，文案在体内取。
 */
const COOKIE_LABELS: string[] = ['会员 ID', '密码散列', 'igneous'];
const COOKIE_HINTS: string[] = ['Member ID', 'Pass Hash', 'igneous'];
/** 左侧标签宽度：三个词里最长的是 igneous，留够一眼可读 */
const COOKIE_LABEL_W: number = 76;
/** Cookie 表单里按钮/输入框的统一高度 */
const COOKIE_BTN_H: number = 40;
/** 账号卡片头部一行的高度（标题 + 右侧状态胶囊） */
const CARD_HEAD_H: number = 52;
/**
 * 存储统计的 UI 超时：超过这个时间还没回，就先把「计算中…」置成「—」。
 * 扫描是异步的（要遍历目录），但界面不能永远停在计算中 —— 10s 是「慢但不至于误判」的折中。
 */
const STORE_UI_TIMEOUT_MS: number = 10000;
/**
 * 设置：站点、登录、外观、列表样式、标签、数据、存储、诊断、关于。
 *
 * 版式按鸿蒙「分组列表」来：一个分组 = 卡上方 12 号次要色标题 + 一张 16 圆角卡片，
 * 卡内每行 56 高、行间 0.5 细线（首尾不画），右侧统一是开关或 ›。
 * 卡片不裁切、行内自带左右 16 内边距，这样点击热区能顶到卡片边缘。
 * 卡片靠 0.5 的细描边与同色浅底区分，所以不裁切也不会糊成一片。
 */
@Component
export struct SettingsPage {
  /**
   * 打开「标签集与观看标签」页。
   *
   * 设置页自己不管导航（页面栈在 Index 里），所以只留一个回调。
   * 这里不用 @Prop：ArkTS 的 @Prop 只支持可观察的数据类型，函数类型要用普通成员
   * （PageHeader 的 onBack 也是这么写的），默认空实现保证没接线时点上去不崩。
   */
  onOpenTagSets: () => void = (): void => {};

  @State private site: Site = Site.EH;
  @State private loggedIn: boolean = false;
  @State private cookieSummary: string = '';
  @State private igneousReady: boolean = false;

  @State private userName: string = '';
  @State private password: string = '';
  @State private memberId: string = '';
  @State private passHash: string = '';
  @State private igneous: string = '';
  @State private busy: boolean = false;
  @State private toast: string = '';
  @State private showCookieForm: boolean = false;
  @State private themeMode: ThemeMode = ThemeMode.AUTO;
  /** 列表样式，取值见 ListStyles；存 Prefs 的 'list_style' */
  @State private listStyle: string = ListStyles.COMPACT;
  @State private tagTransOn: boolean = false;
  @State private tagTransMsg: string = '';
  /** 标签名是否翻译（界面语言 = zh 才翻）。存 Prefs 的 'lang' */
  @State private langZh: boolean = true;
  /** 真机自检用：材质/系统版本/算力档，用户在手机上截图就能定位问题 */

  /**
   * 主题订阅位。
   *
   * Theme.refresh() 会把当前深浅写进 AppStorage 的 'themeDark'（键名与 V2 的 Index 约定一致），
   * 而 Theme.xxx() 本身读的是 Prefs，不可观测。订阅它，跟随系统时系统切深色、
   * 或别处改了主题，本页才会重绘；本页自己点 pill 改的是下面的 @State themeMode。
   */
  @StorageProp('themeDark') private themeDark: boolean = false;

  /** 三类缓存的显示文案：进页面先「计算中…」，scan 回来后换成实际大小 */
  @State private storeSizes: string[] = [STORE_PENDING, STORE_PENDING, STORE_PENDING];
  /** 正处于二次确认的分类键；空串表示没有待确认的操作 */
  @State private storeConfirmKey: string = '';
  /** 清理进行中：期间忽略新的点击，避免并发删同一批文件 */
  @State private storeBusy: boolean = false;
  /** 「数据」卡片里正处于二次确认的键；空串表示没有待确认的操作 */
  @State private dataConfirmKey: string = '';
  /**
   * 「关于」卡里的当前版本，形如 `1.33.6 (1002946)`。
   *
   * 运行时从 bundleManager 读，不再维护手抄常量 —— 那个常量（1.8.5）在 25 个版本里
   * 一直没人同步，屏上显示的版本和真装的包对不上，比不显示更糟。
   */
  @State private versionText: string = '';
  /** 检查更新进行中：用来把行文案换成「检查中…」并禁用点击，避免连点发多次请求 */
  @State private checking: boolean = false;

  private toastTimer: number = -1;
  private confirmTimer: number = -1;
  /**
   * 纯 versionName（不带 versionCode），只给版本比较用，不参与渲染。
   * 不放进 @State：它变了不会影响任何节点，多一个可观察字段只是多一次无谓的脏标记。
   */
  private versionRaw: string = '';
  /**
   * 「数据」卡片自己的确认计时器。
   *
   * 为什么不与存储管理共用 confirmTimer：两张卡是互不相干的两组操作，
   * 共用一个定时器会让「点了存储确认、再去点数据确认」把前者的定时器顶掉，
   * 前者就永远停在确认态。各自一份，互不干扰。
   */
  private dataConfirmTimer: number = -1;
  /**
   * 统计序号：每次重新统计自增。
   * scan 是异步的，而清理完会马上再扫一次；不带序号的话，先发出去的那次可能后回来，
   * 把刚扫到的新数字又覆盖成旧值。
   */
  private storeScanSeq: number = 0;
  private storeScanTimer: number = -1;

  aboutToAppear(): void {
    this.site = Prefs.site();
    this.themeMode = Theme.mode();
    // 老版本存的是 'thumb'，normalize 之后 chip 才能正确高亮
    this.listStyle = ListStyles.normalize(Prefs.listStyle());
    this.tagTransOn = Prefs.bool('tag_trans', false);
    this.langZh = Prefs.str('lang', 'zh') !== 'en';
    this.refreshState();
    this.memberId = Cookies.get('ipb_member_id');
    this.passHash = Cookies.get('ipb_pass_hash');
    this.igneous = Cookies.get('igneous');
    this.refreshStoreSizes();
    this.loadVersion();
  }

  aboutToDisappear(): void {
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
    if (this.confirmTimer >= 0) {
      clearTimeout(this.confirmTimer);
      this.confirmTimer = -1;
    }
    if (this.dataConfirmTimer >= 0) {
      clearTimeout(this.dataConfirmTimer);
      this.dataConfirmTimer = -1;
    }
    if (this.storeScanTimer >= 0) {
      clearTimeout(this.storeScanTimer);
      this.storeScanTimer = -1;
    }
    // 页面销毁后 scan 的回调还可能回来，序号自增让它们全部作废
    this.storeScanSeq++;
  }

  private refreshState(): void {
    this.loggedIn = Cookies.isLoggedIn();
    this.cookieSummary = Cookies.summary();
    this.igneousReady = Cookies.hasIgneous();
  }

  private showToast(text: string): void {
    this.toast = text;
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout(() => {
      this.toast = '';
      this.toastTimer = -1;
    }, 2600);
  }

  private async doPasswordLogin(): Promise<void> {
    if (this.userName.trim().length === 0 || this.password.length === 0) {
      this.showToast('请填写账号和密码');
      return;
    }
    this.busy = true;
    try {
      const err: string = await EhApi.loginPassword(this.userName, this.password);
      this.showToast(err.length === 0 ? '登录成功' : err);
      this.refreshState();
      this.memberId = Cookies.get('ipb_member_id');
      this.passHash = Cookies.get('ipb_pass_hash');
      this.igneous = Cookies.get('igneous');
    } catch (e) {
      this.showToast((e as Error).message);
    }
    this.busy = false;
  }

  /**
   * 复制当前登录态的三个 Cookie 值（`k=v; k=v` 形式）。
   *
   * 只拼站点认识的三个键：member_id / pass_hash 必有，igneous 有才带。
   * 与「粘贴」不同，写剪贴板不需要任何权限，不会出现点了没反应的情况。
   */
  private async copyCookie(): Promise<void> {
    const parts: string[] = [];
    const id: string = Cookies.get('ipb_member_id');
    const hash: string = Cookies.get('ipb_pass_hash');
    const ig: string = Cookies.get('igneous');
    if (id.length > 0) {
      parts.push('ipb_member_id=' + id);
    }
    if (hash.length > 0) {
      parts.push('ipb_pass_hash=' + hash);
    }
    if (ig.length > 0) {
      parts.push('igneous=' + ig);
    }
    if (parts.length === 0) {
      this.showToast('没有可复制的 Cookie');
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,
        parts.join('; '));
      await pasteboard.getSystemPasteboard().setData(data);
      this.showToast('已复制 Cookie');
    } catch (e) {
      this.showToast('复制失败：' + (e as Error).message);
    }
  }

  private async doCookieLogin(): Promise<void> {
    this.busy = true;
    try {
      const err: string = await EhApi.loginByCookie(this.memberId, this.passHash, this.igneous);
      this.showToast(err.length === 0 ? 'Cookie 已保存' : err);
      this.refreshState();
    } catch (e) {
      this.showToast((e as Error).message);
    }
    this.busy = false;
  }


  /** 第 index 格当前值：下标与 COOKIE_LABELS 同序 */
  private cookieValue(index: number): string {
    if (index === 0) {
      return this.memberId;
    }
    return index === 1 ? this.passHash : this.igneous;
  }

  /** 写第 index 格：粘贴和手动输入都走这里，避免三处各写一段 if */
  private setCookieField(index: number, v: string): void {
    if (index === 0) {
      this.memberId = v;
      return;
    }
    if (index === 1) {
      this.passHash = v;
      return;
    }
    this.igneous = v;
  }

  /** 已登录时卡片上显示的会员 ID 摘要：前 6 位 + 省略号，够辨认又不会把整串亮在屏幕上 */
  private memberPreview(): string {
    const id: string = this.memberId.length > 0 ? this.memberId : Cookies.get('ipb_member_id');
    if (id.length === 0) {
      return '—';
    }
    return id.length > 6 ? id.substring(0, 6) + '…' : id;
  }

  // ------------------------------------------------------------ 关于 / 检查更新
  /**
   * 读本包的版本号。
   *
   * getBundleInfoForSelfSync 是同步的、查自己不需要任何权限，进页面读一次即可，
   * 不必为它引入异步时序。读失败（理论上只有打包异常）退回占位文案而不是抛出去 ——
   * 「关于」卡显示不出来不该让整页崩掉。
   */
  private loadVersion(): void {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.versionRaw = info.versionName;
      this.versionText = info.versionName + ' (' + info.versionCode.toString() + ')';
    } catch (e) {
      // 兜底成 0.0.0：这样任何 Release 都会判成「有新版」，用户至少还能自己下包，
      // 而不是因为读不到版本号就永远「已是最新」。
      this.versionRaw = '0.0.0';
      this.versionText = '未知版本';
    }
  }

  /**
   * 检查更新。
   *
   * 结果分四种，全部走系统 toast / 弹窗（不用页内 toast）：这一步可能在弹窗之上，
   * 而页内 hint 会被弹窗遮住，看起来像「点了没反应」。
   *
   * checking 必须在 finally 里复位：失败分支是 return/throw，写在 try 之后会漏掉，
   * 之后每次点击都会被「进行中」挡掉。
   */
  private async doCheckUpdate(): Promise<void> {
    if (this.checking) {
      return;
    }
    this.checking = true;
    try {
      const info: UpdateInfo | null = await Update.checkLatest(this.versionRaw);
      if (info === null) {
        this.systemToast('已是最新版本');
        return;
      }
      this.showUpdateDialog(info);
    } catch (e) {
      // UpdateError 只带一个种类串；其它意外异常（理论上没有）按网络失败处理，
      // 不把内部错误码抛给用户。
      const kind: string = e instanceof UpdateError ? (e as UpdateError).kind : '';
      this.systemToast(kind === UPDATE_PRIVATE ? '仓库未公开，无法检查更新' : '检查更新失败，请稍后重试');
    } finally {
      this.checking = false;
    }
  }

  /**
   * 新版提示。
   *
   * 「去下载」放 primaryButton（高亮的默认按钮位）：「稍后」只是不打断用户的出口，
   * 检查更新的目的就是拿到新包，主按钮不该是「算了」。
   */
  private showUpdateDialog(info: UpdateInfo): void {
    // 走 UIContext.showAlertDialog 而不是全局 AlertDialog.show：
    // 后者自 API 26 起已废弃，且不绑窗口时在分屏下可能弹到别的窗口。
    this.getUIContext().showAlertDialog({
      title: '发现新版本 ' + info.version,
      message: info.body,
      primaryButton: {
        value: '去下载',
        action: () => {
          this.openUrl(info.url);
        }
      },
      secondaryButton: {
        value: '稍后',
        action: () => {
        }
      }
    });
  }

  /**
   * 用系统浏览器打开链接。
   *
   * 走 viewData 的隐式 Want，不指定具体应用（系统会让用户选或直接用默认浏览器）。
   * startAbility 是异步的：同步抛（Want 非法）与异步 reject（没有应用能处理该 uri）
   * 都要兜住，否则失败时界面一动不动。
   */
  private openUrl(url: string): void {
    if (url.length === 0) {
      this.systemToast('该版本没有提供下载地址');
      return;
    }
    try {
      const ctx: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const want: Want = { action: 'ohos.want.action.viewData', uri: url };
      ctx.startAbility(want).catch(() => {
        this.systemToast('无法打开浏览器');
      });
    } catch (e) {
      this.systemToast('无法打开浏览器');
    }
  }

  /**
   * 系统 toast。
   *
   * 用 UIContext 的 getPromptAction() 而不是全局 promptAction.showToast：
   * 后者在 API 18 起已标记废弃，且不带 UIContext 时在多窗口下会弹到别的窗口上。
   */
  private systemToast(text: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: text, duration: 2000 });
    } catch (e) {
      // UIContext 还没绑好（页面已销毁等极端情况）：退回页内 toast，至少不静默
      this.showToast(text);
    }
  }

  // ------------------------------------------------------------ 版式小件
  private statusBar(): number {
    const v: number | undefined = AppStorage.get<number>('statusBarHeight');
    return v === undefined ? 0 : v;
  }

  /**
   * 固定顶栏高度（含状态栏）：标题行 48，滚动内容从这里往下开始。
   *
   * 副标题（「版本 x.y.z」）删掉后，这里也跟着从「状态栏 + 56」收到「状态栏 + 48」；
   * 滚动内容的 top padding 直接读本方法，没有另写死一个数，所以只改这一处就对齐了。
   */
  private headerHeight(): number {
    return this.statusBar() + BAR_ROW_HEIGHT;
  }

  /**
   * 页面底色。
   *
   * 两个分支同色：读 themeDark 是为了让 build() 与 AppStorage 的 'themeDark' 建立依赖
   * （Theme.bg() 内部读 Prefs，不可观测），取色规则仍统一交给 Theme。
   */
  private pageBg(): string {
    if (this.themeDark) {
      return Theme.bg();
    }
    return Theme.bg();
  }

  /** 组标题：画在卡片上方，12 号次要色，左右各缩进 4 让它和卡内文字对齐 */
  @Builder
  private groupTitle(title: string) {
    Text(title)
      .fontSize(12)
      .fontColor(Theme.subText())
      .width('100%')
      .padding({ left: 4, right: 4, top: 12, bottom: 8 })
  }

  /** 行间分隔线：只插在行与行之间，卡片首尾不画 */
  @Builder
  private dividerLine() {
    Divider()
      .strokeWidth(DIVIDER_W)
      .color(Theme.line())
  }

  /** 导航行：左侧主标题（可带一行说明），右侧 › */
  @Builder
  private navRow(label: string, hint: string, onTap: () => void) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(label).fontSize(13).fontColor(Theme.text())
        if (hint.length > 0) {
          Text(hint)
            .fontSize(11)
            .fontColor(Theme.subText())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›').fontSize(16).fontColor(Theme.subText())
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    .onClick(onTap)
  }

  /**
   * 标签翻译语言行：右侧显示当前值而不是箭头（就地切换）。
   *
   * 原先是通用 valueRow(label, value, onTap)，值由调用处算好再传 —— @Builder 的值参数
   * 只会求值一次，切换后右侧永远显示旧语言。这里改成不收任何状态参数，体内读 this.langZh。
   */
  @Builder
  private langRow() {
    Row({ space: 8 }) {
      Text('标签翻译语言').fontSize(13).fontColor(Theme.text()).layoutWeight(1)
      Text(this.langZh ? '中文' : '英文（不翻译）').fontSize(12).fontColor(Theme.subText())
      Text('›').fontSize(16).fontColor(Theme.subText())
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      this.langZh = !this.langZh;
      Prefs.put('lang', this.langZh ? 'zh' : 'en');
      // 语言决定 TagTrans.translate 是否生效（英文界面不套中文标签库），
      // 所以切完要让列表卡片重算一次 chip 文案
      TagTransTick.bump();
      this.showToast(this.langZh ? '标签名将显示中文' : '标签名保持英文原文');
    })
  }

  /**
   * 「当前版本」行：与 langRow 同版式（左标题、右值），右侧是运行时读到的
   * `versionName (versionCode)`。
   *
   * 值从 this.versionText 读而不是当参数传：@Builder 的值参数只在创建时求值一次，
   * loadVersion() 是在 aboutToAppear 里跑的，传值会让这一行永远停在空串上。
   */
  @Builder
  private versionRow() {
    Row({ space: 8 }) {
      Text('当前版本').fontSize(13).fontColor(Theme.text()).layoutWeight(1)
      Text(this.versionText)
        .fontSize(12)
        .fontColor(Theme.subText())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 16, right: 16 })
  }

  /**
   * 「检查更新」行：右侧平时是 ›，检查中换成「检查中…」并整行禁用。
   *
   * 禁用用 .enabled(false) 而不只是 if (this.checking) return：
   * 只拦回调的话手指按下去仍有水波纹，看起来像「点了没反应」；
   * enabled 关掉后连按压反馈一起停，用户能明确知道正在等。
   */
  @Builder
  private updateRow() {
    Row({ space: 8 }) {
      Text('检查更新')
        .fontSize(13)
        .fontColor(this.checking ? Theme.subText() : Theme.text())
        .layoutWeight(1)
      Text(this.checking ? '检查中…' : '›')
        .fontSize(this.checking ? 12 : 16)
        .fontColor(Theme.subText())
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 16, right: 16 })
    .enabled(!this.checking)
    .onClick(() => {
      this.doCheckUpdate();
    })
  }

  /**
   * 存储行：与 langRow 同版式，但右侧文案允许染成红色。
   * 二次确认时文案变成「确认清理?」，红色用来提示「再点一下就真删了」。
   *
   * 只收下标、不收「文案 + 是否危险」这两个值参数，是因为 @Builder 的值参数只在创建时
   * 求值一次，之后父组件的 @State 变了也不会重新传进来 —— 那正是三行永远停在
   * 「计算中…」的原因。改成在 builder 体内直接读 this.storeSizes / this.storeConfirmKey，
   * 节点就会挂上这两个状态的依赖，变化时能真正刷新。
   */
  @Builder
  private storeRow(index: number) {
    Row({ space: 8 }) {
      Text(STORE_LABELS[index]).fontSize(13).fontColor(Theme.text()).layoutWeight(1)
      Text(this.storeValue(index))
        .fontSize(12)
        .fontColor(this.storeDanger(index) ? DANGER_TEXT : Theme.subText())
      Text('›')
        .fontSize(16)
        .fontColor(this.storeDanger(index) ? DANGER_TEXT : Theme.subText())
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 16, right: 16 })
    .onClick(() => this.askClear(STORE_KEYS[index]))
  }

  /**
   * 「数据」卡片的一行：与 navRow 同版式，但确认态要把右侧换成红字「确认清空?」。
   *
   * 为什么不用 navRow(label, hint, onTap)：@Builder 的值参数只在创建时求值一次，
   * 确认态需要改文案，传进去的 label 永远不会变。所以只收下标，确认与否在体内
   * 读 this.dataConfirmKey，节点才会挂上这个 @State 的依赖。
   */
  @Builder
  private dataRow(index: number) {
    Row({ space: 8 }) {
      Text(DATA_LABELS[index]).fontSize(13).fontColor(Theme.text()).layoutWeight(1)
      if (this.dataConfirmKey === DATA_KEYS[index]) {
        Text('确认清空?').fontSize(12).fontColor(DANGER_TEXT)
      }
      Text('›')
        .fontSize(16)
        .fontColor(this.dataConfirmKey === DATA_KEYS[index] ? DANGER_TEXT : Theme.subText())
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 16, right: 16 })
    .onClick(() => this.askData(DATA_KEYS[index]))
  }

  /**
   * 开关行：左标题 + 11 号说明，右侧 Toggle。
   *
   * 不收任何参数，isOn / 说明全在体内读 this.xxx —— @Builder 的值参数只在创建时
   * 求值一次，若把 this.tagTransOn 当参数传进来，用户拨了开关后本行不会跟着更新。
   */
  @Builder
  private toggleRow() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('显示中文标签名').fontSize(13).fontColor(Theme.text())
        // 标签库下载/更新会改 tagTransMsg，说明文案跟着状态走才会出现「正在加载…」
        Text(this.tagTransMsg.length > 0 ? this.tagTransMsg : '数据来自 EhTagTranslation，首次使用需下载')
          .fontSize(11)
          .fontColor(Theme.subText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.tagTransOn })
        .selectedColor(Theme.accent())
        .onChange((v: boolean) => {
          this.setTagTrans(v);
        })
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
  }

  private setTagTrans(v: boolean): void {
    this.tagTransOn = v;
    Prefs.put('tag_trans', v);
    // 回到列表要立刻生效：列表页的 aboutToAppear 不会再走（设置页是 push 出去的，
    // 返回时底下 TabContent 不重建），所以由这里推一次重绘信号。
    TagTransTick.settingsChanged();
    if (v) {
      this.loadTagTrans();
    }
  }

  /**
   * 胶囊选项：高 32、全圆角，选中主色底反白字，未选中细线色底。
   *
   * 参数只有「组别 + 下标 + 文案」这类常量；选中态在体内读 this.themeMode / this.site /
   * this.showCookieForm，节点才会挂上这些 @State 的依赖 —— 否则点了 pill 高亮不跟。
   */
  @Builder
  private pill(group: number, index: number, label: string) {
    Text(label)
      .height(PILL_H)
      .fontSize(12)
      .fontColor(this.pillSelected(group, index) ? Color.White : Theme.subText())
      .textAlign(TextAlign.Center)
      .padding({ left: 14, right: 14 })
      .borderRadius(PILL_RADIUS)
      .backgroundColor(this.pillSelected(group, index) ? Theme.accent() : Theme.line())
      .onClick(() => {
        this.pickPill(group, index);
      })
  }

  private pillSelected(group: number, index: number): boolean {
    if (group === PILL_SITE) {
      // Site.EH = 0 / Site.EX = 1，与 pill 的下标同序
      return this.site === (index === 0 ? Site.EH : Site.EX);
    }
    if (group === PILL_LOGIN) {
      return index === 0 ? !this.showCookieForm : this.showCookieForm;
    }
    return this.themeMode === this.themeOf(index);
  }

  private pickPill(group: number, index: number): void {
    if (group === PILL_SITE) {
      this.pickSite(index === 0 ? Site.EH : Site.EX);
      return;
    }
    if (group === PILL_LOGIN) {
      this.showCookieForm = index === 1;
      return;
    }
    this.pickTheme(this.themeOf(index));
  }

  /** 外观 pill 的下标 → 主题模式：0 跟随系统 / 1 浅色 / 2 深色 */
  private themeOf(index: number): ThemeMode {
    if (index === 0) {
      return ThemeMode.AUTO;
    }
    return index === 1 ? ThemeMode.LIGHT : ThemeMode.DARK;
  }

  /**
   * 输入框。
   *
   * 这里的 value 仍然是值参数，是刻意的：TextInput 的内容由用户输入主导，
   * 若每次按键都从 @State 反向灌一次文本，光标会被顶到末尾。本页也没有
   * 「程序化改写输入框内容」的需求（Cookie 值只在进入页面时读一次）。
   */
  @Builder
  private input(value: string, placeholder: string, onChange: (v: string) => void, isPassword: boolean) {
    TextInput({ text: value, placeholder: placeholder })
      .type(isPassword ? InputType.Password : InputType.Normal)
      .height(40)
      .fontSize(13)
      .fontColor(Theme.text())
      .placeholderColor(Theme.subText())
      .backgroundColor(Theme.line())
      .borderRadius(10)
      .width('100%')
      .onChange((v: string) => onChange(v))
  }

  /**
   * Cookie 的一格：左标签 + 右输入框。
   *
   * 只收下标，值和占位文案全在体内从 COOKIE_LABELS / this.cookieValue() 取：
   * @Builder 的值参数只在创建时求值一次，粘贴是程序化改写这三格，
   * 若把 this.memberId 这类当参数传进来，粘完输入框还会停在旧内容。
   * 右侧 TextInput 的 text 直接绑 @State，才能写入后立刻回显。
   */
  @Builder
  private cookieField(index: number) {
    Row() {
      Text(COOKIE_LABELS[index])
        .fontSize(11)
        .fontColor(Theme.subText())
        .width(COOKIE_LABEL_W)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      TextInput({ text: this.cookieValue(index), placeholder: COOKIE_HINTS[index] })
        .type(InputType.Normal)
        .height(40)
        .fontSize(13)
        .fontColor(Theme.text())
        .placeholderColor(Theme.subText())
        .backgroundColor(Theme.line())
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .layoutWeight(1)
        .onChange((v: string) => {
          this.setCookieField(index, v);
        })
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 16, right: 16 })
  }

  /**
   * Cookie 表单底部两个按钮：主「保存并登录」/ 次「粘贴」。
   *
   * 只读状态、不收参数：busy 一变，加载圈与可点与否都要跟着变。
   * 登录中把主按钮换成 24 的加载圈并吞掉点击，避免连点发多次请求。
   * 文案不再有「重新登录」分支 —— 已登录态整块表单都不渲染了，进不到这里。
   */
  @Builder
  private cookieButtons() {
    Row({ space: 8 }) {
      Row() {
        if (this.busy) {
          LoadingProgress().width(24).height(24).color(Color.White)
        } else {
          Text('保存并登录')
            .fontSize(13)
            .fontColor(Color.White)
        }
      }
      .layoutWeight(1)
      .height(COOKIE_BTN_H)
      .justifyContent(FlexAlign.Center)
      .borderRadius(10)
      .backgroundColor(Theme.accent())
      // 禁用态只降不透明度和吞点击，不改底色：改了会被误认为「另一个按钮」
      .opacity(this.busy ? 0.6 : 1)
      .onClick(() => {
        if (this.busy) {
          return;
        }
        this.doCookieLogin();
      })

      // 「粘贴」按钮已移除：剪贴板读取在部分机型被系统拒绝（错误码 201），
      // 表现为「点了没反应」，而输入框自带的长按粘贴一直可用 —— 留着一个时会失效的
      // 快捷方式，比没有更容易让人以为功能坏了。
    }
    .width('100%')
  }

  /** 表单里的主按钮：40 高，主色底 */
  @Builder
  private primaryButton(label: string, onTap: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(Color.White)
      .width('100%')
      .height(40)
      .textAlign(TextAlign.Center)
      .borderRadius(10)
      .backgroundColor(Theme.accent())
      .onClick(onTap)
  }

  /**
   * 已登录态的账号卡身：只读摘要 + 退出登录。
   *
   * 为什么已登录就不渲染输入框：输入框在这里只有「提交新凭据」一个用途，
   * 而登录着的时候用户的诉求是「确认我现在是谁 / 换个账号」。旧版把输入框一直留着，
   * 空白的用户名/密码框把真正有用的账号名挤到看不见，用户还得先把框清空才敢确认身份。
   * 所以已登录时整块换成只读文本，输入框只在未登录态出现；换账号 = 先退出，表单自然回来。
   *
   * 只读文案取 memberPreview()：账号密码登录时是会员 ID 前 6 位，Cookie 登录时
   * 同一个字段就是用户能对上的唯一标识（站点侧的 cookieSummary 已在卡头胶囊里显示）。
   */
  @Builder
  private accountLoggedIn() {
    Column() {
      Row({ space: 8 }) {
        Text('当前账号')
          .fontSize(12)
          .fontColor(Theme.subText())
        Text(this.memberPreview())
          .fontSize(13)
          .fontColor(Theme.text())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(ROW_H)
      .padding({ left: 16, right: 16 })

      Row({ space: 8 }) {
        Text('已登录，可切换账号：退出后用其它账号重新登录')
          .fontSize(11)
          .fontColor(Theme.subText())
          .layoutWeight(1)
          .maxLines(2)
        // 复制 Cookie：把当前三格真实值拼成浏览器可用的整段，
        // 方便在别的设备/浏览器上继续用同一个登录态。
        Text('复制 Cookie')
          .fontSize(11)
          .fontColor(Theme.accent())
          .height(28)
          .padding({ left: 10, right: 10 })
          .borderRadius(999)
          .backgroundColor(Theme.line())
          .onClick(() => {
            this.copyCookie();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, bottom: 12 })

      // 退出登录：逆向操作，单独一行红字，与主操作区隔开
      this.dividerLine()
      Row() {
        Text('退出登录')
          .fontSize(13)
          .fontColor(DANGER_TEXT)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height(48)
      .onClick(() => {
        this.doLogout();
      })
    }
    .width('100%')
  }

  /**
   * 退出登录。
   *
   * Cookie 的清理必须走工程已有的 EhApi.logout()（内部是 Cookies.clear() + 落盘），
   * 本页不自己删 Cookie —— 只在这一步之后手工同步 @State loggedIn，
   * 因为 Cookies 是普通静态类、不可观测，不同步的话卡片会一直停在已登录态。
   * 顺手清空表单里的旧值，避免退出后 Cookie 三格还留着上一个账号的内容。
   */
  private doLogout(): void {
    EhApi.logout();
    this.userName = '';
    this.password = '';
    this.memberId = '';
    this.passHash = '';
    this.igneous = '';
    this.showCookieForm = false;
    this.refreshState();
    this.showToast('已退出登录，可用其它账号重新登录');
  }

  @Builder
  private headerBar() {
    MaterialSurface({ surfaceHeight: this.headerHeight() }) {
      Column() {
        Row() {
          // 标题直接挂在行上（不再套 Column 放版本号副标题）：
          // 「版本 1.8.5」对设置页没有任何操作性，它在最下方「关于」卡里已经出现过一次，
          // 顶栏再挂一遍纯属重复，还白占一行高度（就是这行副标题让顶栏一直得留 56）。
          // 删掉后 Column 只剩一个子节点，留着只是多一层无意义包裹，所以连 Column 一起去掉。
          Text('设置')
            .fontSize(FONT_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text())
            .maxLines(1)
            .layoutWeight(1)

          if (this.busy) {
            LoadingProgress().width(16).height(16).color(Theme.subText())
          }
        }
        .width('100%')
        .height(BAR_ROW_HEIGHT)
        .padding({ left: PAGE_PAD, right: PAGE_PAD })
      }
      .width('100%')
      // 顶部避让状态栏：沉浸式下内容铺到状态栏下面，标题要躲开它
      .padding({ top: this.statusBar() })
      .alignItems(HorizontalAlign.Start)
    }
  }

  build() {
    // 顶栏固定、分组卡在它下面滚动（与首页同一套写法）：
    // 让位量写在滚动内容的 padding 上，滚起来时这段空隙会跟着滚走，卡片能钻到顶栏下面。
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column() {
          // ------------------------------------------------------ 站点
          this.groupTitle('站点')
          Column() {
            Row({ space: 8 }) {
              Text('当前站点').fontSize(13).fontColor(Theme.text()).layoutWeight(1)
              Row({ space: PILL_GAP }) {
                this.pill(PILL_SITE, 0, 'E-Hentai')
                this.pill(PILL_SITE, 1, 'ExHentai')
              }
            }
            .width('100%')
            .height(ROW_H)
            .padding({ left: 16, right: 16 })

            this.dividerLine()

            Text(this.site === Site.EX ? 'ExHentai 需要 igneous Cookie' : 'E-Hentai 不需要登录也能看')
              .fontSize(11)
              .fontColor(Theme.subText())
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 12 })
          }
          .width('100%')
          .backgroundColor(Theme.card())
          .borderRadius(CARD_RADIUS)
          // 下面每张卡都跟这一条：0.5 的细描边只加在卡片最外层（卡底与页面底颜色太近，
          // 没有这条边卡界会糊）。不用 clip(true) 收圆角 —— 裁切会把 0.5 的边削掉一半。
          .border({ width: CARD_EDGE, color: Theme.line() })
          .margin({ bottom: CARD_GAP })

          // ------------------------------------------------------ 账号
          // 卡头只讲一件事：现在登没登。状态用右侧胶囊表达。
          // 卡身分两态（见 accountLoggedIn() 的注释）：已登录只给只读摘要 + 退出登录，
          // 输入框只在未登录态出现。
          this.groupTitle('账号')
          Column() {
            Row({ space: 8 }) {
              Text('登录状态')
                .fontSize(12)
                .fontColor(Theme.subText())
                .layoutWeight(1)

              Text(this.cookieSummary)
                .fontSize(11)
                .fontColor(this.loggedIn ? Theme.accent() : Theme.subText())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .height(28)
                .padding({ left: 12, right: 12 })
                .borderRadius(PILL_RADIUS)
                .backgroundColor(Theme.line())
            }
            .width('100%')
            .height(CARD_HEAD_H)
            .padding({ left: 16, right: 16 })

            if (this.loggedIn && this.site === Site.EX && !this.igneousReady) {
              this.dividerLine()
              Text('缺少 igneous：EX 站会显示 Sad Panda。请先退出登录，再用 Cookie 登录补上，' +
                '或先在网页版 EX 登录一次。')
                .fontSize(11)
                .fontColor(Theme.accent())
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 12 })
            }

            if (this.loggedIn) {
              // 已登录：不渲染任何 TextInput，换成只读摘要 + 退出登录
              this.dividerLine()
              this.accountLoggedIn()
            } else {
              this.dividerLine()
              Row({ space: 8 }) {
                Text('登录方式').fontSize(13).fontColor(Theme.text()).layoutWeight(1)
                Row({ space: PILL_GAP }) {
                  this.pill(PILL_LOGIN, 0, '账号密码')
                  this.pill(PILL_LOGIN, 1, 'Cookie')
                }
              }
              .width('100%')
              .height(ROW_H)
              .padding({ left: 16, right: 16 })

              this.dividerLine()
              if (!this.showCookieForm) {
                Column({ space: 8 }) {
                  this.input(this.userName, '用户名 / 邮箱', (v: string) => {
                    this.userName = v;
                  }, false)
                  this.input(this.password, '密码', (v: string) => {
                    this.password = v;
                  }, true)
                  this.primaryButton('登录', () => {
                    this.doPasswordLogin();
                  })
                  Text('论坛登录接口偶尔会要求验证码；遇到时请改用 Cookie 登录')
                    .fontSize(11)
                    .fontColor(Theme.subText())
                    .width('100%')
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              } else {
                // 三格改成「标签 + 输入」的两列行：标签固定 84 宽，三格输入框左边对齐成一条线，
                // 行高 56、行间细线，与卡片里其他分组列表同一套节奏，不再是一堆散的方块。
                Column() {
                  this.cookieField(0)
                  this.dividerLine()
                  this.cookieField(1)
                  this.dividerLine()
                  this.cookieField(2)

                  this.dividerLine()
                  Column({ space: 10 }) {
                    this.cookieButtons()
                    Text('在浏览器登录后，从开发者工具或 Cookie 扩展里复制 ipb_member_id 与 ipb_pass_hash 填到上面两格；EX 站还需要 igneous')
                      .fontSize(11)
                      .fontColor(Theme.subText())
                      .width('100%')
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                }
                .width('100%')
              }
            }
          }
          .width('100%')
          .backgroundColor(Theme.card())
          .borderRadius(CARD_RADIUS)
          .border({ width: CARD_EDGE, color: Theme.line() })
          .margin({ bottom: CARD_GAP })

          // ------------------------------------------------------ 外观
          this.groupTitle('外观')
          Column() {
            Row({ space: 8 }) {
              Text('主题').fontSize(13).fontColor(Theme.text()).layoutWeight(1)
              Row({ space: PILL_GAP }) {
                this.pill(PILL_THEME, 0, '跟随系统')
                this.pill(PILL_THEME, 1, '浅色')
                this.pill(PILL_THEME, 2, '深色')
              }
            }
            .width('100%')
            .height(ROW_H)
            .padding({ left: 16, right: 16 })
          }
          .width('100%')
          .backgroundColor(Theme.card())
          .borderRadius(CARD_RADIUS)
          .border({ width: CARD_EDGE, color: Theme.line() })
          .margin({ bottom: CARD_GAP })

          // ------------------------------------------------------ 列表样式
          this.groupTitle('列表样式')
          Column() {
            Row() {
              Text('排布方式').fontSize(13).fontColor(Theme.text()).layoutWeight(1)
              Text(this.listStyleLabel()).fontSize(12).fontColor(Theme.subText())
            }
            .width('100%')
            .height(ROW_H)
            .padding({ left: 16, right: 16 })

            this.dividerLine()

            // 4 个选项在 360vp 下挤不进一行，改用可换行的胶囊组（间距 8）
            Flex({ wrap: FlexWrap.Wrap }) {
              this.listPill(ListStyles.MINIMAL, '极简')
              this.listPill(ListStyles.COMPACT, '紧凑')
              this.listPill(ListStyles.EXTENDED, '详细')
              this.listPill(ListStyles.THUMBNAIL, '封面墙')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 4 })

            Text('极简/紧凑/详细是一行一条，封面墙是两列纯封面网格。')
              .fontSize(11)
              .fontColor(Theme.subText())
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 12 })
          }
          .width('100%')
          .backgroundColor(Theme.card())
          .borderRadius(CARD_RADIUS)
          .border({ width: CARD_EDGE, color: Theme.line() })
          .margin({ bottom: CARD_GAP })

          // ------------------------------------------------------ 标签
          this.groupTitle('标签')
          Column() {
            this.toggleRow()

            if (this.tagTransOn) {
              this.dividerLine()
              Row({ space: PILL_GAP }) {
                Text('更新数据库')
                  .height(28)
                  .fontSize(11)
                  .fontColor(Theme.subText())
                  .textAlign(TextAlign.Center)
                  .padding({ left: 12, right: 12 })
                  .borderRadius(PILL_RADIUS)
                  .backgroundColor(Theme.line())
                  .onClick(() => {
                    this.updateTagTrans();
                  })
                Text('清除缓存')
                  .height(28)
                  .fontSize(11)
                  .fontColor(Theme.subText())
                  .textAlign(TextAlign.Center)
                  .padding({ left: 12, right: 12 })
                  .borderRadius(PILL_RADIUS)
                  .backgroundColor(Theme.line())
                  .onClick(() => {
                    TagTrans.clear();
                    this.tagTransMsg = '缓存已清除';
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 12 })
            }

            // 标签体系的入口：标签集/观看标签是站点侧的数据，翻译语言只影响本地显示，
            // 两行都是一点即走，不占屏幕，所以直接挂在「标签」分组下面。
            this.dividerLine()
            this.navRow('标签集与观看标签', '', () => this.onOpenTagSets())
            this.dividerLine()
            this.langRow()
          }
          .width('100%')
          .backgroundColor(Theme.card())
          .borderRadius(CARD_RADIUS)
          .border({ width: CARD_EDGE, color: Theme.line() })
          .margin({ bottom: CARD_GAP })

          // ------------------------------------------------------ 数据
          // 两行都是不可撤销的本地清空，与「存储管理」同一套二次确认：
          // 第一次点进入确认态、第二次点才真删、3 秒不点自动还原。
          this.groupTitle('历史记录')
          Column() {
            this.dataRow(0)
            this.dividerLine()
            this.dataRow(1)
          }
          .width('100%')
          .backgroundColor(Theme.card())
          .borderRadius(CARD_RADIUS)
          .border({ width: CARD_EDGE, color: Theme.line() })
          .margin({ bottom: CARD_GAP })

          // ------------------------------------------------------ 存储管理
          // 三行分别对应 Storage 的三个缓存分类：右侧显示大小，点一下进入二次确认。
          // 行内文案在确认态换成「确认清理?」，3 秒内不再点就自动还原，避免误删。
          this.groupTitle('存储管理')
          Column() {
            // 三行写死而不是 ForEach：每行只需传下标，文案与确认态都在 storeRow 内部读状态，
            // 这样 @State 变化时这些节点会被真实刷新（列表复用反而会掩盖这个问题）。
            this.storeRow(0)
            this.dividerLine()
            this.storeRow(1)
            this.dividerLine()
            this.storeRow(2)
            // 「全部清理」已移除：三行各自可清，整卡一键清空是这里最容易误触的操作，
            // 而且它清的是三类完全不同的缓存（下载/种子/图片），一次抹掉不该是一个按钮。
          }
          .width('100%')
          .backgroundColor(Theme.card())
          .borderRadius(CARD_RADIUS)
          .border({ width: CARD_EDGE, color: Theme.line() })
          .margin({ bottom: CARD_GAP })

          // ------------------------------------------------------ 关于
          // 前两行是可操作/可变信息的行（56 高、行间细线），版权与免责声明放在
          // 同一张卡的下半段，用 12 号首行 + 11 号说明的排版，不占额外一张卡。
          this.groupTitle('关于')
          Column() {
            this.versionRow()

            this.dividerLine()
            this.updateRow()

            this.dividerLine()
            Column({ space: 6 }) {
              Text('KHenTai · HarmonyOS 移植版').fontSize(13).fontColor(Theme.text())
              Text('原项目：github.com/jiangtian616/JHenTai（Apache-2.0）')
                .fontSize(11)
                .fontColor(Theme.subText())
              Text('本移植版用 ArkTS 重写，不包含下载/归档/评论/标签投票等原版高级功能。' +
                '内容由 E-Hentai / ExHentai 提供，请遵守当地法律与站点规则。')
                .fontSize(11)
                .fontColor(Theme.subText())
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          }
          .width('100%')
          .backgroundColor(Theme.card())
          .borderRadius(CARD_RADIUS)
          .border({ width: CARD_EDGE, color: Theme.line() })

          if (this.toast.length > 0) {
            Text(this.toast)
              .fontSize(12)
              .fontColor(Theme.bg())
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .borderRadius(PILL_RADIUS)
              .backgroundColor(Theme.text())
              .margin({ top: 12 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        // 顶部让位 = 顶栏高度；底栏 80 让位，最后一张卡不会压在悬浮胶囊下面
        .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.headerHeight(), bottom: BOTTOM_PAD })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      // 用 pageBg() 而不是直接 Theme.bg()：前者顺带建立了对 'themeDark' 的依赖，
      // 否则本页只在自身 @State 变化时才重绘，跟随系统切深色不会跟。
      .backgroundColor(this.pageBg())

      // 顶栏最后画：Stack 里越靠后越在上，材质才盖在滚动内容之上
      this.headerBar()
    }
    .width('100%')
    .height('100%')
  }

  /** 组标题右侧的当前值文案 */
  private listStyleLabel(): string {
    if (this.listStyle === ListStyles.MINIMAL) {
      return '极简';
    }
    if (this.listStyle === ListStyles.EXTENDED) {
      return '详细';
    }
    if (this.listStyle === ListStyles.THUMBNAIL) {
      return '封面墙';
    }
    return '紧凑';
  }

  private pickSite(next: Site): void {
    this.site = next;
    Prefs.setSite(next);
    this.showToast(next === Site.EX ? '已切换到 ExHentai（需要 igneous Cookie）' : '已切换到 E-Hentai');
  }

  private pickTheme(next: ThemeMode): void {
    this.themeMode = next;
    Theme.setMode(next);
    this.showToast('已切换主题');
  }

  private async loadTagTrans(): Promise<void> {
    this.tagTransMsg = '正在加载标签库…';
    const ok: boolean = await TagTrans.ensureLoaded();
    this.tagTransMsg = ok ? '标签库就绪' : '标签库加载失败（检查网络或稍后重试）';
  }

  private async updateTagTrans(): Promise<void> {
    this.tagTransMsg = '正在下载最新标签库…';
    const ok: boolean = await TagTrans.update();
    this.tagTransMsg = ok ? '已更新' : '更新失败（检查网络）';
  }

  // ------------------------------------------------------------ 存储管理
  /**
   * 重新统计三类缓存。
   *
   * 先把三行都置成「计算中…」：目录里文件多的时候 scan 要一会儿，
   * 留着旧数字会让人以为清理没生效。
   *
   * 三处结果通道都要落到 UI，不能只等最终 resolve：
   *  1. onPartial —— 每统计完一类就回一次，先出来的先显示，不会因为第三类慢而三行全白等；
   *  2. then —— 完整结果；
   *  3. 定时器 —— 9 秒还没回就把剩下的「计算中…」改成「—」，兜住单次 fileIo 卡死。
   */
  private refreshStoreSizes(): void {
    this.storeSizes = [STORE_PENDING, STORE_PENDING, STORE_PENDING];
    const seq: number = ++this.storeScanSeq;
    if (this.storeScanTimer >= 0) {
      clearTimeout(this.storeScanTimer);
      this.storeScanTimer = -1;
    }

    Storage.scan((part: StorageUsage[]) => {
      if (seq !== this.storeScanSeq) {
        return;
      }
      this.applyStoreSizes(part);
    }).then((list: StorageUsage[]) => {
      if (seq !== this.storeScanSeq) {
        return;
      }
      this.clearStoreScanTimer();
      this.applyStoreSizes(list);
    }).catch(() => {
      // scan 内部已经吞了异常，这里只兜底极端情况（AppContext 未初始化等）
      if (seq !== this.storeScanSeq) {
        return;
      }
      this.clearStoreScanTimer();
      this.storeSizes = [STORE_UNKNOWN, STORE_UNKNOWN, STORE_UNKNOWN];
    });

    this.storeScanTimer = setTimeout(() => {
      this.storeScanTimer = -1;
      if (seq !== this.storeScanSeq) {
        return;
      }
      this.resolvePendingAsUnknown();
    }, STORE_UI_TIMEOUT_MS);
  }

  private clearStoreScanTimer(): void {
    if (this.storeScanTimer >= 0) {
      clearTimeout(this.storeScanTimer);
      this.storeScanTimer = -1;
    }
  }

  /**
   * 把 scan 结果写进 @State storeSizes。
   *
   * 必须是「整个数组替换」而不是 `this.storeSizes[i] = x`：@State 对数组只观测
   * 整体赋值与 push/splice 这类 API，按下标改元素不会通知 UI。
   * part 里没有的分类保持「计算中…」，等后续部分结果或最终结果补齐。
   */
  private applyStoreSizes(list: StorageUsage[]): void {
    const out: string[] = [STORE_PENDING, STORE_PENDING, STORE_PENDING];
    for (let i = 0; i < list.length; i++) {
      const at: number = STORE_KEYS.indexOf(list[i].key);
      if (at >= 0) {
        out[at] = Storage.formatSize(list[i].bytes);
      }
    }
    this.storeSizes = out;
  }

  /** 超时兜底：还停在「计算中…」的行改成「—」，已经有数字的行不动 */
  private resolvePendingAsUnknown(): void {
    const out: string[] = [];
    for (let i = 0; i < STORE_KEYS.length; i++) {
      const v: string = i < this.storeSizes.length ? this.storeSizes[i] : STORE_PENDING;
      out.push(v === STORE_PENDING ? STORE_UNKNOWN : v);
    }
    this.storeSizes = out;
  }

  /** 第 index 行右侧文案：该行处于确认态时显示确认提示，否则显示大小 */
  private storeValue(index: number): string {
    if (index < 0 || index >= STORE_KEYS.length) {
      return '';
    }
    if (this.storeConfirmKey === STORE_KEYS[index]) {
      return '确认清理?';
    }
    if (index >= this.storeSizes.length) {
      return STORE_PENDING;
    }
    return this.storeSizes[index];
  }

  /** 该行是否处于确认态（右侧文字与箭头一起染红） */
  private storeDanger(index: number): boolean {
    if (index < 0 || index >= STORE_KEYS.length) {
      return false;
    }
    return this.storeConfirmKey === STORE_KEYS[index];
  }

  /**
   * 二次确认入口：第一次点只把该行切到确认态并起 3 秒定时器，
   * 定时器到期或点了别的行就还原；确认态下再点同一个目标才真正清理。
   */
  private askClear(key: string): void {
    if (this.storeBusy) {
      return;
    }
    if (this.storeConfirmKey === key) {
      this.runClear(key);
      return;
    }
    this.storeConfirmKey = key;
    if (this.confirmTimer >= 0) {
      clearTimeout(this.confirmTimer);
    }
    this.confirmTimer = setTimeout(() => {
      this.storeConfirmKey = '';
      this.confirmTimer = -1;
    }, CONFIRM_MS);
  }

  /** 执行清理：完成后 toast 告知释放量，并重新统计一次把数字刷新成新值 */
  private async runClear(key: string): Promise<void> {
    this.storeConfirmKey = '';
    if (this.confirmTimer >= 0) {
      clearTimeout(this.confirmTimer);
      this.confirmTimer = -1;
    }
    this.storeBusy = true;
    let freed: number = 0;
    try {
      if (key === 'all') {
        for (let i = 0; i < STORE_KEYS.length; i++) {
          freed += await Storage.clear(STORE_KEYS[i]);
        }
      } else {
        freed = await Storage.clear(key);
      }
      this.showToast('已释放 ' + Storage.formatSize(freed));
    } catch (e) {
      this.showToast('清理失败，请稍后重试');
    }
    this.storeBusy = false;
    this.refreshStoreSizes();
  }

  // ------------------------------------------------------------ 数据卡片
  /**
   * 「数据」卡片的二次确认入口。
   *
   * 为什么要照抄存储管理那套、而不是随手弹个弹窗：本页已经有一套用户刚学会的确认手势
   * （点一次变红字「确认清空?」、3 秒不点自动还原、再点一次才执行），数据卡片和存储卡片
   * 都是「点了就没了」的本地清空，多造第二种交互只会让人误判哪次点击才是真删。
   *
   * 与存储管理的差异只有两点：这里是纯同步删除（没有 async、没有 busy 态、不用重算大小），
   * 以及用独立的 dataConfirmTimer —— 共用 confirmTimer 会让两张卡互相顶掉定时器。
   */
  private askData(key: string): void {
    if (this.dataConfirmKey === key) {
      this.runDataClear(key);
      return;
    }
    this.dataConfirmKey = key;
    if (this.dataConfirmTimer >= 0) {
      clearTimeout(this.dataConfirmTimer);
    }
    this.dataConfirmTimer = setTimeout(() => {
      this.dataConfirmKey = '';
      this.dataConfirmTimer = -1;
    }, CONFIRM_MS);
  }

  /** 执行清空：先复位确认态，再调对应模块的 clear()，最后 toast */
  private runDataClear(key: string): void {
    this.dataConfirmKey = '';
    if (this.dataConfirmTimer >= 0) {
      clearTimeout(this.dataConfirmTimer);
      this.dataConfirmTimer = -1;
    }
    if (key === 'search') {
      SearchHistory.clear();
      this.showToast('已清空搜索历史');
      return;
    }
    History.clear();
    this.showToast('已清空浏览记录');
  }

  @Builder
  private listPill(value: string, label: string) {
    Text(label)
      .height(PILL_H)
      .fontSize(12)
      .fontColor(this.listStyle === value ? Color.White : Theme.subText())
      .textAlign(TextAlign.Center)
      .padding({ left: 14, right: 14 })
      .margin({ right: PILL_GAP, bottom: PILL_GAP })
      .borderRadius(PILL_RADIUS)
      .backgroundColor(this.listStyle === value ? Theme.accent() : Theme.line())
      .onClick(() => {
        this.listStyle = value;
        Prefs.setListStyle(value);
        // 同时写 AppStorage：列表页用 @StorageProp 订阅，切回 tab 立刻是新样式
        AppStorage.setOrCreate<string>('listStyle', value);
        this.showToast('已切换列表样式');
      })
  }
}
