/**
 * #276-S2 Projection typed IPC：upgrade.overview / village.detail。
 * 只读 query；响应携带权威 generation；village.detail 必须显式 villageId + base。
 */

import type { Result } from './result';

export const UPGRADE_OVERVIEW_CHANNEL = 'upgrade.overview' as const;
export const VILLAGE_DETAIL_CHANNEL = 'village.detail' as const;

export const PROJECTION_IPC_CHANNELS = [UPGRADE_OVERVIEW_CHANNEL, VILLAGE_DETAIL_CHANNEL] as const;

export type TrackerBaseDto = 'home' | 'builder';

export type TrackerCategoryDto =
  | 'buildings'
  | 'traps'
  | 'troops'
  | 'spells'
  | 'siegeMachines'
  | 'heroes'
  | 'equipment'
  | 'pets'
  | 'guardians';

export type TrackerDisplayCategoryDto = 'defense' | 'walls' | 'military' | 'craftTable';

export type VillageItemStatusDto =
  'upgrading' | 'complete' | 'maxed' | 'unknown' | 'unavailable' | 'available' | 'unverified';

export type EffectiveVillageItemStatusDto =
  | 'observed'
  | 'manualCompleted'
  | 'manualActive'
  | 'importedActive'
  | 'needsReimport'
  | 'conflict'
  | 'unknown'
  | 'unavailable';

export type CatalogAssetRefDto = {
  readonly container: string | null;
  readonly exportName: string | null;
  readonly renderedPath: string | null;
  readonly missingReason: string | null;
};

export type CatalogDurationStateDto =
  | { readonly kind: 'timed'; readonly seconds: number }
  | { readonly kind: 'instant' }
  | { readonly kind: 'initialLevel' }
  | { readonly kind: 'notApplicable' }
  | { readonly kind: 'sourceMissing' }
  | { readonly kind: 'parseFailed' }
  | { readonly kind: 'unknownReason'; readonly reason: string };

export type UpgradeRequirementDto =
  | { readonly kind: 'townHall'; readonly level: number }
  | { readonly kind: 'builderHall'; readonly level: number }
  | { readonly kind: 'laboratory'; readonly level: number }
  | { readonly kind: 'starLaboratory'; readonly level: number }
  | { readonly kind: 'heroHall'; readonly level: number }
  | { readonly kind: 'blacksmith'; readonly level: number };

export type VillageNextUpgradeDto =
  | { readonly kind: 'available'; readonly level: number; readonly durationSeconds: number | null }
  | {
      readonly kind: 'requires';
      readonly nextLevel: number;
      readonly requirements: readonly UpgradeRequirementDto[];
      readonly referenceDurationSeconds: number | null;
    }
  | { readonly kind: 'globalMaxed' }
  | {
      readonly kind: 'inProgressFact';
      readonly level: number;
      readonly durationSeconds: number | null;
    }
  | { readonly kind: 'unverified' }
  | { readonly kind: 'unknown' };

export type CatalogAvailabilityDto =
  | { readonly kind: 'permanent' }
  | {
      readonly kind: 'seasonal';
      readonly phaseID: string;
      readonly phaseName: string | null;
      readonly status: 'active' | 'notStarted' | 'ended';
    }
  | { readonly kind: 'unconfigured' }
  | {
      readonly kind: 'conflict';
      readonly phaseID: string;
      readonly phaseName: string | null;
      readonly lifecycle: string;
      readonly sourceURL: string | null;
    };

export type CatalogCompatibilityDto =
  | { readonly kind: 'unverified'; readonly gameVersion: string }
  | { readonly kind: 'verified'; readonly gameVersion: string }
  | { readonly kind: 'mismatch'; readonly catalogVersion: string; readonly expectedVersion: string }
  | { readonly kind: 'unavailable' };

