import {
  saturatingAdd,
  saturatingMultiply,
  saturatingSubtract,
  INT64_BOUNDS,
} from '@coc-helper/wire';

import type { CatalogLevel, CatalogUpgradeCost } from '../catalog/types';
import type { CatalogDurationState } from '../catalog/duration-state';
import { catalogDurationState } from '../catalog/duration-state';
import type { GameCatalog } from '../catalog/game-catalog';
import type { SeasonalPhaseTable } from '../catalog/seasonal-phase';
import { EMPTY_SEASONAL_PHASE_TABLE } from '../catalog/seasonal-phase';
import type {
  ManualBaselineReference,
  ManualItemState,
  ManualLevelDistribution,
  ManualLevelQuantity,
  ManualUpgradeCore,
  ManualUpgradeRecord,
  TrackerItemKey,
} from '../manual/types';
import {
  MANUAL_LEVEL_DISTRIBUTION_EMPTY,
  manualEffectiveItemState,
  manualItemState,
  manualLevelDistributionQuantityAt,
  manualLevelDistributionTotalQuantity,
  trackerItemKeyRoot,
  trackerItemKeyStableId,
} from '../manual/types';
import { projectVillageCatalog } from './catalog-projection';
import type {
  EffectiveVillageCountQuality,
  EffectiveVillageItemProvenance,
  EffectiveVillageItemState,
  EffectiveVillageItemStatus,
} from './effective-projection';
import type { TrackerBase, TrackerCategory, TrackerDisplayCategory } from './tracker';
import {
  instanceWeight,
  type ProgressUniverseCoverage,
  type VillageCatalogProjection,
  type VillageItemState,
  type VillageItemStatus,
} from './types';
import type { VillageProfile } from '../import/types';

export type BuildingUpgradeStep = {
  readonly level: number;
  readonly upgradeCosts: readonly CatalogUpgradeCost[] | null;
  readonly durationSeconds: bigint | null;
  readonly missingReason: string | null;
};

export function buildingUpgradeStepHasCost(step: BuildingUpgradeStep): boolean {
  return step.upgradeCosts !== null && step.upgradeCosts.length > 0;
}

export function buildingUpgradeStepHasDuration(step: BuildingUpgradeStep): boolean {
  return step.durationSeconds !== null;
}

export function buildingUpgradeStepIsInstant(step: BuildingUpgradeStep): boolean {
  return step.durationSeconds === 0n;
}

export function buildingUpgradeStepDurationState(
  step: BuildingUpgradeStep,
): CatalogDurationState | null {
  return catalogDurationState(step.durationSeconds, step.missingReason);
}

export type BuildingInstance = {
  readonly id: string;
  readonly item: VillageItemState;
  readonly steps: readonly BuildingUpgradeStep[];
};

export type BuildingResourceTotal = {
  readonly resource: string;
  readonly totalCost: bigint;
};

export type BuildingGroupCompleteness = 'complete' | 'partialMissing' | 'versionMismatch';

export type BuildingGroupCoverage = 'complete' | 'partial' | 'unavailable';

export type BuildingGroupSummary = {
  readonly instanceCount: number;
  readonly remainingLevelCount: number;
  readonly totalDurationSeconds: bigint;
  readonly costByResource: readonly BuildingResourceTotal[];
  readonly saturated: boolean;
  readonly completeness: BuildingGroupCompleteness;
};

export type BuildingGroupUpgradeAction = {
  readonly fromLevel: number;
  readonly targetLevel: number;
  readonly quantity: bigint;
  readonly durationState: CatalogDurationState | null;
  readonly upgradeCosts: readonly CatalogUpgradeCost[] | null;
  readonly coverage: BuildingGroupCoverage;
  readonly baselineReference: ManualBaselineReference | null;
  readonly isStartable: boolean;
  readonly diagnostic: string | null;
};

export type BuildingGroupTrackerState = {
  readonly itemKey: TrackerItemKey;
  readonly coverage: BuildingGroupCoverage;
  readonly importedDistribution: ManualLevelDistribution | null;
  readonly importedCountQuality: EffectiveVillageCountQuality | null;
  readonly manualCompletedDistribution: ManualLevelDistribution | null;
  readonly effectiveCompletedDistribution: ManualLevelDistribution | null;
  readonly activeTargetDistribution: ManualLevelDistribution;
  readonly activeRecords: readonly ManualUpgradeRecord[];
  readonly status: EffectiveVillageItemStatus;
  readonly provenance: readonly EffectiveVillageItemProvenance[];
  readonly diagnostics: readonly string[];
  readonly actions: readonly BuildingGroupUpgradeAction[];
};

