// Minimal reader/writer for WoW SavedVariables files.
// Supports exactly what WoW writes: top-level `Name = value` assignments,
// tables with [key] = value / key = value / positional entries, strings,
// numbers, booleans, nil and -- comments.

export function parseSavedVariables(src) {
  const p = new Parser(src);
  const out = {};
  p.skip();
  while (!p.eof()) {
    const name = p.ident();
    p.skip();
    p.expect('=');
    out[name] = p.value();
    p.skip();
    if (p.peek() === ';') { p.pos++; p.skip(); }
  }
  return out;
}

class Parser {
  constructor(src) { this.src = src; this.pos = 0; }
  eof() { return this.pos >= this.src.length; }
  peek() { return this.src[this.pos]; }
  fail(msg) {
    const line = this.src.slice(0, this.pos).split('\n').length;
    throw new Error(`lua parse error at line ${line}: ${msg}`);
  }
  expect(ch) {
    if (this.src[this.pos] !== ch) this.fail(`expected '${ch}', got '${this.peek() ?? 'EOF'}'`);
    this.pos++;
    this.skip();
  }
  skip() {
    for (;;) {
      while (!this.eof() && /\s/.test(this.peek())) this.pos++;
      if (this.src.startsWith('--', this.pos)) {
        if (this.src.startsWith('--[[', this.pos)) {
          const end = this.src.indexOf(']]', this.pos);
          this.pos = end < 0 ? this.src.length : end + 2;
        } else {
          const end = this.src.indexOf('\n', this.pos);
          this.pos = end < 0 ? this.src.length : end + 1;
        }
        continue;
      }
      return;
    }
  }
  ident() {
    const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(this.src.slice(this.pos, this.pos + 256));
    if (!m) this.fail('expected identifier');
    this.pos += m[0].length;
    return m[0];
  }
  value() {
    this.skip();
    const ch = this.peek();
    let v;
    if (ch === '{') v = this.table();
    else if (ch === '"' || ch === "'") v = this.string();
    else if (ch === '[' && /^\[=*\[/.test(this.src.slice(this.pos, this.pos + 16))) v = this.longString();
    else if (/[-0-9.]/.test(ch)) v = this.number();
    else {
      const word = this.ident();
      if (word === 'true') v = true;
      else if (word === 'false') v = false;
      else if (word === 'nil') v = null;
      else this.fail(`unexpected identifier '${word}'`);
    }
    this.skip();
    return v;
  }
  number() {
    const m = /^-?(0[xX][0-9a-fA-F]+|(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?|inf|nan)/.exec(this.src.slice(this.pos, this.pos + 64));
    if (!m) this.fail('bad number');
    this.pos += m[0].length;
    const t = m[0];
    if (/inf$/.test(t)) return t.startsWith('-') ? -Infinity : Infinity;
    if (/nan$/.test(t)) return NaN;
    if (/0[xX]/.test(t)) return (t.startsWith('-') ? -1 : 1) * parseInt(t.replace(/^-/, ''), 16);
    return Number(t);
  }
  string() {
    const q = this.src[this.pos++];
    let s = '';
    for (;;) {
      if (this.eof()) this.fail('unterminated string');
      const c = this.src[this.pos++];
      if (c === q) return s;
      if (c !== '\\') { s += c; continue; }
      const e = this.src[this.pos++];
      if (e === 'n') s += '\n';
      else if (e === 't') s += '\t';
      else if (e === 'r') s += '\r';
      else if (e === 'a') s += '\x07';
      else if (e === 'b') s += '\b';
      else if (e === 'f') s += '\f';
      else if (e === 'v') s += '\v';
      else if (e === '\n') s += '\n';
      else if (/\d/.test(e)) {
        const m = /^\d{1,3}/.exec(this.src.slice(this.pos - 1, this.pos + 2));
        this.pos += m[0].length - 1;
        s += String.fromCharCode(Number(m[0]));
      } else s += e; // \\ \" \' and anything else literal
    }
  }
  longString() {
    const m = /^\[(=*)\[/.exec(this.src.slice(this.pos, this.pos + 16));
    const close = `]${m[1]}]`;
    const start = this.pos + m[0].length;
    const end = this.src.indexOf(close, start);
    if (end < 0) this.fail('unterminated long string');
    this.pos = end + close.length;
    return this.src.slice(start, end).replace(/^\r?\n/, '');
  }
  table() {
    this.expect('{');
    const entries = [];
    let next = 1;
    while (this.peek() !== '}') {
      if (this.eof()) this.fail('unterminated table');
      let key;
      if (this.peek() === '[' && !/^\[=*\[/.test(this.src.slice(this.pos, this.pos + 16))) {
        this.pos++;
        key = this.value();
        this.expect(']');
        this.expect('=');
      } else {
        const save = this.pos;
        const m = /^[A-Za-z_][A-Za-z0-9_]*\s*=(?!=)/.exec(this.src.slice(this.pos, this.pos + 256));
        if (m && !/^(true|false|nil)\b/.test(m[0])) {
          key = this.ident();
          this.skip();
          this.expect('=');
        } else {
          this.pos = save;
          key = next++;
        }
      }
      const v = this.value();
      if (v !== null) entries.push([key, v]);
      if (this.peek() === ',' || this.peek() === ';') { this.pos++; this.skip(); }
      else if (this.peek() !== '}') this.fail(`expected ',' or '}', got '${this.peek() ?? 'EOF'}'`);
    }
    this.pos++;
    return toJs(entries);
  }
}

// A table whose keys are exactly 1..n becomes an array; anything else an object.
function toJs(entries) {
  const isArray = entries.length > 0 && entries.every(([k], i) => k === i + 1);
  if (isArray) return entries.map(([, v]) => v);
  const obj = {};
  for (const [k, v] of entries) obj[String(k)] = v;
  return obj;
}

export function toLua(value, indent = '') {
  if (value === null || value === undefined) return 'nil';
  if (typeof value === 'boolean') return String(value);
  if (typeof value === 'number') return Number.isFinite(value) ? String(value) : '0';
  if (typeof value === 'string') return luaString(value);
  const inner = indent + '\t';
  const lines = [];
  if (Array.isArray(value)) {
    for (const v of value) lines.push(`${inner}${toLua(v, inner)},`);
  } else {
    for (const [k, v] of Object.entries(value)) {
      if (v === undefined) continue;
      const key = /^-?\d+$/.test(k) ? `[${k}]`
        : /^[A-Za-z_][A-Za-z0-9_]*$/.test(k) && !LUA_KEYWORDS.has(k) ? k
        : `[${luaString(k)}]`;
      lines.push(`${inner}${key} = ${toLua(v, inner)},`);
    }
  }
  if (lines.length === 0) return '{}';
  return `{\n${lines.join('\n')}\n${indent}}`;
}

function luaString(s) {
  return '"' + s.replace(/[\\"\n\r\0]/g, c => ({ '\\': '\\\\', '"': '\\"', '\n': '\\n', '\r': '\\r', '\0': '\\0' })[c]) + '"';
}

const LUA_KEYWORDS = new Set(['and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until', 'while']);
