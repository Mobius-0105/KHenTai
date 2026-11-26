/**
 * 一个够用的 HTML 解析器 + CSS 选择器子集。
 *
 * 为什么自己写：鸿蒙没有内置 DOM，而 E-Hentai 只提供 HTML（没有完整的 JSON 列表 API）。
 * 引入第三方解析库不现实（ArkTS 生态里没有可直接用的），所以这里实现一个容错解析器，
 * 对外提供与 CSS 一致的选择器语义，解析代码才能照着 JHenTai 原版的选择器直接抄。
 *
 * 支持的选择器子集：
 *   tag            div
 *   .class         .glink / .itg.gltc（多类并列）
 *   #id            #gn / #gdd
 *   :nth-child(n)  tr:nth-child(5)（1 基，仅数字）
 *   后代 / 子代     "div.itg tr"、"#gdd > table > tbody > tr"
 *   分组           ".a, .b"（逗号）
 *
 * 不支持 :not()、属性选择器、伪元素 —— 用到的页面里也不需要。
 */
export class HNode {
  tag: string = '';
  attrs: Map<string, string> = new Map<string, string>();
  children: HNode[] = [];
  parent: HNode | null = null;
  /** 仅当该节点是文本节点时有效 */
  text: string = '';
  isText: boolean = false;

  attr(name: string): string {
    const v: string | undefined = this.attrs.get(name);
    return v === undefined ? '' : v;
  }

  hasAttr(name: string): boolean {
    return this.attrs.has(name);
  }

  classes(): string[] {
    const c: string = this.attr('class');
    if (c.length === 0) {
      return [];
    }
    const out: string[] = [];
    const parts: string[] = c.split(' ');
    for (let i = 0; i < parts.length; i++) {
      const t: string = parts[i].trim();
      if (t.length > 0) {
        out.push(t);
      }
    }
    return out;
  }

  hasClass(name: string): boolean {
    const list: string[] = this.classes();
    for (let i = 0; i < list.length; i++) {
      if (list[i] === name) {
        return true;
      }
    }
    return false;
  }

  /** 元素的直接子元素 */
  elementChildren(): HNode[] {
    const out: HNode[] = [];
    for (let i = 0; i < this.children.length; i++) {
      if (!this.children[i].isText) {
        out.push(this.children[i]);
      }
    }
    return out;
  }

  /** 递归拼接的纯文本（已压缩空白） */
  textContent(): string {
    const sb: string[] = [];
    HNode.collectText(this, sb);
    return HNode.normalize(sb.join(' '));
  }

  private static collectText(n: HNode, out: string[]): void {
    if (n.isText) {
      out.push(n.text);
      return;
    }
    if (n.tag === 'script' || n.tag === 'style') {
      return;
    }
    for (let i = 0; i < n.children.length; i++) {
      HNode.collectText(n.children[i], out);
    }
  }

  private static normalize(s: string): string {
    let out: string = '';
    let space: boolean = false;
    for (let i = 0; i < s.length; i++) {
      const ch: string = s.charAt(i);
      if (ch === ' ' || ch === '\n' || ch === '\r' || ch === '\t') {
        space = true;
      } else {
        if (space && out.length > 0) {
          out += ' ';
        }
        space = false;
        out += ch;
      }
    }
    return out.trim();
  }

  /** 所有后代元素（不含自身） */
  descendants(): HNode[] {
    const out: HNode[] = [];
    HNode.walk(this, out);
    return out;
  }

  private static walk(n: HNode, out: HNode[]): void {
    for (let i = 0; i < n.children.length; i++) {
      const c: HNode = n.children[i];
      if (!c.isText) {
        out.push(c);
        HNode.walk(c, out);
      }
    }
  }

  find(selector: string): HNode[] {
    return Css.select(this, selector);
  }

  findFirst(selector: string): HNode | null {
    const list: HNode[] = Css.select(this, selector);
    return list.length > 0 ? list[0] : null;
  }

  /** 首个匹配节点的文本，找不到返回空串 */
  textOf(selector: string): string {
    const n: HNode | null = this.findFirst(selector);
    return n === null ? '' : n.textContent();
  }

  /** 首个匹配节点的属性，找不到返回空串 */
  attrOf(selector: string, name: string): string {
    const n: HNode | null = this.findFirst(selector);
    return n === null ? '' : n.attr(name);
  }
}

/** 选择器的一段：复合选择器 + 与上一段的关系 */
class SelPart {
  tag: string = '';
  id: string = '';
  classes: string[] = [];
  nthChild: number = 0;
  /** ' ' = 任意祖先，'>' = 直接父节点 */
  combinator: string = ' ';
}

const VOID_TAGS: string[] = [
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source',
  'track', 'wbr'
];

const RAW_TAGS: string[] = ['script', 'style', 'textarea', 'title'];

