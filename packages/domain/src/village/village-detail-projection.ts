import type { ManualLevelDistribution } from '../manual/types';
import type { TrackerCategory, TrackerDisplayCategory } from './tracker';
import { instanceWeight, isUpgrading, needsReimport, type VillageItemState } from './types';

export type VillageDetailGroup = {
  readonly category: TrackerCategory | null;
  readonly displayCategory: TrackerDisplayCategory | null;
  readonly items: readonly VillageItemState[];
  readonly id: string;
};

export type VillageParentedRow = {
  readonly item: VillageItemState;
  readonly children: readonly VillageItemState[];
  readonly id: string;
};

export type VillageCategoryCompletion = {
  readonly category: TrackerCategory | null;
  readonly displayCategory: TrackerDisplayCategory | null;
  readonly knownCount: number;
  readonly completedCount: number;
  readonly unknownCount: number;
  readonly saturated: boolean;
  readonly id: string;
  readonly completionRatio: number | null;
  readonly isFullyMaxed: boolean;
};

type EffectiveVillageItemStateLike = {
  readonly status:
    | 'observed'
    | 'manualCompleted'
    | 'manualActive'
    | 'importedActive'
    | 'needsReimport'
    | 'conflict'
    | 'unknown'
    | 'unavailable';
  readonly effectiveCompletedDistribution: ManualLevelDistribution | null;
  readonly importedCurrentLevel?: number | null;
  readonly activeTargetLevel?: number | null;
  readonly currentStageMaxLevel?: number | null;
};

type GroupKey =
  | { readonly kind: 'display'; readonly value: TrackerDisplayCategory }
  | { readonly kind: 'category'; readonly value: TrackerCategory }
  | { readonly kind: 'other' };

const DISPLAY_CATEGORY_SORT_ORDER: Record<TrackerDisplayCategory, number> = {
  defense: 0,
  walls: 1,
  military: 2,
  craftTable: 3,
};

const TRACKER_CATEGORY_SORT_ORDER: Record<TrackerCategory, number> = {
  buildings: 0,
  traps: 1,
  troops: 2,
  spells: 3,
  siegeMachines: 4,
  heroes: 5,
  equipment: 6,
  pets: 7,
  guardians: 8,
};

export function villageDetailMatchesCategoryFilter(
  group: VillageDetailGroup,
  category: TrackerCategory,
): boolean {
  return group.displayCategory === null && group.category === category;
}

export function villageDetailGroups(
  items: readonly VillageItemState[],
): readonly VillageDetailGroup[] {
  const buckets = new Map<string, { key: GroupKey; items: VillageItemState[] }>();
  const keyOrder: GroupKey[] = [];

  for (const item of items) {
    const key = groupKeyFor(item);
    const bucketKey = serializeGroupKey(key);
    if (!buckets.has(bucketKey)) {
      keyOrder.push(key);
      buckets.set(bucketKey, { key, items: [] });
    }
    buckets.get(bucketKey)!.items.push(item);
  }

  return orderedGroupKeys(keyOrder).map((key) => {
    const bucket = buckets.get(serializeGroupKey(key))!.items;
    switch (key.kind) {
      case 'display':
        return {
          category: 'buildings' as const,
          displayCategory: key.value,
          items: bucket,
          id: key.value,
        };
      case 'category':
        return {
          category: key.value,
          displayCategory: null,
          items: bucket,
          id: key.value,
        };
      case 'other':
        return {
          category: null,
          displayCategory: null,
          items: bucket,
          id: 'other',
        };
    }
  });
}

export function villageDetailCompletionStats(
  items: readonly VillageItemState[],
  catalogIsUsable = true,
): readonly VillageCategoryCompletion[] {
  return villageDetailGroups(items).map((group) =>
    completionForItems(group.category, group.displayCategory, group.items, catalogIsUsable),
  );
}

export function villageDetailTotalCompletion(
  items: readonly VillageItemState[],
  catalogIsUsable = true,
): VillageCategoryCompletion {
  return completionForItems(null, null, items, catalogIsUsable);
}

