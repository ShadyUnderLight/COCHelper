import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { bytesToHex, canonicalBytes, canonicalize, parseJson } from './index';

const fixturePath = join(process.cwd(), 'Tests/Golden/Fixtures/json-raw-samples.json');

type Sample = {
  id: string;
  source: string;
  canonicalHex: string;
};

type Reject = {
  id: string;
  source: string;
};

type Fixture = {
  samples: Sample[];
  rejects: Reject[];
};

describe('raw JSON source golden（WA-1 parser parity）', () => {
  const fixture = JSON.parse(readFileSync(fixturePath, 'utf8')) as Fixture;

  it('NFC 等价键与 surrogate pair 对齐 CanonicalJSONValue.fromJSONData', () => {
    for (const sample of fixture.samples) {
      const canonical = canonicalize(parseJson(sample.source));
      expect(bytesToHex(canonicalBytes(canonical)), sample.id).toBe(sample.canonicalHex);
    }
  });

  it('孤立 surrogate 必须拒绝', () => {
    expect(fixture.rejects.length).toBeGreaterThan(0);
    for (const sample of fixture.rejects) {
      expect(() => parseJson(sample.source), sample.id).toThrow();
    }
  });

  it('JS 字符串重载上的未转义孤立 surrogate 必须拒绝', () => {
    expect(() => parseJson(`"${String.fromCharCode(0xd800)}"`)).toThrow();
    expect(() => parseJson(`"${String.fromCharCode(0xdc00)}"`)).toThrow();
    expect(() => parseJson(`"${String.fromCharCode(0xd800, 0x41)}"`)).toThrow();
    const pair = parseJson(`"${String.fromCharCode(0xd800, 0xdc00)}"`);
    expect(pair).toEqual({ kind: 'string', value: '\u{10000}' });
  });
});
