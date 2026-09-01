import type { AccountItem, AccountSnapshot } from '../account';
import { catalogDurationState, type CatalogDurationState } from '../catalog/duration-state';
import type { CatalogCompatibility } from '../catalog/types';
import type { GameCatalog } from '../catalog/game-catalog';
import type { CatalogLevel } from '../catalog/types';
import {
  manualActiveRecords,
  manualEffectiveItemState,
  manualItemState,
  manualLevelDistributionAdd,
  manualLevelDistributionFromQuantities,
  manualLevelDistributionIsEmpty,
  manualLevelDistributionTotalQuantity,
  MANUAL_LEVEL_DISTRIBUTION_EMPTY,
  trackerItemKeyRoot,
  trackerItemKeyStableId,
  type ManualLevelDistribution,
  type ManualUpgradeCore,
  type ManualUpgradeRecord,
  type TrackerItemKey,
  type TrackerNestedPathComponent,
  type TrackerRootIdentity,
} from '../manual/types';
import { liveRemainingSeconds } from './catalog-projection';
import {
  replacingTrackerMetrics,
  villageProgressMetrics,
  type ProgressMetric,
  type ProgressMetricState,
  type VillageProgressMetrics,
} from './progress-metrics';
import type { TrackerBase } from './tracker';
import { catalogLevelRequirements } from './upgrade-requirement';
import type { ProgressUniverseCoverage, VillageItemState, VillageNextUpgrade } from './types';

export type EffectiveVillageItemStatus =
  | 'observed'
  | 'manualCompleted'
  | 'manualActive'
  | 'importedActive'
  | 'needsReimport'
  | 'conflict'
  | 'unknown'
  | 'unavailable';

export type EffectiveVillageItemProvenance =
  'observed' | 'manualCompleted' | 'manualActive' | 'importedActive' | 'needsReimport';

export type EffectiveVillageCountQuality = 'known' | 'malformed' | 'overflowed';

export type EffectiveVillageItemState = {
  readonly itemKey: TrackerItemKey;
  readonly rawItemID: string | null;
  readonly importedCurrentLevel: number | null;
  readonly importedCount: number | null;
  readonly importedInstanceWeight: bigint;
  readonly importedCountOverflowed: boolean;
  readonly importedCountQuality: EffectiveVillageCountQuality;
  readonly importedTimerSeconds: bigint | null;
  readonly importedRemainingSeconds: bigint | null;
  readonly importedDistribution: ManualLevelDistribution | null;
  readonly manualCompletedDistribution: ManualLevelDistribution | null;
  readonly activeManualRecords: readonly ManualUpgradeRecord[];
  readonly activeTargetDistribution: ManualLevelDistribution;
  readonly effectiveCompletedDistribution: ManualLevelDistribution | null;
  readonly status: EffectiveVillageItemStatus;
  readonly provenance: readonly EffectiveVillageItemProvenance[];
  readonly diagnostic: string | null;
  readonly catalogDurationState: CatalogDurationState | null;
  readonly catalogCosts: CatalogLevel['upgradeCosts'] | null;
  readonly catalogNextUpgrade: VillageNextUpgrade | null;
  readonly currentStageMaxLevel: number | null;
  readonly globalMaxLevel: number | null;
  readonly effectiveCompletedLevel: number | null;
  readonly activeTargetLevel: number | null;
};

export type ManualTrackerCoverage = {
  readonly observedItemCount: number;
  readonly manualItemCount: number;
  readonly effectiveItemCount: number;
  readonly activeRecordCount: number;
  readonly unknownItemCount: number;
  readonly state: ProgressMetricState;
  readonly diagnostics: readonly string[];
};

export type BuildEffectiveVillageProjectionInput = {
  readonly snapshot: AccountSnapshot | null;
  readonly rawItems: readonly VillageItemState[];
  readonly items: readonly VillageItemState[];
  readonly catalog: GameCatalog | null;
  readonly catalogIsUsable: boolean;
  readonly compatibility: CatalogCompatibility;
  readonly base: TrackerBase;
  readonly nowMs: number;
  readonly manualUpgradeCore: ManualUpgradeCore | null;
  readonly progressCoverage: ProgressUniverseCoverage;
};

export type EffectiveVillageProjectionResult = {
  readonly items: readonly VillageItemState[];
  readonly rawItems: readonly VillageItemState[];
  readonly trackerItems: readonly EffectiveVillageItemState[];
  readonly manualCoverage: ManualTrackerCoverage;
  readonly progressMetrics: VillageProgressMetrics;
};

