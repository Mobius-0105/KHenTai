import { Cookies } from '../core/Cookies';
import { Prefs } from '../core/Prefs';
import { Theme } from '../core/Theme';
import { TagTrans } from '../core/TagTrans';
import { PageHeader } from '../components/PageHeader';
import {
  TagSet, WatchedTag, loadTagSets, loadWatchedTags, renameTagSet, toggleTagSet, updateWatchedTag, setWatchedTag
} from '../core/TagSets';

/**
 * 「标签集与观看标签」页。
 *
 * 对应原版 JHenTai 的设置 → EH → Tags（tag_sets_page）：上半部分是站点的
 * 标签集（tagset，最多 10 组，可整组启用/停用/着色），下半部分是该组里的
 * 观看（watch）/ 隐藏（hide）标签。
 *
 * 三类写操作各不相同，故意分开：
 *  - 启用/停用、改色 → mytags 的 tagset_action=update（网页表单）
 *  - 已有标签改 watch/hide → api.php 的 setusertag（只需 tagid），不会覆盖别的行
 *  - 新增标签 → mytags 的 usertag_action=add（站点会回 "already exists"，所以只用于新标签）
 * 全部失败都只弹一行提示，不抛异常、不清空已有列表。
 */
@Component
export struct TagSetsPage {
  /** 标签库版本号：加载完成后自增，触发重绘（Map 不是可观察状态） */
  @State private tagTransTick: number = 0;
  onBack: () => void = (): void => {};

  @State private loggedIn: boolean = false;
  @State private loading: boolean = false;
  @State private loadingTags: boolean = false;
  @State private sets: TagSet[] = [];
  @State private tags: WatchedTag[] = [];
  /** 当前正在查看的标签集编号（决定下半部分列出哪一组的标签） */
  @State private currentSet: number = 1;
  @State private busy: boolean = false;
  @State private tip: string = '';
  @State private toast: string = '';

  /** 改名弹层 */
  @State private editOpen: boolean = false;
  /** 直接写 #RRGGBB；用户可以不带 #，保存时再格式化 */
  @State private editId: number = 0;
  @State private editLabel: string = '';
  @State private editColor: string = '';

  private toastTimer: number = -1;

  aboutToAppear(): void {
    // 同上：标签名要中文，库解析完必须重绘
    TagTrans.ensureLoaded().then((ok: boolean) => {
      if (ok) {
        this.tagTransTick = this.tagTransTick + 1;
      }
    });
    this.loggedIn = Cookies.isLoggedIn();
    if (this.loggedIn) {
      this.reload();
    }
  }

