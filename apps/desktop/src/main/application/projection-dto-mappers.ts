/**
 * Domain 投影 → IPC DTO。bigint 转 safe integer；effectiveState 只保留 status。
 */

import type {
  BuildingGroupDto,
  CatalogAssetRefDto,
  CatalogAvailabilityDto,
  CatalogCompatibilityDto,
  CatalogDurationStateDto,
  ProgressMetricDto,
  TrackerItemKeyDto,
  UpgradeDisplayRecordDto,
  UpgradeOverviewPayload,
  UpgradeOverviewStateDto,
  UpgradeRecentCompletionDto,
  VillageCategoryCompletionDto,
  VillageDetailFlatRowDto,
  VillageDetailGroupDto,
  VillageDetailPayload,
  VillageItemStateDto,
  VillageNextUpgradeDto,
  VillageProgressMetricsDto,
} from '@coc-helper/contracts';
import type {
  BuildingGroup,
  CatalogAssetRef,
  CatalogAvailability,
  CatalogCompatibility,
  CatalogDurationState,
  EffectiveVillageItemState,
  ProgressMetric,
  TrackerItemKey,
  UpgradeDisplayRecord,
  UpgradeOverviewRender,
  UpgradeRecentCompletion,
  VillageCategoryCompletion,
  VillageDetailFlatRow,
  VillageDetailGroup,
  VillageItemState,
  VillageNextUpgrade,
  VillageProgressMetrics,
  VillageProfile,
} from '@coc-helper/domain';
import {
  effectiveDetailMissingReason,
  effectiveItemView,
  trackerItemKeyStableId,
} from '@coc-helper/domain';

export function toUpgradeOverviewPayload(input: {
  readonly generation: number;
  readonly nowMs: number;
  readonly catalogVersion: string | null;
  readonly catalogIsUsable: boolean;
  readonly render: UpgradeOverviewRender;
}): UpgradeOverviewPayload {
  return {
    generation: input.generation,
    nowMs: input.nowMs,
    catalogVersion: input.catalogVersion,
    catalogIsUsable: input.catalogIsUsable,
    active: input.render.active.map(toUpgradeDisplayRecordDto),
    pending: input.render.pending.map(toUpgradeDisplayRecordDto),
    state: toUpgradeOverviewStateDto(input.render.state),
  };
}

export function toVillageDetailPayload(input: {
  readonly generation: number;
  readonly nowMs: number;
  readonly village: VillageProfile;
  readonly base: 'home' | 'builder';
  readonly catalogVersion: string | null;
  readonly catalogIsUsable: boolean;
  readonly compatibility: CatalogCompatibility;
  readonly items: readonly VillageItemState[];
  readonly instanceItems: readonly VillageItemState[];
  readonly groups: readonly VillageDetailGroup[];
  readonly completion: readonly VillageCategoryCompletion[];
  readonly totalCompletion: VillageCategoryCompletion;
  readonly metrics: VillageProgressMetrics;
  readonly buildingGroups: readonly BuildingGroup[];
  readonly flatRows: readonly VillageDetailFlatRow[];
}): VillageDetailPayload {
  return {
    generation: input.generation,
    nowMs: input.nowMs,
    villageId: input.village.id,
    villageName: input.village.name,
    villageTag: input.village.tag,
    base: input.base,
    catalogVersion: input.catalogVersion,
    catalogIsUsable: input.catalogIsUsable,
    compatibility: toCatalogCompatibilityDto(input.compatibility),
    items: input.items.map(toVillageItemStateDto),
    instanceItems: input.instanceItems.map(toVillageItemStateDto),
    groups: input.groups.map(toVillageDetailGroupDto),
    completion: input.completion.map(toVillageCategoryCompletionDto),
    totalCompletion: toVillageCategoryCompletionDto(input.totalCompletion),
    metrics: toVillageProgressMetricsDto(input.metrics),
    buildingGroups: input.buildingGroups.map(toBuildingGroupDto),
    flatRows: input.flatRows.map(toVillageDetailFlatRowDto),
  };
}