export function buildEffectiveVillageProjection(
  input: BuildEffectiveVillageProjectionInput,
): EffectiveVillageProjectionResult {
  const {
    snapshot,
    rawItems,
    items,
    catalog,
    catalogIsUsable,
    compatibility,
    base,
    nowMs,
    manualUpgradeCore,
    progressCoverage,
  } = input;

  if (snapshot === null) {
    const unavailable = villageProgressMetrics({
      items: [],
      catalogIsUsable,
      compatibility,
      coverage: progressCoverage,
    });
    return {
      items,
      rawItems,
      trackerItems: [],
      manualCoverage: {
        observedItemCount: 0,
        manualItemCount: manualUpgradeCore?.itemStates.length ?? 0,
        effectiveItemCount: 0,
        activeRecordCount: manualUpgradeCore ? manualActiveRecords(manualUpgradeCore).length : 0,
        unknownItemCount: 0,
        state: manualUpgradeCore === null ? 'unavailable' : 'unknown',
        diagnostics:
          manualUpgradeCore === null
            ? ['未提供本地手动状态。']
            : ['本地手动状态没有对应的导入快照。'],
      },
      progressMetrics: unavailable,
    };
  }

  const keyMap = trackerItemKeyMap(snapshot, base);
  const keyedItems: Array<{ readonly key: TrackerItemKey; readonly item: AccountItem }> = [];
  for (const item of flattenSnapshotItems(snapshot, base)) {
    const key = keyMap.get(item.id);
    if (key !== undefined) {
      keyedItems.push({ key, item });
    }
  }

  const groupedItems = new Map<string, AccountItem[]>();
  for (const entry of keyedItems) {
    const stableID = trackerItemKeyStableId(entry.key);
    const bucket = groupedItems.get(stableID) ?? [];
    bucket.push(entry.item);
    groupedItems.set(stableID, bucket);
  }

  const trackerKeys = [...groupedItems.keys()]
    .map(
      (stableID) => keyedItems.find((entry) => trackerItemKeyStableId(entry.key) === stableID)!.key,
    )
    .sort((left, right) =>
      trackerItemKeyStableId(left).localeCompare(trackerItemKeyStableId(right)),
    );

  const rawByImportID = new Map(rawItems.map((item) => [item.id, item]));
  const stateByKey = new Map<string, EffectiveVillageItemState>();
  for (const key of trackerKeys) {
    const observedItems = groupedItems.get(trackerItemKeyStableId(key)) ?? [];
    const state = makeEffectiveState({
      key,
      observedItems,
      rawItems,
      rawByImportID,
      snapshot,
      catalog,
      catalogIsUsable,
      nowMs,
      manualUpgradeCore,
    });
    if (state !== undefined) {
      stateByKey.set(trackerItemKeyStableId(key), state);
    }
  }

  const attachedItems =
    manualUpgradeCore === null
      ? items
      : items.map((item) =>
          attachEffectiveState(item, effectiveStateForItem(item, keyMap, stateByKey)),
        );
  const attachedRawItems =
    manualUpgradeCore === null
      ? rawItems
      : rawItems.map((item) =>
          attachEffectiveState(item, effectiveStateForItem(item, keyMap, stateByKey)),
        );
  const trackerItems = trackerKeys
    .map((key) => stateByKey.get(trackerItemKeyStableId(key)))
    .filter((state): state is EffectiveVillageItemState => state !== undefined);

  const manualCoverage = makeManualCoverage(trackerItems, manualUpgradeCore);
  const importedMetrics = villageProgressMetrics({
    items: attachedItems.filter((item) => item.status !== 'unavailable'),
    catalogIsUsable,
    compatibility,
    coverage: progressCoverage,
  });

  let progressMetrics = importedMetrics;
  if (manualUpgradeCore !== null) {
    progressMetrics = replacingTrackerMetrics(
      importedMetrics,
      instanceMetric({
        trackerItems,
        availableItems: attachedItems.filter((item) => item.status === 'available'),
        catalogIsUsable,
        compatibility,
        manualCoverage,
      }),
      effectiveMetric({
        trackerItems,
        catalogIsUsable,
        compatibility,
        manualCoverage,
      }),
    );
  }

  return {
    items: attachedItems,
    rawItems: attachedRawItems,
    trackerItems,
    manualCoverage,
    progressMetrics,
  };
}

export function effectiveVillageItemIsKnown(state: EffectiveVillageItemState): boolean {
  return (
    state.status !== 'unknown' &&
    state.status !== 'conflict' &&
    state.status !== 'unavailable' &&
    state.status !== 'needsReimport' &&
    state.effectiveCompletedDistribution !== null
  );
}

export function effectiveVillageItemWithImportedRemainingSeconds(
  state: EffectiveVillageItemState,
  importedRemainingSeconds: bigint | null,
): EffectiveVillageItemState {
  return {
    ...state,
    importedRemainingSeconds,
  };
}

