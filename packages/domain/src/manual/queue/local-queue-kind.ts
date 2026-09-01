import type { CatalogDurationState } from '../../catalog/duration-state';
import { trackerCategoryFromSection } from '../../village/tracker';
import type { ManualUpgradeRecord } from '../types';
import type { QueueAssignmentDecision } from './queue-assignment';

/** Issue #145：本地计时容量类别（与 record.queueKind 自由字符串同构）。 */
export type LocalQueueKind = {
  readonly rawValue: string;
};

export const LOCAL_QUEUE_KIND_BUILDER: LocalQueueKind = { rawValue: 'builder' };
export const LOCAL_QUEUE_KIND_LABORATORY: LocalQueueKind = { rawValue: 'laboratory' };

export const LOCAL_QUEUE_KNOWN_KINDS: readonly LocalQueueKind[] = [
  LOCAL_QUEUE_KIND_BUILDER,
  LOCAL_QUEUE_KIND_LABORATORY,
];

export function createLocalQueueKind(rawValue: string): LocalQueueKind {
  return { rawValue };
}

export function localQueueKindIsKnown(kind: LocalQueueKind): boolean {
  return LOCAL_QUEUE_KNOWN_KINDS.some((known) => known.rawValue === kind.rawValue);
}

export function localQueueKindDisplayName(kind: LocalQueueKind): string {
  switch (kind.rawValue) {
    case 'builder':
      return '建筑工人';
    case 'laboratory':
      return '实验室';
    default:
      return kind.rawValue;
  }
}

export function localQueueKindsEqual(left: LocalQueueKind, right: LocalQueueKind): boolean {
  return left.rawValue === right.rawValue;
}

export function inferredLocalQueueKindForSection(rawSection: string): LocalQueueKind | null {
  const category = trackerCategoryFromSection(rawSection);
  if (category === undefined) {
    return null;
  }
  switch (category) {
    case 'buildings':
    case 'traps':
    case 'heroes':
      return LOCAL_QUEUE_KIND_BUILDER;
    case 'troops':
    case 'spells':
    case 'siegeMachines':
      return LOCAL_QUEUE_KIND_LABORATORY;
    case 'equipment':
    case 'pets':
    case 'guardians':
      return null;
  }
}

export function inferredLocalQueueKindForItemKey(itemKey: {
  readonly rawSection: string;
}): LocalQueueKind | null {
  return inferredLocalQueueKindForSection(itemKey.rawSection);
}

export function inferredLocalQueueKindForItemKeyAndDuration(
  itemKey: { readonly rawSection: string },
  durationState: CatalogDurationState | null | undefined,
): LocalQueueKind | null {
  if (durationState?.kind === 'instant') {
    return null;
  }
  return inferredLocalQueueKindForItemKey(itemKey);
}

export function effectiveLocalQueueKindForRecord(
  record: ManualUpgradeRecord,
): LocalQueueKind | null {
  if (record.durationKind === 'instant') {
    return null;
  }
  return inferredLocalQueueKindForItemKey(record.itemKey);
}

export function effectiveLocalQueueKindForAssignment(
  assignment: QueueAssignmentDecision,
): LocalQueueKind | null {
  return inferredLocalQueueKindForItemKey(assignment.itemKey);
}