export function buildingGroupTrackerAvailableQuantity(
  state: BuildingGroupTrackerState,
  level: number,
): bigint | null {
  if (state.effectiveCompletedDistribution === null) {
    return null;
  }
  return manualLevelDistributionQuantityAt(state.effectiveCompletedDistribution, level);
}

export function buildingGroupTrackerImportedQuantity(
  state: BuildingGroupTrackerState,
): bigint | null {
  if (state.importedDistribution === null) {
    return null;
  }
  return manualLevelDistributionTotalQuantity(state.importedDistribution);
}

export function buildingGroupTrackerCompletedQuantity(
  state: BuildingGroupTrackerState,
): bigint | null {
  if (state.effectiveCompletedDistribution === null) {
    return null;
  }
  return manualLevelDistributionTotalQuantity(state.effectiveCompletedDistribution);
}

export function buildingGroupTrackerActiveQuantity(state: BuildingGroupTrackerState): bigint {
  return manualLevelDistributionTotalQuantity(state.activeTargetDistribution);
}

export function buildingGroupTrackerActiveQuantityFromLevel(
  state: BuildingGroupTrackerState,
  fromLevel: number,
): bigint {
  return state.activeRecords
    .filter((record) => record.fromLevel === fromLevel)
    .reduce((sum, record) => sum + record.quantity, 0n);
}

export function buildingGroupTrackerActiveQuantityTargetLevel(
  state: BuildingGroupTrackerState,
  targetLevel: number,
): bigint {
  return manualLevelDistributionQuantityAt(state.activeTargetDistribution, targetLevel);
}

export type BuildingGroup = {
  readonly base: TrackerBase;
  readonly section: string;
  readonly dataID: bigint;
  readonly name: string;
  readonly instances: readonly BuildingInstance[];
  readonly summary: BuildingGroupSummary;
  readonly displayCategory: TrackerDisplayCategory | null;
  readonly category: TrackerCategory | null;
  readonly trackerState: BuildingGroupTrackerState;
  readonly id: string;
};

export function buildingGroupId(
  base: TrackerBase,
  section: string,
  dataID: bigint,
): string {
  return `${base}:${section}:${dataID}`;
}

export type ProjectBuildingGroupsInput = {
  readonly village: VillageProfile;
  readonly catalog: GameCatalog | null | undefined;
  readonly base: TrackerBase;
  readonly expectedGameVersion?: string | null;
  readonly seasonalPhases?: SeasonalPhaseTable;
  readonly nowMs?: number;
  readonly manualUpgradeCore?: ManualUpgradeCore | null;
};

export type ProjectBuildingGroupsFromProjectionInput = {
  readonly projection: VillageCatalogProjection;
  readonly catalog: GameCatalog | null | undefined;
  readonly base: TrackerBase;
  readonly manualUpgradeCore?: ManualUpgradeCore | null;
};

export function projectBuildingGroups(
  input: ProjectBuildingGroupsInput,
): BuildingGroup[];
export function projectBuildingGroups(
  input: ProjectBuildingGroupsFromProjectionInput,
): BuildingGroup[];
export function projectBuildingGroups(
  input: ProjectBuildingGroupsInput | ProjectBuildingGroupsFromProjectionInput,
): BuildingGroup[] {
  if ('projection' in input) {
    return projectBuildingGroupsFromProjection(input);
  }
  const projection = projectVillageCatalog({
    village: input.village,
    catalog: input.catalog,
    expectedGameVersion: input.expectedGameVersion,
    seasonalPhases: input.seasonalPhases ?? EMPTY_SEASONAL_PHASE_TABLE,
    base: input.base,
    nowMs: input.nowMs ?? Date.now(),
    manualUpgradeCore: input.manualUpgradeCore,
  });
  return projectBuildingGroupsFromProjection({
    projection,
    catalog: input.catalog,
    base: input.base,
    manualUpgradeCore: input.manualUpgradeCore,
  });
}

