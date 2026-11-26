import { hilog } from '@kit.PerformanceAnalysisKit';
import { EhConsts } from './Consts';
import { Http, HttpResp } from './Http';
import { Prefs } from './Prefs';
import { Cookies } from './Cookies';
import { HNode, Html } from '../parse/Html';
import { usertagAddForm } from './TagVote';

const TAG: string = 'JHenTai.TagSets';
/** EH 每个账号最多 10 组标签集，留点余量防站点改版后陷入长循环 */
const MAX_TAGSET: number = 12;
/** 默认标签集：不带 ?tagset= 时站点返回的就是第 1 组 */
const DEFAULT_TAGSET: number = 1;
/** 新加标签的默认权重，与站点 add 表单的默认值一致 */
const DEFAULT_WEIGHT: number = 10;

/**
 * 一组标签集（My Tags 页面左上角那个下拉里的条目）。
 *
 * 站点一侧叫 tagset，每组只能整体「启用/停用」并给一个背景色；
 * 组内才是具体的 watching / hiding 标签。
 */
export class TagSet {
  /** 站点编号，1..10，同时也是 `?tagset=` 的取值 */
  id: number = 0;
  /** 显示名（站点叫 tagset_name），未命名时是 “Tag Set N” */
  label: string = '';
  /** 是否启用。名字不能叫 enabled（ArkTS 保留成员名） */
  on: boolean = true;
  /** '#RRGGBB'，未着色时为空串 */
  color: string = '';
}

/**
 * 一条被观看/隐藏的标签。
 *
 * 站点的每一行都有独立 id（usertag_<tagId>），改状态走 api.php 的 setusertag，
 * 所以 tagId 必须留着；只看名字是区分不了大小写变体的。
 */
export class WatchedTag {
  /** 站点内部 id，0 表示还没有对应行（只能走 add 表单） */
  tagId: number = 0;
  ns: string = '';
  key: string = '';
  /** '#RRGGBB'，未着色时为空串 */
  color: string = '';
  weight: number = 0;
  /** 在画廊列表里高亮 */
  watch: boolean = false;
  /** 在画廊列表里隐藏 */
  hide: boolean = false;
  /** 所属标签集编号 */
  tagSetId: number = DEFAULT_TAGSET;
}

/** mytags 页里内联的 apikey，改标签状态（setusertag）要用；登录态变化后重新抓 */
let apiKeyCache: string = '';

function myTagsUrl(tagSetNo: number): string {
  return EhConsts.index(Prefs.site()) + '/mytags?tagset=' + tagSetNo.toString();
}

/** 取一页 mytags；失败一律返回空串（未登录时会 302 到登录页，解析自然为空） */
async function fetchMyTags(tagSetNo: number): Promise<string> {
  try {
    const resp: HttpResp = await Http.get(myTagsUrl(tagSetNo));
    if (resp.code !== 200) {
      return '';
    }
    return resp.body;
  } catch (e) {
    // Http 会把限流/封禁/Cloudflare 翻译成 EhError 抛出，这里全部降级
    hilog.warn(0x0000, TAG, 'fetch mytags %{public}d failed', tagSetNo);
    return '';
  }
}

/** 解析成节点树；解析器自己不会抛，但多一层兜底，坏页面就当没有 */
function parseDoc(body: string): HNode | null {
  try {
    return Html.parse(body);
  } catch (e) {
    return null;
  }
}

/** 站点颜色是 6 位十六进制（带不带 # 都有），统一成 '#RRGGBB'，认不出就当没颜色 */
function normalizeColor(raw: string): string {
  const t: string = raw.trim().replace('#', '');
  if (!/^[0-9a-fA-F]{6}$/.test(t)) {
    return '';
  }
  return '#' + t.toUpperCase();
}

