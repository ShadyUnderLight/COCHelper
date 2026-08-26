import { describe, expect, it } from 'vitest';

import {
  jsonBool,
  jsonNull,
  jsonNumber,
  jsonString,
  parseCanonicalizerInt64,
  parseCatalogDataIdKey,
  parseLegacyInt64,
  parseSwiftInt64,
} from './index';

describe('Int64 三层解析（WA-6）', () => {
  it('Canonicalizer 只接受 number token', () => {
    expect(parseCanonicalizerInt64(jsonNumber('2'))).toBe(2n);
    expect(parseCanonicalizerInt64(jsonNumber('+0000002'))).toBe(2n);
    expect(parseCanonicalizerInt64(jsonString('2'))).toBeUndefined();
    expect(parseCanonicalizerInt64(jsonNumber('2.0'))).toBeUndefined();
    expect(parseCanonicalizerInt64(jsonBool(true))).toBeUndefined();
    expect(parseCanonicalizerInt64(jsonNull())).toBeUndefined();
    expect(parseCanonicalizerInt64(jsonNumber('9223372036854775808'))).toBeUndefined();
    expect(parseCanonicalizerInt64(jsonNumber('-9223372036854775808'))).toBe(-9223372036854775808n);
  });

  it('legacy importer 接受字符串非规范形式和整 Double', () => {
    expect(parseLegacyInt64(jsonString('+0000002'))).toEqual({ ok: true, value: 2n });
    expect(parseLegacyInt64(jsonNumber('2'))).toEqual({ ok: true, value: 2n });
    expect(parseLegacyInt64(jsonNumber('2.0'))).toEqual({ ok: true, value: 2n });
    expect(parseLegacyInt64(undefined)).toEqual({ ok: false, reason: 'missing' });
    expect(parseLegacyInt64(jsonNull())).toEqual({ ok: false, reason: 'missing' });
    expect(parseLegacyInt64(jsonString('2.5'))).toEqual({ ok: false, reason: 'typeMismatch' });
    expect(parseLegacyInt64(jsonNumber('2.5'))).toEqual({ ok: false, reason: 'typeMismatch' });
    expect(parseLegacyInt64(jsonNumber('9223372036854775808'))).toEqual({
      ok: false,
      reason: 'typeMismatch',
    });
  });

  it('catalog 宇宙键拒绝非 canonical 重序列化', () => {
    expect(parseCatalogDataIdKey('buildings:2')).toEqual({
      ok: true,
      section: 'buildings',
      dataID: 2n,
    });
    expect(parseCatalogDataIdKey('buildings:+0000002').ok).toBe(false);
    expect(parseCatalogDataIdKey('buildings:02').ok).toBe(false);
    expect(parseCatalogDataIdKey(':2').ok).toBe(false);
    expect(parseCatalogDataIdKey('buildings:').ok).toBe(false);
    expect(parseCatalogDataIdKey('buildings:2:3').ok).toBe(false);
    expect(parseSwiftInt64('+0000002')).toBe(2n);
  });
});
