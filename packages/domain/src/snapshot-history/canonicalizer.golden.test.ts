import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { parseUuid } from '@coc-helper/wire';

import { parseAccountSnapshot } from '../account/parser';
import { describe, expect, it } from 'vitest';

import { canonicalizeSnapshotHistory, observationIdentityKey } from './canonicalizer';
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
  it('observation 身份稳定且 encodedJSONHex 匹配冻结值（Issue #304 无 fingerprint）', () => {
    const root = resolve(process.cwd());
    const goldenText = readFileSync(
      resolve(root, 'Tests/Golden/Fixtures/account_snapshot_golden.json'),
      'utf8',
    );
    const expected = JSON.parse(
      readFileSync(resolve(root, 'Tests/Golden/Fixtures/parser_golden_expected.json'), 'utf8'),
    ) as {
      historyEntry: {
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

    // 相同输入重复归一化 → 同一 observation 身份（duplicate 判等基础）。
    const reparsed = parseAccountSnapshot(goldenText, { clock: new GoldenClock() });
    expect(reparsed.ok).toBe(true);
    if (!reparsed.ok) {
      return;
    }
    const again = canonicalizeSnapshotHistory(reparsed.value, {
      villageID: GOLDEN_VILLAGE_ID,
      lineageID: GOLDEN_LINEAGE_ID,
      appliedAtRefSeconds: GOLDEN_APPLIED_AT_REF_SECONDS,
      snapshotID: GOLDEN_SNAPSHOT_ID,
      isBaseline: false,
      baselineReason: null,
    });
    expect(observationIdentityKey(again.observation)).toBe(
      observationIdentityKey(entry.observation),
    );
    expect(historyEntryWireHex(entry)).toBe(expected.historyEntry.encodedJSONHex);
  });
});
