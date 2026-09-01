import type { UuidString } from '@coc-helper/wire';

import type { CatalogUpgradeCost } from '../catalog/types';
import type { TrackerBase } from '../village/tracker';

export type TrackerNestedKind = 'root' | 'type' | 'module';

export type TrackerRootIdentity = {
  readonly base: TrackerBase;
  readonly rawSection: string;
  readonly dataID: bigint;
};

export type TrackerNestedPathComponent = {
  readonly kind: TrackerNestedKind;
  readonly dataID: bigint;
};

export type TrackerItemKey = {
  readonly base: TrackerBase;
  readonly rawSection: string;
  readonly dataID: bigint;
  readonly nestedKind: TrackerNestedKind;
  readonly nestedRootIdentity: TrackerRootIdentity | null;
  readonly nestedPath: readonly TrackerNestedPathComponent[];
};

export function trackerItemKeyStableId(key: TrackerItemKey): string {
  const root = key.nestedRootIdentity
    ? `${key.nestedRootIdentity.base}:${key.nestedRootIdentity.rawSection}:${key.nestedRootIdentity.dataID}`
    : '-';
  const path = key.nestedPath.map((component) => `${component.kind}:${component.dataID}`).join('/');
  return [key.base, key.rawSection, key.dataID.toString(), key.nestedKind, root, path].join('|');
}

/** Swift `stableID` 兼容别名。 */
export function trackerItemKeyStableID(key: TrackerItemKey): string {
  return trackerItemKeyStableId(key);
}

export function withTrackerItemKeyStableID(
  key: TrackerItemKey,
): TrackerItemKey & { readonly stableID: string } {
  return Object.assign(key, { stableID: trackerItemKeyStableId(key) });
}

export function trackerItemKeyRoot(
  base: TrackerBase,
  rawSection: string,
  dataID: bigint,
): TrackerItemKey {
  return {
    base,
    rawSection,
    dataID,
    nestedKind: 'root',
    nestedRootIdentity: null,
    nestedPath: [],
  };
}

export type ManualLevelQuantity = {
  readonly level: number;
  readonly quantity: bigint;
};

export type ManualLevelDistribution = {
  readonly levels: readonly ManualLevelQuantity[];
  readonly quantityAt: (level: number) => bigint;
  readonly totalQuantity: bigint;
  readonly isEmpty: boolean;
};

export const MANUAL_LEVEL_DISTRIBUTION_EMPTY: ManualLevelDistribution =
  createManualLevelDistribution([]);

function createManualLevelDistribution(
  levels: readonly ManualLevelQuantity[],
): ManualLevelDistribution {
  const sorted = levels.slice().sort((left, right) => left.level - right.level);
  return {
    levels: sorted,
    quantityAt(level: number) {
      return sorted.find((entry) => entry.level === level)?.quantity ?? 0n;
    },
    get totalQuantity() {
      return sorted.reduce((total, entry) => total + entry.quantity, 0n);
    },
    get isEmpty() {
      return sorted.length === 0;
    },
  };
}

export function manualLevelDistributionTotalQuantity(
  distribution: ManualLevelDistribution,
): bigint {
  return distribution.totalQuantity;
}

export function manualLevelDistributionIsEmpty(distribution: ManualLevelDistribution): boolean {
  return distribution.isEmpty;
}

export function manualLevelDistributionQuantityAt(
  distribution: ManualLevelDistribution,
  level: number,
): bigint {
  return distribution.quantityAt(level);
}

export function manualLevelDistributionFromQuantities(
  levelQuantities: ReadonlyMap<number, bigint>,
): ManualLevelDistribution | undefined {
  const levels: ManualLevelQuantity[] = [];
  for (const level of [...levelQuantities.keys()].sort((left, right) => left - right)) {
    const quantity = levelQuantities.get(level);
    if (quantity === undefined || quantity <= 0n || level < 0) {
      return undefined;
    }
    let total = 0n;
    for (const entry of levels) {
      total += entry.quantity;
    }
    if (total + quantity < total) {
      return undefined;
    }
    levels.push({ level, quantity });
  }
  return createManualLevelDistribution(levels);
}

export function manualLevelDistributionAdd(
  distribution: ManualLevelDistribution,
  level: number,
  quantity: bigint,
): ManualLevelDistribution | undefined {
  if (quantity <= 0n || level < 0) {
    return undefined;
  }
  const quantities = new Map<number, bigint>();
  for (const entry of distribution.levels) {
    quantities.set(entry.level, entry.quantity);
  }
  const existing = quantities.get(level) ?? 0n;
  const sum = existing + quantity;
  if (sum < existing) {
    return undefined;
  }
  quantities.set(level, sum);
  return manualLevelDistributionFromQuantities(quantities);
}

export function manualLevelDistributionSubtract(
  distribution: ManualLevelDistribution,
  level: number,
  quantity: bigint,
): ManualLevelDistribution | undefined {
  if (quantity <= 0n) {
    return undefined;
  }
  const available = manualLevelDistributionQuantityAt(distribution, level);
  if (available < quantity) {
    return undefined;
  }
  const quantities = new Map<number, bigint>();
  for (const entry of distribution.levels) {
    quantities.set(entry.level, entry.quantity);
  }
  const remaining = available - quantity;
  if (remaining === 0n) {
    quantities.delete(level);
  } else {
    quantities.set(level, remaining);
  }
  return manualLevelDistributionFromQuantities(quantities);
}

export type ManualBaselineReference = {
  readonly revision: string;
  readonly fingerprint: string | null;
  readonly lineageID: string | null;
};