function makeEffectiveState(input: {
  readonly key: TrackerItemKey;
  readonly observedItems: readonly AccountItem[];
  readonly rawItems: readonly VillageItemState[];
  readonly rawByImportID: ReadonlyMap<string, VillageItemState>;
  readonly snapshot: AccountSnapshot;
  readonly catalog: GameCatalog | null;
  readonly catalogIsUsable: boolean;
  readonly nowMs: number;
  readonly manualUpgradeCore: ManualUpgradeCore | null;
}): EffectiveVillageItemState | undefined {
  const orderedObservedItems = input.observedItems
    .slice()
    .sort((left, right) => left.id.localeCompare(right.id));
  if (orderedObservedItems.length === 0) {
    return undefined;
  }
  const firstObserved = orderedObservedItems[0]!;
  const importedDistribution = levelDistribution(orderedObservedItems);
  const rawInstanceWeight = computeRawInstanceWeight(orderedObservedItems);
  const importedCountQuality = countQuality(orderedObservedItems, rawInstanceWeight);
  const importedCount =
    importedDistribution !== null &&
    manualLevelDistributionTotalQuantity(importedDistribution) <= BigInt(Number.MAX_SAFE_INTEGER)
      ? Number(manualLevelDistributionTotalQuantity(importedDistribution))
      : null;

  const representative =
    input.rawItems.find(
      (item) => item.id === firstObserved.id || item.id === `agg:${firstObserved.id}`,
    ) ?? input.rawByImportID.get(firstObserved.id);

  const manualItem = input.manualUpgradeCore
    ? manualItemState(input.manualUpgradeCore, input.key)
    : undefined;
  const manualEffective = input.manualUpgradeCore
    ? manualEffectiveItemState(input.manualUpgradeCore, input.key)
    : undefined;
  const activeRecords = input.manualUpgradeCore
    ? manualActiveRecords(input.manualUpgradeCore)
        .filter(
          (record) => trackerItemKeyStableId(record.itemKey) === trackerItemKeyStableId(input.key),
        )
        .slice()
        .sort((left, right) => left.recordID.localeCompare(right.recordID))
    : [];
  const activeTarget = manualEffective?.activeTargetDistribution ?? MANUAL_LEVEL_DISTRIBUTION_EMPTY;

  let effectiveCompleted: ManualLevelDistribution | null;
  switch (manualItem?.status) {
    case 'manualCompleted':
      effectiveCompleted = manualEffective?.effectiveCompletedDistribution ?? null;
      break;
    case 'unknown':
    case 'conflict':
      effectiveCompleted = null;
      break;
    case 'observed':
    case undefined:
      effectiveCompleted = importedDistribution;
      break;
  }

  const observedActiveItems = orderedObservedItems.filter((item) => {
    const remaining = liveRemainingSeconds(item, input.snapshot, input.nowMs);
    return remaining !== null && remaining > 0n;
  });
  const observedNeedsReimport = orderedObservedItems.some((item) => {
    return (
      item.timerSeconds !== null && liveRemainingSeconds(item, input.snapshot, input.nowMs) === 0n
    );
  });
  const exactActiveMatch = hasExactActiveMatch({
    records: activeRecords,
    observedItems: observedActiveItems,
    snapshot: input.snapshot,
    nowMs: input.nowMs,
  });
  const activeCatalogDiagnostic =
    activeRecords.length === 0
      ? null
      : activeCatalogDiagnosticFor({
          records: activeRecords,
          key: input.key,
          representative: representative ?? null,
          catalog: input.catalog,
          catalogIsUsable: input.catalogIsUsable,
        });

  let status: EffectiveVillageItemStatus;
  let provenance: EffectiveVillageItemProvenance[] = [];
  let diagnostic: string | null = null;

  if (activeCatalogDiagnostic !== null) {
    status = 'unknown';
    provenance = ['manualActive'];
    if (observedActiveItems.length > 0) {
      provenance.push('importedActive');
    }
    diagnostic = activeCatalogDiagnostic;
  } else if (representative?.status === 'unavailable') {
    status = 'unavailable';
  } else if (representative?.status === 'unknown' || representative?.status === 'unverified') {
    status = 'unknown';
    diagnostic = representative.missingReason ?? '导入项目的目录状态无法验证。';
  } else if (manualItem?.status === 'conflict') {
    status = 'conflict';
    diagnostic = '本地手动状态处于冲突，暂不生成有效完成等级。';
  } else if (manualItem?.status === 'unknown') {
    status = 'unknown';
    diagnostic = '本地手动状态未知，暂不把缺失解释为零级或已完成。';
  } else if (activeRecords.length > 0 && observedActiveItems.length > 0 && !exactActiveMatch) {
    status = 'conflict';
    provenance = ['manualActive', 'importedActive'];
    diagnostic = '导入计时与本地手动记录无法按 key、等级、数量和计时证据精确匹配。';
  } else if (activeRecords.length > 0) {
    status = 'manualActive';
    provenance.push('manualActive');
    if (observedActiveItems.length > 0) {
      provenance.push('importedActive');
    }
  } else if (manualItem?.status === 'manualCompleted') {
    status = 'manualCompleted';
    provenance.push('manualCompleted');
    if (observedNeedsReimport) {
      provenance.push('needsReimport');
    }
  } else if (observedNeedsReimport) {
    status = 'needsReimport';
    provenance.push('needsReimport');
  } else if (observedActiveItems.length > 0) {
    status = 'importedActive';
    provenance.push('importedActive');
  } else {
    status = 'observed';
    provenance.push('observed');
  }

  const stageMax = representative?.currentStageMaxLevel ?? null;
  const globalMax = representative?.maxLevel ?? null;
  let effectiveCatalogProjection: {
    readonly nextUpgrade: VillageNextUpgrade;
    readonly catalogLevel: CatalogLevel | null;
  } | null = null;

  if (activeRecords.length === 0 && manualItem?.status === 'manualCompleted') {
    const effectiveLevel =
      effectiveCompleted !== null && effectiveCompleted.levels.length === 1
        ? effectiveCompleted.levels[0]!.level
        : null;
    effectiveCatalogProjection = effectiveCatalogProjectionFor({
      key: input.key,
      currentLevel: effectiveLevel,
      stageMax,
      catalog: input.catalog,
      catalogIsUsable: input.catalogIsUsable,
    });
  }

  const targetLevel = activeRecords[0]?.targetLevel ?? representative?.nextLevel ?? null;
  const catalogLevel =
    effectiveCatalogProjection?.catalogLevel ??
    (targetLevel !== null
      ? (input.catalog
          ?.item(input.key.rawSection, input.key.dataID)
          ?.levels.find((level) => level.level === targetLevel) ?? null)
      : null);

  let catalogDuration: CatalogDurationState | null;
  let catalogCosts: CatalogLevel['upgradeCosts'] | null;
  if (
    status === 'unknown' ||
    status === 'conflict' ||
    status === 'needsReimport' ||
    status === 'unavailable'
  ) {
    catalogDuration = null;
    catalogCosts = null;
  } else {
    catalogDuration =
      (catalogLevel !== null && catalogLevel !== undefined
        ? catalogDurationState(catalogLevel.durationSeconds, catalogLevel.missingReason)
        : null) ??
      representative?.nextLevelDurationState ??
      null;
    catalogCosts = catalogLevel?.upgradeCosts ?? null;
  }

  return {
    itemKey: input.key,
    rawItemID: representative?.id ?? null,
    importedCurrentLevel: uniformValue(orderedObservedItems.map((item) => item.level)),
    importedCount,
    importedInstanceWeight: rawInstanceWeight.total,
    importedCountOverflowed: rawInstanceWeight.overflowed,
    importedCountQuality,
    importedTimerSeconds: uniformValue(orderedObservedItems.map((item) => item.timerSeconds)),
    importedRemainingSeconds:
      observedActiveItems.length === 0
        ? uniformValue(orderedObservedItems.map((item) => item.remainingSeconds))
        : uniformValue(
            observedActiveItems.map(
              (item) =>
                liveRemainingSeconds(item, input.snapshot, input.nowMs) ?? item.remainingSeconds,
            ),
          ),
    importedDistribution: importedDistribution,
    manualCompletedDistribution: manualItem?.manualCompletedDistribution ?? null,
    activeManualRecords: activeRecords,
    activeTargetDistribution: activeTarget,
    effectiveCompletedDistribution: effectiveCompleted,
    status,
    provenance,
    diagnostic,
    catalogDurationState: catalogDuration,
    catalogCosts,
    catalogNextUpgrade: effectiveCatalogProjection?.nextUpgrade ?? null,
    currentStageMaxLevel: stageMax,
    globalMaxLevel: globalMax,
    effectiveCompletedLevel:
      effectiveCompleted !== null && effectiveCompleted.levels.length === 1
        ? effectiveCompleted.levels[0]!.level
        : null,
    activeTargetLevel: activeTarget.levels.length === 1 ? activeTarget.levels[0]!.level : null,
  };
}

