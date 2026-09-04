import type { UuidString } from '@coc-helper/wire';

import type { SnapshotHistoryEnvelope, SnapshotHistoryLineageMetadata } from './store-types';
import type { SnapshotHistoryEntry, SnapshotLineageResolution } from './types';

function lineageHasConflict(reason: SnapshotLineageResolution['reason']): boolean {
  return reason === 'missingTag' || reason === 'invalidTag' || reason === 'previousConflict';
}

export function upsertSnapshotHistoryLineage(
  lineages: readonly SnapshotHistoryLineageMetadata[],
  villageID: UuidString,
  entry: SnapshotHistoryEntry,
  hasConflict: boolean,
): SnapshotHistoryLineageMetadata[] {
  const next = lineages.map((lineage) =>
    lineage.villageID === villageID ? { ...lineage, isActive: false } : lineage,
  );
  const updated: SnapshotHistoryLineageMetadata = {
    villageID,
    lineageID: entry.lineageID,
    normalizedPlayerTag: entry.normalizedPlayerTag,
    lastEntryID: entry.snapshotID,
    lastAppliedAtRefSeconds: entry.appliedAtRefSeconds,
    hasConflict,
    isActive: true,
  };
  const existingIndex = next.findIndex((lineage) => lineage.lineageID === entry.lineageID);
  if (existingIndex >= 0) {
    const replaced = next.slice();
    replaced[existingIndex] = updated;
    return replaced;
  }
  return [...next, updated];
}

export function appendSnapshotHistoryEntry(
  envelope: SnapshotHistoryEnvelope,
  entry: SnapshotHistoryEntry,
  lineage: SnapshotLineageResolution,
): SnapshotHistoryEnvelope {
  return {
    ...envelope,
    entries: [...envelope.entries, entry],
    lineages: upsertSnapshotHistoryLineage(
      envelope.lineages,
      entry.villageID,
      entry,
      lineageHasConflict(lineage.reason),
    ),
    lastDiagnostic: null,
  };
}
