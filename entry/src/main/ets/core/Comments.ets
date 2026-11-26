import { hilog } from '@kit.PerformanceAnalysisKit';
import { EhConsts } from './Consts';
import { Gallery } from './Models';
import { Http, HttpResp } from './Http';
import { HNode, Html } from '../parse/Html';
import { Prefs } from './Prefs';

const TAG: string = 'JHenTai.Comments';

/**
 * api.php 的凭证。
 *
 * EH 的详情页把 apikey / apiuid 直接渲染在两个 `var` 语句里，只有登录后才有。
 * 用它调 api.php 比抓 HTML 表单稳（投票接口没有可用的网页入口）。
 */
export class ApiCred {
  key: string = '';
  uid: string = '';

  /** 两个字段都拿到才算可用；缺失时调用方直接降级为“不可投票”，不弹错 */
  ok(): boolean {
    return this.key.length > 0 && this.uid.length > 0;
  }
}

/** 从详情页 HTML 里抠 apikey / apiuid。站点两种写法都出现过，所以引号可选。 */
export function parseApiCred(html: string): ApiCred {
  const cred: ApiCred = new ApiCred();
  if (html.length === 0) {
    return cred;
  }
  try {
    const km: RegExpMatchArray | null = html.match(/var\s+apikey\s*=\s*["']?([0-9a-zA-Z]+)["']?/);
    if (km !== null) {
      cred.key = km[1];
    }
    const um: RegExpMatchArray | null = html.match(/var\s+apiuid\s*=\s*["']?(\d+)["']?/);
    if (um !== null) {
      cred.uid = um[1];
    }
  } catch (e) {
    hilog.warn(0x0000, TAG, 'parse cred failed');
  }
  return cred;
}

/** 一条评论 */
export class Comment {
  id: string = '';
  userName: string = '';
  userId: string = '';
  /** 社区打分，可能为负 */
  score: number = 0;
  time: string = '';
  content: string = '';
  /** 是否还能投票（已投过 / 未登录时站点会给 .c5.nosel） */
  canVote: boolean = false;
}

/**
 * 解析详情页评论区。
 *
 * 评论区的结构随站点改版会漂移（有时正文在第二个 .c6，有时 id 挂在 .c6 里的 <a> 上），
 * 所以这里全部按“找得到就用、找不到给空值”的方式写，宁可少一个字段也不抛异常 ——
 * 评论区不该让整个详情页挂掉。
 */
export function parseComments(html: string): Comment[] {
  const out: Comment[] = [];
  if (html.length === 0) {
    return out;
  }
  try {
    const doc: HNode = Html.parse(html);
    let items: HNode[] = doc.find('#cdiv .c1');
    if (items.length === 0) {
      items = doc.find('#cdiv > div');
    }
    if (items.length === 0) {
      items = doc.find('.c1');
    }
    for (let i = 0; i < items.length; i++) {
      const node: HNode = items[i];
      const c: Comment = new Comment();

      // id：真实页面上 id 直接挂在 .c1 自身（id="comment_123456"），
      // 少数布局挂在里面的锚点上、或只在 href 的 #comment_xxx 里，三种都试
      const all: HNode[] = node.descendants();
      const ownId: string = node.attr('id');
      if (ownId.startsWith('comment_')) {
        c.id = ownId.substring(8);
      }
      for (let k = 0; k < all.length; k++) {
        if (c.id.length > 0) {
          break;
        }
        const id: string = all[k].attr('id');
        if (id.startsWith('comment_')) {
          c.id = id.substring(8);
          break;
        }
        const href: string = all[k].attr('href');
        const hm: RegExpMatchArray | null = href.match(/comment_(\d+)/);
        if (hm !== null) {
          c.id = hm[1];
        }
      }

      // 用户名：.c3 里的链接
      c.userName = node.textOf('.c3 a');
      if (c.userName.length === 0) {
        c.userName = node.textOf('.c3');
      }

      // 用户 id：评论里的链接带 showuser=<id>
      for (let k = 0; k < all.length; k++) {
        const href: string = all[k].attr('href');
        const um: RegExpMatchArray | null = href.match(/showuser=(\d+)/);
        if (um !== null) {
          c.userId = um[1];
          break;
        }
      }
      if (c.userId.length === 0) {
        const tm: RegExpMatchArray | null = node.textContent().match(/showuser=(\d+)/);
        if (tm !== null) {
          c.userId = tm[1];
        }
      }

      // 正文：通常第一个 .c6 是“Posted on ...”锚点，第二个才是正文；
      // 结构变化时取文本最长的那块，比固定下标更抗改版。
      const bodies: HNode[] = node.find('.c6');
      if (bodies.length >= 2) {
        c.content = bodies[1].textContent();
      } else if (bodies.length === 1) {
        c.content = bodies[0].textContent();
      }

      // 分数：.c5 文本形如 "Score +12" / "+12" / "-5"
      const c5: HNode | null = node.findFirst('.c5');
      if (c5 !== null) {
        const sm: RegExpMatchArray | null = c5.textContent().match(/([+-]?\d+)/);
        if (sm !== null) {
          const v: number = parseInt(sm[1], 10);
          if (!isNaN(v)) {
            c.score = v;
          }
        }
        // .nosel = 站点没给投票按钮（未登录 / 已投过）
        c.canVote = !c5.hasClass('nosel');
      }

      // 时间：.c7；没有就退到第一条 .c6 的文本里找日期
      c.time = node.textOf('.c7');
      if (c.time.length === 0 && bodies.length > 0) {
        const dm: RegExpMatchArray | null = bodies[0].textContent().match(/\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}/);
        if (dm !== null) {
          c.time = dm[0];
        }
      }

      out.push(c);
    }
  } catch (e) {
    hilog.warn(0x0000, TAG, 'parse comments failed');
  }
  return out;
}

/**
 * 发表评论。成功返回空串，失败返回可直接展示的文案。
 *
 * 站点把错误也渲染在正常页面里（200 + <p class="br">），所以不能只看状态码。
 */
export async function postComment(gallery: Gallery, text: string): Promise<string> {
  const body: string = 'commenttext_new=' + encodeURIComponent(text);
  try {
    const resp: HttpResp = await Http.postForm(gallery.url, body, gallery.url);
    if (resp.code === 403) {
      return '没有发表权限（可能未登录或账号受限）';
    }
    const doc: HNode = Html.parse(resp.body);
    const err: string = doc.textOf('p.br');
    if (err.length > 0) {
      return err;
    }
    if (resp.code !== 200 && resp.code !== 302) {
      return '发表失败（' + resp.code.toString() + '）';
    }
    return '';
  } catch (e) {
    const msg: string = e instanceof Error ? (e as Error).message : '网络异常';
    hilog.warn(0x0000, TAG, 'post comment failed: %{public}s', msg);
    return msg;
  }
}

/**
 * 给评论投票。
 *
 * 走 api.php 而不是网页：网页投票依赖表单里的 apikey 隐藏域，还得先抓页面；
 * api.php 只要凭证 + comment_id，响应里的 comment_score 非 null 即成功。
 */
export async function voteComment(cred: ApiCred, gallery: Gallery, commentId: string, up: boolean): Promise<boolean> {
  if (!cred.ok() || commentId.length === 0) {
    return false;
  }
  // 不用对象字面量拼 JSON：apiuid 必须是数字，手工拼能精确控制引号
  const body: string = '{"method":"votecomment","apiuid":' + cred.uid +
    ',"apikey":"' + cred.key + '"' +
    ',"gid":' + gallery.gid +
    ',"token":"' + gallery.token + '"' +
    ',"comment_id":"' + commentId + '"' +
    ',"comment_vote":' + (up ? '1' : '-1') + '}';
  try {
    const resp: HttpResp = await Http.postJson(EhConsts.api(Prefs.site()), body);
    if (resp.code !== 200 || resp.body.length === 0) {
      return false;
    }
    const obj: Record<string, Object> = JSON.parse(resp.body) as Record<string, Object>;
    const score: Object | undefined = obj['comment_score'];
    if (score === undefined) {
      return false;
    }
    return score !== null;
  } catch (e) {
    hilog.warn(0x0000, TAG, 'vote comment failed');
    return false;
  }
}