function effectiveStateForItem(
  item: VillageItemState,
  keyMap: ReadonlyMap<string, TrackerItemKey>,
  states: ReadonlyMap<string, EffectiveVillageItemState>,
): EffectiveVillageItemState | undefined {
  const importID = item.id.startsWith('agg:') ? item.id.slice(4) : item.id;
  const key = keyMap.get(importID);
  if (key === undefined) {
    return undefined;
  }
  return states.get(trackerItemKeyStableId(key));
}

function attachEffectiveState(
  item: VillageItemState,
  effectiveState: EffectiveVillageItemState | undefined,
): VillageItemState {
  return {
    ...item,
    effectiveState,
  };
}

function makeManualCoverage(
  trackerItems: readonly EffectiveVillageItemState[],
  manualUpgradeCore: ManualUpgradeCore | null,
): ManualTrackerCoverage {
  if (manualUpgradeCore === null) {
    return {
      observedItemCount: trackerItems.length,
      manualItemCount: 0,
      effectiveItemCount: 0,
      activeRecordCount: 0,
      unknownItemCount: 0,
      state: 'unavailable',
      diagnostics: ['未提供本地手动状态。'],
    };
  }

  const supportedItems = trackerItems.filter((item) => item.status !== 'unavailable');
  const trackerKeys = new Set(supportedItems.map((item) => trackerItemKeyStableId(item.itemKey)));
  const unmatched = manualUpgradeCore.itemStates.filter(
    (state) => !trackerKeys.has(trackerItemKeyStableId(state.itemKey)),
  ).length;
  const unknown = supportedItems.filter(
    (item) => item.status === 'unknown' || item.status === 'conflict',
  ).length;
  const effective = supportedItems.filter(
    (item) => item.effectiveCompletedDistribution !== null,
  ).length;
  const diagnostics: string[] = [];
  if (unmatched > 0) {
    diagnostics.push(`有 ${unmatched} 条本地手动状态没有对应的当前快照项目。`);
  }
  if (unknown > 0) {
    diagnostics.push(`有 ${unknown} 个项目的本地有效状态未知或冲突。`);
  }

  let state: ProgressMetricState;
  if (supportedItems.length === 0) {
    state = 'unknown';
  } else if (unmatched > 0 || unknown > 0 || effective < supportedItems.length) {
    state = 'partial';
  } else {
    state = 'ready';
  }

  return {
    observedItemCount: supportedItems.length,
    manualItemCount: manualUpgradeCore.itemStates.length,
    effectiveItemCount: effective,
    activeRecordCount: manualActiveRecords(manualUpgradeCore).length,
    unknownItemCount: unknown,
    state,
    diagnostics,
  };
}