export function villageDetailParentedRows(
  items: readonly VillageItemState[],
): readonly VillageParentedRow[] {
  const flatNormalizedIDs = new Set(
    items.filter((item) => !item.isNested).map((item) => normalizedID(item.id)),
  );
  const childrenByRoot = new Map<string, VillageItemState[]>();
  for (const item of items) {
    if (!item.isNested) {
      continue;
    }
    const root = rootParentPath(item.id);
    if (root !== undefined && flatNormalizedIDs.has(root)) {
      const children = childrenByRoot.get(root) ?? [];
      children.push(item);
      childrenByRoot.set(root, children);
    }
  }

  const rows: VillageParentedRow[] = [];
  const seenRoots = new Set<string>();
  for (const item of items) {
    if (item.isNested) {
      const root = rootParentPath(item.id);
      if (root !== undefined && flatNormalizedIDs.has(root)) {
        continue;
      }
      rows.push({ item, children: [], id: item.id });
    } else {
      const key = normalizedID(item.id);
      const children = seenRoots.has(key) ? [] : (childrenByRoot.get(key) ?? []);
      seenRoots.add(key);
      rows.push({ item, children, id: item.id });
    }
  }
  return rows;
}

export function villageDetailInstanceCount(items: readonly VillageItemState[]): number {
  return villageDetailInstanceCountAndOverflow(items).count;
}

export function villageDetailInstanceCountAndOverflow(items: readonly VillageItemState[]): {
  readonly count: number;
  readonly didOverflow: boolean;
} {
  let didOverflow = false;
  const count = items.reduce((accumulator, item) => {
    if (item.countOverflowed) {
      didOverflow = true;
    }
    const next = accumulator + instanceWeight(item);
    if (!Number.isFinite(next) || next > Number.MAX_SAFE_INTEGER) {
      didOverflow = true;
      return Number.MAX_SAFE_INTEGER;
    }
    return next;
  }, 0);
  return { count, didOverflow };
}

export function villageDetailIsKnown(item: VillageItemState): boolean {
  const effective = item.effectiveState as EffectiveVillageItemStateLike | null | undefined;
  if (effective) {
    if (!effectiveVillageItemIsKnown(effective)) {
      return false;
    }
    if (item.maxLevel === null) {
      return false;
    }
    const currentLevel = effectiveCurrentLevel(item, effective);
    if (currentLevel === null) {
      return false;
    }
    if (
      isEffectivelyUpgrading(item, effective) &&
      item.maxLevel !== null &&
      effectiveTargetLevel(item, effective) !== null &&
      effectiveTargetLevel(item, effective)! > item.maxLevel
    ) {
      return false;
    }
    return true;
  }

  if (
    item.status === 'unknown' ||
    item.status === 'unavailable' ||
    item.status === 'available' ||
    item.status === 'unverified'
  ) {
    return false;
  }
  if (item.maxLevel === null || item.currentLevel === null) {
    return false;
  }
  if (
    isUpgrading(item) &&
    item.nextLevel !== null &&
    item.maxLevel !== null &&
    item.nextLevel > item.maxLevel
  ) {
    return false;
  }
  return true;
}

function completionForItems(
  category: TrackerCategory | null,
  displayCategory: TrackerDisplayCategory | null,
  items: readonly VillageItemState[],
  catalogIsUsable: boolean,
): VillageCategoryCompletion {
  const knownInfo = catalogIsUsable
    ? villageDetailInstanceCountAndOverflow(items.filter((item) => villageDetailIsKnown(item)))
    : { count: 0, didOverflow: false };
  const completedInfo = catalogIsUsable
    ? villageDetailInstanceCountAndOverflow(
        items.filter((item) => isEffectivelyMaxed(item) && villageDetailIsKnown(item)),
      )
    : { count: 0, didOverflow: false };
  const unknownInfo = villageDetailInstanceCountAndOverflow(
    catalogIsUsable ? items.filter((item) => !villageDetailIsKnown(item)) : items,
  );
  const id = displayCategory ?? category ?? 'other';
  const knownCount = knownInfo.count;
  const completedCount = completedInfo.count;
  const unknownCount = unknownInfo.count;
  const saturated = knownInfo.didOverflow || completedInfo.didOverflow || unknownInfo.didOverflow;
  return {
    category,
    displayCategory,
    knownCount,
    completedCount,
    unknownCount,
    saturated,
    id,
    completionRatio: !saturated && knownCount > 0 ? completedCount / knownCount : null,
    isFullyMaxed:
      !saturated && knownCount > 0 && unknownCount === 0 && completedCount === knownCount,
  };
}

