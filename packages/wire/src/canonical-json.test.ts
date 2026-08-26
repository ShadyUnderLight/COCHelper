import { describe, expect, it } from 'vitest';

import {
  bytesToHex,
  canonicalBytes,
  canonicalize,
  jsonArray,
  jsonNumber,
  parseJson,
} from './index';

describe('canonical JSON 排序与转义', () => {
  it('对象键序与数组序无关，重复数组元素保留', () => {
    const scrambled = parseJson('{"z":[{"b":2,"a":1},1,1,{"a":1,"b":2}],"a":[2,1,1]}');
    expect(new TextDecoder().decode(canonicalBytes(canonicalize(scrambled)))).toBe(
      '{"a":[1,1,2],"z":[1,1,{"a":1,"b":2},{"a":1,"b":2}]}',
    );

    const duplicates = canonicalize(parseJson('[1,1]'));
    const singleton = canonicalize(parseJson('[1]'));
    expect(bytesToHex(canonicalBytes(duplicates))).not.toBe(bytesToHex(canonicalBytes(singleton)));

    const left = canonicalize(parseJson('[1,2,1]'));
    const right = canonicalize(parseJson('[2,1,1]'));
    expect(bytesToHex(canonicalBytes(left))).toBe(bytesToHex(canonicalBytes(right)));
  });

  it('强制转义 solidus，且不转义 DEL / U+2028 / U+2029', () => {
    expect(new TextDecoder().decode(canonicalBytes(parseJson('"a/b"')))).toBe('"a\\/b"');
    const special = parseJson(jsonEscapeProbe());
    const encoded = new TextDecoder().decode(canonicalBytes(special));
    expect(encoded.includes('\\u007f')).toBe(false);
    expect(encoded.includes('\\u2028')).toBe(false);
    expect(encoded.includes('\\u2029')).toBe(false);
  });

  it('null 与空对象在 canonical 层可区分', () => {
    expect(bytesToHex(canonicalBytes(parseJson('{"k":null}')))).not.toBe(
      bytesToHex(canonicalBytes(parseJson('{}'))),
    );
  });

  it('1.0 / 1e2 规范化为 NSNumber.stringValue 形态', () => {
    expect(parseJson('1.0')).toEqual(jsonNumber('1'));
    expect(parseJson('1e2')).toEqual(jsonNumber('100'));
    expect(parseJson('-2.5')).toEqual(jsonNumber('-2.5'));
    expect(parseJson('-0')).toEqual(jsonNumber('0'));
  });

  it('拒绝畸形 JSON', () => {
    expect(() => parseJson('{not json')).toThrow();
    expect(() => parseJson('{"a":1,}')).toThrow();
    expect(() => parseJson('01')).toThrow();
    expect(() => parseJson('')).toThrow();
    expect(() => parseJson('[1] extra')).toThrow();
  });

  it('canonicalize 不改变重复项数量', () => {
    const value = canonicalize(jsonArray([jsonNumber('1'), jsonNumber('1')]));
    expect(value.kind === 'array' && value.items.length === 2).toBe(true);
  });
});

function jsonEscapeProbe(): string {
  return `"${String.fromCharCode(0x7f)}\u2028\u2029x"`;
}