function instanceMetric(input: {
  readonly trackerItems: readonly EffectiveVillageItemState[];
  readonly availableItems: readonly VillageItemState[];
  readonly catalogIsUsable: boolean;
  readonly compatibility: CatalogCompatibility;
  readonly manualCoverage: ManualTrackerCoverage;
}): ProgressMetric {
  if (!input.catalogIsUsable) {
    return unavailableMetric('instanceProgress', '实例');
  }

  let numerator = 0;
  let denominator = 0;
  let unknown = 0;
  let saturated = false;
  for (const item of input.trackerItems) {
    if (item.status === 'unavailable') {
      continue;
    }
    const distribution = trackerDistribution(item);
    const weight = Number(item.importedInstanceWeight);
    saturated = saturated || item.importedCountOverflowed;
    saturated = saturated || addInt(denominator, weight).overflowed;
    denominator = addInt(denominator, weight).value;
    if (
      !effectiveVillageItemIsKnown(item) ||
      distribution === null ||
      manualLevelDistributionIsEmpty(distribution) ||
      item.currentStageMaxLevel === null ||
      item.currentStageMaxLevel <= 0
    ) {
      saturated = saturated || addInt(unknown, weight).overflowed;
      unknown = addInt(unknown, weight).value;
      continue;
    }
    const completed = distribution.levels
      .filter((entry) => entry.level >= item.currentStageMaxLevel!)
      .reduce((total, entry) => total + entry.quantity, 0n);
    const completedNumber = Number(completed);
    saturated = saturated || addInt(numerator, completedNumber).overflowed;
    numerator = addInt(numerator, completedNumber).value;
  }

  for (const item of input.availableItems) {
    const weight = item.count ?? 1;
    saturated = saturated || addInt(denominator, weight).overflowed;
    denominator = addInt(denominator, weight).value;
  }

  const reason = input.manualCoverage.diagnostics.join(' ');
  return makeProgressMetric({
    kind: 'instanceProgress',
    numerator,
    denominator,
    saturated,
    unknownWeight: unknown,
    compatibility: input.compatibility,
    extraReason: reason.length === 0 ? null : reason,
    units: '实例',
  });
}

function effectiveMetric(input: {
  readonly trackerItems: readonly EffectiveVillageItemState[];
  readonly catalogIsUsable: boolean;
  readonly compatibility: CatalogCompatibility;
  readonly manualCoverage: ManualTrackerCoverage;
}): ProgressMetric {
  if (!input.catalogIsUsable) {
    return unavailableMetric('effectiveTrackerProgress', '级');
  }

  let numerator = 0;
  let denominator = 0;
  let unknown = 0;
  let saturated = false;
  for (const item of input.trackerItems) {
    if (item.status === 'unavailable') {
      continue;
    }
    saturated = saturated || item.importedCountOverflowed;
    const weight = Number(item.importedInstanceWeight);
    if (
      !effectiveVillageItemIsKnown(item) ||
      item.globalMaxLevel === null ||
      item.globalMaxLevel <= 0
    ) {
      saturated = saturated || addInt(unknown, weight).overflowed;
      unknown = addInt(unknown, weight).value;
      continue;
    }
    const distribution = trackerDistribution(item);
    if (distribution === null || manualLevelDistributionIsEmpty(distribution)) {
      saturated = saturated || addInt(unknown, weight).overflowed;
      unknown = addInt(unknown, weight).value;
      continue;
    }
    for (const entry of distribution.levels) {
      const denominatorProduct = multiplyInt64(entry.quantity, BigInt(item.globalMaxLevel));
      saturated =
        saturated ||
        denominatorProduct.overflowed ||
        addInt(denominator, denominatorProduct.value).overflowed;
      denominator = addInt(denominator, denominatorProduct.value).value;

      const cappedLevel = Math.min(Math.max(0, entry.level), item.globalMaxLevel);
      const numeratorProduct = multiplyInt64(entry.quantity, BigInt(cappedLevel));
      saturated =
        saturated ||
        numeratorProduct.overflowed ||
        addInt(numerator, numeratorProduct.value).overflowed;
      numerator = addInt(numerator, numeratorProduct.value).value;
    }
  }

  const reason = input.manualCoverage.diagnostics.join(' ');
  return makeProgressMetric({
    kind: 'effectiveTrackerProgress',
    numerator,
    denominator,
    saturated,
    unknownWeight: unknown,
    compatibility: input.compatibility,
    extraReason: reason.length === 0 ? null : reason,
    units: '级',
  });
}