/** CSS 选择器子集的实现 */
export class Css {

  static select(root: HNode, selector: string): HNode[] {
    const groups: string[] = selector.split(',');
    const all: HNode[] = root.descendants();
    const out: HNode[] = [];
    const seen: Set<HNode> = new Set<HNode>();
    for (let g = 0; g < groups.length; g++) {
      const parts: SelPart[] = Css.parse(groups[g].trim());
      if (parts.length === 0) {
        continue;
      }
      for (let i = 0; i < all.length; i++) {
        const n: HNode = all[i];
        if (Css.matches(n, parts, parts.length - 1)) {
          if (!seen.has(n)) {
            seen.add(n);
            out.push(n);
          }
        }
      }
    }
    return out;
  }

  private static parse(selector: string): SelPart[] {
    // 把 '>' 拆成独立 token，方便统一按空格切分
    const normalized: string = ' ' + selector.split('>').join(' > ') + ' ';
    const tokens: string[] = normalized.split(' ').filter((t: string): boolean => t.length > 0);
    const parts: SelPart[] = [];
    let pendingCombinator: string = ' ';
    for (let i = 0; i < tokens.length; i++) {
      const t: string = tokens[i];
      if (t === '>') {
        pendingCombinator = '>';
        continue;
      }
      const p: SelPart = Css.parseCompound(t);
      if (p.tag.length === 0 && p.id.length === 0 && p.classes.length === 0 && p.nthChild === 0) {
        continue;
      }
      p.combinator = parts.length === 0 ? ' ' : pendingCombinator;
      pendingCombinator = ' ';
      parts.push(p);
    }
    return parts;
  }

  private static parseCompound(token: string): SelPart {
    const p: SelPart = new SelPart();
    let i: number = 0;
    // 标签名
    let tag: string = '';
    while (i < token.length && token.charAt(i) !== '.' && token.charAt(i) !== '#' && token.charAt(i) !== ':') {
      tag += token.charAt(i);
      i++;
    }
    p.tag = tag.toLowerCase();
    while (i < token.length) {
      const ch: string = token.charAt(i);
      if (ch === '.') {
        i++;
        let cls: string = '';
        while (i < token.length && token.charAt(i) !== '.' && token.charAt(i) !== '#' && token.charAt(i) !== ':') {
          cls += token.charAt(i);
          i++;
        }
        if (cls.length > 0) {
          p.classes.push(cls);
        }
      } else if (ch === '#') {
        i++;
        let id: string = '';
        while (i < token.length && token.charAt(i) !== '.' && token.charAt(i) !== '#' && token.charAt(i) !== ':') {
          id += token.charAt(i);
          i++;
        }
        p.id = id;
      } else if (ch === ':') {
        i++;
        let pseudo: string = '';
        while (i < token.length && token.charAt(i) !== '.') {
          pseudo += token.charAt(i);
          i++;
        }
        // 只认 :nth-child(n)
        const m: RegExpMatchArray | null = pseudo.match(/nth-child\((\d+)\)/);
        if (m !== null) {
          p.nthChild = parseInt(m[1], 10);
        }
      } else {
        i++;
      }
    }
    return p;
  }

  private static matchesCompound(n: HNode, p: SelPart): boolean {
    if (n.isText) {
      return false;
    }
    if (p.tag.length > 0 && n.tag !== p.tag) {
      return false;
    }
    if (p.id.length > 0 && n.attr('id') !== p.id) {
      return false;
    }
    for (let i = 0; i < p.classes.length; i++) {
      if (!n.hasClass(p.classes[i])) {
        return false;
      }
    }
    if (p.nthChild > 0) {
      const parent: HNode | null = n.parent;
      if (parent === null) {
        return false;
      }
      const siblings: HNode[] = parent.elementChildren();
      let idx: number = -1;
      for (let i = 0; i < siblings.length; i++) {
        if (siblings[i] === n) {
          idx = i;
          break;
        }
      }
      if (idx + 1 !== p.nthChild) {
        return false;
      }
    }
    return true;
  }

  /** 从 idx 往前匹配整条链 */
  private static matches(n: HNode, parts: SelPart[], idx: number): boolean {
    if (!Css.matchesCompound(n, parts[idx])) {
      return false;
    }
    if (idx === 0) {
      return true;
    }
    const comb: string = parts[idx].combinator;
    if (comb === '>') {
      const p: HNode | null = n.parent;
      if (p === null || p.tag.length === 0) {
        return false;
      }
      return Css.matches(p, parts, idx - 1);
    }
    let cur: HNode | null = n.parent;
    while (cur !== null && cur.tag.length > 0) {
      if (Css.matches(cur, parts, idx - 1)) {
        return true;
      }
      cur = cur.parent;
    }
    return false;
  }
}