function groupKeyFor(item: VillageItemState): GroupKey {
  if (item.displayCategory !== null) {
    return { kind: 'display', value: item.displayCategory };
  }
  if (item.category !== null) {
    return { kind: 'category', value: item.category };
  }
  return { kind: 'other' };
}

function serializeGroupKey(key: GroupKey): string {
  switch (key.kind) {
    case 'display':
      return `display:${key.value}`;
    case 'category':
      return `category:${key.value}`;
    case 'other':
      return 'other';
  }
}

function orderedGroupKeys(keys: readonly GroupKey[]): GroupKey[] {
  return keys.slice().sort((left, right) => {
    const leftOrder = groupKeySortOrder(left);
    const rightOrder = groupKeySortOrder(right);
    if (leftOrder !== rightOrder) {
      return leftOrder - rightOrder;
    }
    return serializeGroupKey(left).localeCompare(serializeGroupKey(right));
  });
}

function groupKeySortOrder(key: GroupKey): number {
  switch (key.kind) {
    case 'display':
      return DISPLAY_CATEGORY_SORT_ORDER[key.value];
    case 'category':
      return 100 + TRACKER_CATEGORY_SORT_ORDER[key.value];
    case 'other':
      return 1000;
  }
}

function effectiveVillageItemIsKnown(effective: EffectiveVillageItemStateLike): boolean {
  return (
    effective.status !== 'unknown' &&
    effective.status !== 'conflict' &&
    effective.status !== 'unavailable' &&
    effective.status !== 'needsReimport' &&
    effective.effectiveCompletedDistribution !== null
  );
}

function effectiveCurrentLevel(
  item: VillageItemState,
  effective: EffectiveVillageItemStateLike,
): number | null {
  const distribution = effective.effectiveCompletedDistribution;
  if (distribution !== null && distribution.levels.length === 1) {
    return distribution.levels[0]!.level;
  }
  return effective.importedCurrentLevel ?? item.currentLevel;
}

function effectiveTargetLevel(
  item: VillageItemState,
  effective: EffectiveVillageItemStateLike,
): number | null {
  if (effective.status === 'manualActive') {
    return effective.activeTargetLevel ?? null;
  }
  if (effective.status === 'observed' || effective.status === 'importedActive') {
    return item.nextLevel;
  }
  return null;
}

function isEffectivelyUpgrading(
  item: VillageItemState,
  effective: EffectiveVillageItemStateLike,
): boolean {
  switch (effective.status) {
    case 'manualActive':
    case 'importedActive':
      return true;
    default:
      return false;
  }
}

function isEffectivelyMaxed(item: VillageItemState): boolean {
  const effective = item.effectiveState as EffectiveVillageItemStateLike | null | undefined;
  if (effective) {
    if (effective.status === 'manualActive' || effective.status === 'importedActive') {
      return false;
    }
    if (!effectiveVillageItemIsKnown(effective)) {
      return false;
    }
    const currentLevel = effectiveCurrentLevel(item, effective);
    const effectiveMax = effective.currentStageMaxLevel ?? item.maxLevel;
    if (currentLevel === null || effectiveMax === null) {
      return false;
    }
    return currentLevel >= effectiveMax;
  }
  return item.status === 'maxed';
}

function normalizedID(id: string): string {
  return id.startsWith('agg:') ? id.slice(4) : id;
}

function isNestedPath(id: string): boolean {
  const colon = id.indexOf(':');
  if (colon < 0) {
    return false;
  }
  const path = id.slice(colon + 1);
  return path.split('.').some((segment) => segment === 'types' || segment === 'modules');
}

function rootParentPath(id: string): string | undefined {
  let current = id;
  while (isNestedPath(current)) {
    const dot = current.lastIndexOf('.');
    if (dot < 0) {
      return undefined;
    }
    current = current.slice(0, dot);
  }
  return normalizedID(current);
}

// Re-export for progress-metrics parity with Swift internal names.
export const instanceCount = villageDetailInstanceCount;
export const instanceCountAndOverflow = villageDetailInstanceCountAndOverflow;
export const isKnown = villageDetailIsKnown;

// needsReimport used by progress-metrics filter.
export { needsReimport };