export function projectBuildingGroupsFromProjection(
  input: ProjectBuildingGroupsFromProjectionInput,
): BuildingGroup[] {
  const { projection, catalog, base, manualUpgradeCore } = input;
  const records = projection.rawItems.filter(
    (record) =>
      !record.isNested &&
      (record.section === 'buildings' || record.section === 'buildings2') &&
      record.base === base,
  );

  const grouped = new Map<string, VillageItemState[]>();
  for (const record of records) {
    const key = `${record.section}:${record.dataID}`;
    const bucket = grouped.get(key);
    if (bucket === undefined) {
      grouped.set(key, [record]);
    } else {
      bucket.push(record);
    }
  }

  const keys = [...grouped.keys()].sort((left, right) => {
    const [leftSection, leftDataID] = left.split(':');
    const [rightSection, rightDataID] = right.split(':');
    if (leftSection !== rightSection) {
      return leftSection!.localeCompare(rightSection!);
    }
    const leftID = BigInt(leftDataID!);
    const rightID = BigInt(rightDataID!);
    return leftID < rightID ? -1 : leftID > rightID ? 1 : 0;
  });

  const effectiveByKey = new Map(
    (projection.effectiveTrackerItems as readonly EffectiveVillageItemState[]).map(
      (item) => [stableTrackerItemKeyId(item.itemKey), item] as const,
    ),
  );

  return keys.flatMap((key) => {
    const groupRecords = grouped.get(key);
    if (groupRecords === undefined || groupRecords.length === 0) {
      return [];
    }
    const first = [...groupRecords].sort((left, right) => left.id.localeCompare(right.id))[0]!;
    const instances = groupRecords.map((record) => ({
      id: record.id,
      item: record,
      steps: buildingUpgradeStepsForItem(record, catalog, projection.catalogIsUsable),
    }));
    const itemKey = trackerItemKeyRoot(base, first.section, first.dataID);
    const coverage = buildingGroupCoverage(itemKey, projection.progressCoverage);
    return [
      {
        base,
        section: first.section,
        dataID: first.dataID,
        name: first.name,
        instances,
        summary: buildingGroupSummary(instances, projection.catalogIsUsable, catalog === null),
        displayCategory: first.displayCategory,
        category: first.category,
        trackerState: buildingGroupTrackerState(
          itemKey,
          effectiveByKey.get(stableTrackerItemKeyId(itemKey)) ?? null,
          catalog,
          projection.catalogIsUsable,
          manualUpgradeCore,
          coverage,
        ),
        id: buildingGroupId(base, first.section, first.dataID),
      },
    ];
  });
}

function stableTrackerItemKeyId(itemKey: TrackerItemKey): string {
  return trackerItemKeyStableId(itemKey);
}

function buildingGroupTrackerState(
  itemKey: TrackerItemKey,
  effective: EffectiveVillageItemState | null,
  catalog: GameCatalog | null | undefined,
  catalogIsUsable: boolean,
  manualUpgradeCore: ManualUpgradeCore | null | undefined,
  coverage: BuildingGroupCoverage,
): BuildingGroupTrackerState {
  if (effective === null) {
    return {
      itemKey,
      coverage,
      importedDistribution: null,
      importedCountQuality: null,
      manualCompletedDistribution: null,
      effectiveCompletedDistribution: null,
      activeTargetDistribution: MANUAL_LEVEL_DISTRIBUTION_EMPTY,
      activeRecords: [],
      status: 'unavailable',
      provenance: [],
      diagnostics: ['没有对应的稳定 tracker 状态。'],
      actions: [],
    };
  }

  const diagnostics = effective.diagnostic === null ? [] : [effective.diagnostic];
  if (effective.effectiveCompletedDistribution === null) {
    diagnostics.push('完成等级分布未知，不能生成升级操作。');
  }
  switch (effective.importedCountQuality) {
    case 'known':
      break;
    case 'malformed':
      diagnostics.push('快照数量字段缺失或非正数，不能安全启动本地升级。');
      break;
    case 'overflowed':
      diagnostics.push('快照数量汇总溢出，不能安全启动本地升级。');
      break;
  }
  switch (coverage) {
    case 'complete':
      break;
    case 'partial':
      diagnostics.push('建筑 scope 覆盖不完整，不能安全启动本地升级。');
      break;
    case 'unavailable':
      diagnostics.push('建筑 scope 覆盖状态不可用，不能安全启动本地升级。');
      break;
  }
  if (catalog === null || catalog === undefined || !catalogIsUsable) {
    diagnostics.push('目录不可用，不能生成升级操作。');
  } else if (catalog.item(itemKey.rawSection, itemKey.dataID) === undefined) {
    diagnostics.push('目录中没有对应的升级条目，不能生成升级操作。');
  }
  if (manualUpgradeCore === null || manualUpgradeCore === undefined) {
    diagnostics.push('未提供本地 tracker 状态，升级操作不可直接执行。');
  } else if (manualItemState(manualUpgradeCore, itemKey) === undefined) {
    diagnostics.push('本地 tracker 没有对应的 itemState，升级操作不可直接执行。');
  }

  return {
    itemKey,
    coverage,
    importedDistribution: effective.importedDistribution,
    importedCountQuality: effective.importedCountQuality,
    manualCompletedDistribution: effective.manualCompletedDistribution,
    effectiveCompletedDistribution: effective.effectiveCompletedDistribution,
    activeTargetDistribution: effective.activeTargetDistribution,
    activeRecords: effective.activeManualRecords,
    status: effective.status,
    provenance: effective.provenance,
    diagnostics: uniqueStrings(diagnostics),
    actions: buildingGroupActions(
      effective,
      catalog,
      catalogIsUsable,
      manualUpgradeCore,
      coverage,
    ),
  };
}