/** HTML -> 节点树 */
export class Html {

  static parse(html: string): HNode {
    const root: HNode = new HNode();
    root.tag = '#document';
    const stack: HNode[] = [root];
    let i: number = 0;
    const n: number = html.length;

    while (i < n) {
      const lt: number = html.indexOf('<', i);
      if (lt < 0) {
        Html.addText(stack[stack.length - 1], html.substring(i));
        break;
      }
      if (lt > i) {
        Html.addText(stack[stack.length - 1], html.substring(i, lt));
      }
      // 注释 / doctype / CDATA
      if (html.startsWith('<!--', lt)) {
        const end: number = html.indexOf('-->', lt + 4);
        i = end < 0 ? n : end + 3;
        continue;
      }
      if (html.startsWith('<!', lt) || html.startsWith('<?', lt)) {
        const end: number = html.indexOf('>', lt);
        i = end < 0 ? n : end + 1;
        continue;
      }
      // 闭合标签
      if (html.startsWith('</', lt)) {
        const end: number = html.indexOf('>', lt);
        const name: string = html.substring(lt + 2, end < 0 ? n : end).trim().toLowerCase();
        Html.closeTag(stack, name);
        i = end < 0 ? n : end + 1;
        continue;
      }
      // 开始标签
      const tagInfo: TagInfo = Html.readOpenTag(html, lt);
      if (tagInfo.end <= lt) {
        // 不是合法标签，当普通文本
        Html.addText(stack[stack.length - 1], '<');
        i = lt + 1;
        continue;
      }
      // 隐式闭合：这些标签在同一容器里出现第二个时，前一个必须结束。
      // 不按 HTML 规范处理的话，站点一旦省掉 </a>（压缩输出里常见），20 个格子会
      // **层层嵌套**：`#gdt a` 仍然返回 20 个节点，但每个节点的子树都包含了后面所有格子，
      // 于是「取锚点里的第一个 img/背景」会得到同一个地址 —— 一屏同图就是这么来的。
      Html.autoClose(stack, tagInfo.name);
      const el: HNode = new HNode();
      el.tag = tagInfo.name;
      el.attrs = tagInfo.attrs;
      const parent: HNode = stack[stack.length - 1];
      el.parent = parent;
      parent.children.push(el);

      i = tagInfo.end;
      if (!tagInfo.selfClosing && !Html.isVoid(el.tag)) {
        if (Html.isRaw(el.tag)) {
          // script/style 内部不再解析标签
          const close: number = Html.indexOfIgnoreCase(html, '</' + el.tag, i);
          const textEnd: number = close < 0 ? n : close;
          if (textEnd > i) {
            Html.addText(el, html.substring(i, textEnd));
          }
          const gt: number = close < 0 ? n : html.indexOf('>', close);
          i = gt < 0 ? n : gt + 1;
        } else {
          stack.push(el);
        }
      }
    }
    return root;
  }

  private static isVoid(tag: string): boolean {
    for (let i = 0; i < VOID_TAGS.length; i++) {
      if (VOID_TAGS[i] === tag) {
        return true;
      }
    }
    return false;
  }

  private static isRaw(tag: string): boolean {
    for (let i = 0; i < RAW_TAGS.length; i++) {
      if (RAW_TAGS[i] === tag) {
        return true;
      }
    }
    return false;
  }

  private static indexOfIgnoreCase(hay: string, needle: string, from: number): number {
    const lower: string = hay.toLowerCase();
    return lower.indexOf(needle.toLowerCase(), from);
  }

  /**
   * 隐式闭合：遇到新标签时，把仍然开着的「同类标签」先关掉。
   *
   * 只处理会互相嵌套导致子树串味的几对（a / li / p / td / th / tr）。
   * 其它标签不做猜测 —— 乱关比不关更糟。
   */
  private static autoClose(stack: HNode[], tag: string): void {
    let closeWith: string = '';
    if (tag === 'a') {
      closeWith = 'a';
    } else if (tag === 'li') {
      closeWith = 'li';
    } else if (tag === 'p') {
      closeWith = 'p';
    } else if (tag === 'td' || tag === 'th') {
      closeWith = 'td';
    } else if (tag === 'tr') {
      closeWith = 'tr';
    }
    if (closeWith.length === 0) {
      return;
    }
    for (let i = stack.length - 1; i >= 1; i--) {
      const t: string = stack[i].tag;
      if (t === closeWith || (closeWith === 'td' && t === 'th')) {
        stack.length = i;
        return;
      }
      // 遇到容器级标签就停：说明上一个同类标签已经在别的作用域里闭合了
      if (t === 'table' || t === 'div' || t === 'ul' || t === 'body') {
        return;
      }
    }
  }

