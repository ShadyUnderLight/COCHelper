import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import {
  SnapshotDiffEngine,
  canonicalizeSnapshotHistory,
  encodeHistoryEntryWire,
  historyEntryWireHex,
  hydrateVerifiedCoverageOnEntry,
  parseAccountSnapshot,
  snapshotDiffWireHex,
} from '@coc-helper/domain';
import {
  bytesToHex,
  canonicalBytes,
  canonicalize,
  parseJson,
  parseUuid,
  type Sha256Fingerprint,
} from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { assertParity } from './compare';
import { compareManualOutcomeParity } from './manual-parity-compare';
import { loadGoldenManifest, readGoldenFixture } from './manifest';
import { createSwiftOracleRunner, SWIFT_ORACLE_PROTOCOL_VERSION } from './oracle';

type DiffContractEntry = {
  readonly text: string;
  readonly appliedAtRefSeconds: number;
  readonly snapshotID: string;
  readonly lineageID?: string;
};

type FrozenOutcome = {
  readonly comparisonState?: string;
  readonly changeCount?: string;
  readonly encodedJSONHex?: string;
  readonly outputFingerprint: string;
  readonly canonicalHex: string;
};

type DiffContract = {
  readonly importedAtRefSeconds: number;
  readonly villageID: string;
  readonly lineageID: string;
  readonly canonicalizeCase: {
    readonly id: string;
    readonly snapshotFixture: string;
    readonly snapshotID: string;
    readonly appliedAtRefSeconds: number;
    readonly importedAtRefSeconds: number;
    readonly expected: FrozenOutcome;
  };
  readonly diffCases: readonly {
    readonly id: string;
    readonly from: DiffContractEntry;
    readonly to: DiffContractEntry;
    readonly expected: FrozenOutcome & {
      readonly comparisonState: string;
      readonly changeCount: string;
      readonly encodedJSONHex: string;
    };
  }[];
};

const root = process.cwd();
const manifest = loadGoldenManifest(root);
const diffContractEntry = manifest.cases.find(
  (entry) => entry.id === 'diff/snapshot-history-contract',
);
if (diffContractEntry === undefined) {
  throw new Error('golden manifest 缺少 diff/snapshot-history-contract。');
}
const diffContract = readGoldenFixture(root, diffContractEntry) as DiffContract;
const oracle = createSwiftOracleRunner({ root });

const VILLAGE_ID = parseUuid(diffContract.villageID)!;
const LINEAGE_ID = parseUuid(diffContract.lineageID)!;

class GoldenClock {
  constructor(private readonly importedAtRefSeconds: number) {}

  nowMs(): number {
    return (this.importedAtRefSeconds + 978_307_200) * 1000;
  }
}

function manualParityHex(value: Record<string, string>): string {
  const bytes = canonicalBytes(canonicalize(parseJson(JSON.stringify(value))));
  return bytesToHex(bytes);
}

function hydrateEntry(entry: ReturnType<typeof canonicalizeSnapshotHistory>) {
  return hydrateVerifiedCoverageOnEntry({
    entry: entry as Parameters<typeof hydrateVerifiedCoverageOnEntry>[0]['entry'],
    policy: 'testsAllowTestFixture',
  });
}

function buildEntry(input: DiffContractEntry) {
  const parsed = parseAccountSnapshot(input.text, {
    clock: new GoldenClock(diffContract.importedAtRefSeconds),
  });
  expect(parsed.ok).toBe(true);
  if (!parsed.ok) {
    throw new Error('parse failed');
  }
  return canonicalizeSnapshotHistory(parsed.value, {
    villageID: VILLAGE_ID,
    lineageID: input.lineageID === undefined ? LINEAGE_ID : parseUuid(input.lineageID)!,
    appliedAtRefSeconds: input.appliedAtRefSeconds,
    snapshotID: parseUuid(input.snapshotID)!,
  });
}

function buildDiffOutcome(
  from: ReturnType<typeof buildEntry>,
  to: ReturnType<typeof buildEntry>,
): string {
  const diff = SnapshotDiffEngine.compare(hydrateEntry(from), hydrateEntry(to));
  return manualParityHex({
    comparisonState: diff.comparisonState,
    changeCount: String(diff.changes.length),
    encodedJSONHex: snapshotDiffWireHex(diff, from.appliedAtRefSeconds, to.appliedAtRefSeconds),
  });
}

