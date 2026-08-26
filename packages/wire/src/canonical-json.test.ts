import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  bytesToHex,
  canonicalBytes,
  canonicalize,
  jsonArray,
  jsonNumber,
  parseJson,
} from './index';
import type { CanonicalJsonValue } from './json-value';

const fixtureDir = join(process.cwd(), 'Tests/Golden/Fixtures');

describe('canonical JSON golden（WA-2）', () => {
  it('逐字节对齐 Tests/Golden/Fixtures/canonical-json-expected.json', () => {
    const samplesRoot = parseJson(readFileSync(join(fixtureDir, 'canonical-json-samples.json')));
    const expected = JSON.parse(
      readFileSync(join(fixtureDir, 'canonical-json-expected.json'), 'utf8'),
    ) as { expectations: Record<string, string> };

    const sampleMap = objectFields(field(samplesRoot, 'samples'));
    const sampleIds = Object.keys(sampleMap).sort();
    const expectedIds = Object.keys(expected.expectations).sort();
    expect(sampleIds).toEqual(expectedIds);

    for (const id of sampleIds) {
      const canonical = canonicalize(sampleMap[id]!);
      expect(bytesToHex(canonicalBytes(canonical)), id).toBe(expected.expectations[id]);
    }
  });

  it('canonical bytes 重解析后必须幂等', () => {
    const samplesRoot = parseJson(readFileSync(join(fixtureDir, 'canonical-json-samples.json')));
    const sampleMap = objectFields(field(samplesRoot, 'samples'));
    for (const [id, sample] of Object.entries(sampleMap)) {
      const bytes = canonicalBytes(canonicalize(sample));
      const reparsed = canonicalize(parseJson(bytes));
      expect(bytesToHex(canonicalBytes(reparsed)), id).toBe(bytesToHex(bytes));
    }
  });

  it('JSON.parse 会丢掉 2^53+1，lossless 解析必须保住', () => {
    const token = '9007199254740993';
    expect(JSON.parse(token)).toBe(9007199254740992);
    const parsed = parseJson(token);
    expect(parsed).toEqual(jsonNumber(token));
  });
});

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

function field(value: CanonicalJsonValue, key: string): CanonicalJsonValue {
  if (value.kind !== 'object' || value.fields[key] === undefined) {
    throw new Error(`缺少字段 ${key}`);
  }
  return value.fields[key];
}

function objectFields(value: CanonicalJsonValue): Record<string, CanonicalJsonValue> {
  if (value.kind !== 'object') {
    throw new Error('期望对象');
  }
  return { ...value.fields };
}

function jsonEscapeProbe(): string {
  return `"${String.fromCharCode(0x7f)}\u2028\u2029x"`;
}