function toUpgradeOverviewStateDto(state: UpgradeOverviewRender['state']): UpgradeOverviewStateDto {
  return {
    manualActiveCount: state.manualActiveCount,
    importedActiveCount: state.importedActiveCount,
    deduplicatedDisplayCount: state.deduplicatedDisplayCount,
    manualCompletedCount: state.manualCompletedCount,
    completedRecently: state.completedRecently.map(toUpgradeRecentCompletionDto),
    activeRecords: state.activeRecords.map(toUpgradeDisplayRecordDto),
    attentionRecords: state.attentionRecords.map(toUpgradeDisplayRecordDto),
    needsReimportRecords: state.needsReimportRecords.map(toUpgradeDisplayRecordDto),
  };
}

function toUpgradeDisplayRecordDto(record: UpgradeDisplayRecord): UpgradeDisplayRecordDto {
  return {
    id: record.id,
    villageID: record.villageID,
    villageName: record.villageName,
    villageTag: record.villageTag,
    base: record.base,
    item: toVillageItemStateDto(record.item),
    catalogVersion: record.catalogVersion,
    villageMetrics: toVillageProgressMetricsDto(record.villageMetrics),
  };
}

function toUpgradeRecentCompletionDto(
  completion: UpgradeRecentCompletion,
): UpgradeRecentCompletionDto {
  return {
    id: completion.id,
    villageID: completion.villageID,
    itemKey: toTrackerItemKeyDto(completion.itemKey),
    itemName: completion.itemName,
    targetLevel: completion.targetLevel,
    quantity: bigintToNumber(completion.quantity),
    completedAtMs: completion.completedAtMs,
  };
}

export function toVillageItemStateDto(item: VillageItemState): VillageItemStateDto {
  const effective = effectiveItemView(item);
  return {
    id: item.id,
    section: item.section,
    dataID: bigintToNumber(item.dataID),
    base: item.base,
    name: item.name,
    category: item.category,
    currentLevel: item.currentLevel,
    count: item.count,
    timerSeconds: optionalBigintToNumber(item.timerSeconds),
    remainingSeconds: optionalBigintToNumber(item.remainingSeconds),
    nextLevel: item.nextLevel,
    nextLevelDurationSeconds: optionalBigintToNumber(item.nextLevelDurationSeconds),
    nextLevelDurationState: optionalDurationState(item.nextLevelDurationState),
    maxLevel: item.maxLevel,
    currentStageMaxLevel: item.currentStageMaxLevel,
    nextUpgrade: optionalNextUpgrade(item.nextUpgrade),
    status: item.status,
    missingReason: item.missingReason,
    catalogItemMissingReason: item.catalogItemMissingReason,
    availability: toCatalogAvailabilityDto(item.availability),
    icon: optionalAssetRef(item.icon),
    levelVisual: optionalAssetRef(item.levelVisual),
    currentLevelIcon: optionalAssetRef(item.currentLevelIcon),
    currentLevelVisual: optionalAssetRef(item.currentLevelVisual),
    isNested: item.isNested,
    displayCategory: item.displayCategory,
    countOverflowed: item.countOverflowed === true,
    effectiveStatus: readEffectiveStatus(item.effectiveState),
    effectiveCurrentLevel: effective.currentLevel,
    effectiveTargetLevel: effective.targetLevel,
    effectiveNextUpgrade: optionalNextUpgrade(effective.nextUpgrade),
    effectiveNextLevelDurationState: optionalDurationState(effective.durationState),
    effectiveDiagnostic: effective.diagnostic,
    effectiveIsMaxed: effective.isMaxed,
    effectiveDetailMissingReason: effectiveDetailMissingReason(item),
  };
}

function toVillageDetailGroupDto(group: VillageDetailGroup): VillageDetailGroupDto {
  return {
    id: group.id,
    category: group.category,
    displayCategory: group.displayCategory,
    itemIds: group.items.map((item) => item.id),
  };
}

