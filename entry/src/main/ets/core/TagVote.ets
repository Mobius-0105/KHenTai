import { hilog } from '@kit.PerformanceAnalysisKit';
import { EhConsts } from './Consts';
import { Gallery } from './Models';
import { Http, HttpResp } from './Http';
import { Prefs } from './Prefs';
import { ApiCred } from './Comments';

const TAG: string = 'JHenTai.TagVote';

/**
 * 给标签投票（taggallery）。
 *
 * 与评论投票同理走 api.php：网页端的标签投票是把整页标签一起 POST 回详情页，
 * 要先把页面里所有隐藏域原样带回，既脆弱又容易覆盖别人的票；
 * api.php 只提交单条 tag + vote，语义明确。
 * 响应里出现 error 字段即失败（例如 "Invalid tag"、"You have already voted"）。
 */
export async function voteTag(cred: ApiCred, gallery: Gallery, ns: string, tag: string, up: boolean): Promise<boolean> {
  if (!cred.ok() || ns.length === 0 || tag.length === 0) {
    return false;
  }
  const full: string = ns + ':' + tag;
  const body: string = '{"method":"taggallery","apiuid":' + cred.uid +
    ',"apikey":"' + cred.key + '"' +
    ',"gid":' + gallery.gid +
    ',"token":"' + gallery.token + '"' +
    ',"tags":["' + full + '"]' +
    ',"vote":' + (up ? '1' : '-1') + '}';
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
    hilog.warn(0x0000, TAG, 'tag vote rejected: %{public}s', err.toString());
    return false;
  } catch (e) {
    hilog.warn(0x0000, TAG, 'vote tag failed');
    return false;
  }
}

/**
 * mytags 页 add 表单的字段拼接。
 *
 * 单独抽出来是因为 TagSets.ets 的 setWatchedTag 用的是同一套字段
 * （usertag_action=add 那一组），两处各写一遍必然会有一处漏字段。
 * 站点默认权重就是 10，这里由调用方显式给，避免以后有人以为它能随便改。
 */
export function usertagAddForm(tag: string, watch: boolean, hide: boolean, weight: number, color: string): string {
  return 'usertag_action=add' +
    '&tagname_new=' + encodeURIComponent(tag) +
    '&tagcolor_new=' + encodeURIComponent(color) +
    '&usertag_target=0' +
    '&tagweight_new=' + weight.toString() +
    '&tagwatch_new=' + (watch ? 'on' : '') +
    '&taghide_new=' + (hide ? 'on' : '');
}

/**
 * 把标签加入“观看列表”（My Tags 的 watched 分组）。
 *
 * ExHentai 的 watched 标签就是 My Tags 里 tagwatch=on 的那些，所以这里提交的是
 * mytags 的 add 表单。只实现“加入”一个方向：取消观看要走 mass 操作（选中 → 批量改）
 * 或者删掉再重加，语义容易出错，宁可在 UI 上不提供。
 */
export async function toggleWatchTag(gallery: Gallery, ns: string, tag: string, watch: boolean): Promise<boolean> {
  if (!watch || ns.length === 0 || tag.length === 0) {
    return false;
  }
  const base: string = EhConsts.index(Prefs.site());
  // 之前这里错把命名空间当组号传（?tagset=female），站点只会落到第 1 组；
  // 详情页加的标签本来就进默认组，所以固定 1。
  const url: string = base + '/mytags?tagset=1';
  const form: string = usertagAddForm(ns + ':' + tag, true, false, 10, '');
  try {
    const resp: HttpResp = await Http.postForm(url, form, gallery.url);
    if (resp.code !== 200 && resp.code !== 302) {
      return false;
    }
    // 表单校验失败时页面仍是 200，只会多出一段 "Invalid tag" / "Tag already exists"
    if (resp.body.indexOf('Invalid tag') >= 0) {
      return false;
    }
    return true;
  } catch (e) {
    hilog.warn(0x0000, TAG, 'watch tag failed');
    return false;
  }
}