function assertFrozenSemanticFields(
  caseId: string,
  actual: ReturnType<typeof SnapshotDiffEngine.compare>,
  from: ReturnType<typeof buildEntry>,
  to: ReturnType<typeof buildEntry>,
  expected: FrozenOutcome,
): void {
  expect(actual.comparisonState, `${caseId}.comparisonState`).toBe(expected.comparisonState);
  expect(String(actual.changes.length), `${caseId}.changeCount`).toBe(expected.changeCount);
  expect(
    snapshotDiffWireHex(actual, from.appliedAtRefSeconds, to.appliedAtRefSeconds),
    `${caseId}.encodedJSONHex`,
  ).toBe(expected.encodedJSONHex);
}

async function assertFrozenOutcomeParity(input: {
  readonly caseId: string;
  readonly source: string;
  readonly operation: 'snapshot-history-canonicalize' | 'snapshot-history-diff';
  readonly typescriptHex: string;
  readonly expected: FrozenOutcome;
}): Promise<void> {
  const response = await oracle({
    protocolVersion: SWIFT_ORACLE_PROTOCOL_VERSION,
    caseId: input.caseId,
    operation: input.operation,
    source: input.source,
  });
  assertParity(
    compareManualOutcomeParity({
      caseId: input.caseId,
      source: input.source,
      typescriptHex: input.typescriptHex,
      swift: response,
      expectedCanonicalHex: input.expected.canonicalHex,
      expectedOutputFingerprint: input.expected.outputFingerprint as Sha256Fingerprint,
      category: 'ordering',
    }),
  );
}

describe('snapshot history Swift oracle parity', () => {
  it('golden canonicalize 与 fixture expected 一致', async () => {
    const goldenText = readFileSync(
      resolve(root, diffContract.canonicalizeCase.snapshotFixture),
      'utf8',
    );
    const source = JSON.stringify({
      kind: 'canonicalize',
      snapshotText: goldenText,
      villageID: VILLAGE_ID,
      lineageID: LINEAGE_ID,
      snapshotID: diffContract.canonicalizeCase.snapshotID,
      appliedAtRefSeconds: diffContract.canonicalizeCase.appliedAtRefSeconds,
      importedAtRefSeconds: diffContract.canonicalizeCase.importedAtRefSeconds,
    });
    const parsed = parseAccountSnapshot(goldenText, {
      clock: new GoldenClock(diffContract.canonicalizeCase.importedAtRefSeconds),
    });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }
    const entry = canonicalizeSnapshotHistory(parsed.value, {
      villageID: VILLAGE_ID,
      lineageID: LINEAGE_ID,
      appliedAtRefSeconds: diffContract.canonicalizeCase.appliedAtRefSeconds,
      snapshotID: parseUuid(diffContract.canonicalizeCase.snapshotID)!,
    });
    const typescriptHex = manualParityHex({
      canonicalFingerprint: entry.canonicalFingerprint,
      encodedJSONHex: historyEntryWireHex(entry),
      integrityFingerprint: entry.integrityFingerprint,
    });
    await assertFrozenOutcomeParity({
      caseId: `snapshot-history-${diffContract.canonicalizeCase.id}`,
      source,
      operation: 'snapshot-history-canonicalize',
      typescriptHex,
      expected: diffContract.canonicalizeCase.expected,
    });
  });

  for (const contractCase of diffContract.diffCases) {
    it(`diff ${contractCase.id} 与 fixture expected 一致`, async () => {
      const from = buildEntry(contractCase.from);
      const to = buildEntry(contractCase.to);
      const diff = SnapshotDiffEngine.compare(hydrateEntry(from), hydrateEntry(to));
      assertFrozenSemanticFields(contractCase.id, diff, from, to, contractCase.expected);
      const source = JSON.stringify({
        kind: 'diff',
        fromEntryJSON: encodeHistoryEntryWire(from),
        toEntryJSON: encodeHistoryEntryWire(to),
      });
      await assertFrozenOutcomeParity({
        caseId: `snapshot-history-diff-${contractCase.id}`,
        source,
        operation: 'snapshot-history-diff',
        typescriptHex: buildDiffOutcome(from, to),
        expected: contractCase.expected,
      });
    });
  }
});