function toVillageCategoryCompletionDto(
  completion: VillageCategoryCompletion,
): VillageCategoryCompletionDto {
  return {
    id: completion.id,
    category: completion.category,
    displayCategory: completion.displayCategory,
    knownCount: completion.knownCount,
    completedCount: completion.completedCount,
    unknownCount: completion.unknownCount,
    saturated: completion.saturated,
    completionRatio: completion.completionRatio,
    isFullyMaxed: completion.isFullyMaxed,
  };
}

function toVillageDetailFlatRowDto(row: VillageDetailFlatRow): VillageDetailFlatRowDto {
  switch (row.kind) {
    case 'sectionHeader':
      return {
        kind: 'sectionHeader',
        groupID: row.groupID,
        stats:
          row.stats === null || row.stats === undefined
            ? null
            : toVillageCategoryCompletionDto(row.stats),
      };
    case 'craftTable':
      return {
        kind: 'craftTable',
        groupID: row.groupID,
        stats:
          row.stats === null || row.stats === undefined
            ? null
            : toVillageCategoryCompletionDto(row.stats),
      };
    case 'groupHeader':
      return { kind: 'groupHeader', groupID: row.groupID };
    case 'instance':
      return {
        kind: 'instance',
        groupID: row.groupID,
        instanceID: row.instanceID,
        leadingDivider: row.leadingDivider,
      };
    case 'legacy':
      return {
        kind: 'legacy',
        itemID: row.itemID,
        groupID: row.groupID,
        indented: row.indented,
        leadingDivider: row.leadingDivider,
      };
  }
}

function toBuildingGroupDto(group: BuildingGroup): BuildingGroupDto {
  return {
    id: group.id,
    base: group.base,
    section: group.section,
    dataID: bigintToNumber(group.dataID),
    name: group.name,
    category: group.category,
    displayCategory: group.displayCategory,
    instanceIds: group.instances.map((instance) => instance.id),
    summary: {
      instanceCount: group.summary.instanceCount,
      remainingLevelCount: group.summary.remainingLevelCount,
      totalDurationSeconds: bigintToNumber(group.summary.totalDurationSeconds),
      costByResource: group.summary.costByResource.map((entry) => ({
        resource: entry.resource,
        totalCost: bigintToNumber(entry.totalCost),
      })),
      saturated: group.summary.saturated,
      completeness: group.summary.completeness,
    },
    trackerStatus: group.trackerState.status,
  };
}

function toVillageProgressMetricsDto(metrics: VillageProgressMetrics): VillageProgressMetricsDto {
  return {
    currentStageProgress: toProgressMetricDto(metrics.currentStageProgress),
    globalProgress: toProgressMetricDto(metrics.globalProgress),
    snapshotCoverage: toProgressMetricDto(metrics.snapshotCoverage),
    instanceProgress: toProgressMetricDto(metrics.instanceProgress),
    effectiveTrackerProgress: toProgressMetricDto(metrics.effectiveTrackerProgress),
  };
}

function toProgressMetricDto(metric: ProgressMetric): ProgressMetricDto {
  return {
    kind: metric.kind,
    numerator: metric.numerator,
    denominator: metric.denominator,
    state: metric.state,
    saturated: metric.saturated,
    units: metric.units,
    degradedReason: metric.degradedReason,
    ratio: metric.ratio,
  };
}

function toTrackerItemKeyDto(key: TrackerItemKey): TrackerItemKeyDto {
  return {
    base: key.base,
    rawSection: key.rawSection,
    dataID: bigintToNumber(key.dataID),
    nestedKind: key.nestedKind,
    nestedRootIdentity:
      key.nestedRootIdentity === null
        ? null
        : {
            base: key.nestedRootIdentity.base,
            rawSection: key.nestedRootIdentity.rawSection,
            dataID: bigintToNumber(key.nestedRootIdentity.dataID),
          },
    nestedPath: key.nestedPath.map((component) => ({
      kind: component.kind,
      dataID: bigintToNumber(component.dataID),
    })),
    stableId: trackerItemKeyStableId(key),
  };
}