  aboutToDisappear(): void {
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
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

  /** 拉全套：标签集列表 + 当前组的标签 */
  private async reload(): Promise<void> {
    this.loading = true;
    this.tip = '';
    try {
      this.sets = await loadTagSets();
      // 当前组可能已经不在列表里（换了账号/站点改版），回落到第一组
      let exists: boolean = false;
      for (let i = 0; i < this.sets.length; i++) {
        if (this.sets[i].id === this.currentSet) {
          exists = true;
          break;
        }
      }
      if (!exists && this.sets.length > 0) {
        this.currentSet = this.sets[0].id;
      }
      if (this.sets.length === 0) {
        this.tip = '没有取到标签集：可能是站点改版，或账号里一组都没有';
      }
      this.loadingTags = true;
      this.tags = await loadWatchedTags(this.currentSet);
      this.loadingTags = false;
    } catch (e) {
      this.tip = '加载失败（检查网络后重试）';
    }
    this.loading = false;
  }

  /** 只换下半部分的标签，切组时不用整页重刷 */
  private async loadTags(): Promise<void> {
    this.loadingTags = true;
    try {
      this.tags = await loadWatchedTags(this.currentSet);
    } catch (e) {
      this.tags = [];
    }
    this.loadingTags = false;
  }

  private async selectSet(id: number): Promise<void> {
    if (this.currentSet === id) {
      return;
    }
    this.currentSet = id;
    await this.loadTags();
  }

  private onOf(id: number): boolean {
    for (let i = 0; i < this.sets.length; i++) {
      if (this.sets[i].id === id) {
        return this.sets[i].on;
      }
    }
    return true;
  }

  /** 整组启用/停用：必须把当前颜色带回表单，否则站点会把颜色清掉 */
  private async onToggle(t: TagSet, on: boolean): Promise<void> {
    if (this.busy || on === t.on) {
      return;
    }
    this.busy = true;
    const ok: boolean = await toggleTagSet(t.id, on, t.color);
    this.busy = false;
    if (!ok) {
      this.showToast('切换失败，已重新读取');
      await this.reload();
      return;
    }
    const next: TagSet[] = [];
    for (let i = 0; i < this.sets.length; i++) {
      const s: TagSet = this.sets[i];
      const c: TagSet = new TagSet();
      c.id = s.id;
      c.label = s.label;
      c.color = s.color;
      c.on = s.id === t.id ? on : s.on;
      next.push(c);
    }
    this.sets = next;
  }

  private openEdit(t: TagSet): void {
    this.editId = t.id;
    this.editLabel = t.label;
    this.editColor = t.color;
    this.editOpen = true;
  }

  /** 站点只接受 6 位十六进制，带不带 # 都行；认不出就发空串（= 不着色） */
  private fmtColor(raw: string): string {
    const t: string = raw.trim().replace('#', '');
    if (!/^[0-9a-fA-F]{6}$/.test(t)) {
      return '';
    }
    return '#' + t.toUpperCase();
  }

  private async doSaveRename(): Promise<void> {
    const label: string = this.editLabel.trim();
    if (label.length === 0) {
      this.showToast('名称不能为空');
      return;
    }
    this.busy = true;
    const ok: boolean = await renameTagSet(this.editId, label, this.fmtColor(this.editColor), this.onOf(this.editId));
    this.busy = false;
    this.editOpen = false;
    if (!ok) {
      // 站点侧大概率不支持改名（原版也从不传非空 tagset_name），颜色一般能存住
      this.showToast('保存失败：站点可能不允许改名，可只改颜色试试');
      await this.reload();
      return;
    }
    this.showToast('已保存');
    await this.reload();
  }

  /** 改一条标签的 watch/hide：三态互斥，点哪个就把另两个关掉 */
  private async applyTag(t: WatchedTag, watch: boolean, hide: boolean): Promise<void> {
    if (this.busy || (t.watch === watch && t.hide === hide)) {
      return;
    }
    this.busy = true;
    let ok: boolean = false;
    if (t.tagId > 0) {
      ok = await updateWatchedTag(t.tagId, watch, hide, t.weight, t.color);
    } else {
      // 没有 tagid 说明行还没落库，只能走 add（字段与 TagVote 共用）
      const full: string = t.ns.length > 0 ? t.ns + ':' + t.key : t.key;
      ok = await setWatchedTag(full, watch, hide);
    }
    this.busy = false;
    if (!ok) {
      this.showToast('修改失败');
      return;
    }
    const next: WatchedTag[] = [];
    for (let i = 0; i < this.tags.length; i++) {
      const s: WatchedTag = this.tags[i];
      const c: WatchedTag = new WatchedTag();
      c.tagId = s.tagId;
      c.ns = s.ns;
      c.key = s.key;
      c.color = s.color;
      c.weight = s.weight;
      c.tagSetId = s.tagSetId;
      if (s.tagId === t.tagId) {
        c.watch = watch;
        c.hide = hide;
      } else {
        c.watch = s.watch;
        c.hide = s.hide;
      }
      next.push(c);
    }
    this.tags = next;
  }

  /** 标签显示名：开了翻译且命中时补一段中文，正文始终保留英文原名 */
  private tagLabel(t: WatchedTag): string {
    const raw: string = t.ns.length > 0 ? t.ns + ':' + t.key : t.key;
    if (!Prefs.bool('tag_trans', false)) {
      return raw;
    }
    // 读 tick 建立依赖：库加载完成后这里会重新求值
    const tick: number = this.tagTransTick;
    const zh: string = tick < 0 ? '' : TagTrans.translate(t.ns, t.key);
    return zh.length > 0 ? raw + ' · ' + zh : raw;
  }

  private subtitle(): string {
    if (!this.loggedIn) {
      return '需要登录';
    }
    return this.sets.length.toString() + ' 组 · ' + this.tags.length.toString() + ' 条标签';
  }

  @Builder
  private section(title: string, hint: string) {
    Column({ space: 2 }) {
      Text(title).fontSize(12).fontColor(Theme.subText())
      if (hint.length > 0) {
        Text(hint).fontSize(10).fontColor(Theme.subText())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 4, right: 4, top: 16, bottom: 6 })
  }

  @Builder
  private setRow(t: TagSet) {
    Row({ space: 10 }) {
      Circle({ width: 10, height: 10 })
        .fill(t.color.length > 0 ? t.color : Theme.line())

      Column({ space: 2 }) {
        Text(t.label)
          .fontSize(13)
          .fontColor(Theme.text())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text('第 ' + t.id.toString() + ' 组' + (this.currentSet === t.id ? ' · 正在查看' : ''))
          .fontSize(10)
          .fontColor(this.currentSet === t.id ? Theme.accent() : Theme.subText())
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      // 切组只接在左侧文字区，避免点开关时连带换了正在看的组
      .onClick(() => this.selectSet(t.id))

      Text('改名')
        .fontSize(11)
        .fontColor(Theme.accent())
        .padding({ left: 6, right: 6 })
        .onClick(() => this.openEdit(t))

      Toggle({ type: ToggleType.Switch, isOn: t.on })
        .selectedColor('#34C759')
        .onChange((on: boolean) => {
          this.onToggle(t, on);
        })
    }
    .width('100%')
    .height(58)
    .padding({ left: 10, right: 10 })
    .borderRadius(12)
    .backgroundColor(this.currentSet === t.id ? Theme.card() : Color.Transparent)
  }

  @Builder
  private stateChip(label: string, active: boolean, onTap: () => void) {
    Text(label)
      .fontSize(11)
      .fontColor(active ? Color.White : Theme.subText())
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .borderRadius(9)
      .backgroundColor(active ? '#2F6BD8' : Theme.line())
      .onClick(onTap)
  }

  @Builder
  private tagRow(t: WatchedTag) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Circle({ width: 8, height: 8 })
          .fill(t.color.length > 0 ? t.color : Theme.line())
        Text(this.tagLabel(t))
          .fontSize(13)
          .fontColor(Theme.text())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('权重 ' + t.weight.toString())
          .fontSize(10)
          .fontColor(Theme.subText())
      }
      .width('100%')

      Row({ space: 8 }) {
        this.stateChip('观看', t.watch, () => this.applyTag(t, true, false))
        this.stateChip('隐藏', t.hide, () => this.applyTag(t, false, true))
        this.stateChip('不关注', !t.watch && !t.hide, () => this.applyTag(t, false, false))
        Blank()
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor(Theme.card())
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private editSheetBuilder() {
    Column({ space: 12 }) {
      Text('标签集设置').fontSize(15).fontColor(Theme.text()).margin({ top: 10 })
      TextInput({ text: this.editLabel, placeholder: '标签集名称' })
        .height(40)
        .fontSize(13)
        .fontColor(Theme.text())
        .placeholderColor(Theme.subText())
        .backgroundColor(Theme.line())
        .borderRadius(10)
        .width('100%')
        .onChange((v: string) => {
          this.editLabel = v;
        })
      TextInput({ text: this.editColor, placeholder: '颜色 #RRGGBB（留空不着色）' })
        .height(40)
        .fontSize(13)
        .fontColor(Theme.text())
        .placeholderColor(Theme.subText())
        .backgroundColor(Theme.line())
        .borderRadius(10)
        .width('100%')
        .onChange((v: string) => {
          this.editColor = v;
        })

      Row({ space: 10 }) {
        Text('取消')
          .layoutWeight(1)
          .height(38)
          .fontSize(12)
          .fontColor(Theme.subText())
          .textAlign(TextAlign.Center)
          .borderRadius(10)
          .backgroundColor(Theme.line())
          .onClick(() => {
            this.editOpen = false;
          })
        Text(this.busy ? '保存中…' : '保存')
          .layoutWeight(1)
          .height(38)
          .fontSize(12)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .borderRadius(10)
          .backgroundColor('#2F6BD8')
          .onClick(() => {
            this.doSaveRename();
          })
      }
      .width('100%')

      Text('站点的 tagset 表单只有「名称 / 启用 / 颜色」三个字段；如果名称存不住，说明站点把组名做成了只读。')
        .fontSize(10)
        .fontColor(Theme.subText())
        .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  build() {
    Column() {
      PageHeader({
        title: '标签集与观看标签',
        subtitle: this.subtitle(),
        onBack: () => this.onBack()
      })

      if (!this.loggedIn) {
        Column({ space: 10 }) {
          Text('需要登录').fontSize(14).fontColor(Theme.text())
          Text('标签集和观看/隐藏标签都存在站点账号里，登录后才能读写。\n请到「设置 → 登录状态」登录后再回到这里。')
            .fontSize(11)
            .fontColor(Theme.subText())
            .textAlign(TextAlign.Center)
          Text('返回')
            .fontSize(12)
            .fontColor(Theme.accent())
            .padding({ top: 6 })
            .onClick(() => this.onBack())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding({ left: 32, right: 32 })
      } else if (this.loading && this.sets.length === 0) {
        Column() {
          LoadingProgress().width(24).height(24).color(Theme.subText())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            if (this.tip.length > 0) {
              Text(this.tip)
                .fontSize(11)
                .fontColor('#E8963C')
                .width('100%')
                .padding({ top: 10 })
            }

            this.section('标签集', '点一行查看该组的标签；开关控制整组是否在画廊列表里生效')
            Column({ space: 2 }) {
              ForEach(this.sets, (t: TagSet) => {
                this.setRow(t)
              }, (t: TagSet) => t.id.toString() + (t.on ? '1' : '0') + t.label + t.color)
            }
            .width('100%')

            this.section('观看 / 隐藏的标签', '「观看」高亮、「隐藏」从列表里滤掉，两者互斥；权重决定排序')
            if (this.loadingTags) {
              Row() {
                LoadingProgress().width(16).height(16).color(Theme.subText())
                Text('正在读取第 ' + this.currentSet.toString() + ' 组…')
                  .fontSize(11)
                  .fontColor(Theme.subText())
                  .margin({ left: 8 })
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
            } else if (this.tags.length === 0) {
              Text('这一组里还没有观看或隐藏的标签。\n可以在画廊详情里点标签，「加入观看」就会出现在这里。')
                .fontSize(11)
                .fontColor(Theme.subText())
                .width('100%')
                .padding({ top: 8, bottom: 8 })
            } else {
              Column({ space: 8 }) {
                ForEach(this.tags, (t: WatchedTag) => {
                  this.tagRow(t)
                }, (t: WatchedTag) => t.tagId.toString() + (t.watch ? 'w' : '') + (t.hide ? 'h' : ''))
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 40 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }

      if (this.toast.length > 0) {
        Text(this.toast)
          .fontSize(12)
          .fontColor(Color.White)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(999)
          .backgroundColor('#33383F')
          .margin({ bottom: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg())
    .bindSheet(this.editOpen, this.editSheetBuilder(), {
      height: 320,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.card(),
      maskColor: '#99000000'
    })
  }
}
