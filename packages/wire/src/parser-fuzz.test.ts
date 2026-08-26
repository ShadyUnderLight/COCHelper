import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { bytesToHex, canonicalBytes, canonicalize, parseJson } from './index';

const fixturePath = join(process.cwd(), 'Tests/Golden/Fixtures/primitive-fuzz-corpus.json');

type ValidCase = {
  id: string;
  source: string;
  canonicalHex: string;
};

type RejectCase = {
  id: string;
  source: string;
};

type FuzzCorpus = {
  valid: ValidCase[];
  rejects: RejectCase[];
};

describe('共享原语 parser boundary corpus', () => {
  const corpus = JSON.parse(readFileSync(fixturePath, 'utf8')) as FuzzCorpus;

  it('保留深层结构、长整数和 __proto__ 普通键', () => {
    for (const sample of corpus.valid) {
      const canonical = canonicalize(parseJson(sample.source));
      expect(bytesToHex(canonicalBytes(canonical)), sample.id).toBe(sample.canonicalHex);
    }
  });

  it('拒绝语法、surrogate 和非有限数字边界', () => {
    for (const sample of corpus.rejects) {
      expect(() => parseJson(sample.source), sample.id).toThrow();
    }
  });
});