export type VillageItemStateDto = {
  readonly id: string;
  readonly section: string;
  readonly dataID: number;
  readonly base: TrackerBaseDto;
  readonly name: string;
  readonly category: TrackerCategoryDto | null;
  readonly currentLevel: number | null;
  readonly count: number | null;
  readonly timerSeconds: number | null;
  readonly remainingSeconds: number | null;
  readonly nextLevel: number | null;
  readonly nextLevelDurationSeconds: number | null;
  readonly nextLevelDurationState: CatalogDurationStateDto | null;
  readonly maxLevel: number | null;
  readonly currentStageMaxLevel: number | null;
  readonly nextUpgrade: VillageNextUpgradeDto | null;
  readonly status: VillageItemStatusDto;
  readonly missingReason: string | null;
  readonly catalogItemMissingReason: string | null;
  readonly availability: CatalogAvailabilityDto;
  readonly icon: CatalogAssetRefDto | null;
  readonly levelVisual: CatalogAssetRefDto | null;
  readonly currentLevelIcon: CatalogAssetRefDto | null;
  readonly currentLevelVisual: CatalogAssetRefDto | null;
  readonly isNested: boolean;
  readonly displayCategory: TrackerDisplayCategoryDto | null;
  readonly countOverflowed: boolean;
  readonly effectiveStatus: EffectiveVillageItemStatusDto | null;
  /**
   * Authoritative 有效视图（domain `effectiveItemView` 直出，无 sidecar 时
   * 回退 raw）。renderer 等级/升级/时长只读这组字段，不再碰上面 raw 字段。
   */
  readonly effectiveCurrentLevel: number | null;
  readonly effectiveTargetLevel: number | null;
  readonly effectiveNextUpgrade: VillageNextUpgradeDto | null;
  readonly effectiveNextLevelDurationState: CatalogDurationStateDto | null;
  readonly effectiveDiagnostic: string | null;
  readonly effectiveIsMaxed: boolean;
};

export type ProgressMetricStateDto = 'ready' | 'partial' | 'unavailable' | 'unknown';

export type ProgressMetricDto = {
  readonly kind: string;
  readonly numerator: number;
  readonly denominator: number;
  readonly state: ProgressMetricStateDto;
  readonly saturated: boolean;
  readonly units: string;
  readonly degradedReason: string | null;
  readonly ratio: number | null;
};

export type VillageProgressMetricsDto = {
  readonly currentStageProgress: ProgressMetricDto;
  readonly globalProgress: ProgressMetricDto;
  readonly snapshotCoverage: ProgressMetricDto;
  readonly instanceProgress: ProgressMetricDto;
  readonly effectiveTrackerProgress: ProgressMetricDto;
};

export type TrackerItemKeyDto = {
  readonly base: TrackerBaseDto;
  readonly rawSection: string;
  readonly dataID: number;
  readonly nestedKind: string;
  readonly nestedRootIdentity: {
    readonly base: TrackerBaseDto;
    readonly rawSection: string;
    readonly dataID: number;
  } | null;
  readonly nestedPath: readonly { readonly kind: string; readonly dataID: number }[];
  readonly stableId: string;
};

export type UpgradeDisplayRecordDto = {
  readonly id: string;
  readonly villageID: string;
  readonly villageName: string;
  readonly villageTag: string | null;
  readonly base: TrackerBaseDto;
  readonly item: VillageItemStateDto;
  readonly catalogVersion: string | null;
  readonly villageMetrics: VillageProgressMetricsDto;
};

export type UpgradeRecentCompletionDto = {
  readonly id: string;
  readonly villageID: string;
  readonly itemKey: TrackerItemKeyDto;
  readonly itemName: string;
  readonly targetLevel: number;
  readonly quantity: number;
  readonly completedAtMs: number;
};

export type UpgradeOverviewStateDto = {
  readonly manualActiveCount: number;
  readonly importedActiveCount: number;
  readonly deduplicatedDisplayCount: number;
  readonly manualCompletedCount: number;
  readonly completedRecently: readonly UpgradeRecentCompletionDto[];
  readonly activeRecords: readonly UpgradeDisplayRecordDto[];
  readonly attentionRecords: readonly UpgradeDisplayRecordDto[];
  readonly needsReimportRecords: readonly UpgradeDisplayRecordDto[];
};

export type UpgradeOverviewRequest = Record<string, never>;

export type UpgradeOverviewPayload = {
  readonly generation: number;
  readonly nowMs: number;
  readonly catalogVersion: string | null;
  readonly catalogIsUsable: boolean;
  readonly active: readonly UpgradeDisplayRecordDto[];
  readonly pending: readonly UpgradeDisplayRecordDto[];
  readonly state: UpgradeOverviewStateDto;
};

