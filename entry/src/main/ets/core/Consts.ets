/**
 * 站点常量与视觉常量。
 *
 * URL 与 JHenTai 原版 `lib/src/consts/eh_consts.dart` 一一对应；
 * 标签命名空间配色参考原版的 namespace 配色表。
 */

export enum Site {
  EH = 0,
  EX = 1
}

export class EhConsts {
  static readonly EH_INDEX: string = 'https://e-hentai.org';
  static readonly EX_INDEX: string = 'https://exhentai.org';
  static readonly EH_API: string = 'https://api.e-hentai.org/api.php';
  static readonly EX_API: string = 'https://exhentai.org/api.php';
  /**
   * EX 的 gdata 走独立子域 api.exhentai.org（不是 exhentai.org/api.php）。
   * 来源：JHenTai/lib/src/net/req.dart:383 —— 原版 gdata 地址按站点二选一，
   * EX 侧写的就是 api.exhentai.org；两个地址的鉴权都靠同一套 Cookie。
   */
  static readonly EX_GDATA_API: string = 'https://api.exhentai.org/api.php';
  static readonly FORUMS: string = 'https://forums.e-hentai.org/index.php';
  static readonly LOGIN_POST: string = 'https://forums.e-hentai.org/index.php?act=Login&CODE=01';
  static readonly BOUNCE_LOGIN: string = 'https://e-hentai.org/bounce_login.php';

  static index(site: Site): string {
    return site === Site.EX ? EhConsts.EX_INDEX : EhConsts.EH_INDEX;
  }

  static api(site: Site): string {
    return site === Site.EX ? EhConsts.EX_API : EhConsts.EH_API;
  }

  static host(site: Site): string {
    return site === Site.EX ? 'exhentai.org' : 'e-hentai.org';
  }

  /** 移动端 UA：EH 对桌面 UA 会给桌面版页面，选择器会变，所以固定用移动 UA */
  static readonly USER_AGENT: string =
    'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) ' +
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  static readonly EH_509_IMAGE: string = 'https://ehgt.org/g/509.gif';
  static readonly EX_509_IMAGE: string = 'https://exhentai.org/img/509.gif';
}

/** 画廊分类：EH 的 10 个分类，配色沿用原版观感 */
export class CategoryInfo {
  name: string;
  label: string;
  color: string;

  constructor(name: string, label: string, color: string) {
    this.name = name;
    this.label = label;
    this.color = color;
  }
}

const CATEGORIES: CategoryInfo[] = [
  new CategoryInfo('doujinshi', '同人志', '#E85C5C'),
  new CategoryInfo('manga', '漫画', '#E8963C'),
  new CategoryInfo('artistcg', '画师CG', '#C9A227'),
  new CategoryInfo('gamecg', '游戏CG', '#4E9E5A'),
  new CategoryInfo('imageset', '图集', '#3C8FE8'),
  new CategoryInfo('cosplay', 'Cosplay', '#A45CD8'),
  new CategoryInfo('asianporn', '亚洲', '#D8578C'),
  new CategoryInfo('non-h', '非 H', '#7A8290'),
  new CategoryInfo('western', '欧美', '#C97B3C'),
  new CategoryInfo('misc', '其他', '#8E8E93')
];

export class Categories {
  static of(raw: string): CategoryInfo {
    const key: string = raw.trim().toLowerCase().split(' ').join('');
    for (let i = 0; i < CATEGORIES.length; i++) {
      if (CATEGORIES[i].name === key) {
        return CATEGORIES[i];
      }
    }
    return new CategoryInfo('misc', raw.length > 0 ? raw : '其他', '#8E8E93');
  }
}

/** 标签命名空间：展示名 + 配色 */
export class NamespaceInfo {
  ns: string;
  label: string;
  color: string;

  constructor(ns: string, label: string, color: string) {
    this.ns = ns;
    this.label = label;
    this.color = color;
  }
}

const NAMESPACES: NamespaceInfo[] = [
  new NamespaceInfo('reclass', '重分类', '#E85C5C'),
  new NamespaceInfo('language', '语言', '#E8963C'),
  new NamespaceInfo('parody', '原作', '#8B5CF6'),
  new NamespaceInfo('character', '角色', '#3B82F6'),
  new NamespaceInfo('group', '社团', '#4E9E5A'),
  new NamespaceInfo('artist', '画师', '#E85C9B'),
  new NamespaceInfo('cosplayer', 'Coser', '#D8A45C'),
  new NamespaceInfo('female', '女性', '#E86FAE'),
  new NamespaceInfo('male', '男性', '#4FA3FF'),
  new NamespaceInfo('mixed', '混合', '#B07CFF'),
  new NamespaceInfo('other', '其他', '#8E8E93')
];

export class Namespaces {
  static of(ns: string): NamespaceInfo {
    for (let i = 0; i < NAMESPACES.length; i++) {
      if (NAMESPACES[i].ns === ns) {
        return NAMESPACES[i];
      }
    }
    return new NamespaceInfo(ns, ns, '#8E8E93');
  }
}

/** 收藏夹分类名（0-9 + 已删除） */
export class FavCats {
  static readonly NAMES: string[] = [
    'Favorite 0', 'Favorite 1', 'Favorite 2', 'Favorite 3', 'Favorite 4',
    'Favorite 5', 'Favorite 6', 'Favorite 7', 'Favorite 8', 'Favorite 9'
  ];

  static label(cat: number): string {
    if (cat < 0 || cat > 9) {
      return '已删除';
    }
    return FavCats.NAMES[cat];
  }
}

/** 搜索时“排除分类”的位掩码：与 EH 的 f_cats 参数一致（默认全部包含 = 0） */
export class SearchCats {
  static readonly ALL: number = 0;
}
