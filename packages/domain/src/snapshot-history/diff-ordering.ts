import type { SnapshotChange, SnapshotDiff } from './diff-types';
import { snapshotItemIdentityKey } from './types';

export function compareSnapshotChanges(left: SnapshotChange, right: SnapshotChange): number {
  const identityCompare = snapshotItemIdentityKey(left.identity).localeCompare(
    snapshotItemIdentityKey(right.identity),
  );
  if (identityCompare !== 0) {
    return identityCompare;
  }
  const kindCompare = left.changeKind.localeCompare(right.changeKind);
  if (kindCompare !== 0) {
    return kindCompare;
  }
  const oldLevelCompare =
    (left.oldLevel ?? Number.MIN_SAFE_INTEGER) - (right.oldLevel ?? Number.MIN_SAFE_INTEGER);
  if (oldLevelCompare !== 0) {
    return oldLevelCompare;
  }
  const newLevelCompare =
    (left.newLevel ?? Number.MIN_SAFE_INTEGER) - (right.newLevel ?? Number.MIN_SAFE_INTEGER);
  if (newLevelCompare !== 0) {
    return newLevelCompare;
  }
  return (
    (left.movedQuantity ?? Number.MIN_SAFE_INTEGER) -
    (right.movedQuantity ?? Number.MIN_SAFE_INTEGER)
  );
}

export function sortSnapshotChanges(changes: readonly SnapshotChange[]): SnapshotChange[] {
  return [...changes].sort(compareSnapshotChanges);
}

export function compareSnapshotDiffs(left: SnapshotDiff, right: SnapshotDiff): number {
  const appliedAtCompare = left.toAppliedAt.getTime() - right.toAppliedAt.getTime();
  if (appliedAtCompare !== 0) {
    return appliedAtCompare;
  }
  return left.toSnapshotID.localeCompare(right.toSnapshotID);
}
