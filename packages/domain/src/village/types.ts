import type { AccountDataDiagnostic } from '../account';
import type { CatalogAssetRef, CatalogCompatibility } from '../catalog/types';
import type { CatalogAvailability } from '../catalog/seasonal-phase';
import type { CatalogDurationState } from '../catalog/duration-state';
import type { VillageProfile } from '../import/types';
import type { UpgradeRequirement } from './upgrade-requirement';
import type { TrackerBase, TrackerCategory, TrackerDisplayCategory } from './tracker';

export type VillageItemStatus =
  'upgrading' | 'complete' | 'maxed' | 'unknown' | 'unavailable' | 'available' | 'unverified';

export type VillageNextUpgrade =
  | { readonly kind: 'available'; readonly level: number; readonly durationSeconds: bigint | null }
  | {
      readonly kind: 'requires';
      readonly nextLevel: number;
      readonly requirements: readonly UpgradeRequirement[];
      readonly referenceDurationSeconds: bigint | null;
    }
  | { readonly kind: 'globalMaxed' }
  | {
      readonly kind: 'inProgressFact';
      readonly level: number;
      readonly durationSeconds: bigint | null;
    }
  | { readonly kind: 'unverified' }
  | { readonly kind: 'unknown' };

export type VillageItemState = {
  readonly id: string;
  readonly section: string;
  readonly dataID: bigint;
  readonly base: TrackerBase;
  readonly name: string;
  readonly category: TrackerCategory | null;
  readonly currentLevel: number | null;
  readonly count: number | null;
  readonly timerSeconds: bigint | null;
  readonly remainingSeconds: bigint | null;
  readonly nextLevel: number | null;
  readonly nextLevelDurationSeconds: bigint | null;
  readonly nextLevelDurationState: CatalogDurationState | null;
  readonly maxLevel: number | null;
  readonly currentStageMaxLevel: number | null;
  readonly nextUpgrade: VillageNextUpgrade | null;
  readonly status: VillageItemStatus;
  readonly missingReason: string | null;
  readonly catalogItemMissingReason: string | null;
  readonly availability: CatalogAvailability;
  readonly icon: CatalogAssetRef | null;
  readonly levelVisual: CatalogAssetRef | null;
  readonly currentLevelIcon: CatalogAssetRef | null;
  readonly currentLevelVisual: CatalogAssetRef | null;
  readonly isNested: boolean;
  readonly displayCategory: TrackerDisplayCategory | null;
  readonly countOverflowed?: boolean;
  readonly effectiveState?: unknown;
};

export function isUpgrading(item: VillageItemState): boolean {
  return (item.remainingSeconds ?? 0) > 0;
}

export function needsReimport(item: VillageItemState): boolean {
  return item.timerSeconds !== null && item.remainingSeconds === 0n;
}

/** count == null 或 count <= 0 时按 1 计；否则为 count。 */
export function instanceWeight(item: VillageItemState): number {
  const { count } = item;
  if (count === null || count <= 0) {
    return 1;
  }
  return count;
}

export type ProgressUniverseCoverage =
  | { readonly kind: 'unavailable' }
  | {
      readonly kind: 'partial';
      readonly missingSections: ReadonlySet<string>;
      readonly unmodeledCategories: ReadonlySet<TrackerCategory>;
    }
  | { readonly kind: 'complete' };

export function progressUniverseCoverageIsComplete(coverage: ProgressUniverseCoverage): boolean {
  return coverage.kind === 'complete';
}

export type VillageCatalogProjection = {
  readonly villageID: string;
  readonly villageName: string;
  readonly base: TrackerBase;
  readonly catalogVersion: string | null;
  readonly catalogIsUsable: boolean;
  readonly compatibility: CatalogCompatibility;
  readonly items: readonly VillageItemState[];
  readonly rawItems: readonly VillageItemState[];
  readonly effectiveTrackerItems: readonly unknown[];
  readonly manualCoverage: unknown;
  readonly progressMetrics: unknown;
  readonly diagnostics: readonly AccountDataDiagnostic[];
  readonly progressCoverage: ProgressUniverseCoverage;
};

export type VillageProjectionProvider = (
  village: VillageProfile,
  base: TrackerBase,
  nowMs: number,
) => VillageCatalogProjection;
