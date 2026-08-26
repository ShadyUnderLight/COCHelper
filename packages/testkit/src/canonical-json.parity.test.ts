import { describe, expect, it } from 'vitest';

import {
  bytesToHex,
  canonicalBytes,
  canonicalize,
  jsonNumber,
  parseJson,
  type CanonicalJsonValue,
} from '@coc-helper/wire';

import { compareParity, loadGoldenBytes, loadGoldenJson } from './index';

describe('canonical JSON golden（WA-2）', () => {
  it('逐字节对齐 Tests/Golden/Fixtures/canonical-json-expected.json', () => {
    const samplesRoot = parseJson(loadGoldenBytes('canonical-json-samples.json'));
    const expected = loadGoldenJson<{ expectations: Record<string, string> }>(
      'canonical-json-expected.json',
    );

    const sampleMap = objectFields(field(samplesRoot, 'samples'));
    const sampleIds = Object.keys(sampleMap).sort();
    const expectedIds = Object.keys(expected.expectations).sort();
    compareParity({ expected: expectedIds, actual: sampleIds, defaultKind: 'ordering' });

    for (const id of sampleIds) {
      const canonical = canonicalize(sampleMap[id]!);
      compareParity({
        expected: expected.expectations[id],
        actual: bytesToHex(canonicalBytes(canonical)),
        path: `$.${id}`,
      });
    }
  });

  it('canonical bytes 重解析后必须幂等', () => {
    const samplesRoot = parseJson(loadGoldenBytes('canonical-json-samples.json'));
    const sampleMap = objectFields(field(samplesRoot, 'samples'));
    for (const [id, sample] of Object.entries(sampleMap)) {
      const bytes = canonicalBytes(canonicalize(sample));
      const reparsed = canonicalize(parseJson(bytes));
      compareParity({
        expected: bytesToHex(bytes),
        actual: bytesToHex(canonicalBytes(reparsed)),
        path: `$.${id}`,
      });
    }
  });

  it('JSON.parse 会丢掉 2^53+1，lossless 解析必须保住', () => {
    const token = '9007199254740993';
    expect(JSON.parse(token)).toBe(9007199254740992);
    const parsed = parseJson(token);
    expect(parsed).toEqual(jsonNumber(token));
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
