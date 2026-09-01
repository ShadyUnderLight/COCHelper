import type { UuidString } from '@coc-helper/wire';

import type { CatalogUpgradeCost } from '../catalog/types';
import type { TrackerBase } from '../village/tracker';
import {
  MANUAL_LEVEL_DISTRIBUTION_EMPTY,
  manualLevelDistributionAdd,
  manualLevelDistributionFromQuantities,
  manualLevelDistributionIsEmpty,
  manualLevelDistributionQuantityAt,
  manualLevelDistributionSubtract,
  manualLevelDistributionTotalQuantity,
} from './level-distribution';

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

export {
  MANUAL_LEVEL_DISTRIBUTION_EMPTY,
  manualLevelDistributionAdd,
  manualLevelDistributionFromQuantities,
  manualLevelDistributionIsEmpty,
  manualLevelDistributionQuantityAt,
  manualLevelDistributionSubtract,
  manualLevelDistributionTotalQuantity,
};

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

function manualAvailableCompletedDistribution(
  core: ManualUpgradeCore,
  state: ManualItemState,
): ManualLevelDistribution | undefined {
  let base: ManualLevelDistribution;
  switch (state.status) {
    case 'observed': {
      const imported = state.importedObservation?.levelDistribution;
      if (imported === undefined || imported === null) {
        return undefined;
      }
      base = imported;
      break;
    }
    case 'manualCompleted':
      base = state.manualCompletedDistribution;
      break;
    case 'unknown':
    case 'conflict':
      return undefined;
  }
  let available = base;
  for (const record of core.records) {
    if (
      record.status === 'active' &&
      trackerItemKeyStableId(record.itemKey) === trackerItemKeyStableId(state.itemKey)
    ) {
      const next = manualLevelDistributionSubtract(available, record.fromLevel, record.quantity);
      if (next === undefined) {
        return undefined;
      }
      available = next;
    }
  }
  return available;
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
      effectiveCompleted = manualAvailableCompletedDistribution(core, state) ?? null;
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