function buildingGroupActions(
  effective: EffectiveVillageItemState,
  catalog: GameCatalog | null | undefined,
  catalogIsUsable: boolean,
  manualUpgradeCore: ManualUpgradeCore | null | undefined,
  coverage: BuildingGroupCoverage,
): BuildingGroupUpgradeAction[] {
  if (!catalogIsUsable) {
    return [];
  }
  const distribution = effective.effectiveCompletedDistribution;
  if (distribution === null) {
    return [];
  }
  const catalogItem = catalog?.item(
    effective.itemKey.rawSection,
    effective.itemKey.dataID,
  );
  if (catalogItem === undefined || catalogItem.base !== effective.itemKey.base) {
    return [];
  }

  const manualItem = manualUpgradeCore === null || manualUpgradeCore === undefined
    ? undefined
    : manualItemState(manualUpgradeCore, effective.itemKey);
  const manualEffective =
    manualUpgradeCore === null || manualUpgradeCore === undefined
      ? undefined
      : manualEffectiveItemState(manualUpgradeCore, effective.itemKey);
  const levels = [...catalogItem.levels].sort((left, right) => left.level - right.level);

  return distribution.levels.flatMap((source) => {
    const target = levels.find((level) => level.level > source.level);
    if (target === undefined) {
      return [];
    }

    const reasons: string[] = [];
    switch (coverage) {
      case 'complete':
        break;
      case 'partial':
        reasons.push('建筑 scope 覆盖不完整，不能安全启动本地升级。');
        break;
      case 'unavailable':
        reasons.push('建筑 scope 覆盖状态不可用，不能安全启动本地升级。');
        break;
    }
    switch (effective.status) {
      case 'observed':
      case 'manualCompleted':
      case 'manualActive':
        break;
      case 'importedActive':
        reasons.push('导入计时尚未被本地 tracker 精确接管。');
        break;
      case 'needsReimport':
        reasons.push('导入快照需要重新导入。');
        break;
      case 'conflict':
        reasons.push('本地与导入状态冲突。');
        break;
      case 'unknown':
        reasons.push('当前等级分布未知。');
        break;
      case 'unavailable':
        reasons.push('当前项目不可用。');
        break;
    }

    switch (effective.importedCountQuality) {
      case 'known':
        break;
      case 'malformed':
        reasons.push('快照数量字段缺失或非正数，不能安全启动本地升级。');
        break;
      case 'overflowed':
        reasons.push('快照数量汇总溢出，不能安全启动本地升级。');
        break;
    }

    if (manualUpgradeCore === null || manualUpgradeCore === undefined) {
      reasons.push('未提供本地 tracker 状态，不能直接执行升级。');
    } else if (manualItem !== undefined) {
      if (!manualItemIsStructurallyValid(manualItem)) {
        reasons.push('本地 tracker 的 itemState 或 baseline 无效。');
        return [
          makeBuildingGroupAction(
            source,
            target,
            coverage,
            manualItem.baselineReference,
            reasons,
            reasons,
          ),
        ];
      }
      switch (manualItem.status) {
        case 'observed':
        case 'manualCompleted':
          break;
        case 'unknown':
          reasons.push('本地 tracker 状态未知。');
          break;
        case 'conflict':
          reasons.push('本地 tracker 状态冲突。');
          break;
      }
      if (
        manualEffective === undefined ||
        manualEffective.effectiveCompletedDistribution === null
      ) {
        reasons.push('本地 tracker 无可执行的完成等级分布。');
        return [
          makeBuildingGroupAction(
            source,
            target,
            coverage,
            manualItem.baselineReference,
            reasons,
            reasons,
          ),
        ];
      }
      const coreDistribution = manualEffective.effectiveCompletedDistribution;
      if (manualLevelDistributionQuantityAt(coreDistribution, source.level) < source.quantity) {
        reasons.push('本地 tracker 的可用数量不足。');
      }
      if (
        !manualLevelDistributionsEqual(
          coreDistribution,
          effective.effectiveCompletedDistribution,
        )
      ) {
        reasons.push('快照 effective 分布与本地 tracker 分布不一致。');
      }
    } else {
      reasons.push('本地 tracker 没有对应的 itemState。');
    }

    if (effective.currentStageMaxLevel !== null && effective.currentStageMaxLevel !== undefined) {
      if (target.level > effective.currentStageMaxLevel) {
        reasons.push('目标等级超过当前阶段上限。');
      }
    } else {
      reasons.push('当前阶段上限无法验证。');
    }

    if (
      effective.globalMaxLevel !== null &&
      effective.globalMaxLevel !== undefined &&
      target.level > effective.globalMaxLevel
    ) {
      reasons.push('目标等级超过目录全局上限。');
    }

    const targetDurationState = catalogDurationState(
      target.durationSeconds,
      target.missingReason,
    );
    if (
      targetDurationState?.kind !== 'timed' &&
      targetDurationState?.kind !== 'instant'
    ) {
      reasons.push('目标升级时长不可用。');
    }

    const blockingReasons = [...reasons];
    const actionDiagnostics = [...reasons];
    if (target.upgradeCosts?.some((cost) => cost.parseFailed) === true) {
      actionDiagnostics.push('目标升级费用含解析失败项，启动时保留 raw 费用证据。');
    } else if (target.upgradeCosts === null) {
      actionDiagnostics.push('目标升级费用未知，启动时保留 unknown cost 状态。');
    }

    return [
      makeBuildingGroupAction(
        source,
        target,
        coverage,
        manualItem?.baselineReference ?? null,
        blockingReasons,
        actionDiagnostics,
      ),
    ];
  });
}

