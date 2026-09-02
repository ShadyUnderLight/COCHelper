import { resolveSnapshotLineage } from './lineage-resolver';
import { upsertSnapshotHistoryLineage } from './envelope-mutation';
import type { SnapshotHistoryLineageMetadata } from './store-types';
import type { SnapshotHistoryEntry, SnapshotLineageResolution } from './types';

function lineageHasConflict(reason: SnapshotLineageResolution['reason']): boolean {
  return reason === 'missingTag' || reason === 'invalidTag' || reason === 'previousConflict';
}

/**
 * 将 lineage index 视为由 entries 按 persisted 数组顺序 append 派生的 cache。
 * 与 import service 一致，不按 appliedAt / snapshotID 重排。
 */
export function recomputeLineageIndexFromEntries(
  entries: readonly SnapshotHistoryEntry[],
): readonly SnapshotHistoryLineageMetadata[] {
  let lineages: SnapshotHistoryLineageMetadata[] = [];

  for (const entry of entries) {
    const active = lineages.find(
      (lineage) => lineage.villageID === entry.villageID && lineage.isActive,
    );
    const previous =
      active === undefined
        ? null
        : {
            villageID: active.villageID,
            lineageID: active.lineageID,
            normalizedPlayerTag: active.normalizedPlayerTag,
            hasConflict: active.hasConflict,
          };
    const resolution = resolveSnapshotLineage({
      villageID: entry.villageID,
      normalizedPlayerTag: entry.normalizedPlayerTag,
      previous,
    });
    lineages = upsertSnapshotHistoryLineage(
      lineages,
      entry.villageID,
      entry,
      lineageHasConflict(resolution.reason),
    );
  }

  return lineages;
}

export function lineageMetadataEqual(
  left: SnapshotHistoryLineageMetadata,
  right: SnapshotHistoryLineageMetadata,
): boolean {
  return (
    left.villageID === right.villageID &&
    left.lineageID === right.lineageID &&
    left.normalizedPlayerTag === right.normalizedPlayerTag &&
    left.lastEntryID === right.lastEntryID &&
    left.lastFingerprint === right.lastFingerprint &&
    left.lastAppliedAtRefSeconds === right.lastAppliedAtRefSeconds &&
    left.hasConflict === right.hasConflict &&
    left.isActive === right.isActive
  );
}

export function lineageIndexesEqual(
  left: readonly SnapshotHistoryLineageMetadata[],
  right: readonly SnapshotHistoryLineageMetadata[],
): boolean {
  if (left.length !== right.length) {
    return false;
  }
  const sortKey = (lineage: SnapshotHistoryLineageMetadata): string => lineage.lineageID;
  const sortedLeft = [...left].sort((a, b) => sortKey(a).localeCompare(sortKey(b)));
  const sortedRight = [...right].sort((a, b) => sortKey(a).localeCompare(sortKey(b)));
  return sortedLeft.every((lineage, index) => {
    const counterpart = sortedRight[index];
    return counterpart !== undefined && lineageMetadataEqual(lineage, counterpart);
  });
}