function trackerDistribution(state: EffectiveVillageItemState): ManualLevelDistribution | null {
  if (state.effectiveCompletedDistribution === null) {
    return state.status === 'manualActive' ? state.importedDistribution : null;
  }
  if (state.status !== 'manualActive') {
    return state.effectiveCompletedDistribution;
  }
  let restored = state.effectiveCompletedDistribution;
  for (const record of state.activeManualRecords) {
    const next = manualLevelDistributionAdd(restored, record.fromLevel, record.quantity);
    if (next === undefined) {
      return state.importedDistribution;
    }
    restored = next;
  }
  return restored;
}

function makeProgressMetric(input: {
  readonly kind: ProgressMetric['kind'];
  readonly numerator: number;
  readonly denominator: number;
  readonly saturated: boolean;
  readonly unknownWeight: number;
  readonly compatibility: CatalogCompatibility;
  readonly extraReason: string | null;
  readonly units: string;
}): ProgressMetric {
  const reasons: string[] = [];
  if (input.denominator === 0) {
    reasons.push('无可确认项目，暂无法计算');
  }
  if (input.unknownWeight > 0) {
    reasons.push(`${input.unknownWeight} 个实例未知或无法验证，结果仅为可确认项目。`);
  }
  if (input.extraReason !== null) {
    reasons.push(input.extraReason);
  }
  if (input.compatibility.kind === 'unverified') {
    reasons.push('目录与玩家版本未验证，百分比可能过时。');
  }
  const state: ProgressMetricState =
    input.denominator === 0 ? 'unknown' : reasons.length === 0 ? 'ready' : 'partial';
  const ratio =
    !input.saturated && input.denominator > 0 && (state === 'ready' || state === 'partial')
      ? input.numerator / input.denominator
      : null;
  return {
    kind: input.kind,
    numerator: input.numerator,
    denominator: input.denominator,
    state,
    saturated: input.saturated,
    units: input.units,
    degradedReason: reasons.length === 0 ? null : reasons.join(' '),
    ratio,
  };
}

function unavailableMetric(kind: ProgressMetric['kind'], units: string): ProgressMetric {
  return {
    kind,
    numerator: 0,
    denominator: 0,
    state: 'unavailable',
    saturated: false,
    units,
    degradedReason: '目录不可用或版本不匹配，暂无法计算该指标。',
    ratio: null,
  };
}

function levelDistribution(items: readonly AccountItem[]): ManualLevelDistribution | null {
  if (items.length === 0 || items.some((item) => item.level === null)) {
    return null;
  }
  const quantities = new Map<number, bigint>();
  for (const item of items) {
    const level = item.level!;
    const quantity = BigInt(Math.max(item.count ?? 1, 1));
    const existing = quantities.get(level) ?? 0n;
    const sum = existing + quantity;
    if (sum < existing) {
      return null;
    }
    quantities.set(level, sum);
  }
  return manualLevelDistributionFromQuantities(quantities) ?? null;
}

function countQuality(
  items: readonly AccountItem[],
  rawInstanceWeight: { readonly total: bigint; readonly overflowed: boolean },
): EffectiveVillageCountQuality {
  if (rawInstanceWeight.overflowed) {
    return 'overflowed';
  }
  if (!items.every((item) => item.count !== null && item.count > 0)) {
    return 'malformed';
  }
  return 'known';
}

function computeRawInstanceWeight(items: readonly AccountItem[]): {
  readonly total: bigint;
  readonly overflowed: boolean;
} {
  let total = 0n;
  let overflowed = false;
  for (const item of items) {
    const quantity = BigInt(Math.max(item.count ?? 1, 1));
    const sum = total + quantity;
    if (sum < total) {
      total = BigInt(Number.MAX_SAFE_INTEGER);
      overflowed = true;
    } else {
      total = sum;
    }
  }
  return { total, overflowed };
}

function uniformValue<T>(values: readonly (T | null | undefined)[]): T | null {
  if (values.length === 0) {
    return null;
  }
  const first = values[0] ?? null;
  for (const value of values.slice(1)) {
    if (value !== first) {
      return null;
    }
  }
  return first;
}

