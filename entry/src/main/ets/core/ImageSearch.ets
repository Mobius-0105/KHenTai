import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EhConsts } from './Consts';
import { EhUrl, Gallery, GalleryPage } from './Models';
import { EhApi } from './EhApi';
import { Cookies } from './Cookies';
import { Prefs } from './Prefs';

const TAG: string = 'JHenTai.ImageSearch';

/** 上传接口固定在 upld 子域，和当前浏览站点无关（EX 也用这个） */
const UPLOAD_URL: string = 'https://upld.e-hentai.org/image_lookup.php';

/** 按扩展名猜 MIME；猜不到用 jpeg（相册选择器给的基本都是图片） */
function mimeOf(path: string): string {
  const lower: string = path.toLowerCase();
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.gif')) {
    return 'image/gif';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  if (lower.endsWith('.bmp')) {
    return 'image/bmp';
  }
  return 'image/jpeg';
}

/** file:// URI 转本地路径（@ohos.net.http 的 filePath 只认真实路径） */
function toPath(uri: string): string {
  let p: string = uri;
  try {
    if (p.startsWith('file://')) {
      p = p.substring(7);
      // 形如 file://localhost/xxx 时要丢掉 host
      if (p.startsWith('localhost/')) {
        p = p.substring(9);
        p = '/' + p;
      }
      p = decodeURIComponent(p);
    }
  } catch (e) {
    hilog.warn(0x0000, TAG, 'uri decode failed');
  }
  return p;
}

/**
 * 以图搜图（EH 的 Image Search）。
 *
 * multipart 走 http 的 multiFormDataList：字段名必须是 sfile，
 * 另外带 f_sfile/fs_similar/fs_exp 三个开关，缺了站点会当成普通上传。
 * 结果页是列表 HTML，直接复用列表解析器；解析不出时再退到正则抓 /g/ 链接，
 * 保证“上传成功但站点改了版式”时至少还能给出结果。
 */
export async function searchByImage(uri: string): Promise<Gallery[]> {
  const out: Gallery[] = [];
  const path: string = toPath(uri);
  if (path.length === 0) {
    return out;
  }
  try {
    if (!fileIo.accessSync(path)) {
      return out;
    }
  } catch (e) {
    return out;
  }

  const base: string = EhConsts.index(Prefs.site());
  const req: http.HttpRequest = http.createHttp();
  try {
    const filePart: http.MultiFormData = {
      name: 'sfile',
      contentType: mimeOf(path),
      filePath: path,
      remoteFileName: 'image.jpg'
    };
    const flagFile: http.MultiFormData = {
      name: 'f_sfile',
      contentType: 'text/plain',
      data: 'File Search'
    };
    const flagSimilar: http.MultiFormData = {
      name: 'fs_similar',
      contentType: 'text/plain',
      data: 'on'
    };
    const flagExp: http.MultiFormData = {
      name: 'fs_exp',
      contentType: 'text/plain',
      data: 'on'
    };

    const header: Record<string, string> = {};
    header['User-Agent'] = EhConsts.USER_AGENT;
    header['Referer'] = base + '/';
    header['Content-Type'] = 'multipart/form-data';
    const cookie: string = Cookies.header();
    if (cookie.length > 0) {
      header['Cookie'] = cookie;
    }

    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: header,
      connectTimeout: 30000,
      // 站点要先算感知哈希再比对，慢的时候会超过一分钟
      readTimeout: 120000,
      expectDataType: http.HttpDataType.STRING,
      multiFormDataList: [filePart, flagFile, flagSimilar, flagExp]
    };
    const resp: http.HttpResponse = await req.request(UPLOAD_URL, options);
    const r: string | Object | ArrayBuffer = resp.result;
    const html: string = typeof r === 'string' ? r : '';
    if (resp.responseCode !== 200 || html.length === 0) {
      hilog.warn(0x0000, TAG, 'lookup http %{public}d', resp.responseCode);
      return out;
    }

    try {
      const page: GalleryPage = EhApi.parseList(html, base);
      for (let i = 0; i < page.items.length; i++) {
        out.push(page.items[i]);
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'parse lookup result failed');
    }
    if (out.length > 0) {
      return out;
    }

    // 兜底：直接从 HTML 里抓 /g/ 链接并去重
    const seen: Set<string> = new Set<string>();
    const re: RegExp = /\/g\/(\d+)\/([0-9a-fA-F]+)/g;
    let m: RegExpExecArray | null = re.exec(html);
    while (m !== null) {
      const key: string = m[1] + '/' + m[2];
      if (!seen.has(key)) {
        seen.add(key);
        const g: Gallery | null = EhUrl.parseGallery(base + '/g/' + key + '/');
        if (g !== null) {
          out.push(g);
        }
      }
      m = re.exec(html);
    }
    return out;
  } catch (e) {
    hilog.error(0x0000, TAG, 'image search failed');
    return [];
  } finally {
    req.destroy();
  }
}
