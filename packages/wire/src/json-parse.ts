import {
  JsonParseError,
  emptyJsonObjectFields,
  jsonArray,
  jsonBool,
  jsonNull,
  jsonNumber,
  jsonObject,
  jsonString,
  type CanonicalJsonValue,
} from './json-value';
import { normalizeJsonNumberToken } from './json-number';

/**
 * Lossless JSON 解析（WA-1）。允许 fragment，对齐 `JSONSerialization` `.fragmentsAllowed`。
 * 禁止走 `JSON.parse`：大于 Number.MAX_SAFE_INTEGER 的整数必须保住。
 */
export function parseJson(input: string | Uint8Array): CanonicalJsonValue {
  const text = typeof input === 'string' ? input : decodeUtf8(input);
  const parser = new JsonParser(text);
  return parser.parseDocument();
}

function decodeUtf8(bytes: Uint8Array): string {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    throw new JsonParseError('JSON 不是合法 UTF-8。');
  }
}

class JsonParser {
  private pos = 0;

  constructor(private readonly source: string) {}

  parseDocument(): CanonicalJsonValue {
    this.skipWs();
    if (this.pos >= this.source.length) {
      throw new JsonParseError('JSON 为空。');
    }
    const value = this.parseValue();
    this.skipWs();
    if (this.pos !== this.source.length) {
      throw new JsonParseError('JSON 在值之后还有多余内容。');
    }
    return value;
  }

  private parseValue(): CanonicalJsonValue {
    const ch = this.peek();
    if (ch === '{') {
      return this.parseObject();
    }
    if (ch === '[') {
      return this.parseArray();
    }
    if (ch === '"') {
      return jsonString(this.parseString());
    }
    if (ch === 't') {
      this.expectLiteral('true');
      return jsonBool(true);
    }
    if (ch === 'f') {
      this.expectLiteral('false');
      return jsonBool(false);
    }
    if (ch === 'n') {
      this.expectLiteral('null');
      return jsonNull();
    }
    if (ch === '-' || isDigit(ch)) {
      return jsonNumber(normalizeJsonNumberToken(this.parseNumberToken()));
    }
    throw new JsonParseError('发现不支持的 JSON 值类型。');
  }

  private parseObject(): CanonicalJsonValue {
    this.expect('{');
    this.skipWs();
    const fields = emptyJsonObjectFields();
    // NFC 身份 → 当前胜出拼写。JS Record 用原始字符串相等，无法单独表达 Swift String ==。
    const identityKeys = new Map<string, string>();
    if (this.peek() === '}') {
      this.pos += 1;
      return jsonObject(fields);
    }
    while (true) {
      this.skipWs();
      if (this.peek() !== '"') {
        throw new JsonParseError('对象键必须是字符串。');
      }
      const key = this.parseString();
      this.skipWs();
      this.expect(':');
      this.skipWs();
      this.assignObjectField(fields, identityKeys, key, this.parseValue());
      this.skipWs();
      const next = this.peek();
      if (next === ',') {
        this.pos += 1;
        continue;
      }
      if (next === '}') {
        this.pos += 1;
        break;
      }
      throw new JsonParseError('对象语法错误。');
    }
    return jsonObject(fields);
  }

  /**
   * 对齐 `JSONSerialization.jsonObject` → `[String: Any]` → `CanonicalJSONValue`。
   *
   * NSDictionary 按 NSString 字面值保留重复键；桥接到 Swift Dictionary 时按
   * `String` 规范化等价合并。实测：
   * - 相同拼写：JSONSerialization 保留首次值；
   * - UTF-16 更长的拼写覆盖（NFC vs NFD 时即 NFD）；
   * - 等长但拼写不同：后出现的拼写和值胜出（Å vs Å）。
   */
  private assignObjectField(
    fields: Record<string, CanonicalJsonValue>,
    identityKeys: Map<string, string>,
    key: string,
    value: CanonicalJsonValue,
  ): void {
    const identity = key.normalize('NFC');
    const stored = identityKeys.get(identity);
    if (stored !== undefined && (key === stored || key.length < stored.length)) {
      return;
    }
    if (stored !== undefined && stored !== key) {
      delete fields[stored];
    }
    identityKeys.set(identity, key);
    fields[key] = value;
  }

  private parseArray(): CanonicalJsonValue {
    this.expect('[');
    this.skipWs();
    if (this.peek() === ']') {
      this.pos += 1;
      return jsonArray([]);
    }
    const items: CanonicalJsonValue[] = [];
    while (true) {
      this.skipWs();
      items.push(this.parseValue());
      this.skipWs();
      const next = this.peek();
      if (next === ',') {
        this.pos += 1;
        continue;
      }
      if (next === ']') {
        this.pos += 1;
        break;
      }
      throw new JsonParseError('数组语法错误。');
    }
    return jsonArray(items);
  }

