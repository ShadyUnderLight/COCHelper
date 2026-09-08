import { parseUuid, refSecondsToUnixSeconds } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../../account/parser';
import {
  canonicalizeSnapshotHistory,
  createSnapshotHistoryEnvelope,
  planSnapshotHistoryImport,
} from '../../snapshot-history';
import { SNAPSHOT_HISTORY_SCHEMA } from '../../snapshot-history/schema';
import {
  createManualItemStateForStatus,
  createManualLevelDistributionFromPairs,
  createManualUpgradeCoreState,
} from '../core';
import { trackerItemKeyRoot, trackerItemKeyStableId } from '../types';
import { createManualTrackerVillageState } from '../village-state';
import {
  applyManualLineageComparable,
  buildReconciliationEvidenceFromActiveEntry,
  buildReconciliationEvidenceFromHistory,
  manualBaselineReferenceForHistoryEntry,
  previousEntryBeforeActive,
} from './from-history';
import { reconciliationTimeConfidence } from './helpers';
import { previewReconciliation } from './service';

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

function msFromRef(refSeconds: number): number {
  return refSecondsToUnixSeconds(refSeconds) * 1000;
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

  it('previousEntryBeforeActive 按 persisted append 顺序，不按 appliedAt/UUID 重排', () => {
    const snapshot = parseSnapshot(`{"tag":"${TAG}","buildings":[]}`);
    const appliedAt = 42;
    // UUID 字典序会把 C 排到最前；persisted 顺序仍是 A → B → C。
    const entryA = {
      ...canonicalizeSnapshotHistory(snapshot, {
        villageID: VILLAGE_ID,
        lineageID: LINEAGE_ID,
        appliedAtRefSeconds: appliedAt,
        snapshotID: parseUuid('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')!,
      }),
      sourceTimestampRefSeconds: 10,
    };
    const entryB = {
      ...canonicalizeSnapshotHistory(snapshot, {
        villageID: VILLAGE_ID,
        lineageID: LINEAGE_ID,
        appliedAtRefSeconds: appliedAt,
        snapshotID: parseUuid('cccccccc-cccc-cccc-cccc-cccccccccccc')!,
      }),
      sourceTimestampRefSeconds: 20,
    };
    const entryC = {
      ...canonicalizeSnapshotHistory(snapshot, {
        villageID: VILLAGE_ID,
        lineageID: LINEAGE_ID,
        appliedAtRefSeconds: appliedAt,
        snapshotID: parseUuid('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')!,
      }),
      sourceTimestampRefSeconds: 30,
    };
    expect([entryC.snapshotID, entryA.snapshotID, entryB.snapshotID].slice().sort()).toEqual([
      entryC.snapshotID,
      entryA.snapshotID,
      entryB.snapshotID,
    ]);

    const envelope = createSnapshotHistoryEnvelope({
      entries: [entryA, entryB, entryC],
      lineages: [
        {
          villageID: VILLAGE_ID,
          lineageID: LINEAGE_ID,
          normalizedPlayerTag: TAG,
          lastEntryID: entryC.snapshotID,
          lastAppliedAtRefSeconds: appliedAt,
          hasConflict: false,
          isActive: true,
        },
      ],
      migrationMarker: {
        version: SNAPSHOT_HISTORY_SCHEMA.envelope,
        completedAtRefSeconds: appliedAt,
      },
    });

    expect(previousEntryBeforeActive(envelope, entryC)?.snapshotID).toBe(entryB.snapshotID);
    expect(previousEntryBeforeActive(envelope, entryB)?.snapshotID).toBe(entryA.snapshotID);
    expect(previousEntryBeforeActive(envelope, entryA)).toBeNull();
  });

  it('duplicate metadata 的最新 source timestamp 用于 previous/current，避免 stale 被当成可靠新观察', () => {
    const snapshotE1 = parseSnapshot(
      `{"tag":"${TAG}","buildings":[{"data":1000001,"lvl":1,"cnt":1}]}`,
    );
    const snapshotE2 = parseSnapshot(
      `{"tag":"${TAG}","buildings":[{"data":1000001,"lvl":1,"cnt":1}]}`,
    );
    const entryE1 = {
      ...canonicalizeSnapshotHistory(snapshotE1, {
        villageID: VILLAGE_ID,
        lineageID: LINEAGE_ID,
        appliedAtRefSeconds: 10,
        snapshotID: parseUuid('11111111-1111-1111-1111-111111111111')!,
        isBaseline: true,
        baselineReason: 'initial',
      }),
      sourceTimestampRefSeconds: 100,
    };
    const entryE2 = {
      ...canonicalizeSnapshotHistory(snapshotE2, {
        villageID: VILLAGE_ID,
        lineageID: LINEAGE_ID,
        appliedAtRefSeconds: 20,
        snapshotID: parseUuid('22222222-2222-2222-2222-222222222222')!,
      }),
      sourceTimestampRefSeconds: 300,
    };
    const envelope = createSnapshotHistoryEnvelope({
      entries: [entryE1, entryE2],
      lineages: [
        {
          villageID: VILLAGE_ID,
          lineageID: LINEAGE_ID,
          normalizedPlayerTag: TAG,
          lastEntryID: entryE2.snapshotID,
          lastAppliedAtRefSeconds: 20,
          hasConflict: false,
          isActive: true,
        },
      ],
      duplicateMetadata: {
        [entryE1.snapshotID]: {
          lastSeenAtRefSeconds: 15,
          lastSourceTimestampRefSeconds: 500,
          duplicateImportCount: 1,
        },
      },
      migrationMarker: { version: SNAPSHOT_HISTORY_SCHEMA.envelope, completedAtRefSeconds: 20 },
    });

    const evidence = buildReconciliationEvidenceFromActiveEntry({
      villageID: VILLAGE_ID,
      envelope,
      activeEntry: entryE2,
    });

    expect(evidence.previousSourceTimestampMs).toBe(msFromRef(500));
    expect(evidence.sourceTimestampMs).toBe(msFromRef(300));
    expect(
      reconciliationTimeConfidence(evidence.previousSourceTimestampMs, evidence.sourceTimestampMs),
    ).toBe('sourceTimestampConflict');

    const itemKey = trackerItemKeyRoot('home', 'buildings', 1_000_001n);
    const state = createManualTrackerVillageState({
      villageID: VILLAGE_ID,
      core: createManualUpgradeCoreState({
        itemStates: [
          createManualItemStateForStatus({
            itemKey,
            baselineReference: {
              revision: `${entryE1.snapshotID}:observation:1`,
              lineageID: LINEAGE_ID,
            },
            imported: createManualLevelDistributionFromPairs([[1, 1n]]),
            status: 'observed',
            sourceTimestampMs: msFromRef(500),
          }),
        ],
      }),
      stateUpdatedAtMs: msFromRef(15),
    });
    const preview = previewReconciliation(evidence, state, msFromRef(20));
    const item = preview.items.find(
      (entry) => trackerItemKeyStableId(entry.itemKey) === trackerItemKeyStableId(itemKey),
    );
    expect(item?.classification).toBe('staleImport');
  });

  it('duplicate metadata 的 lastSourceTimestamp 为 null 时不得退回 entry 旧时间', () => {
    const snapshot = parseSnapshot(
      `{"tag":"${TAG}","buildings":[{"data":1000001,"lvl":1,"cnt":1}]}`,
    );
    const entry = {
      ...canonicalizeSnapshotHistory(snapshot, {
        villageID: VILLAGE_ID,
        lineageID: LINEAGE_ID,
        appliedAtRefSeconds: 10,
        snapshotID: parseUuid('33333333-3333-3333-3333-333333333333')!,
      }),
      sourceTimestampRefSeconds: 100,
    };
    const envelope = createSnapshotHistoryEnvelope({
      entries: [entry],
      lineages: [
        {
          villageID: VILLAGE_ID,
          lineageID: LINEAGE_ID,
          normalizedPlayerTag: TAG,
          lastEntryID: entry.snapshotID,
          lastAppliedAtRefSeconds: 10,
          hasConflict: false,
          isActive: true,
        },
      ],
      duplicateMetadata: {
        [entry.snapshotID]: {
          lastSeenAtRefSeconds: 12,
          lastSourceTimestampRefSeconds: null,
          duplicateImportCount: 1,
        },
      },
      migrationMarker: { version: SNAPSHOT_HISTORY_SCHEMA.envelope, completedAtRefSeconds: 12 },
    });

    const evidence = buildReconciliationEvidenceFromActiveEntry({
      villageID: VILLAGE_ID,
      envelope,
      activeEntry: entry,
    });
    expect(evidence.sourceTimestampMs).toBeNull();
    expect(evidence.sourceTimestampMs).not.toBe(msFromRef(100));
  });
});