/** 从页面脚本里抠 apikey（`apikey = "..."`），抠不到就保留旧值 */
function pickApiKey(body: string): string {
  if (body.length === 0) {
    return apiKeyCache;
  }
  const m: RegExpMatchArray | null = body.match(/apikey\s*=\s*["']([0-9a-zA-Z]+)["']/);
  if (m !== null && m[1].length > 0) {
    return m[1];
  }
  return apiKeyCache;
}

function hasChecked(scope: HNode, selector: string): boolean {
  const n: HNode | null = scope.findFirst(selector);
  return n === null ? false : n.hasAttr('checked');
}

/**
 * 解析下拉里的标签集列表。
 *
 * 站点结构（原版 JHenTai 的 myTagsPage2TagSetNamesAndTagSetsAndApikey 用的就是它）：
 *   #tagset_outer > div > select > option   value=组号, 文本=组名
 * 这里用 `#tagset_outer option` 而不是带 > 的完整链：多一层 div 也不至于全空。
 */
function parseOptions(doc: HNode): TagSet[] {
  const nodes: HNode[] = doc.find('#tagset_outer option');
  const out: TagSet[] = [];
  const seen: Set<number> = new Set<number>();
  for (let i = 0; i < nodes.length && out.length < MAX_TAGSET; i++) {
    const id: number = parseInt(nodes[i].attr('value'), 10);
    if (isNaN(id) || id <= 0 || seen.has(id)) {
      continue;
    }
    seen.add(id);
    const item: TagSet = new TagSet();
    item.id = id;
    const text: string = nodes[i].textContent().trim();
    item.label = text.length > 0 ? text : '标签集 ' + id.toString();
    out.push(item);
  }
  return out;
}

/** 当前页只带「它自己这一组」的启用状态和颜色：`#tagset_enable[checked]` / `#tagcolor[value]` */
function readTagSetState(doc: HNode, out: TagSet): void {
  const box: HNode | null = doc.findFirst('#tagset_enable');
  // 拿不到 checkbox 时按「启用」处理：默认停用会让用户以为标签集被清了
  out.on = box === null ? true : box.hasAttr('checked');
  out.color = normalizeColor(doc.attrOf('#tagcolor', 'value'));
}

/** 补一组标签集的启用状态/颜色（每组的状态只在自己的 ?tagset= 页面上） */
async function fillTagSetState(item: TagSet): Promise<void> {
  const body: string = await fetchMyTags(item.id);
  if (body.length === 0) {
    return;
  }
  try {
    readTagSetState(Html.parse(body), item);
  } catch (e) {
    hilog.warn(0x0000, TAG, 'parse tagset %{public}d failed', item.id);
  }
}

/**
 * 读取全部标签集。
 *
 * 为什么要发多次请求：站点的启用状态和颜色是「当前组」的表单字段，
 * 一次请求只能拿到一组，所以要按下拉里的组号各取一次（最多 10 组）。
 * 串行而不是并发：EH 对并发翻页有速率限制，串行最多多花两三秒，
 * 并发却可能整批被限流，反而全空。
 *
 * 未登录、网络失败、站点改版一律返回空数组，不抛异常。
 */
export async function loadTagSets(): Promise<TagSet[]> {
  if (!Cookies.isLoggedIn()) {
    return [];
  }
  const body: string = await fetchMyTags(DEFAULT_TAGSET);
  if (body.length === 0) {
    return [];
  }
  const doc: HNode | null = parseDoc(body);
  if (doc === null) {
    return [];
  }
  apiKeyCache = pickApiKey(body);

  const list: TagSet[] = parseOptions(doc);
  if (list.length === 0) {
    // 下拉解析失败但页面确实是 mytags（有启用开关）：退化成一个默认组，页面仍可用
    if (doc.findFirst('#tagset_enable') === null) {
      return [];
    }
    const only: TagSet = new TagSet();
    only.id = DEFAULT_TAGSET;
    only.label = '标签集 ' + DEFAULT_TAGSET.toString();
    readTagSetState(doc, only);
    return [only];
  }

  for (let i = 0; i < list.length; i++) {
    if (list[i].id === DEFAULT_TAGSET) {
      readTagSetState(doc, list[i]);
    } else {
      await fillTagSetState(list[i]);
    }
  }
  return list;
}

/**
 * POST 一次 tagset_action=update。
 *
 * 表单字段取自原版 JHenTai 的 requestUpdateTagSet：
 *   tagset_action=update & tagset_name= & tagset_enable=on & tagset_color=
 * 要注意的是原版永远把 tagset_name 传空串，也就是说「改名」在站点侧大概率
 * 不被这个接口支持（下拉里的名字可能是只读的）。这里仍然把名字带上，
 * 站点若忽略它，只会表现为改名无效，不会破坏启用状态和颜色。
 */
async function postTagSetUpdate(id: number, label: string, on: boolean, color: string): Promise<boolean> {
  if (!Cookies.isLoggedIn() || id <= 0) {
    return false;
  }
  const form: string = 'tagset_action=update' +
    '&tagset_name=' + encodeURIComponent(label) +
    '&tagset_enable=' + (on ? 'on' : '') +
    '&tagset_color=' + encodeURIComponent(color);
  const url: string = myTagsUrl(id);
  try {
    const resp: HttpResp = await Http.postForm(url, form, url);
    if (resp.code !== 200 && resp.code !== 302) {
      hilog.warn(0x0000, TAG, 'tagset update http %{public}d', resp.code);
      return false;
    }
    // 表单校验失败时仍是 200，正文里会多出一段提示
    if (resp.body.indexOf('Invalid') >= 0) {
      return false;
    }
    return true;
  } catch (e) {
    hilog.warn(0x0000, TAG, 'tagset update failed');
    return false;
  }
}

/** 改名 + 改色。on 用来保留原来的启用状态（不传则视为启用） */
export async function renameTagSet(id: number, label: string, color: string, on: boolean = true): Promise<boolean> {
  return postTagSetUpdate(id, label, on, color);
}

/** 启用/停用一组标签集。color 必须带上当前颜色，否则站点会把颜色清掉 */
export async function toggleTagSet(id: number, on: boolean, color: string = ''): Promise<boolean> {
  return postTagSetUpdate(id, '', on, color);
}

/**
 * 读取某组里的观看/隐藏标签。
 *
 * 站点结构（对应原版解析器的 #usertags_outer 段）：
 *   #usertags_outer > div#usertag_<id>   每一行
 *     #tagpreview_<id>[title="ns:key"]   标签全名放在 title 上
 *     #tagwatch_<id>[checked]            观看
 *     #taghide_<id>[checked]             隐藏
 *     #tagcolor_<id>[value]              颜色
 *     #tagweight_<id>[value]             权重
 * usertag_0 是站点给「新增行」留的模板，必须跳过，否则会多出一条空标签。
 */
export async function loadWatchedTags(tagSetNo: number = DEFAULT_TAGSET): Promise<WatchedTag[]> {
  if (!Cookies.isLoggedIn()) {
    return [];
  }
  const body: string = await fetchMyTags(tagSetNo);
  if (body.length === 0) {
    return [];
  }
  apiKeyCache = pickApiKey(body);
  const doc: HNode | null = parseDoc(body);
  if (doc === null) {
    return [];
  }

  const rows: HNode[] = doc.find('#usertags_outer > div');
  const out: WatchedTag[] = [];
  for (let i = 0; i < rows.length; i++) {
    const id: string = rows[i].attr('id');
    if (id.length === 0 || id === 'usertag_0') {
      continue;
    }
    const tagId: number = parseInt(id.replace('usertag_', ''), 10);
    if (isNaN(tagId) || tagId <= 0) {
      continue;
    }

    const preview: HNode | null = doc.findFirst('#tagpreview_' + tagId.toString());
    let full: string = '';
    if (preview !== null) {
      full = preview.attr('title');
      if (full.length === 0) {
        full = preview.textContent();
      }
    }
    if (full.trim().length === 0) {
      continue;
    }

    const item: WatchedTag = new WatchedTag();
    item.tagId = tagId;
    const colon: number = full.indexOf(':');
    if (colon > 0) {
      item.ns = full.substring(0, colon).trim();
      item.key = full.substring(colon + 1).trim();
    } else {
      // 没有命名空间的标签（站点允许）整串当 key
      item.ns = '';
      item.key = full.trim();
    }
    if (item.key.length === 0) {
      continue;
    }
    item.watch = hasChecked(doc, '#tagwatch_' + tagId.toString());
    item.hide = hasChecked(doc, '#taghide_' + tagId.toString());
    item.color = normalizeColor(doc.attrOf('#tagcolor_' + tagId.toString(), 'value'));
    const w: number = parseInt(doc.attrOf('#tagweight_' + tagId.toString(), 'value'), 10);
    item.weight = isNaN(w) ? 0 : w;
    item.tagSetId = tagSetNo;
    out.push(item);
  }
  return out;
}

/**
 * 新增一条标签（usertag_action=add）。
 *
 * 字段与 core/TagVote.ets 的 toggleWatchTag 完全共用（usertagAddForm），
 * 语义上只适合「站点里还没有这条标签」；已经在列表里的标签要用 updateWatchedTag，
 * 否则站点会回 "Tag already exists"，watch/hide 都不会变。
 */
export async function setWatchedTag(tag: string, watch: boolean, hide: boolean): Promise<boolean> {
  const full: string = tag.trim();
  if (!Cookies.isLoggedIn() || full.length === 0) {
    return false;
  }
  const url: string = myTagsUrl(DEFAULT_TAGSET);
  const form: string = usertagAddForm(full, watch, hide, DEFAULT_WEIGHT, '');
  try {
    const resp: HttpResp = await Http.postForm(url, form, url);
    if (resp.code !== 200 && resp.code !== 302) {
      return false;
    }
    if (resp.body.indexOf('Invalid tag') >= 0 || resp.body.indexOf('already exists') >= 0) {
      return false;
    }
    return true;
  } catch (e) {
    hilog.warn(0x0000, TAG, 'add watched tag failed');
    return false;
  }
}

/**
 * 改一条已有标签的观看/隐藏状态。
 *
 * 走 api.php 的 setusertag（原版 requestUpdateWatchedTag 同一个接口），
 * 而不是 mytags 的网页表单：网页表单要带上整页其它行，容易覆盖别人的改动；
 * api.php 只提交 tagid + 三个状态位，语义明确，也不需要 302 兜底。
 * 响应里出现 error 字段即失败（apikey 失效、tagid 不属于本账号等）。
 */
export async function updateWatchedTag(
  tagId: number, watch: boolean, hide: boolean, weight: number, color: string
): Promise<boolean> {
  const uid: string = Cookies.get('ipb_member_id');
  if (tagId <= 0 || uid.length === 0 || apiKeyCache.length === 0) {
    return false;
  }
  const body: string = '{"method":"setusertag"' +
    ',"apiuid":' + uid +
    ',"apikey":"' + apiKeyCache + '"' +
    ',"tagcolor":"' + color + '"' +
    ',"taghide":' + (hide ? '1' : '0') +
    ',"tagwatch":' + (watch ? '1' : '0') +
    ',"tagid":' + tagId.toString() +
    ',"tagweight":"' + weight.toString() + '"}';
  try {
    const resp: HttpResp = await Http.postJson(EhConsts.api(Prefs.site()), body);
    if (resp.code !== 200 || resp.body.length === 0) {
      return false;
    }
    const obj: Record<string, Object> = JSON.parse(resp.body) as Record<string, Object>;
    const err: Object | undefined = obj['error'];
    if (err === undefined || err === null) {
      return true;
    }
    hilog.warn(0x0000, TAG, 'setusertag rejected: %{public}s', err.toString());
    return false;
  } catch (e) {
    hilog.warn(0x0000, TAG, 'setusertag failed');
    return false;
  }
}