export type ManualImportedObservation = {
  readonly reference: ManualBaselineReference;
  readonly levelDistribution: ManualLevelDistribution | null;
  readonly sourceTimestampMs: number | null;
  readonly observedTimer: boolean;
  readonly observedTimerCoverageComplete: boolean;
};

export type ManualItemStatus = 'observed' | 'manualCompleted' | 'unknown' | 'conflict';

export type ManualItemState = {
  readonly itemKey: TrackerItemKey;
  readonly baselineReference: ManualBaselineReference;
  readonly importedObservation: ManualImportedObservation | null;
  readonly manualCompletedDistribution: ManualLevelDistribution;
  readonly status: ManualItemStatus;
};

export type ManualCatalogProvenance = {
  readonly gameVersion: string;
  readonly buildTag: string | null;
  readonly sourceFingerprint: string | null;
  readonly manifestSchemaVersion: number | null;
};

export type ManualUpgradeDurationKind = 'timed' | 'instant';

export type ManualUpgradeRecordStatus = 'active' | 'completed' | 'cancelled';

export type ManualUpgradeRecord = {
  readonly recordID: UuidString;
  readonly itemKey: TrackerItemKey;
  readonly fromLevel: number;
  readonly targetLevel: number;
  readonly quantity: bigint;
  readonly startedAtMs: number;
  readonly expectedEndAtMs: number;
  readonly durationSeconds: bigint;
  readonly durationKind: ManualUpgradeDurationKind;
  readonly frozenCosts: readonly CatalogUpgradeCost[] | null;
  readonly catalogProvenance: ManualCatalogProvenance;
  readonly baselineReference: ManualBaselineReference;
  readonly queueKind: string | null;
  readonly status: ManualUpgradeRecordStatus;
};

export type ManualEffectiveItemState = {
  readonly itemKey: TrackerItemKey;
  readonly baselineReference: ManualBaselineReference;
  readonly importedDistribution: ManualLevelDistribution | null;
  readonly manualCompletedDistribution: ManualLevelDistribution;
  readonly activeTargetDistribution: ManualLevelDistribution;
  readonly effectiveCompletedDistribution: ManualLevelDistribution | null;
  readonly status: ManualItemStatus;
  readonly effectiveCompletedLevel: number | null;
  readonly activeTargetLevel: number | null;
};

export type ManualUpgradeCore = {
  readonly itemStates: readonly ManualItemState[];
  readonly records: readonly ManualUpgradeRecord[];
  readonly contentFingerprint: string;
};

function manualRecordOrder(left: ManualUpgradeRecord, right: ManualUpgradeRecord): number {
  if (left.expectedEndAtMs !== right.expectedEndAtMs) {
    return left.expectedEndAtMs - right.expectedEndAtMs;
  }
  return left.recordID.localeCompare(right.recordID);
}

export function manualActiveRecords(core: ManualUpgradeCore): readonly ManualUpgradeRecord[] {
  return core.records
    .filter((record) => record.status === 'active')
    .slice()
    .sort(manualRecordOrder);
}

export function manualCompletedHistory(core: ManualUpgradeCore): readonly ManualUpgradeRecord[] {
  return core.records
    .filter((record) => record.status === 'completed')
    .slice()
    .sort(manualRecordOrder);
}

export function manualItemState(
  core: ManualUpgradeCore,
  itemKey: TrackerItemKey,
): ManualItemState | undefined {
  return core.itemStates.find(
    (state) => trackerItemKeyStableId(state.itemKey) === trackerItemKeyStableId(itemKey),
  );
}

function manualActiveTargetDistribution(
  core: ManualUpgradeCore,
  itemKey: TrackerItemKey,
): ManualLevelDistribution | undefined {
  let distribution = MANUAL_LEVEL_DISTRIBUTION_EMPTY;
  for (const record of core.records) {
    if (
      record.status === 'active' &&
      trackerItemKeyStableId(record.itemKey) === trackerItemKeyStableId(itemKey)
    ) {
      const next = manualLevelDistributionAdd(distribution, record.targetLevel, record.quantity);
      if (next === undefined) {
        return undefined;
      }
      distribution = next;
    }
  }
  return distribution;
}

export function manualEffectiveItemState(
  core: ManualUpgradeCore,
  itemKey: TrackerItemKey,
): ManualEffectiveItemState | undefined {
  const state = manualItemState(core, itemKey);
  if (state === undefined) {
    return undefined;
  }
  const activeTarget = manualActiveTargetDistribution(core, itemKey);
  if (activeTarget === undefined) {
    return undefined;
  }

  const imported = state.importedObservation?.levelDistribution ?? null;
  let effectiveCompleted: ManualLevelDistribution | null;
  switch (state.status) {
    case 'observed':
      effectiveCompleted = imported;
      break;
    case 'manualCompleted':
      effectiveCompleted = state.manualCompletedDistribution;
      break;
    case 'unknown':
    case 'conflict':
      effectiveCompleted = null;
      break;
  }

  return {
    itemKey: state.itemKey,
    baselineReference: state.baselineReference,
    importedDistribution: imported,
    manualCompletedDistribution: state.manualCompletedDistribution,
    activeTargetDistribution: activeTarget,
    effectiveCompletedDistribution: effectiveCompleted,
    status: state.status,
    effectiveCompletedLevel:
      effectiveCompleted !== null && effectiveCompleted.levels.length === 1
        ? effectiveCompleted.levels[0]!.level
        : null,
    activeTargetLevel: activeTarget.levels.length === 1 ? activeTarget.levels[0]!.level : null,
  };
}