export type UpgradeOverviewResponse = Result<UpgradeOverviewPayload>;

export type VillageDetailRequest = {
  readonly villageId: string;
  readonly base: TrackerBaseDto;
};

export type VillageDetailGroupDto = {
  readonly id: string;
  readonly category: TrackerCategoryDto | null;
  readonly displayCategory: TrackerDisplayCategoryDto | null;
  readonly itemIds: readonly string[];
};

export type VillageCategoryCompletionDto = {
  readonly id: string;
  readonly category: TrackerCategoryDto | null;
  readonly displayCategory: TrackerDisplayCategoryDto | null;
  readonly knownCount: number;
  readonly completedCount: number;
  readonly unknownCount: number;
  readonly saturated: boolean;
  readonly completionRatio: number | null;
  readonly isFullyMaxed: boolean;
};

export type VillageDetailFlatRowDto =
  | {
      readonly kind: 'sectionHeader';
      readonly groupID: string;
      readonly stats: VillageCategoryCompletionDto | null;
    }
  | {
      readonly kind: 'craftTable';
      readonly groupID: string;
      readonly stats: VillageCategoryCompletionDto | null;
    }
  | { readonly kind: 'groupHeader'; readonly groupID: string }
  | {
      readonly kind: 'instance';
      readonly groupID: string;
      readonly instanceID: string;
      readonly leadingDivider: boolean;
    }
  | {
      readonly kind: 'legacy';
      readonly itemID: string;
      readonly groupID: string;
      readonly indented: boolean;
      readonly leadingDivider: boolean;
    };

export type BuildingGroupSummaryDto = {
  readonly instanceCount: number;
  readonly remainingLevelCount: number;
  readonly totalDurationSeconds: number;
  readonly costByResource: readonly { readonly resource: string; readonly totalCost: number }[];
  readonly saturated: boolean;
  readonly completeness: 'complete' | 'partialMissing' | 'versionMismatch';
};

export type BuildingGroupDto = {
  readonly id: string;
  readonly base: TrackerBaseDto;
  readonly section: string;
  readonly dataID: number;
  readonly name: string;
  readonly category: TrackerCategoryDto | null;
  readonly displayCategory: TrackerDisplayCategoryDto | null;
  readonly instanceIds: readonly string[];
  readonly summary: BuildingGroupSummaryDto;
  readonly trackerStatus: EffectiveVillageItemStatusDto;
};

export type VillageDetailPayload = {
  readonly generation: number;
  readonly nowMs: number;
  readonly villageId: string;
  readonly villageName: string;
  readonly villageTag: string | null;
  readonly base: TrackerBaseDto;
  readonly catalogVersion: string | null;
  readonly catalogIsUsable: boolean;
  readonly compatibility: CatalogCompatibilityDto;
  readonly items: readonly VillageItemStateDto[];
  /**
   * 仅供实例 ID 解析的原始条目（含已聚合项的原始记录，如 idle 建筑的 raw
   * 记录）。UI 不得直接列表渲染；`items` 仍是唯一的列表数据源。
   */
  readonly instanceItems: readonly VillageItemStateDto[];
  readonly groups: readonly VillageDetailGroupDto[];
  readonly completion: readonly VillageCategoryCompletionDto[];
  readonly totalCompletion: VillageCategoryCompletionDto;
  readonly metrics: VillageProgressMetricsDto;
  readonly buildingGroups: readonly BuildingGroupDto[];
  readonly flatRows: readonly VillageDetailFlatRowDto[];
};

export type VillageDetailResponse = Result<VillageDetailPayload>;

export type ProjectionIpcBridge = {
  upgradeOverview: (request?: UpgradeOverviewRequest) => Promise<UpgradeOverviewResponse>;
  villageDetail: (request: VillageDetailRequest) => Promise<VillageDetailResponse>;
};

export const PROJECTION_IPC_BRIDGE_KEYS = [
  'upgradeOverview',
  'villageDetail',
] as const satisfies ReadonlyArray<keyof ProjectionIpcBridge>;
