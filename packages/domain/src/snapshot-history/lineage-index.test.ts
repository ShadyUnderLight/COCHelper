import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account/parser';
import {
  canonicalizeSnapshotHistory,
  createSnapshotHistoryEnvelope,
  validateSnapshotHistoryEnvelope,
} from './index';
import { lineageIndexesEqual, recomputeLineageIndexFromEntries } from './lineage-index';
import { resolveSnapshotLineage } from './lineage-resolver';

const GOLDEN_IMPORTED_AT_REF_SECONDS = 807_529_133;
const APPLIED_AT = 100;
const VILLAGE_ID = parseUuid('cccccccc-cccc-cccc-cccc-cccccccccccc')!;
const TAG_A = '#2QJQ8J88';
const TAG_B = '#2QJQ8J89';
const SNAPSHOT_ID_FIRST = parseUuid('ffffffff-ffff-4fff-8fff-ffffffffffff')!;
const SNAPSHOT_ID_SECOND = parseUuid('00000000-0000-4000-8000-000000000001')!;

class GoldenClock {
  nowMs(): number {
    return (GOLDEN_IMPORTED_AT_REF_SECONDS + 978_307_200) * 1000;
  }
}

function snapshotFromTag(tag: string) {
  const parsed = parseAccountSnapshot(`{"tag":"${tag}","buildings":[]}`, {
    clock: new GoldenClock(),
  });
  expect(parsed.ok).toBe(true);
  if (!parsed.ok) {
    throw new Error('parse failed');
  }
  return parsed.value;
}

describe('recomputeLineageIndexFromEntries', () => {
  it('按 persisted entry 顺序 replay，相同 appliedAt 时不按 snapshotID 重排', () => {
    const firstLineage = resolveSnapshotLineage({
      villageID: VILLAGE_ID,
      normalizedPlayerTag: TAG_A,
      previous: null,
    });
    const entry1 = canonicalizeSnapshotHistory(snapshotFromTag(TAG_A), {
      villageID: VILLAGE_ID,
      lineageID: firstLineage.lineageID,
      appliedAtRefSeconds: APPLIED_AT,
      snapshotID: SNAPSHOT_ID_FIRST,
      isBaseline: true,
      baselineReason: 'initial',
    });

    const secondLineage = resolveSnapshotLineage({
      villageID: VILLAGE_ID,
      normalizedPlayerTag: TAG_B,
      previous: {
        villageID: VILLAGE_ID,
        lineageID: entry1.lineageID,
        normalizedPlayerTag: TAG_A,
        hasConflict: false,
      },
    });
    const entry2 = canonicalizeSnapshotHistory(snapshotFromTag(TAG_B), {
      villageID: VILLAGE_ID,
      lineageID: secondLineage.lineageID,
      appliedAtRefSeconds: APPLIED_AT,
      snapshotID: SNAPSHOT_ID_SECOND,
      isBaseline: true,
      baselineReason: 'tagChanged',
    });

    expect(String(SNAPSHOT_ID_SECOND) < String(SNAPSHOT_ID_FIRST)).toBe(true);

    const entries = [entry1, entry2];
    const lineages = recomputeLineageIndexFromEntries(entries);
    const active = lineages.find((lineage) => lineage.isActive);
    expect(active?.lineageID).toBe(entry2.lineageID);
    expect(active?.normalizedPlayerTag).toBe(TAG_B);
    expect(active?.lastEntryID).toBe(SNAPSHOT_ID_SECOND);

    const envelope = createSnapshotHistoryEnvelope({
      entries,
      lineages,
      migrationMarker: { version: 1, completedAtRefSeconds: APPLIED_AT },
    });
    expect(() => validateSnapshotHistoryEnvelope(envelope)).not.toThrow();
    expect(lineageIndexesEqual(lineages, envelope.lineages)).toBe(true);
  });
});