function makeBuildingGroupAction(
  source: ManualLevelQuantity,
  target: CatalogLevel,
  coverage: BuildingGroupCoverage,
  baselineReference: ManualBaselineReference | null,
  blockingReasons: readonly string[],
  diagnostics: readonly string[],
): BuildingGroupUpgradeAction {
  return {
    fromLevel: source.level,
    targetLevel: target.level,
    quantity: 1n,
    durationState: catalogDurationState(target.durationSeconds, target.missingReason),
    upgradeCosts: target.upgradeCosts,
    coverage,
    baselineReference,
    isStartable: blockingReasons.length === 0 && source.quantity > 0n,
    diagnostic: diagnostics.length === 0 ? null : diagnostics.join('；'),
  };
}

function buildingGroupCoverage(
  itemKey: TrackerItemKey,
  progressCoverage: ProgressUniverseCoverage,
): BuildingGroupCoverage {
  if (itemKey.base !== 'home' || itemKey.rawSection !== 'buildings') {
    return 'unavailable';
  }
  switch (progressCoverage.kind) {
    case 'complete':
      return 'complete';
    case 'unavailable':
      return 'unavailable';
    case 'partial':
      return progressCoverage.missingSections.has('buildings') ||
        progressCoverage.unmodeledCategories.has('buildings')
        ? 'partial'
        : 'complete';
  }
}

