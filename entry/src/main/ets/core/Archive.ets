import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EhConsts } from './Consts';
import { EhUrl, Gallery } from './Models';
import { Http, HttpResp } from './Http';
import { HNode, Html } from '../parse/Html';
import { Prefs } from './Prefs';
import { Cookies } from './Cookies';

const TAG: string = 'JHenTai.Archive';

export enum ArchiveSize {
  ORIGINAL = 0,
  RESAMPLE = 1
}

export class ArchiveResult {
  ok: boolean = false;
  downloadUrl: string = '';
  /** 失败原因，UI 直接展示 */
  message: string = '';
}

/** 在响应 HTML 里找一个可下载的链接（.zip 或后续 archiver.php 步骤） */
function pickLink(html: string, base: string): string {
  try {
    const doc: HNode = Html.parse(html);
    const anchors: HNode[] = doc.find('a');
    let fallback: string = '';
    for (let i = 0; i < anchors.length; i++) {
      const href: string = anchors[i].attr('href');
      if (href.length === 0) {
        continue;
      }
      const isZip: boolean = href.indexOf('.zip') >= 0;
      const isArchiver: boolean = href.indexOf('archiver.php?') >= 0;
      if (!isZip && !isArchiver) {
        continue;
      }
      const text: string = anchors[i].textContent().toLowerCase();
      if (isZip || text.indexOf('download') >= 0) {
        return EhUrl.absolute(Html.decodeEntities(href), base);
      }
      if (fallback.length === 0) {
        fallback = EhUrl.absolute(Html.decodeEntities(href), base);
      }
    }
    if (fallback.length > 0) {
      return fallback;
    }
    // 少数情况下站点用 meta refresh 跳转
    const metas: HNode[] = doc.find('meta');
    for (let i = 0; i < metas.length; i++) {
      if (metas[i].attr('http-equiv').toLowerCase() !== 'refresh') {
        continue;
      }
      const um: RegExpMatchArray | null = metas[i].attr('content').match(/url=([^;\s]+)/i);
      if (um !== null) {
        return EhUrl.absolute(Html.decodeEntities(um[1]), base);
      }
    }
  } catch (e) {
    hilog.warn(0x0000, TAG, 'pick link failed');
  }
  return '';
}

/**
 * 申请归档下载。
 *
 * 流程是两跳：详情页里有 archiver.php 的入口（`#gd5` 里的 onclick），
 * POST 之后站点才决定给什么：
 *  - 302 到 zip：直接可用；
 *  - 200 + 等待页：站点在打包，页面里带 Download Archive 链接；
 *  - 200 + 提示：GP 不足 / 需要 downloader。
 * 因此必须按正文分支处理，不能只看状态码。
 */
