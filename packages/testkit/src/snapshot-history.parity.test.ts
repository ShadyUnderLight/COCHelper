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
import { createSwiftOracleRunner, SWIFT_ORACLE_PROTOCOL_VERSION } from './oracle';

const root = process.cwd();
const oracle = createSwiftOracleRunner({ root });

const GOLDEN_IMPORTED_AT_REF_SECONDS = 807_529_133;
const GOLDEN_APPLIED_AT_REF_SECONDS = 807_629_133;
const VILLAGE_ID = '00000000-0000-0000-0000-000000000001';
const LINEAGE_ID = '00000000-0000-0000-0000-000000000002';

class GoldenClock {
  nowMs(): number {
    return (GOLDEN_IMPORTED_AT_REF_SECONDS + 978_307_200) * 1000;
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

function buildEntry(input: {
  readonly text: string;
  readonly appliedAtRefSeconds: number;
  readonly snapshotID: string;
  readonly lineageID?: string;
}) {
  const parsed = parseAccountSnapshot(input.text, { clock: new GoldenClock() });
  expect(parsed.ok).toBe(true);
  if (!parsed.ok) {
    throw new Error('parse failed');
  }
  return canonicalizeSnapshotHistory(parsed.value, {
    villageID: VILLAGE_ID,
    lineageID: input.lineageID ?? LINEAGE_ID,
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
  const goldenText = readFileSync(
    resolve(root, 'Tests/Golden/Fixtures/account_snapshot_golden.json'),
    'utf8',
  );
  const parsed = parseAccountSnapshot(goldenText, { clock: new GoldenClock() });
  expect(parsed.ok).toBe(true);
  if (!parsed.ok) {
    return;
  }
  const entry = canonicalizeSnapshotHistory(parsed.value, {
    villageID: VILLAGE_ID,
    lineageID: LINEAGE_ID,
    appliedAtRefSeconds: GOLDEN_APPLIED_AT_REF_SECONDS,
    snapshotID: '00000000-0000-0000-0000-000000000003',
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
      resolve(root, 'Tests/Golden/Fixtures/account_snapshot_golden.json'),
      'utf8',
    );
    await assertCanonicalizeParity(
      'snapshot-history-golden-canonicalize',
      JSON.stringify({
        kind: 'canonicalize',
        snapshotText: goldenText,
        villageID: VILLAGE_ID,
        lineageID: LINEAGE_ID,
        snapshotID: '00000000-0000-0000-0000-000000000003',
        appliedAtRefSeconds: GOLDEN_APPLIED_AT_REF_SECONDS,
        importedAtRefSeconds: GOLDEN_IMPORTED_AT_REF_SECONDS,
      }),
    );
  });

  it('diff level increased 与 Swift oracle 一致', async () => {
    const from = buildEntry({
      text: '{"tag":"#GOLDEN01","buildings":[{"data":1000013,"lvl":1}]}',
      appliedAtRefSeconds: 100,
      snapshotID: '00000000-0000-0000-0000-000000000010',
    });
    const to = buildEntry({
      text: '{"tag":"#GOLDEN01","buildings":[{"data":1000013,"lvl":2}]}',
      appliedAtRefSeconds: 200,
      snapshotID: '00000000-0000-0000-0000-000000000011',
    });
    await assertDiffParity('snapshot-history-diff-level-increased', from, to);
  });

  it('diff A→B→A comparable no change 与 Swift oracle 一致', async () => {
    const a = buildEntry({
      text: '{"tag":"#GOLDEN01","buildings":[{"data":1000013,"lvl":5}]}',
      appliedAtRefSeconds: 100,
      snapshotID: '00000000-0000-0000-0000-000000000020',
    });
    const b = buildEntry({
      text: '{"tag":"#GOLDEN01","buildings":[{"data":1000013,"lvl":6}]}',
      appliedAtRefSeconds: 200,
      snapshotID: '00000000-0000-0000-0000-000000000021',
    });
    const a2 = buildEntry({
      text: '{"tag":"#GOLDEN01","buildings":[{"data":1000013,"lvl":5}]}',
      appliedAtRefSeconds: 300,
      snapshotID: '00000000-0000-0000-0000-000000000022',
    });
    await assertDiffParity('snapshot-history-diff-b-to-a', b, a2);
  });

  it('diff partial coverage 不产生删除 与 Swift oracle 一致', async () => {
    const from = buildEntry({
      text: '{"tag":"#GOLDEN01","buildings":[{"data":1000013,"lvl":1},{"data":1000016,"lvl":1}]}',
      appliedAtRefSeconds: 100,
      snapshotID: '00000000-0000-0000-0000-000000000030',
    });
    const to = buildEntry({
      text: '{"tag":"#GOLDEN01","buildings":[{"data":1000013,"lvl":2}]}',
      appliedAtRefSeconds: 200,
      snapshotID: '00000000-0000-0000-0000-000000000031',
    });
    await assertDiffParity('snapshot-history-diff-partial-coverage', from, to);
  });
});
