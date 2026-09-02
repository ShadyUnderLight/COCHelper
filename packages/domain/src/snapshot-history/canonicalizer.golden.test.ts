import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { parseUuid } from '@coc-helper/wire';

import { parseAccountSnapshot } from '../account/parser';
import { describe, expect, it } from 'vitest';

import { canonicalizeSnapshotHistory } from './canonicalizer';
import { historyEntryWireHex } from './wire-encode';

const GOLDEN_IMPORTED_AT_REF_SECONDS = 807_529_133;
const GOLDEN_APPLIED_AT_REF_SECONDS = 807_629_133;
const GOLDEN_VILLAGE_ID = parseUuid('00000000-0000-0000-0000-000000000001')!;
const GOLDEN_LINEAGE_ID = parseUuid('00000000-0000-0000-0000-000000000002')!;
const GOLDEN_SNAPSHOT_ID = parseUuid('00000000-0000-0000-0000-000000000003')!;

class GoldenClock {
  nowMs(): number {
    return (GOLDEN_IMPORTED_AT_REF_SECONDS + 978_307_200) * 1000;
  }
}

describe('SnapshotHistoryCanonicalizer golden', () => {
  it('canonicalFingerprint、integrityFingerprint 与 encodedJSONHex 匹配冻结值', () => {
    const root = resolve(process.cwd());
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
      isBaseline: false,
      baselineReason: null,
    });

    expect(entry.canonicalFingerprint).toBe(expected.historyEntry.canonicalFingerprint);
    expect(entry.integrityFingerprint).toBe(expected.historyEntry.integrityFingerprint);
    expect(historyEntryWireHex(entry)).toBe(expected.historyEntry.encodedJSONHex);
  });
});