  /** 闭合到最近的同名标签；找不到就忽略这个闭合标签 */
  private static closeTag(stack: HNode[], name: string): void {
    for (let i = stack.length - 1; i >= 1; i--) {
      if (stack[i].tag === name) {
        stack.length = i;
        return;
      }
    }
  }

  private static addText(parent: HNode, raw: string): void {
    const text: string = Html.decodeEntities(raw);
    if (text.length === 0) {
      return;
    }
    // 纯空白文本节点没有用，直接丢（选择器不依赖它）
    if (text.trim().length === 0) {
      return;
    }
    const t: HNode = new HNode();
    t.isText = true;
    t.text = text;
    t.parent = parent;
    parent.children.push(t);
  }

  /** 解析 `<tag attr="v" ...>`，返回结束位置 */
  private static readOpenTag(html: string, lt: number): TagInfo {
    const info: TagInfo = new TagInfo();
    let i: number = lt + 1;
    const n: number = html.length;
    let name: string = '';
    while (i < n) {
      const ch: string = html.charAt(i);
      if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '>' || ch === '/') {
        break;
      }
      name += ch;
      i++;
    }
    if (name.length === 0 || !Html.isLetter(name.charAt(0))) {
      info.end = lt;
      return info;
    }
    info.name = name.toLowerCase();

    while (i < n) {
      // 跳过空白
      while (i < n && Html.isSpace(html.charAt(i))) {
        i++;
      }
      if (i >= n) {
        break;
      }
      const ch: string = html.charAt(i);
      if (ch === '>') {
        info.end = i + 1;
        return info;
      }
      if (ch === '/') {
        info.selfClosing = true;
        const gt: number = html.indexOf('>', i);
        info.end = gt < 0 ? n : gt + 1;
        return info;
      }
      // 属性名
      let key: string = '';
      while (i < n) {
        const c: string = html.charAt(i);
        if (c === '=' || c === ' ' || c === '>' || c === '/' || c === '\t' || c === '\n' || c === '\r') {
          break;
        }
        key += c;
        i++;
      }
      if (key.length === 0) {
        i++;
        continue;
      }
      while (i < n && Html.isSpace(html.charAt(i))) {
        i++;
      }
      let value: string = '';
      if (i < n && html.charAt(i) === '=') {
        i++;
        while (i < n && Html.isSpace(html.charAt(i))) {
          i++;
        }
        const quote: string = i < n ? html.charAt(i) : '';
        if (quote === '"' || quote === '\'') {
          const endQuote: number = html.indexOf(quote, i + 1);
          const stop: number = endQuote < 0 ? n : endQuote;
          value = html.substring(i + 1, stop);
          i = stop + 1;
        } else {
          let v: string = '';
          while (i < n) {
            const c: string = html.charAt(i);
            if (c === ' ' || c === '>' || c === '\t' || c === '\n' || c === '\r') {
              break;
            }
            v += c;
            i++;
          }
          value = v;
        }
      }
      if (!info.attrs.has(key.toLowerCase())) {
        info.attrs.set(key.toLowerCase(), Html.decodeEntities(value));
      }
    }
    info.end = n;
    return info;
  }

  private static isLetter(ch: string): boolean {
    return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
  }

  private static isSpace(ch: string): boolean {
    return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r';
  }

  /** 只处理常见的实体，够解析 EH 页面 */
  static decodeEntities(s: string): string {
    if (s.indexOf('&') < 0) {
      return s;
    }
    let out: string = '';
    let i: number = 0;
    while (i < s.length) {
      const amp: number = s.indexOf('&', i);
      if (amp < 0) {
        out += s.substring(i);
        break;
      }
      out += s.substring(i, amp);
      const semi: number = s.indexOf(';', amp);
      if (semi < 0 || semi - amp > 10) {
        out += '&';
        i = amp + 1;
        continue;
      }
      const body: string = s.substring(amp + 1, semi);
      const decoded: string = Html.decodeOne(body);
      if (decoded.length === 0) {
        out += '&' + body + ';';
      } else {
        out += decoded;
      }
      i = semi + 1;
    }
    return out;
  }

  private static decodeOne(body: string): string {
    switch (body) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return '\'';
      case 'nbsp':
        return ' ';
      case '#39':
        return '\'';
      default:
        break;
    }
    if (body.startsWith('#x') || body.startsWith('#X')) {
      const code: number = parseInt(body.substring(2), 16);
      return isNaN(code) ? '' : String.fromCharCode(code);
    }
    if (body.startsWith('#')) {
      const code: number = parseInt(body.substring(1), 10);
      return isNaN(code) ? '' : String.fromCharCode(code);
    }
    return '';
  }
}

class TagInfo {
  name: string = '';
  attrs: Map<string, string> = new Map<string, string>();
  selfClosing: boolean = false;
  end: number = 0;
}
