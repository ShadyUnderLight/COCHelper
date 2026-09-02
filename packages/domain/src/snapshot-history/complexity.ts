import type { SnapshotHistoryEntry } from './types';

export type SnapshotHistoryComplexityDiagnostic = {
  readonly entryCount: number;
  readonly totalItemCount: number;
  readonly maxNestedDepth: number;
  readonly maxItemsPerEntry: number;
  readonly largestEntrySnapshotID: string | null;
};

export function diagnoseSnapshotHistoryComplexity(
  entries: readonly SnapshotHistoryEntry[],
): SnapshotHistoryComplexityDiagnostic {
  let totalItemCount = 0;
  let maxNestedDepth = 0;
  let maxItemsPerEntry = 0;
  let largestEntrySnapshotID: string | null = null;

  for (const entry of entries) {
    const itemCount = entry.observation.items.length;
    totalItemCount += itemCount;
    if (itemCount > maxItemsPerEntry) {
      maxItemsPerEntry = itemCount;
      largestEntrySnapshotID = entry.snapshotID;
    }
    for (const item of entry.observation.items) {
      const depth = 1 + item.identity.nestedParentPath.length;
      if (depth > maxNestedDepth) {
        maxNestedDepth = depth;
      }
    }
  }

  return {
    entryCount: entries.length,
    totalItemCount,
    maxNestedDepth,
    maxItemsPerEntry,
    largestEntrySnapshotID,
  };
}

export function diagnoseEnvelopeComplexity(
  entries: readonly SnapshotHistoryEntry[],
): SnapshotHistoryComplexityDiagnostic {
  return diagnoseSnapshotHistoryComplexity(entries);
}
