import { hilog } from '@kit.PerformanceAnalysisKit';
import { EhConsts } from './Consts';
import { EhUrl, Gallery } from './Models';
import { Http, HttpResp } from './Http';
import { HNode, Html } from '../parse/Html';
import { Prefs } from './Prefs';

const TAG: string = 'JHenTai.Torrents';

/** 一个种子 */
export class Torrent {
  id: string = '';
  name: string = '';
  /** 原样保留站点文案（如 "1.2 GB"），由 UI 决定要不要换算 */
  sizeText: string = '';
  seeds: number = 0;
  peers: number = 0;
  added: string = '';
  /** 绝对地址的 .torrent 下载链接 */
  url: string = '';
}

/** 表格里第一个整数；找不到返回 0 */
function firstInt(s: string): number {
  const m: RegExpMatchArray | null = s.match(/(\d+)/);
  if (m === null) {
    return 0;
  }
  const v: number = parseInt(m[1], 10);
  return isNaN(v) ? 0 : v;
}

/**
 * 读取画廊的种子列表。
 *
 * gallerytorrents.php 是纯表格页，没有稳定类名，所以按“行内有 .torrent 链接才算数”
 * 来筛选：表头行、广告行都拿不到链接，自然被跳过。列位置用“大小所在列”做锚点，
 * 而不是写死 td 下标 —— 站点偶尔会在前面插一列图标。
 */
export async function loadTorrents(gallery: Gallery): Promise<Torrent[]> {
  const out: Torrent[] = [];
  if (gallery.gid.length === 0 || gallery.token.length === 0) {
    return out;
  }
  const base: string = EhConsts.index(Prefs.site());
  const url: string = base + '/gallerytorrents.php?gid=' + encodeURIComponent(gallery.gid) +
    '&t=' + encodeURIComponent(gallery.token);
  try {
    const resp: HttpResp = await Http.get(url, gallery.url);
    if (resp.code !== 200 || resp.body.length === 0) {
      return out;
    }
    const doc: HNode = Html.parse(resp.body);
    let rows: HNode[] = doc.find('#torrentlist tr');
    if (rows.length === 0) {
      rows = doc.find('table tr');
    }
    for (let i = 0; i < rows.length; i++) {
      const row: HNode = rows[i];
      if (row.findFirst('th') !== null) {
        continue;
      }
      const t: Torrent = new Torrent();

      const anchors: HNode[] = row.find('a');
      for (let k = 0; k < anchors.length; k++) {
        const href: string = anchors[k].attr('href');
        if (href.indexOf('.torrent') < 0) {
          continue;
        }
        t.url = EhUrl.absolute(href, base);
        const im: RegExpMatchArray | null = href.match(/\/torrent\/([^\/?'"]+)\.torrent/);
        if (im !== null) {
          t.id = im[1];
        }
        break;
      }
      if (t.url.length === 0) {
        continue;
      }

      // 名字：.gt1 是名字列；没有就取**文本最长**且不是纯数字/文件大小的那一格。
      // 种子表里只有名字是长文本，序号（1）、大小（1.2 GB）、做种数（10）都会被排除，
      // 比写死 td 下标抗改版（站点偶尔会在前面插一列图标）。
      t.name = row.textOf('.gt1');
      if (t.name.length === 0) {
        const cells0: HNode[] = row.find('td');
        let best: string = '';
        for (let k = 0; k < cells0.length; k++) {
          const tx: string = cells0[k].textContent();
          if (tx.length <= best.length) {
            continue;
          }
          if (/^[\d.,\s]+$/.test(tx)) {
            continue;
          }
          if (/^[\d.,\s]*(B|KB|MB|GB)$/i.test(tx)) {
            continue;
          }
          best = tx;
        }
        t.name = best;
      }
      if (t.name.length === 0 && anchors.length > 0) {
        for (let k = 0; k < anchors.length; k++) {
          const txt: string = anchors[k].textContent();
          if (txt.length > 0 && anchors[k].attr('href').indexOf('.torrent') < 0) {
            t.name = txt;
            break;
          }
        }
      }

      const rowText: string = row.textContent();
      const sm: RegExpMatchArray | null = rowText.match(/(\d+(?:\.\d+)?)\s*(B|KB|MB|GB)/i);
      let sizeIdx: number = -1;
      if (sm !== null) {
        t.sizeText = sm[1] + ' ' + sm[2].toUpperCase();
      }

      // 种子/连接数：以“含大小文本的列”为锚点，后面两列分别是 seeds / peers
      const cells: HNode[] = row.find('td');
      if (sm !== null && cells.length > 0) {
        for (let k = 0; k < cells.length; k++) {
          if (cells[k].textContent().indexOf(sm[1]) >= 0) {
            sizeIdx = k;
            break;
          }
        }
      }
      if (sizeIdx >= 0 && cells.length > sizeIdx + 2) {
        t.seeds = firstInt(cells[sizeIdx + 1].textContent());
        t.peers = firstInt(cells[sizeIdx + 2].textContent());
        if (cells.length > sizeIdx + 3) {
          t.added = cells[sizeIdx + 3].textContent();
        }
      } else if (cells.length >= 4) {
        // 兜底：老版面的固定布局 name / size / seeds / peers / date
        t.seeds = firstInt(cells[2].textContent());
        t.peers = firstInt(cells[3].textContent());
        if (cells.length >= 5) {
          t.added = cells[4].textContent();
        }
      }

      out.push(t);
    }
  } catch (e) {
    hilog.warn(0x0000, TAG, 'load torrents failed');
    return [];
  }
  return out;
}
