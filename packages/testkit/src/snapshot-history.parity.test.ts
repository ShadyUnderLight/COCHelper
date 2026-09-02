import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import {
  canonicalizeSnapshotHistory,
  historyEntryWireHex,
  parseAccountSnapshot,
} from '@coc-helper/domain';
import { bytesToHex, canonicalBytes, canonicalize, parseJson } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { assertParity } from './compare';
import { compareManualOutcomeParity } from './manual-parity-compare';
import { createSwiftOracleRunner, SWIFT_ORACLE_PROTOCOL_VERSION } from './oracle';

const root = process.cwd();
const oracle = createSwiftOracleRunner({ root });

const GOLDEN_IMPORTED_AT_REF_SECONDS = 807_529_133;
const GOLDEN_APPLIED_AT_REF_SECONDS = 807_629_133;
const GOLDEN_VILLAGE_ID = '00000000-0000-0000-0000-000000000001';
const GOLDEN_LINEAGE_ID = '00000000-0000-0000-0000-000000000002';
const GOLDEN_SNAPSHOT_ID = '00000000-0000-0000-0000-000000000003';

class GoldenClock {
  nowMs(): number {
    return (GOLDEN_IMPORTED_AT_REF_SECONDS + 978_307_200) * 1000;
  }
}

function manualParityHex(value: Record<string, string>): string {
  const bytes = canonicalBytes(canonicalize(parseJson(JSON.stringify(value))));
  return bytesToHex(bytes);
}

describe('snapshot history Swift oracle parity', () => {
  it('golden canonicalize 与 Swift oracle 一致', async () => {
    const goldenText = readFileSync(
      resolve(root, 'Tests/Golden/Fixtures/account_snapshot_golden.json'),
      'utf8',
    );
    const expected = JSON.parse(
      readFileSync(resolve(root, 'Tests/Golden/Fixtures/parser_golden_expected.json'), 'utf8'),
    ) as {
      historyEntry: {
        canonicalFingerprint: string;
        integrityFingerprint: string;
        encodedJSONHex: string;
      };
    };

    const parsed = parseAccountSnapshot(goldenText, { clock: new GoldenClock() });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }

    const entry = canonicalizeSnapshotHistory(parsed.value, {
      villageID: GOLDEN_VILLAGE_ID,
      lineageID: GOLDEN_LINEAGE_ID,
      appliedAtRefSeconds: GOLDEN_APPLIED_AT_REF_SECONDS,
      snapshotID: GOLDEN_SNAPSHOT_ID,
    });

    expect(entry.canonicalFingerprint).toBe(expected.historyEntry.canonicalFingerprint);
    expect(entry.integrityFingerprint).toBe(expected.historyEntry.integrityFingerprint);
    expect(historyEntryWireHex(entry)).toBe(expected.historyEntry.encodedJSONHex);

    const source = JSON.stringify({
      kind: 'canonicalize',
      snapshotText: goldenText,
      villageID: GOLDEN_VILLAGE_ID,
      lineageID: GOLDEN_LINEAGE_ID,
      snapshotID: GOLDEN_SNAPSHOT_ID,
      appliedAtRefSeconds: GOLDEN_APPLIED_AT_REF_SECONDS,
      importedAtRefSeconds: GOLDEN_IMPORTED_AT_REF_SECONDS,
    });

    const response = await oracle({
      protocolVersion: SWIFT_ORACLE_PROTOCOL_VERSION,
      caseId: 'snapshot-history-golden-canonicalize',
      operation: 'snapshot-history-canonicalize',
      source,
    });

    const typescriptHex = manualParityHex({
      canonicalFingerprint: entry.canonicalFingerprint,
      encodedJSONHex: historyEntryWireHex(entry),
      integrityFingerprint: entry.integrityFingerprint,
    });

    assertParity(
      compareManualOutcomeParity({
        caseId: 'snapshot-history-golden-canonicalize',
        source,
        typescriptHex,
        swift: response,
        category: 'wire',
      }),
    );
  });
});