function buildingUpgradeStepsForItem(
  item: VillageItemState,
  catalog: GameCatalog | null | undefined,
  catalogIsUsable: boolean,
): BuildingUpgradeStep[] {
  if (
    !catalogIsUsable ||
    (isEffectivelyUpgrading(item) && item.currentStageMaxLevel === null) ||
    item.status === 'unverified' ||
    item.status === 'unknown' ||
    effectiveStateIsUnusable(item) ||
    item.maxLevel === null ||
    catalog?.item(item.section, item.dataID) === undefined
  ) {
    return [];
  }

  const effectiveMax = item.currentStageMaxLevel ?? item.maxLevel;
  const currentLevel = effectiveCurrentLevel(item);
  const catalogItem = catalog!.item(item.section, item.dataID)!;

  return [...catalogItem.levels]
    .filter(
      (level) =>
        level.level > (currentLevel ?? Number.MAX_SAFE_INTEGER) &&
        level.level <= effectiveMax,
    )
    .sort((left, right) => left.level - right.level)
    .map((level) => ({
      level: level.level,
      upgradeCosts: level.upgradeCosts,
      durationSeconds: level.durationSeconds,
      missingReason: level.missingReason,
    }));
}

function buildingGroupSummary(
  instances: readonly BuildingInstance[],
  catalogIsUsable: boolean,
  catalogIsNil: boolean,
): BuildingGroupSummary {
  let instanceCount = 0;
  let remainingLevelCount = 0;
  let totalDurationSeconds = 0n;
  const costByResource = new Map<string, bigint>();
  let hasPartialMissing = false;
  let hasVersionMismatch = false;
  let saturated = false;

  for (const instance of instances) {
    const count = instanceWeight(instance.item);
    const instanceCountResult = saturatingAddInt(instanceCount, count);
    instanceCount = instanceCountResult.value;
    saturated =
      saturated || instance.item.countOverflowed === true || instanceCountResult.overflowed;

    const maxLevel = instance.item.maxLevel;
    const currentLevel = effectiveCurrentLevel(instance.item);
    if (
      maxLevel !== null &&
      currentLevel !== null &&
      currentLevel !== undefined &&
      currentLevel > maxLevel
    ) {
      hasVersionMismatch = true;
    }

    if (
      instance.item.status === 'unverified' ||
      instance.item.status === 'unknown' ||
      effectiveStateIsUnusable(instance.item) ||
      (isEffectivelyUpgrading(instance.item) && instance.steps.length === 0)
    ) {
      hasPartialMissing = true;
    } else if (maxLevel !== null && currentLevel !== null && currentLevel !== undefined) {
      const effectiveMax = instance.item.currentStageMaxLevel ?? maxLevel;
      const levelDifference = saturatingSubtract(
        BigInt(effectiveMax),
        BigInt(currentLevel),
        INT64_BOUNDS,
      );
      saturated = saturated || levelDifference.overflowed;
      const remainingLevels = Math.max(0, Number(levelDifference.value));
      const weightedRemainingLevels = saturatingMultiply(
        BigInt(remainingLevels),
        BigInt(count),
        INT64_BOUNDS,
      );
      saturated = saturated || weightedRemainingLevels.overflowed;
      const remainingTotal = saturatingAddInt(
        remainingLevelCount,
        Number(weightedRemainingLevels.value),
      );
      remainingLevelCount = remainingTotal.value;
      saturated = saturated || remainingTotal.overflowed;
    }

    if (
      instance.item.maxLevel !== null &&
      instance.item.status !== 'unverified' &&
      instance.item.status !== 'unknown' &&
      !effectiveStateIsUnusable(instance.item)
    ) {
      const effectiveMax = instance.item.currentStageMaxLevel ?? instance.item.maxLevel;
      const maxed =
        effectiveCurrentLevel(instance.item) !== null &&
        effectiveCurrentLevel(instance.item) !== undefined &&
        effectiveCurrentLevel(instance.item)! >= effectiveMax;
      if (
        effectiveCurrentLevel(instance.item) === null ||
        effectiveCurrentLevel(instance.item) === undefined ||
        (instance.steps.length === 0 && !maxed)
      ) {
        hasPartialMissing = true;
      }
    } else {
      hasPartialMissing = true;
    }

    for (const step of instance.steps) {
      if (
        step.upgradeCosts === null ||
        step.upgradeCosts.length === 0 ||
        step.durationSeconds === null
      ) {
        hasPartialMissing = true;
      }
      if (step.durationSeconds !== null) {
        const weightedDuration = saturatingMultiply(
          step.durationSeconds,
          BigInt(count),
          INT64_BOUNDS,
        );
        saturated = saturated || weightedDuration.overflowed;
        const durationTotal = saturatingAddBigInt(
          totalDurationSeconds,
          weightedDuration.value,
        );
        totalDurationSeconds = durationTotal.value;
        saturated = saturated || durationTotal.overflowed;
      }
      for (const cost of step.upgradeCosts ?? []) {
        if (cost.parseFailed || cost.amount === null) {
          hasPartialMissing = true;
          continue;
        }
        const weightedCost = saturatingMultiply(cost.amount, BigInt(count), INT64_BOUNDS);
        saturated = saturated || weightedCost.overflowed;
        const previous = costByResource.get(cost.resource) ?? 0n;
        const costTotal = saturatingAddBigInt(previous, weightedCost.value);
        costByResource.set(cost.resource, costTotal.value);
        saturated = saturated || costTotal.overflowed;
      }
    }
  }

  const completeness: BuildingGroupCompleteness = catalogIsNil
    ? 'partialMissing'
    : !catalogIsUsable
      ? 'versionMismatch'
      : hasVersionMismatch
        ? 'versionMismatch'
        : hasPartialMissing
          ? 'partialMissing'
          : 'complete';

  return {
    instanceCount,
    remainingLevelCount,
    totalDurationSeconds,
    costByResource: [...costByResource.entries()]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([resource, totalCost]) => ({ resource, totalCost })),
    saturated,
    completeness,
  };
}

