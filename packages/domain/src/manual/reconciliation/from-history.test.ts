import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../../account/parser';
import {
  canonicalizeSnapshotHistory,
  createSnapshotHistoryEnvelope,
  planSnapshotHistoryImport,
} from '../../snapshot-history';
import { SNAPSHOT_HISTORY_SCHEMA } from '../../snapshot-history/schema';
import { trackerItemKeyStableId } from '../types';
import {
  applyManualLineageComparable,
  buildReconciliationEvidenceFromActiveEntry,
  buildReconciliationEvidenceFromHistory,
  manualBaselineReferenceForHistoryEntry,
} from './from-history';

const TAG = '#2QJQ8J88';
const VILLAGE_ID = parseUuid('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')!;
const LINEAGE_ID = parseUuid('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')!;

class FixedClock {
  constructor(private readonly nowMsValue: number) {}
  nowMs(): number {
    return this.nowMsValue;
  }
}

function parseSnapshot(text: string) {
  const parsed = parseAccountSnapshot(text, {
    clock: new FixedClock(1_700_000_000_000),
  });
  expect(parsed.ok).toBe(true);
  if (!parsed.ok) {
    throw new Error('parse failed');
  }
  return parsed.value;
}

describe('buildReconciliationEvidenceFromHistory', () => {
  it('从首导入 entry 构建 baseline revision 与空 buildings observation', () => {
    const snapshot = parseSnapshot(`{"tag":"${TAG}","buildings":[]}`);
    const entry = canonicalizeSnapshotHistory(snapshot, {
      villageID: VILLAGE_ID,
      lineageID: LINEAGE_ID,
      appliedAtRefSeconds: 20,
      isBaseline: true,
      baselineReason: 'initial',
    });
    const envelope = createSnapshotHistoryEnvelope({
      entries: [entry],
      lineages: [
        {
          villageID: VILLAGE_ID,
          lineageID: entry.lineageID,
          normalizedPlayerTag: TAG,
          lastEntryID: entry.snapshotID,
          lastAppliedAtRefSeconds: entry.appliedAtRefSeconds,
          hasConflict: false,
          isActive: true,
        },
      ],
      migrationMarker: { version: SNAPSHOT_HISTORY_SCHEMA.envelope, completedAtRefSeconds: 20 },
    });
    const decision = planSnapshotHistoryImport({
      snapshot,
      villageID: VILLAGE_ID,
      currentTag: null,
      hasCurrentSnapshot: false,
      envelope: createSnapshotHistoryEnvelope({
        migrationMarker: {
          version: SNAPSHOT_HISTORY_SCHEMA.envelope,
          completedAtRefSeconds: 19,
        },
      }),
      appliedAtRefSeconds: 20,
    });

    const evidence = buildReconciliationEvidenceFromHistory({
      villageID: VILLAGE_ID,
      previousEntry: null,
      decision,
    });

    expect(evidence.villageID).toBe(VILLAGE_ID);
    expect(evidence.duplicate).toBe(false);
    expect(evidence.lineageComparable).toBe(true);
    expect(evidence.newBaselineReference).toEqual(
      manualBaselineReferenceForHistoryEntry(decision.entry, decision.envelope),
    );
    expect(evidence.newBaselineReference.revision).toBe(decision.entry.snapshotID);
    expect(evidence.newBaselineReference.lineageID).toBe(decision.entry.lineageID);
    expect(evidence.previousSnapshotID).toBeNull();
    // 空 buildings 数组不产生 item observation
    expect(evidence.observations.size).toBe(0);

    // 用已有 envelope 对照 reference 构造
    expect(manualBaselineReferenceForHistoryEntry(entry, envelope).revision).toBe(entry.snapshotID);
  });

  it('带等级的 building 生成 distributionComplete observation', () => {
    const snapshot = parseSnapshot(
      `{"tag":"${TAG}","buildings":[{"data":1000001,"lvl":3,"cnt":1}]}`,
    );
    const decision = planSnapshotHistoryImport({
      snapshot,
      villageID: VILLAGE_ID,
      currentTag: null,
      hasCurrentSnapshot: false,
      envelope: createSnapshotHistoryEnvelope({
        migrationMarker: {
          version: SNAPSHOT_HISTORY_SCHEMA.envelope,
          completedAtRefSeconds: 1,
        },
      }),
      appliedAtRefSeconds: 2,
    });

    const evidence = buildReconciliationEvidenceFromHistory({
      villageID: VILLAGE_ID,
      previousEntry: null,
      decision,
    });

    expect(evidence.observations.size).toBe(1);
    const [stableId, observation] = [...evidence.observations.entries()][0]!;
    expect(observation.distributionComplete).toBe(true);
    expect(observation.distribution?.quantityAt(3)).toBe(1n);
    expect(evidence.itemKeysByStableID.get(stableId)?.dataID).toBe(1_000_001n);
    expect(stableId).toBe(trackerItemKeyStableId(evidence.itemKeysByStableID.get(stableId)!));
  });

  it('applyManualLineageComparable 在 baseline lineage 不一致时关闭 comparable', () => {
    const snapshot = parseSnapshot(`{"tag":"${TAG}","buildings":[]}`);
    const decision = planSnapshotHistoryImport({
      snapshot,
      villageID: VILLAGE_ID,
      currentTag: null,
      hasCurrentSnapshot: false,
      envelope: createSnapshotHistoryEnvelope({
        migrationMarker: {
          version: SNAPSHOT_HISTORY_SCHEMA.envelope,
          completedAtRefSeconds: 1,
        },
      }),
      appliedAtRefSeconds: 2,
    });
    const evidence = buildReconciliationEvidenceFromHistory({
      villageID: VILLAGE_ID,
      previousEntry: null,
      decision,
    });
    expect(evidence.lineageComparable).toBe(true);

    const patched = applyManualLineageComparable(evidence, {
      revision: 'old',
      lineageID: 'cccccccc-cccc-cccc-cccc-cccccccccccc',
    });
    expect(patched.lineageComparable).toBe(false);

    const same = applyManualLineageComparable(evidence, {
      revision: 'old',
      lineageID: evidence.newBaselineReference.lineageID,
    });
    expect(same.lineageComparable).toBe(true);
  });

  it('buildReconciliationEvidenceFromActiveEntry 对已有 entry 标记 duplicate=false', () => {
    const snapshot = parseSnapshot(
      `{"tag":"${TAG}","buildings":[{"data":1000001,"lvl":3,"cnt":1}]}`,
    );
    const decision = planSnapshotHistoryImport({
      snapshot,
      villageID: VILLAGE_ID,
      currentTag: null,
      hasCurrentSnapshot: false,
      envelope: createSnapshotHistoryEnvelope({
        migrationMarker: {
          version: SNAPSHOT_HISTORY_SCHEMA.envelope,
          completedAtRefSeconds: 1,
        },
      }),
      appliedAtRefSeconds: 2,
    });
    const evidence = buildReconciliationEvidenceFromActiveEntry({
      villageID: VILLAGE_ID,
      envelope: decision.envelope,
      activeEntry: decision.entry,
    });
    expect(evidence.duplicate).toBe(false);
    expect(evidence.newBaselineReference.revision).toBe(decision.entry.snapshotID);
    expect(evidence.observations.size).toBe(1);
  });
});