function activeCatalogDiagnosticFor(input: {
  readonly records: readonly ManualUpgradeRecord[];
  readonly key: TrackerItemKey;
  readonly representative: VillageItemState | null;
  readonly catalog: GameCatalog | null;
  readonly catalogIsUsable: boolean;
}): string | null {
  if (!input.catalogIsUsable || input.catalog === null) {
    return '当前静态目录不可用于验证本地进行中的手动升级。';
  }
  const manifest = input.catalog.manifest;
  if (manifest === null) {
    return '当前目录缺少 manifest，无法验证本地手动升级来源。';
  }

  switch (input.representative?.availability.kind) {
    case 'permanent':
    case 'seasonal':
      if (
        input.representative.availability.kind === 'seasonal' &&
        input.representative.availability.status !== 'active'
      ) {
        return `当前目录生命周期状态为 ${input.representative.availability.status}，不能把本地进行中升级视为可验证状态。`;
      }
      break;
    case 'unconfigured':
      return '当前目录未配置该项目的生命周期，不能验证本地进行中升级。';
    case 'conflict':
      return '当前目录的项目生命周期存在冲突，不能验证本地进行中升级。';
    case undefined:
      return '当前项目没有可验证的目录生命周期。';
  }

  for (const record of input.records) {
    const provenance = record.catalogProvenance;
    if (provenance.gameVersion !== input.catalog.gameVersion) {
      return '本地手动升级记录的目录版本与当前目录不一致。';
    }
    if (
      provenance.buildTag !== manifest.buildTag ||
      provenance.sourceFingerprint !== manifest.sourceFingerprint ||
      provenance.manifestSchemaVersion !== manifest.schemaVersion
    ) {
      return '本地手动升级记录的目录 manifest 或 source fingerprint 与当前目录不一致。';
    }
    const catalogItem = input.catalog.item(input.key.rawSection, input.key.dataID);
    const level = catalogItem?.levels.find((entry) => entry.level === record.targetLevel);
    const durationState =
      level === undefined ? null : catalogDurationState(level.durationSeconds, level.missingReason);
    if (catalogItem === undefined || durationState === null) {
      return '当前目录缺少本地手动升级目标等级的可信时长。';
    }
    switch (durationState.kind) {
      case 'timed':
        if (record.durationKind !== 'timed' || record.durationSeconds !== durationState.seconds) {
          return '本地手动升级冻结时长与当前目录不一致。';
        }
        break;
      case 'instant':
        if (record.durationKind !== 'instant' || record.durationSeconds !== 0n) {
          return '本地手动升级冻结时长与当前目录的即时升级语义不一致。';
        }
        break;
      default:
        return '当前目录的升级时长状态不可用于本地手动升级。';
    }
  }
  return null;
}

function matchesActiveRecord(input: {
  readonly record: ManualUpgradeRecord;
  readonly item: AccountItem;
  readonly snapshot: AccountSnapshot;
  readonly nowMs: number;
}): boolean {
  const level = input.item.level;
  if (
    level === null ||
    input.record.fromLevel !== level ||
    input.record.targetLevel !== level + 1 ||
    input.record.quantity !== BigInt(Math.max(input.item.count ?? 1, 1)) ||
    input.item.timerSeconds === null
  ) {
    return false;
  }
  const remaining = liveRemainingSeconds(input.item, input.snapshot, input.nowMs);
  if (remaining === null) {
    return false;
  }
  const rawExpectedRemaining = safeFloorSeconds(
    (input.record.expectedEndAtMs - input.nowMs) / 1000,
  );
  if (rawExpectedRemaining === null) {
    return false;
  }
  const expectedRemaining = rawExpectedRemaining < 0n ? 0n : rawExpectedRemaining;
  const delta =
    expectedRemaining > remaining ? expectedRemaining - remaining : remaining - expectedRemaining;
  return delta <= 1n;
}

function hasExactActiveMatch(input: {
  readonly records: readonly ManualUpgradeRecord[];
  readonly observedItems: readonly AccountItem[];
  readonly snapshot: AccountSnapshot;
  readonly nowMs: number;
}): boolean {
  if (
    input.records.length === 0 ||
    input.observedItems.length === 0 ||
    input.records.length > input.observedItems.length
  ) {
    return false;
  }

  const candidates = input.records.map((record) =>
    input.observedItems
      .map((item, index) => ({ item, index }))
      .filter(({ item }) =>
        matchesActiveRecord({
          record,
          item,
          snapshot: input.snapshot,
          nowMs: input.nowMs,
        }),
      )
      .map(({ index }) => index),
  );
  if (candidates.some((indices) => indices.length === 0)) {
    return false;
  }

  const order = candidates
    .map((indices, index) => ({ index, size: indices.length }))
    .sort((left, right) =>
      left.size === right.size ? left.index - right.index : left.size - right.size,
    )
    .map((entry) => entry.index);

  const owner = new Array<number | null>(input.observedItems.length).fill(null);

  function augment(recordIndex: number, visited: Set<number>): boolean {
    for (const itemIndex of candidates[recordIndex]!) {
      if (visited.has(itemIndex)) {
        continue;
      }
      visited.add(itemIndex);
      const previousRecord = owner[itemIndex];
      if (previousRecord != null) {
        if (augment(previousRecord, visited)) {
          owner[itemIndex] = recordIndex;
          return true;
        }
      } else {
        owner[itemIndex] = recordIndex;
        return true;
      }
    }
    return false;
  }

  for (const recordIndex of order) {
    if (!augment(recordIndex, new Set())) {
      return false;
    }
  }
  return true;
}

