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
export const LOCAL_QUEUE_KIND_HERO: LocalQueueKind = { rawValue: 'hero' };
export const LOCAL_QUEUE_KIND_EQUIPMENT: LocalQueueKind = { rawValue: 'equipment' };

/** UI 选择器顺序；arbitrary rawValue 仍合法。 */
export const LOCAL_QUEUE_KNOWN_KINDS: readonly LocalQueueKind[] = [
  LOCAL_QUEUE_KIND_BUILDER,
  LOCAL_QUEUE_KIND_LABORATORY,
  LOCAL_QUEUE_KIND_HERO,
  LOCAL_QUEUE_KIND_EQUIPMENT,
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
    case 'hero':
      return '英雄';
    case 'equipment':
      return '装备';
    default:
      return kind.rawValue;
  }
}

export function localQueueKindsEqual(left: LocalQueueKind, right: LocalQueueKind): boolean {
  return left.rawValue === right.rawValue;
}

/** UI 默认推荐：不是容量 gate 的 authoritative evidence。 */
export function suggestedLocalQueueKindForSection(rawSection: string): LocalQueueKind | null {
  const category = trackerCategoryFromSection(rawSection);
  if (category === undefined) {
    return null;
  }
  switch (category) {
    case 'buildings':
    case 'traps':
      return LOCAL_QUEUE_KIND_BUILDER;
    case 'troops':
    case 'spells':
    case 'siegeMachines':
      return LOCAL_QUEUE_KIND_LABORATORY;
    case 'heroes':
      return LOCAL_QUEUE_KIND_HERO;
    case 'equipment':
      return LOCAL_QUEUE_KIND_EQUIPMENT;
    case 'pets':
    case 'guardians':
      return null;
  }
}

export function suggestedLocalQueueKindForItemKey(itemKey: {
  readonly rawSection: string;
}): LocalQueueKind | null {
  return suggestedLocalQueueKindForSection(itemKey.rawSection);
}

export function suggestedLocalQueueKindForItemKeyAndDuration(
  itemKey: { readonly rawSection: string },
  durationState: CatalogDurationState | null | undefined,
): LocalQueueKind | null {
  if (durationState?.kind === 'instant') {
    return null;
  }
  return suggestedLocalQueueKindForItemKey(itemKey);
}

/** @deprecated 仅 UI 推荐；容量 gate 不得使用。 */
export const inferredLocalQueueKindForSection = suggestedLocalQueueKindForSection;
/** @deprecated 仅 UI 推荐；容量 gate 不得使用。 */
export const inferredLocalQueueKindForItemKey = suggestedLocalQueueKindForItemKey;
/** @deprecated 仅 UI 推荐；容量 gate 不得使用。 */
export const inferredLocalQueueKindForItemKeyAndDuration =
  suggestedLocalQueueKindForItemKeyAndDuration;

export function effectiveLocalQueueKindForRecord(
  record: ManualUpgradeRecord,
): LocalQueueKind | null {
  if (record.durationKind === 'instant') {
    return null;
  }
  if (record.queueKind === null) {
    return null;
  }
  return createLocalQueueKind(record.queueKind);
}

export function effectiveLocalQueueKindForAssignment(
  assignment: QueueAssignmentDecision,
): LocalQueueKind | null {
  return assignment.queueKind;
}