  private parseString(): string {
    this.expect('"');
    let result = '';
    while (this.pos < this.source.length) {
      const ch = this.source[this.pos]!;
      if (ch === '"') {
        this.pos += 1;
        return result;
      }
      if (ch === '\\') {
        this.pos += 1;
        result += this.parseEscape();
        continue;
      }
      const code = ch.charCodeAt(0);
      if (code < 0x20) {
        throw new JsonParseError('字符串含有未转义的控制字符。');
      }
      if (code >= 0xd800 && code <= 0xdbff) {
        const low = this.source.charCodeAt(this.pos + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          result += ch + this.source[this.pos + 1]!;
          this.pos += 2;
          continue;
        }
        throw new JsonParseError('孤立的 Unicode 代理项。');
      }
      if (code >= 0xdc00 && code <= 0xdfff) {
        throw new JsonParseError('孤立的 Unicode 代理项。');
      }
      result += ch;
      this.pos += 1;
    }
    throw new JsonParseError('字符串未闭合。');
  }

  private parseEscape(): string {
    const ch = this.peek();
    this.pos += 1;
    switch (ch) {
      case '"':
      case '\\':
      case '/':
        return ch;
      case 'b':
        return '\b';
      case 'f':
        return '\f';
      case 'n':
        return '\n';
      case 'r':
        return '\r';
      case 't':
        return '\t';
      case 'u': {
        const code = this.parseHex4();
        if (code >= 0xd800 && code <= 0xdbff) {
          if (!this.source.startsWith('\\u', this.pos)) {
            throw new JsonParseError('孤立的 Unicode 代理项。');
          }
          this.pos += 2;
          const low = this.parseHex4();
          if (low < 0xdc00 || low > 0xdfff) {
            throw new JsonParseError('非法 Unicode 代理对。');
          }
          return String.fromCodePoint(0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00));
        }
        if (code >= 0xdc00 && code <= 0xdfff) {
          throw new JsonParseError('孤立的 Unicode 代理项。');
        }
        return String.fromCharCode(code);
      }
      default:
        throw new JsonParseError('非法转义序列。');
    }
  }

  private parseHex4(): number {
    const hex = this.source.slice(this.pos, this.pos + 4);
    if (!/^[0-9a-fA-F]{4}$/.test(hex)) {
      throw new JsonParseError('非法 \\u 转义。');
    }
    this.pos += 4;
    return Number.parseInt(hex, 16);
  }

  private parseNumberToken(): string {
    const start = this.pos;
    if (this.peek() === '-') {
      this.pos += 1;
    }
    if (this.peek() === '0') {
      this.pos += 1;
      if (isDigit(this.peek())) {
        throw new JsonParseError('数字不得有前导零。');
      }
    } else if (isDigit1to9(this.peek())) {
      this.pos += 1;
      while (isDigit(this.peek())) {
        this.pos += 1;
      }
    } else {
      throw new JsonParseError('非法数字。');
    }
    if (this.peek() === '.') {
      this.pos += 1;
      if (!isDigit(this.peek())) {
        throw new JsonParseError('小数点后必须有数字。');
      }
      while (isDigit(this.peek())) {
        this.pos += 1;
      }
    }
    const exp = this.peek();
    if (exp === 'e' || exp === 'E') {
      this.pos += 1;
      const sign = this.peek();
      if (sign === '+' || sign === '-') {
        this.pos += 1;
      }
      if (!isDigit(this.peek())) {
        throw new JsonParseError('指数必须有数字。');
      }
      while (isDigit(this.peek())) {
        this.pos += 1;
      }
    }
    return this.source.slice(start, this.pos);
  }

  private expectLiteral(literal: string): void {
    if (!this.source.startsWith(literal, this.pos)) {
      throw new JsonParseError('发现不支持的 JSON 值类型。');
    }
    this.pos += literal.length;
  }

  private expect(ch: string): void {
    if (this.peek() !== ch) {
      throw new JsonParseError(`期望 '${ch}'。`);
    }
    this.pos += 1;
  }

  private skipWs(): void {
    while (this.pos < this.source.length) {
      const code = this.source.charCodeAt(this.pos);
      if (code === 0x20 || code === 0x09 || code === 0x0a || code === 0x0d) {
        this.pos += 1;
        continue;
      }
      break;
    }
  }

  private peek(): string {
    return this.source[this.pos] ?? '';
  }
}

function isDigit(ch: string): boolean {
  return ch >= '0' && ch <= '9';
}

function isDigit1to9(ch: string): boolean {
  return ch >= '1' && ch <= '9';
}