function effectiveStateIsUnusable(item: VillageItemState): boolean {
  const state = item.effectiveState as EffectiveVillageItemState | undefined;
  if (state === undefined) {
    return false;
  }
  switch (state.status) {
    case 'unknown':
    case 'conflict':
    case 'needsReimport':
    case 'unavailable':
      return true;
    case 'observed':
    case 'manualCompleted':
    case 'manualActive':
    case 'importedActive':
      return false;
  }
}

function effectiveCompletedLevel(state: EffectiveVillageItemState): number | null {
  if (state.effectiveCompletedDistribution?.levels.length === 1) {
    return state.effectiveCompletedDistribution.levels[0]?.level ?? null;
  }
  return null;
}

function effectiveCurrentLevel(item: VillageItemState): number | null | undefined {
  const state = item.effectiveState as EffectiveVillageItemState | undefined;
  return (
    (state === undefined ? undefined : effectiveCompletedLevel(state)) ??
    state?.importedCurrentLevel ??
    item.currentLevel
  );
}

function isEffectivelyUpgrading(item: VillageItemState): boolean {
  const state = item.effectiveState as EffectiveVillageItemState | undefined;
  if (state === undefined) {
    return (item.remainingSeconds ?? 0n) > 0n;
  }
  return state.status === 'manualActive' || state.status === 'importedActive';
}

function uniqueStrings(values: readonly string[]): string[] {
  const seen = new Set<string>();
  return values.filter((value) => {
    if (seen.has(value)) {
      return false;
    }
    seen.add(value);
    return true;
  });
}

function manualItemIsStructurallyValid(state: ManualItemState): boolean {
  return (
    state.itemKey.rawSection.length > 0 &&
    state.itemKey.dataID > 0n &&
    state.baselineReference.revision.trim().length > 0
  );
}

function manualLevelDistributionsEqual(
  left: ManualLevelDistribution,
  right: ManualLevelDistribution | null,
): boolean {
  if (right === null) {
    return false;
  }
  if (left.levels.length !== right.levels.length) {
    return false;
  }
  return left.levels.every((entry, index) => {
    const other = right.levels[index];
    return other !== undefined && entry.level === other.level && entry.quantity === other.quantity;
  });
}

function saturatingAddInt(left: number, right: number): { value: number; overflowed: boolean } {
  const result = saturatingAdd(BigInt(left), BigInt(right), INT64_BOUNDS);
  return { value: Number(result.value), overflowed: result.overflowed };
}

function saturatingAddBigInt(
  left: bigint,
  right: bigint,
): { value: bigint; overflowed: boolean } {
  return saturatingAdd(left, right, INT64_BOUNDS);
}
