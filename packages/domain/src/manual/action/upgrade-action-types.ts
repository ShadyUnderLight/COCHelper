import type { CatalogDurationState } from '../../catalog/duration-state';
import type { CatalogUpgradeCost } from '../../catalog/types';
import type { TrackerBase } from '../../village/tracker';
import type {
  UpgradeDisplaySort,
  UpgradeDisplayStateFilter,
} from '../../village/village-detail-flat-row-cache';
import type { ManualBaselineReference, ManualCatalogProvenance, TrackerItemKey } from '../types';

export type { UpgradeDisplaySort, UpgradeDisplayStateFilter };

export type UpgradeActionCoverage = 'complete' | 'partial' | 'unavailable';

export type UpgradeActionSource = 'row' | 'group';

export type UpgradeAction = {
  readonly itemKey: TrackerItemKey;
  readonly itemName: string;
  readonly base: TrackerBase;
  readonly fromLevel: number | null;
  readonly targetLevel: number | null;
  readonly quantity: bigint;
  readonly durationState: CatalogDurationState | null;
  readonly frozenCosts: readonly CatalogUpgradeCost[] | null;
  readonly catalogProvenance: ManualCatalogProvenance | null;
  readonly baselineReference: ManualBaselineReference | null;
  readonly isStartable: boolean;
  readonly disabledReason: string | null;
  readonly diagnostics: readonly string[];
  readonly sourceKind: UpgradeActionSource;
  readonly id: string;
};

export type UpgradeDisplayFilter = {
  readonly base?: TrackerBase;
  readonly category?: import('../../village/tracker').TrackerCategory;
  readonly state?: UpgradeDisplayStateFilter;
  readonly text?: string;
  readonly sort?: UpgradeDisplaySort;
};

export function createUpgradeAction(input: {
  readonly itemKey: TrackerItemKey;
  readonly itemName: string;
  readonly base: TrackerBase;
  readonly fromLevel: number | null;
  readonly targetLevel: number | null;
  readonly quantity: bigint;
  readonly durationState: CatalogDurationState | null;
  readonly frozenCosts: readonly CatalogUpgradeCost[] | null;
  readonly catalogProvenance: ManualCatalogProvenance | null;
  readonly baselineReference: ManualBaselineReference | null;
  readonly isStartable: boolean;
  readonly disabledReason: string | null;
  readonly diagnostics: readonly string[];
  readonly sourceKind?: UpgradeActionSource;
}): UpgradeAction {
  const action: UpgradeAction = {
    itemKey: input.itemKey,
    itemName: input.itemName,
    base: input.base,
    fromLevel: input.fromLevel,
    targetLevel: input.targetLevel,
    quantity: input.quantity,
    durationState: input.durationState,
    frozenCosts: input.frozenCosts,
    catalogProvenance: input.catalogProvenance,
    baselineReference: input.baselineReference,
    isStartable: input.isStartable,
    disabledReason: input.disabledReason,
    diagnostics: input.diagnostics,
    sourceKind: input.sourceKind ?? 'row',
    id: '',
  };
  return { ...action, id: upgradeActionId(action) };
}

export function upgradeActionId(action: UpgradeAction): string {
  return `${action.itemKey.base}|${action.itemKey.rawSection}|${action.itemKey.dataID}:${action.fromLevel ?? -1}->${action.targetLevel ?? -1}`;
}
