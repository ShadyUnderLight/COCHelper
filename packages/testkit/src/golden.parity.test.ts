import { describe, it } from 'vitest';

import { bytesToHex, canonicalBytes, canonicalize, parseJson } from '@coc-helper/wire';

import {
  assertParity,
  compareCanonicalParity,
  createSwiftOracleRunner,
  loadGoldenManifest,
  readGoldenFixture,
  SWIFT_ORACLE_PROTOCOL_VERSION,
  type CanonicalOutcome,
} from './index';

type CorpusSample = {
  readonly id: string;
  readonly source: string;
  readonly canonicalHex?: string;
};

type Corpus = {
  readonly valid: readonly CorpusSample[];
  readonly rejects: readonly CorpusSample[];
};

const root = process.cwd();
const manifest = loadGoldenManifest(root);
const oracle = createSwiftOracleRunner({ root });

describe('Swift oracle / TypeScript golden parity', () => {
  for (const entry of manifest.cases) {
    it(entry.id, async () => {
      const corpus = parseCorpus(readGoldenFixture(root, entry));
      for (const sample of corpus.valid) {
        await assertSample(entry.id, sample, true, oracle);
      }
      for (const sample of corpus.rejects) {
        await assertSample(entry.id, sample, false, oracle);
      }
    });
  }
});

async function assertSample(
  caseId: string,
  sample: CorpusSample,
  accepted: boolean,
  runOracle: ReturnType<typeof createSwiftOracleRunner>,
): Promise<void> {
  const typescript = evaluate(sample.source);
  const swift = await runOracle({
    protocolVersion: SWIFT_ORACLE_PROTOCOL_VERSION,
    caseId: `${caseId}/${sample.id}`,
    operation: 'canonical-json',
    source: sample.source,
  });
  const report = compareCanonicalParity({
    caseId: `${caseId}/${sample.id}`,
    source: sample.source,
    expectedAccepted: accepted,
    expectedCanonicalHex: sample.canonicalHex,
    typescript,
    swift,
    category: 'wire',
  });
  assertParity(report);
}

function evaluate(source: string): CanonicalOutcome {
  try {
    return {
      ok: true,
      canonicalHex: bytesToHex(canonicalBytes(canonicalize(parseJson(source)))),
    };
  } catch {
    return { ok: false, errorKind: 'invalidJson' };
  }
}

function parseCorpus(value: unknown): Corpus {
  if (!isRecord(value) || !Array.isArray(value.samples) || !Array.isArray(value.rejects)) {
    throw new Error('parity fixture 必须包含 samples/rejects 数组。');
  }
  return {
    valid: value.samples.map((sample, index) => parseSample(sample, `samples[${index}]`, true)),
    rejects: value.rejects.map((sample, index) => parseSample(sample, `rejects[${index}]`, false)),
  };
}

function parseSample(value: unknown, label: string, requireCanonicalHex: boolean): CorpusSample {
  if (!isRecord(value) || typeof value.id !== 'string' || typeof value.source !== 'string') {
    throw new Error(`parity fixture ${label} 形状无效。`);
  }
  if (requireCanonicalHex && typeof value.canonicalHex !== 'string') {
    throw new Error(`parity fixture ${label} 缺少 canonicalHex。`);
  }
  return {
    id: value.id,
    source: value.source,
    canonicalHex: typeof value.canonicalHex === 'string' ? value.canonicalHex : undefined,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