function toCatalogAvailabilityDto(value: CatalogAvailability): CatalogAvailabilityDto {
  switch (value.kind) {
    case 'permanent':
      return { kind: 'permanent' };
    case 'seasonal':
      return {
        kind: 'seasonal',
        phaseID: value.phaseID,
        phaseName: value.phaseName,
        status: value.status,
      };
    case 'unconfigured':
      return { kind: 'unconfigured' };
    case 'conflict':
      return {
        kind: 'conflict',
        phaseID: value.phaseID,
        phaseName: value.phaseName,
        lifecycle: value.lifecycle,
        sourceURL: value.sourceURL,
      };
  }
}

function toCatalogCompatibilityDto(value: CatalogCompatibility): CatalogCompatibilityDto {
  switch (value.kind) {
    case 'unverified':
      return { kind: 'unverified', gameVersion: value.gameVersion };
    case 'verified':
      return { kind: 'verified', gameVersion: value.gameVersion };
    case 'mismatch':
      return {
        kind: 'mismatch',
        catalogVersion: value.catalogVersion,
        expectedVersion: value.expectedVersion,
      };
    case 'unavailable':
      return { kind: 'unavailable' };
  }
}

function optionalNextUpgrade(value: VillageNextUpgrade | null): VillageNextUpgradeDto | null {
  if (value === null) {
    return null;
  }
  switch (value.kind) {
    case 'available':
      return {
        kind: 'available',
        level: value.level,
        durationSeconds: optionalBigintToNumber(value.durationSeconds),
      };
    case 'requires':
      return {
        kind: 'requires',
        nextLevel: value.nextLevel,
        requirements: [...value.requirements],
        referenceDurationSeconds: optionalBigintToNumber(value.referenceDurationSeconds),
      };
    case 'globalMaxed':
      return { kind: 'globalMaxed' };
    case 'inProgressFact':
      return {
        kind: 'inProgressFact',
        level: value.level,
        durationSeconds: optionalBigintToNumber(value.durationSeconds),
      };
    case 'unverified':
      return { kind: 'unverified' };
    case 'unknown':
      return { kind: 'unknown' };
  }
}

function optionalDurationState(value: CatalogDurationState | null): CatalogDurationStateDto | null {
  if (value === null) {
    return null;
  }
  switch (value.kind) {
    case 'timed':
      return { kind: 'timed', seconds: bigintToNumber(value.seconds) };
    case 'instant':
      return { kind: 'instant' };
    case 'initialLevel':
      return { kind: 'initialLevel' };
    case 'notApplicable':
      return { kind: 'notApplicable' };
    case 'sourceMissing':
      return { kind: 'sourceMissing' };
    case 'parseFailed':
      return { kind: 'parseFailed' };
    case 'unknownReason':
      return { kind: 'unknownReason', reason: value.reason };
  }
}

function optionalAssetRef(value: CatalogAssetRef | null): CatalogAssetRefDto | null {
  if (value === null) {
    return null;
  }
  return {
    container: value.container,
    exportName: value.exportName,
    renderedPath: value.renderedPath,
    missingReason: value.missingReason,
  };
}

function readEffectiveStatus(value: unknown): VillageItemStateDto['effectiveStatus'] {
  if (typeof value !== 'object' || value === null) {
    return null;
  }
  const status = (value as EffectiveVillageItemState).status;
  if (
    status === 'observed' ||
    status === 'manualCompleted' ||
    status === 'manualActive' ||
    status === 'importedActive' ||
    status === 'needsReimport' ||
    status === 'conflict' ||
    status === 'unknown' ||
    status === 'unavailable'
  ) {
    return status;
  }
  return null;
}

function optionalBigintToNumber(value: bigint | null | undefined): number | null {
  if (value === null || value === undefined) {
    return null;
  }
  return bigintToNumber(value);
}

function bigintToNumber(value: bigint): number {
  const asNumber = Number(value);
  if (!Number.isSafeInteger(asNumber) || BigInt(asNumber) !== value) {
    throw new RangeError(`IPC DTO 超出 JS safe integer：${value.toString()}`);
  }
  return asNumber;
}