function effectiveCatalogProjectionFor(input: {
  readonly key: TrackerItemKey;
  readonly currentLevel: number | null;
  readonly stageMax: number | null;
  readonly catalog: GameCatalog | null;
  readonly catalogIsUsable: boolean;
}): {
  readonly nextUpgrade: VillageNextUpgrade;
  readonly catalogLevel: CatalogLevel | null;
} | null {
  const catalogItem = input.catalog?.item(input.key.rawSection, input.key.dataID);
  if (catalogItem === undefined) {
    return null;
  }
  if (!input.catalogIsUsable) {
    return { nextUpgrade: { kind: 'unknown' }, catalogLevel: null };
  }
  if (input.currentLevel === null || input.currentLevel < 0) {
    return { nextUpgrade: { kind: 'unknown' }, catalogLevel: null };
  }
  if (input.stageMax === null || input.stageMax <= 0) {
    return { nextUpgrade: { kind: 'unverified' }, catalogLevel: null };
  }
  if (input.currentLevel >= catalogItem.maxLevel) {
    return { nextUpgrade: { kind: 'globalMaxed' }, catalogLevel: null };
  }

  const threshold = input.currentLevel >= input.stageMax ? input.stageMax : input.currentLevel;
  const realNext = catalogItem.levels
    .slice()
    .sort((left, right) => left.level - right.level)
    .find((level) => level.level > threshold);
  if (realNext === undefined) {
    return { nextUpgrade: { kind: 'globalMaxed' }, catalogLevel: null };
  }
  if (realNext.level <= input.currentLevel) {
    return { nextUpgrade: { kind: 'unknown' }, catalogLevel: null };
  }
  if (input.currentLevel >= input.stageMax) {
    const requirements = catalogLevelRequirements(realNext, catalogItem.base);
    if (requirements.length === 0) {
      return { nextUpgrade: { kind: 'globalMaxed' }, catalogLevel: null };
    }
    return {
      nextUpgrade: {
        kind: 'requires',
        nextLevel: realNext.level,
        requirements,
        referenceDurationSeconds: realNext.durationSeconds,
      },
      catalogLevel: realNext,
    };
  }
  return {
    nextUpgrade: {
      kind: 'available',
      level: realNext.level,
      durationSeconds: realNext.durationSeconds,
    },
    catalogLevel: realNext,
  };
}

function trackerItemKeyMap(
  snapshot: AccountSnapshot,
  base: TrackerBase,
): Map<string, TrackerItemKey> {
  const result = new Map<string, TrackerItemKey>();

  function visit(
    item: AccountItem,
    section: string,
    root: TrackerRootIdentity | null,
    path: readonly TrackerNestedPathComponent[],
  ): void {
    let key: TrackerItemKey;
    let childRoot: TrackerRootIdentity;
    if (root !== null) {
      key = {
        base,
        rawSection: section,
        dataID: item.dataID,
        nestedKind: path[path.length - 1]?.kind ?? 'root',
        nestedRootIdentity: root,
        nestedPath: path,
      };
      childRoot = root;
    } else {
      const rootIdentity: TrackerRootIdentity = { base, rawSection: section, dataID: item.dataID };
      key = trackerItemKeyRoot(base, section, item.dataID);
      childRoot = rootIdentity;
    }
    result.set(item.id, key);
    for (const child of item.types) {
      visit(child, section, childRoot, [...path, { kind: 'type', dataID: child.dataID }]);
    }
    for (const child of item.modules) {
      visit(child, section, childRoot, [...path, { kind: 'module', dataID: child.dataID }]);
    }
  }

  for (const section of Object.keys(snapshot.objectSections).sort()) {
    const isBuilderSection = section.endsWith('2');
    if (isBuilderSection !== (base === 'builder')) {
      continue;
    }
    for (const item of snapshot.objectSections[section] ?? []) {
      visit(item, section, null, []);
    }
  }
  return result;
}

function flattenSnapshotItems(snapshot: AccountSnapshot, base: TrackerBase): AccountItem[] {
  const items: AccountItem[] = [];
  for (const section of Object.keys(snapshot.objectSections).sort()) {
    const isBuilderSection = section.endsWith('2');
    if (isBuilderSection !== (base === 'builder')) {
      continue;
    }
    for (const item of snapshot.objectSections[section] ?? []) {
      flattenItem(item, items);
    }
  }
  return items;
}

function flattenItem(item: AccountItem, out: AccountItem[]): void {
  out.push(item);
  for (const child of item.types) {
    flattenItem(child, out);
  }
  for (const child of item.modules) {
    flattenItem(child, out);
  }
}

function safeFloorSeconds(intervalSeconds: number): bigint | null {
  if (!Number.isFinite(intervalSeconds)) {
    return null;
  }
  const floored = Math.floor(intervalSeconds);
  if (floored < Number.MIN_SAFE_INTEGER || floored >= Number.MAX_SAFE_INTEGER) {
    return null;
  }
  return BigInt(floored);
}

function addInt(
  target: number,
  value: number,
): { readonly value: number; readonly overflowed: boolean } {
  const converted = value > Number.MAX_SAFE_INTEGER ? Number.MAX_SAFE_INTEGER : Math.max(0, value);
  const next = target + converted;
  if (!Number.isFinite(next) || next > Number.MAX_SAFE_INTEGER) {
    return { value: Number.MAX_SAFE_INTEGER, overflowed: true };
  }
  return { value: next, overflowed: false };
}

function multiplyInt64(
  lhs: bigint,
  rhs: bigint,
): { readonly value: number; readonly overflowed: boolean } {
  const product = lhs * rhs;
  if (product > BigInt(Number.MAX_SAFE_INTEGER)) {
    return { value: Number.MAX_SAFE_INTEGER, overflowed: true };
  }
  return { value: Number(product), overflowed: false };
}
