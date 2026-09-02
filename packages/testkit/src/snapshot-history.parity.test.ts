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
import { bytesToHex, canonicalBytes, canonicalize, parseJson, parseUuid } from '@coc-helper/wire';
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

type DiffContract = {
  readonly importedAtRefSeconds: number;
  readonly appliedAtRefSeconds: number;
  readonly villageID: string;
  readonly lineageID: string;
  readonly canonicalizeCase: {
    readonly id: string;
    readonly snapshotFixture: string;
    readonly snapshotID: string;
    readonly appliedAtRefSeconds: number;
    readonly importedAtRefSeconds: number;
  };
  readonly diffCases: readonly {
    readonly id: string;
    readonly from: DiffContractEntry;
    readonly to: DiffContractEntry;
  }[];
};

const root = process.cwd();
const manifest = loadGoldenManifest(root);
const diffContractEntry = manifest.cases.find((entry) => entry.id === 'diff/snapshot-history-contract');
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

async function assertCanonicalizeParity(caseId: string, source: string): Promise<void> {
  const response = await oracle({
    protocolVersion: SWIFT_ORACLE_PROTOCOL_VERSION,
    caseId,
    operation: 'snapshot-history-canonicalize',
    source,
  });
  const goldenText = readFileSync(resolve(root, diffContract.canonicalizeCase.snapshotFixture), 'utf8');
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
  assertParity(
    compareManualOutcomeParity({
      caseId,
      source,
      typescriptHex,
      swift: response,
      category: 'wire',
    }),
  );
}

async function assertDiffParity(
  caseId: string,
  from: ReturnType<typeof buildEntry>,
  to: ReturnType<typeof buildEntry>,
): Promise<void> {
  const fromHydrated = hydrateEntry(from);
  const toHydrated = hydrateEntry(to);
  const diff = SnapshotDiffEngine.compare(fromHydrated, toHydrated);
  const source = JSON.stringify({
    kind: 'diff',
    fromEntryJSON: encodeHistoryEntryWire(from),
    toEntryJSON: encodeHistoryEntryWire(to),
  });
  const response = await oracle({
    protocolVersion: SWIFT_ORACLE_PROTOCOL_VERSION,
    caseId,
    operation: 'snapshot-history-diff',
    source,
  });
  const typescriptHex = manualParityHex({
    comparisonState: diff.comparisonState,
    changeCount: String(diff.changes.length),
    encodedJSONHex: snapshotDiffWireHex(diff, from.appliedAtRefSeconds, to.appliedAtRefSeconds),
  });
  assertParity(
    compareManualOutcomeParity({
      caseId,
      source,
      typescriptHex,
      swift: response,
      category: 'wire',
    }),
  );
}

describe('snapshot history Swift oracle parity', () => {
  it('golden canonicalize 与 Swift oracle 一致', async () => {
    const goldenText = readFileSync(
      resolve(root, diffContract.canonicalizeCase.snapshotFixture),
      'utf8',
    );
    await assertCanonicalizeParity(
      `snapshot-history-${diffContract.canonicalizeCase.id}`,
      JSON.stringify({
        kind: 'canonicalize',
        snapshotText: goldenText,
        villageID: VILLAGE_ID,
        lineageID: LINEAGE_ID,
        snapshotID: diffContract.canonicalizeCase.snapshotID,
        appliedAtRefSeconds: diffContract.canonicalizeCase.appliedAtRefSeconds,
        importedAtRefSeconds: diffContract.canonicalizeCase.importedAtRefSeconds,
      }),
    );
  });

  for (const contractCase of diffContract.diffCases) {
    it(`diff ${contractCase.id} 与 Swift oracle 一致`, async () => {
      const from = buildEntry(contractCase.from);
      const to = buildEntry(contractCase.to);
      await assertDiffParity(`snapshot-history-diff-${contractCase.id}`, from, to);
    });
  }
});