export async function requestArchive(gallery: Gallery, size: ArchiveSize): Promise<ArchiveResult> {
  const res: ArchiveResult = new ArchiveResult();
  const base: string = EhConsts.index(Prefs.site());
  try {
    const detail: HttpResp = await Http.get(gallery.url);
    if (detail.code !== 200) {
      res.message = '详情页请求失败（' + detail.code.toString() + '）';
      return res;
    }
    const am: RegExpMatchArray | null = detail.body.match(/archiver\.php\?[^'"\s<>]+/);
    if (am === null) {
      res.message = '这个画廊没有归档下载（可能被上传者禁用，或需要登录后才有权限）';
      return res;
    }
    const archiverUrl: string = EhUrl.absolute(Html.decodeEntities(am[0]), base);

    const isRes: boolean = size === ArchiveSize.RESAMPLE;
    const form: string = 'dltype=' + (isRes ? 'res' : 'org') +
      '&dlcheck=' + encodeURIComponent('Download ' + (isRes ? 'Resample' : 'Original') + ' Archive');
    const resp: HttpResp = await Http.postForm(archiverUrl, form, gallery.url);

    if (resp.location.length > 0 && resp.location.indexOf('http') === 0) {
      res.ok = true;
      res.downloadUrl = resp.location;
      return res;
    }
    if (resp.code !== 200 && resp.code !== 302) {
      res.message = '归档请求失败（' + resp.code.toString() + '）';
      return res;
    }

    const body: string = resp.body;
    if (body.indexOf('You do not have enough funds') >= 0) {
      res.message = 'GP 不足：归档下载需要消耗 GP，请先到站点充值后再试';
      return res;
    }
    if (body.indexOf('requires a downloader') >= 0 || body.indexOf('requires the use of a downloader') >= 0) {
      // 等待页：站点已受理，但还需要一次“Download Archive”确认（这一步会扣 GP）
      res.downloadUrl = pickLink(body, base);
      if (res.downloadUrl.length > 0) {
        res.ok = true;
        return res;
      }
      res.message = '站点正在打包归档，请稍后重试';
      return res;
    }

    res.downloadUrl = pickLink(body, base);
    if (res.downloadUrl.length > 0) {
      res.ok = true;
      return res;
    }
    res.message = '站点没有返回下载地址（可能未登录，或该画廊的归档不可用）';
    return res;
  } catch (e) {
    const msg: string = e instanceof Error ? (e as Error).message : '网络异常';
    hilog.warn(0x0000, TAG, 'request archive failed: %{public}s', msg);
    res.message = msg;
    return res;
  }
}

/**
 * 流式下载到文件。
 *
 * 归档动辄几百 MB，不能用 request() 一次性收进内存（默认上限 5MB，超了直接失败），
 * 所以用 requestInStream + dataReceive 边收边写，进度用 dataReceiveProgress 上报。
 */
export async function downloadArchiveTo(
  url: string,
  destDir: string,
  fileName: string,
  onProgress: (received: number, total: number) => void
): Promise<string> {
  if (url.length === 0 || destDir.length === 0 || fileName.length === 0) {
    return '';
  }
  const path: string = destDir + '/' + fileName;
  const req: http.HttpRequest = http.createHttp();
  let file: fileIo.File | null = null;
  let received: number = 0;
  let writeFailed: boolean = false;
  try {
    if (!fileIo.accessSync(destDir)) {
      fileIo.mkdirSync(destDir, true);
    }
    file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    const fd: number = file.fd;

    req.on('dataReceive', (chunk: ArrayBuffer) => {
      if (writeFailed || chunk.byteLength === 0) {
        return;
      }
      try {
        let written: number = 0;
        while (written < chunk.byteLength) {
          const n: number = fileIo.writeSync(fd, chunk.slice(written));
          if (n <= 0) {
            break;
          }
          written += n;
        }
        received += written;
      } catch (e) {
        writeFailed = true;
      }
    });
    req.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo) => {
      onProgress(info.receiveSize, info.totalSize);
    });

    const header: Record<string, string> = {};
    header['User-Agent'] = EhConsts.USER_AGENT;
    header['Referer'] = EhConsts.index(Prefs.site()) + '/';
    const cookie: string = Cookies.header();
    if (cookie.length > 0) {
      header['Cookie'] = cookie;
    }
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: header,
      connectTimeout: 20000,
      // 大包慢链路常见，读超时给足；真正的超时由 UI 取消
      readTimeout: 300000,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    };
    const code: number = await req.requestInStream(url, options);
    if (code !== 200 && code !== 206) {
      hilog.warn(0x0000, TAG, 'archive http %{public}d', code);
      return '';
    }
    if (writeFailed || received === 0) {
      return '';
    }
    return path;
  } catch (e) {
    hilog.error(0x0000, TAG, 'download archive failed');
    return '';
  } finally {
    try {
      req.off('dataReceive');
      req.off('dataReceiveProgress');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'off events failed');
    }
    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch (e) {
        hilog.warn(0x0000, TAG, 'close file failed');
      }
    }
    req.destroy();
  }
}

/**
 * 解压 zip。
 *
 * zlib.decompressFile 的 outFile 参数语义取决于压缩包内容：压缩包里如果只有一个根目录，
 * 会解到该目录下；这里约定调用方传入“希望作为根”的目录，并在解压后按需在 UI 侧列出文件。
 */
export async function unzip(zipPath: string, destDir: string): Promise<boolean> {
  if (zipPath.length === 0 || destDir.length === 0) {
    return false;
  }
  try {
    if (!fileIo.accessSync(destDir)) {
      fileIo.mkdirSync(destDir, true);
    }
    await zlib.decompressFile(zipPath, destDir);
    return true;
  } catch (e) {
    hilog.error(0x0000, TAG, 'unzip failed');
    return false;
  }
}
