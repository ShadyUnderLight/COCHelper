import { generateUuid } from '@coc-helper/wire';

import type { AccountDataDiagnostic, AccountItem, AccountSnapshot } from '../account';
import type { CraftTableCatalog } from '../catalog/craft-table';
import { catalogDurationState, type CatalogDurationState } from '../catalog/duration-state';
import {
  catalogCompatibilityIsUsable,
  resolveCatalogCompatibility,
  type GameCatalog,
} from '../catalog/game-catalog';
import {
  EMPTY_SEASONAL_PHASE_TABLE,
  type CatalogAvailability,
  type SeasonalPhaseTable,
} from '../catalog/seasonal-phase';
import type { CatalogCompatibility, CatalogItem, CatalogLevel } from '../catalog/types';
import { UNIVERSE_TOWN_HALL_COUNT } from '../catalog/types';
import type { ManualUpgradeCore } from '../manual/types';
import { flattenAccountItems } from './account-items';
import { resolveDisplayCategory, rootIdOfItemId } from './display-category';
import {
  buildEffectiveVillageProjection,
  effectiveVillageItemWithImportedRemainingSeconds,
  type EffectiveVillageItemState,
  type ManualTrackerCoverage,
} from './effective-projection';
import {
  playerUnlockLevelsFromSnapshot,
  type PlayerUnlockLevels,
} from './player-unlock-levels';
import { villageProgressMetrics } from './progress-metrics';
import type { TrackerBase, TrackerCategory } from './tracker';
import { trackerCategoryFromSection } from './tracker';
import {
  catalogItemRequirements,
  catalogLevelRequirements,
  type UpgradeRequirement,
} from './upgrade-requirement';
import type { VillageProfile } from '../import/types';
import {
  instanceWeight,
  isUpgrading,
  progressUniverseCoverageIsComplete,
  type ProgressUniverseCoverage,
  type VillageCatalogProjection,
  type VillageItemState,
  type VillageNextUpgrade,
} from './types';

const PROGRESS_SECTIONS = new Set([
  'buildings',
  'traps',
  'units',
  'spells',
  'siege_machines',
  'heroes',
  'equipment',
  'pets',
  'guardians',
]);

const ALL_TRACKER_CATEGORIES: readonly TrackerCategory[] = [
  'buildings',
  'traps',
  'troops',
  'spells',
  'siegeMachines',
  'heroes',
  'equipment',
  'pets',
  'guardians',
];

const INT_MAX = Number.MAX_SAFE_INTEGER;

export type ProjectVillageCatalogInput = {
  readonly village: VillageProfile;
  readonly catalog: GameCatalog | null | undefined;
  readonly expectedGameVersion?: string | null;
  readonly seasonalPhases?: SeasonalPhaseTable;
  readonly craftTableCatalog?: CraftTableCatalog | null;
  readonly base: TrackerBase;
  readonly nowMs: number;
  readonly manualUpgradeCore?: ManualUpgradeCore | null;
};

export type RefreshingTimersInput = {
  readonly nowMs: number;
  readonly builtAtMs: number;
  readonly importedAtMs: number;
};

export function projectVillageCatalog(input: ProjectVillageCatalogInput): VillageCatalogProjection {
  const {
    village,
    catalog,
    expectedGameVersion,
    seasonalPhases = EMPTY_SEASONAL_PHASE_TABLE,
    craftTableCatalog,
    base,
    nowMs,
    manualUpgradeCore,
  } = input;

  const diagnostics: AccountDataDiagnostic[] = [];
  const compatibility = resolveCatalogCompatibility(catalog, expectedGameVersion);
  const catalogIsUsable = catalogCompatibilityIsUsable(compatibility);

  switch (compatibility.kind) {
    case 'unavailable':
      diagnostics.push(
        makeDiagnostic(
          'warning',
          `GameCatalog/${base}`,
          '静态升级目录不可用，等级上限与完整时长信息将缺失。',
        ),
      );
      break;
    case 'unverified':
      diagnostics.push(
        makeDiagnostic(
          'info',
          `GameCatalog/${base}`,
          `静态目录版本 ${compatibility.gameVersion}；与玩家版本未验证。`,
        ),
      );
      break;
    case 'mismatch':
      diagnostics.push(
        makeDiagnostic(
          'warning',
          `GameCatalog/${base}`,
          `静态目录版本 ${compatibility.catalogVersion} 与期望版本 ${compatibility.expectedVersion} 不匹配，完整时长与上限信息可能过时。`,
        ),
      );
      break;
    case 'verified':
      break;
  }

  const unlocks = playerUnlockLevelsFromSnapshot(village.accountSnapshot, manualUpgradeCore ?? null);
  const buildingUniverseAvailable =
    base === 'home' &&
    catalogIsUsable &&
    catalog?.hasUniverseData === true &&
    unlocks.townHall !== null &&
    unlocks.townHall >= 1 &&
    unlocks.townHall <= UNIVERSE_TOWN_HALL_COUNT;

  const progressCoverage = computeProgressCoverage(
    buildingUniverseAvailable,
    village.accountSnapshot ?? null,
    catalog,
  );

  const importedRecords =
    village.accountSnapshot === null || village.accountSnapshot === undefined
      ? []
      : recordsFromSnapshot({
          snapshot: village.accountSnapshot,
          catalog: catalog ?? null,
          base,
          nowMs,
          unlocks,
          catalogIsUsable,
          seasonalPhases,
          craftTableCatalog: craftTableCatalog ?? null,
        });

  const aggregated =
    village.accountSnapshot === null || village.accountSnapshot === undefined
      ? []
      : aggregateVillageItems(importedRecords).concat(
          buildingUniverseAvailable
            ? universeSupplement({
                snapshot: village.accountSnapshot,
                catalog: catalog ?? null,
                unlocks,
                base,
              })
            : [],
        );

  if (manualUpgradeCore !== null && manualUpgradeCore !== undefined) {
    const effective = buildEffectiveVillageProjection({
      snapshot: village.accountSnapshot ?? null,
      rawItems: importedRecords,
      items: aggregated,
      catalog: catalog ?? null,
      catalogIsUsable,
      compatibility,
      base,
      nowMs,
      manualUpgradeCore,
      progressCoverage,
    });

    return {
      villageID: village.id,
      villageName: village.name,
      base,
      catalogVersion: catalog?.gameVersion ?? null,
      catalogIsUsable,
      compatibility,
      items: effective.items,
      rawItems: effective.rawItems,
      effectiveTrackerItems: effective.trackerItems,
      manualCoverage: effective.manualCoverage,
      progressMetrics: effective.progressMetrics,
      diagnostics,
      progressCoverage,
    };
  }

  const manualCoverage = stubManualCoverage(importedRecords.length);
  const progressMetrics = villageProgressMetrics({
    items: aggregated,
    catalogIsUsable,
    compatibility,
    coverage: progressCoverage,
  });

  return {
    villageID: village.id,
    villageName: village.name,
    base,
    catalogVersion: catalog?.gameVersion ?? null,
    catalogIsUsable,
    compatibility,
    items: aggregated,
    rawItems: importedRecords,
    effectiveTrackerItems: [],
    manualCoverage,
    progressMetrics,
    diagnostics,
    progressCoverage,
  };
}

export function liveRemainingSeconds(
  item: AccountItem,
  snapshot: AccountSnapshot,
  nowMs: number,
): bigint | null {
  if (item.remainingSeconds === null) {
    return null;
  }
  const elapsed = safeFloorInt64(nowMs - snapshot.importedAtMs);
  if (elapsed === null) {
    return null;
  }
  const remaining = item.remainingSeconds - elapsed;
  return remaining > 0n ? remaining : 0n;
}

export function refreshTimerDelta(
  nowMs: number,
  builtAtMs: number,
  importedAtMs: number,
): bigint {
  const elapsedNow = safeFloorInt64(nowMs - importedAtMs);
  const elapsedAtBuilt = safeFloorInt64(builtAtMs - importedAtMs);
  if (elapsedNow === null || elapsedAtBuilt === null) {
    return 0n;
  }
  const delta = elapsedNow - elapsedAtBuilt;
  return delta > 0n ? delta : 0n;
}

export function currentStageMaxLevel(
  catalogItem: CatalogItem,
  unlocks: PlayerUnlockLevels,
): number | null {
  const itemRequirements = catalogItemRequirements(catalogItem);
  if (itemRequirements.length === 0) {
    return catalogItem.maxLevel;
  }

  for (const requirement of itemRequirements) {
    if (playerUnlockLevelForRequirement(unlocks, requirement) === null) {
      return null;
    }
  }

  let highest: number | null = null;
  const sortedLevels = [...catalogItem.levels].sort((left, right) => left.level - right.level);
  for (const level of sortedLevels) {
    const satisfied = catalogLevelRequirements(level, catalogItem.base).every((requirement) => {
      const unlock = playerUnlockLevelForRequirement(unlocks, requirement);
      return unlock !== null && unlock >= requirement.level;
    });
    if (!satisfied) {
      break;
    }
    highest = level.level;
  }
  return highest;
}

export function aggregateVillageItems(records: readonly VillageItemState[]): VillageItemState[] {
  const result: VillageItemState[] = [];
  const upgradingKeys = new Set<string>();
  const grouped = new Map<string, VillageItemState[]>();

  for (const record of records) {
    if (!isUpgrading(record)) {
      continue;
    }
    result.push(record);
    upgradingKeys.add(aggregateKey(record));
  }

  for (const record of records) {
    if (isUpgrading(record)) {
      continue;
    }
    const key = aggregateKey(record);
    const groupKey = upgradingKeys.has(key) ? `${key}|idle` : key;
    const group = grouped.get(groupKey) ?? [];
    group.push(record);
    grouped.set(groupKey, group);
  }

  for (const key of [...grouped.keys()].sort()) {
    const group = grouped.get(key);
    if (group === undefined || group.length === 0) {
      continue;
    }
    const first = group[0]!;
    let aggregatedCount = 0;
    let countOverflowed = false;
    for (const record of group) {
      const next = saturatingIntAdd(aggregatedCount, instanceWeight(record));
      aggregatedCount = next.sum;
      countOverflowed = countOverflowed || next.overflowed;
    }

    const groupHasFinishedTimer = group.some(
      (record) => record.timerSeconds !== null && record.remainingSeconds === 0n,
    );
    const representativeTimer = group
      .filter((record) => record.timerSeconds !== null && record.remainingSeconds === 0n)
      .map((record) => record.timerSeconds)
      .filter((value): value is bigint => value !== null)
      .reduce<bigint | null>(
        (min, value) => (min === null || value < min ? value : min),
        null,
      );

    result.push({
      id: `agg:${first.id}`,
      section: first.section,
      dataID: first.dataID,
      base: first.base,
      name: first.name,
      category: first.category,
      currentLevel: first.currentLevel,
      count: aggregatedCount,
      timerSeconds: groupHasFinishedTimer ? representativeTimer : null,
      remainingSeconds: groupHasFinishedTimer ? 0n : null,
      nextLevel: null,
      nextLevelDurationSeconds: first.nextLevelDurationSeconds,
      nextLevelDurationState: first.nextLevelDurationState,
      maxLevel: first.maxLevel,
      currentStageMaxLevel: first.currentStageMaxLevel,
      nextUpgrade: first.nextUpgrade,
      status: first.status,
      missingReason: first.missingReason,
      catalogItemMissingReason: first.catalogItemMissingReason,
      availability: first.availability,
      icon: first.icon,
      levelVisual: first.levelVisual,
      currentLevelIcon: first.currentLevelIcon,
      currentLevelVisual: first.currentLevelVisual,
      isNested: first.isNested,
      displayCategory: first.displayCategory,
      countOverflowed,
      effectiveState: first.effectiveState,
    });
  }

  return result;
}

export function universeSupplement(input: {
  readonly snapshot: AccountSnapshot;
  readonly catalog: GameCatalog | null;
  readonly unlocks: PlayerUnlockLevels;
  readonly base: TrackerBase;
}): VillageItemState[] {
  const { snapshot, catalog, unlocks, base } = input;
  if (base !== 'home' || unlocks.townHall === null || catalog === null || !catalog.hasUniverseData) {
    return [];
  }

  const observedWeights = new Map<string, number>();
  for (const section of Object.keys(snapshot.objectSections)) {
    if (section.endsWith('2')) {
      continue;
    }
    for (const record of snapshot.objectSections[section] ?? []) {
      const key = `${section}:${record.dataID.toString()}`;
      const weight = Math.max(record.count ?? 1, 1);
      const current = observedWeights.get(key) ?? 0;
      const next = saturatingIntAdd(current, weight);
      observedWeights.set(key, next.sum);
    }
  }

  const townHallLevel = unlocks.townHall;
  const result: VillageItemState[] = [];

  for (const key of catalog.universeKeys()) {
    if (key.section.endsWith('2')) {
      continue;
    }
    const universeCount = catalog.universeCount(key.section, key.dataID, townHallLevel);
    if (universeCount === undefined || universeCount <= 0) {
      continue;
    }

    const itemKey = `${key.section}:${key.dataID.toString()}`;
    const observed = observedWeights.get(itemKey) ?? 0;
    const diffCount = universeCount - observed;
    if (diffCount === 0) {
      continue;
    }

    const catalogItem = catalog.item(key.section, key.dataID);
    if (catalogItem === undefined) {
      continue;
    }

    const category = trackerCategoryFromSection(key.section) ?? null;
    const displayCategory = resolveDisplayCategory({
      section: key.section,
      dataID: key.dataID,
      base: 'home',
      rootParentDataID: null,
      catalog,
    });
    const stageMax = currentStageMaxLevel(catalogItem, unlocks);

    if (diffCount > 0) {
      result.push({
        id: `universe:${itemKey}`,
        section: key.section,
        dataID: key.dataID,
        base: 'home',
        name: catalogItem.name,
        category,
        currentLevel: 0,
        count: diffCount,
        timerSeconds: null,
        remainingSeconds: null,
        nextLevel: null,
        nextLevelDurationSeconds: null,
        nextLevelDurationState: null,
        maxLevel: catalogItem.maxLevel,
        currentStageMaxLevel: stageMax,
        nextUpgrade: null,
        status: 'available',
        missingReason: null,
        catalogItemMissingReason: catalogItem.missingReason,
        availability: { kind: 'unconfigured' },
        icon: catalogItem.icon,
        levelVisual: catalogItem.levelVisual,
        currentLevelIcon: null,
        currentLevelVisual: null,
        isNested: false,
        displayCategory: displayCategory ?? null,
      });
      continue;
    }

    result.push({
      id: `universe:${itemKey}`,
      section: key.section,
      dataID: key.dataID,
      base: 'home',
      name: catalogItem.name,
      category,
      currentLevel: null,
      count: -diffCount,
      timerSeconds: null,
      remainingSeconds: null,
      nextLevel: null,
      nextLevelDurationSeconds: null,
      nextLevelDurationState: null,
      maxLevel: catalogItem.maxLevel,
      currentStageMaxLevel: stageMax,
      nextUpgrade: null,
      status: 'unknown',
      missingReason: '观测实例数超过宇宙上限（数据异常，可能为已拆除建筑或目录过时）。',
      catalogItemMissingReason: catalogItem.missingReason,
      availability: { kind: 'unconfigured' },
      icon: catalogItem.icon,
      levelVisual: catalogItem.levelVisual,
      currentLevelIcon: null,
      currentLevelVisual: null,
      isNested: false,
      displayCategory: displayCategory ?? null,
    });
  }

  return result;
}

export function refreshingTimers(
  projection: VillageCatalogProjection,
  input: RefreshingTimersInput,
): { readonly projection: VillageCatalogProjection; readonly expired: boolean } {
  const delta = refreshTimerDelta(input.nowMs, input.builtAtMs, input.importedAtMs);
  let expired = false;

  const refreshItem = (item: VillageItemState): VillageItemState => {
    if (item.remainingSeconds === null || item.remainingSeconds <= 0n) {
      return item;
    }
    const newRemaining = item.remainingSeconds - delta;
    const clamped = newRemaining > 0n ? newRemaining : 0n;
    if (clamped === 0n) {
      expired = true;
    }
    return withRemainingSeconds(item, clamped);
  };

  const refreshedEffective = projection.effectiveTrackerItems.map((state) => {
    const effective = state as EffectiveVillageItemState;
    if (effective.importedRemainingSeconds === null || effective.importedRemainingSeconds <= 0n) {
      return effective;
    }
    const newRemaining = effective.importedRemainingSeconds - delta;
    const clamped = newRemaining > 0n ? newRemaining : 0n;
    if (clamped === 0n) {
      expired = true;
    }
    return effectiveVillageItemWithImportedRemainingSeconds(effective, clamped);
  });

  return {
    projection: {
      ...projection,
      items: projection.items.map(refreshItem),
      rawItems: projection.rawItems.map(refreshItem),
      effectiveTrackerItems: refreshedEffective,
    },
    expired,
  };
}

function recordsFromSnapshot(input: {
  readonly snapshot: AccountSnapshot;
  readonly catalog: GameCatalog | null;
  readonly base: TrackerBase;
  readonly nowMs: number;
  readonly unlocks: PlayerUnlockLevels;
  readonly catalogIsUsable: boolean;
  readonly seasonalPhases: SeasonalPhaseTable;
  readonly craftTableCatalog: CraftTableCatalog | null;
}): VillageItemState[] {
  const rootParentDataIDs = new Map<string, bigint>();
  for (const item of flattenAccountItems(input.snapshot)) {
    if (!isNestedItem(item)) {
      rootParentDataIDs.set(rootIdOfItemId(item.id), item.dataID);
    }
  }

  return flattenAccountItems(input.snapshot)
    .map((item) =>
      mapItem({
        item,
        catalog: input.catalog,
        base: input.base,
        nowMs: input.nowMs,
        rootParentDataIDs,
        unlocks: input.unlocks,
        catalogIsUsable: input.catalogIsUsable,
        seasonalPhases: input.seasonalPhases,
        craftTableCatalog: input.craftTableCatalog,
        snapshot: input.snapshot,
      }),
    )
    .filter((item): item is VillageItemState => item !== null);
}

function mapItem(input: {
  readonly item: AccountItem;
  readonly snapshot: AccountSnapshot;
  readonly catalog: GameCatalog | null;
  readonly base: TrackerBase;
  readonly nowMs: number;
  readonly rootParentDataIDs: ReadonlyMap<string, bigint>;
  readonly unlocks: PlayerUnlockLevels;
  readonly catalogIsUsable: boolean;
  readonly seasonalPhases: SeasonalPhaseTable;
  readonly craftTableCatalog: CraftTableCatalog | null;
}): VillageItemState | null {
  const {
    item,
    snapshot,
    catalog,
    base,
    nowMs,
    rootParentDataIDs,
    unlocks,
    catalogIsUsable,
    seasonalPhases,
    craftTableCatalog,
  } = input;

  const isBuilderSection = item.section.endsWith('2');
  if (isBuilderSection !== (base === 'builder')) {
    return null;
  }

  const nested = isNestedItem(item);
  const itemKey = `${item.section}:${item.dataID.toString()}`;
  const catalogItem = nested ? undefined : catalog?.item(item.section, item.dataID);

  let lifecycle: 'permanent' | 'seasonalCandidate' | null | undefined;
  if (catalogItem !== undefined) {
    lifecycle = catalogItem.lifecycle;
  } else if (nested) {
    lifecycle = craftTableCatalog?.defense(item.dataID)?.lifecycle ?? null;
  } else {
    lifecycle = null;
  }

  const availability = seasonalPhases.availability(itemKey, lifecycle, nowMs);
  const remainingSeconds = liveRemainingSeconds(item, snapshot, nowMs);
  const upgrading = (remainingSeconds ?? 0n) > 0n;
  const category = trackerCategoryFromSection(item.section) ?? null;
  const displayCategory = resolveDisplayCategory({
    section: item.section,
    dataID: item.dataID,
    base,
    rootParentDataID: nested ? (rootParentDataIDs.get(rootIdOfItemId(item.id)) ?? null) : null,
    catalog,
  });

  if (category === null) {
    return makeVillageItemState({
      id: item.id,
      section: item.section,
      dataID: item.dataID,
      base,
      name: accountItemNameLabel(item),
      category: null,
      currentLevel: item.level,
      count: item.count,
      timerSeconds: item.timerSeconds,
      remainingSeconds,
      nextLevel: null,
      nextLevelDurationSeconds: null,
      nextLevelDurationState: null,
      maxLevel: null,
      currentStageMaxLevel: null,
      nextUpgrade: null,
      status: 'unavailable',
      missingReason: `该类别不参与升级追踪（${item.section}）。`,
      catalogItemMissingReason: null,
      availability,
      icon: null,
      levelVisual: null,
      currentLevelIcon: null,
      currentLevelVisual: null,
      isNested: nested,
      displayCategory: displayCategory ?? null,
    });
  }

  const baseMatches =
    catalogItem !== undefined ? catalogBaseMatches(catalogItem, base) : false;

  const nextLevel =
    upgrading && item.level !== null && item.level !== undefined ? item.level + 1 : null;

  const stageMax =
    baseMatches && catalogItem !== undefined && catalogIsUsable
      ? currentStageMaxLevel(catalogItem, unlocks)
      : null;

  const realNext = resolveRealNextLevel({
    baseMatches,
    catalogItem,
    currentLevel: item.level,
    stageMax,
  });

  const durationProjection = resolveNextLevelDuration({
    baseMatches,
    catalog,
    catalogItem,
    catalogIsUsable,
    stageMax,
    upgrading,
    nextLevel,
    currentLevel: item.level,
    realNext,
  });

  const nextUpgrade = resolveNextUpgrade({
    baseMatches,
    catalog,
    catalogItem,
    catalogIsUsable,
    stageMax,
    upgrading,
    currentLevel: item.level,
    realNext,
  });

  const { status, missingReason } = resolveStatusAndMissingReason({
    upgrading,
    nested,
    baseMatches,
    catalogItem,
    catalog,
    catalogIsUsable,
    stageMax,
    item,
  });

  const currentLevelAssets = resolveCurrentLevelAssets({
    baseMatches,
    catalogItem,
    currentLevel: item.level,
  });

  return makeVillageItemState({
    id: item.id,
    section: item.section,
    dataID: item.dataID,
    base,
    name: catalogItem?.name ?? accountItemNameLabel(item),
    category,
    currentLevel: item.level,
    count: item.count,
    timerSeconds: item.timerSeconds,
    remainingSeconds,
    nextLevel,
    nextLevelDurationSeconds: durationProjection.seconds,
    nextLevelDurationState: durationProjection.state,
    maxLevel: baseMatches ? (catalogItem?.maxLevel ?? null) : null,
    currentStageMaxLevel: stageMax,
    nextUpgrade,
    status,
    missingReason,
    catalogItemMissingReason: baseMatches ? (catalogItem?.missingReason ?? null) : null,
    availability,
    icon: baseMatches ? (catalogItem?.icon ?? null) : null,
    levelVisual: baseMatches ? (catalogItem?.levelVisual ?? null) : null,
    currentLevelIcon: currentLevelAssets.icon,
    currentLevelVisual: currentLevelAssets.visual,
    isNested: nested,
    displayCategory: displayCategory ?? null,
  });
}

function resolveRealNextLevel(input: {
  readonly baseMatches: boolean;
  readonly catalogItem: CatalogItem | undefined;
  readonly currentLevel: number | null;
  readonly stageMax: number | null;
}): CatalogLevel | undefined {
  const { baseMatches, catalogItem, currentLevel, stageMax } = input;
  if (!baseMatches || catalogItem === undefined || currentLevel === null || currentLevel === undefined) {
    return undefined;
  }
  if (currentLevel >= catalogItem.maxLevel) {
    return undefined;
  }

  const threshold =
    stageMax !== null && currentLevel >= stageMax ? stageMax : currentLevel;
  return [...catalogItem.levels]
    .sort((left, right) => left.level - right.level)
    .find((level) => level.level > threshold);
}

function resolveNextLevelDuration(input: {
  readonly baseMatches: boolean;
  readonly catalog: GameCatalog | null;
  readonly catalogItem: CatalogItem | undefined;
  readonly catalogIsUsable: boolean;
  readonly stageMax: number | null;
  readonly upgrading: boolean;
  readonly nextLevel: number | null;
  readonly currentLevel: number | null;
  readonly realNext: CatalogLevel | undefined;
}): { readonly seconds: bigint | null; readonly state: CatalogDurationState | null } {
  const {
    baseMatches,
    catalog,
    catalogItem,
    catalogIsUsable,
    stageMax,
    upgrading,
    nextLevel,
    currentLevel,
    realNext,
  } = input;

  if (!baseMatches || catalogItem === undefined || !catalogIsUsable || (stageMax === null && !upgrading)) {
    return { seconds: null, state: null };
  }

  if (nextLevel !== null) {
    const target = catalog?.catalogLevel(nextLevel, catalogItem);
    return {
      seconds: target?.durationSeconds ?? null,
      state: target ? catalogDurationState(target.durationSeconds, target.missingReason) : null,
    };
  }

  const effectiveMax = stageMax ?? catalogItem.maxLevel;
  if (currentLevel !== null && currentLevel !== undefined && currentLevel < effectiveMax) {
    const target = realNext ? catalog?.catalogLevel(realNext.level, catalogItem) : undefined;
    return {
      seconds: target?.durationSeconds ?? null,
      state: target ? catalogDurationState(target.durationSeconds, target.missingReason) : null,
    };
  }

  return { seconds: null, state: null };
}

function resolveNextUpgrade(input: {
  readonly baseMatches: boolean;
  readonly catalog: GameCatalog | null;
  readonly catalogItem: CatalogItem | undefined;
  readonly catalogIsUsable: boolean;
  readonly stageMax: number | null;
  readonly upgrading: boolean;
  readonly currentLevel: number | null;
  readonly realNext: CatalogLevel | undefined;
}): VillageNextUpgrade | null {
  const {
    baseMatches,
    catalog,
    catalogItem,
    catalogIsUsable,
    stageMax,
    upgrading,
    currentLevel,
    realNext,
  } = input;

  if (!baseMatches || catalogItem === undefined) {
    return null;
  }

  if (upgrading) {
    if (currentLevel === null || currentLevel === undefined) {
      return { kind: 'unknown' };
    }
    const factLevel = currentLevel + 1;
    const duration = catalogIsUsable
      ? (catalog?.durationToUpgradeLevel(factLevel, catalogItem) ?? null)
      : null;
    return { kind: 'inProgressFact', level: factLevel, durationSeconds: duration };
  }

  if (!catalogIsUsable) {
    return { kind: 'unknown' };
  }

  if (stageMax !== null) {
    const levelValue = currentLevel ?? -1;
    if (levelValue >= catalogItem.maxLevel) {
      return { kind: 'globalMaxed' };
    }
    if (levelValue >= stageMax) {
      if (realNext === undefined) {
        return { kind: 'globalMaxed' };
      }
      if (currentLevel !== null && currentLevel !== undefined && realNext.level <= currentLevel) {
        return { kind: 'unknown' };
      }
      const requirements = catalogLevelRequirements(realNext, catalogItem.base);
      if (requirements.length === 0) {
        return { kind: 'globalMaxed' };
      }
      return {
        kind: 'requires',
        nextLevel: realNext.level,
        requirements,
        referenceDurationSeconds:
          catalog?.durationToUpgradeLevel(realNext.level, catalogItem) ?? null,
      };
    }
    if (realNext !== undefined) {
      return {
        kind: 'available',
        level: realNext.level,
        durationSeconds: catalog?.durationToUpgradeLevel(realNext.level, catalogItem) ?? null,
      };
    }
    return { kind: 'unknown' };
  }

  return { kind: 'unverified' };
}

function resolveStatusAndMissingReason(input: {
  readonly upgrading: boolean;
  readonly nested: boolean;
  readonly baseMatches: boolean;
  readonly catalogItem: CatalogItem | undefined;
  readonly catalog: GameCatalog | null;
  readonly catalogIsUsable: boolean;
  readonly stageMax: number | null;
  readonly item: AccountItem;
}): { readonly status: VillageItemState['status']; readonly missingReason: string | null } {
  const { upgrading, nested, baseMatches, catalogItem, catalog, catalogIsUsable, stageMax, item } =
    input;

  if (upgrading) {
    if (nested) {
      return {
        status: 'upgrading',
        missingReason: `嵌套模块/类型不参与静态目录 join（${item.section}:${item.dataID.toString()}）。`,
      };
    }
    if (baseMatches && catalogItem !== undefined && !catalogIsUsable) {
      return {
        status: 'upgrading',
        missingReason: `目录版本不匹配（${catalog?.gameVersion ?? '?'} vs 期望版本），旧目录等级/时长不可信。`,
      };
    }
    return {
      status: 'upgrading',
      missingReason: missingReasonForStatus({
        baseMatches,
        catalogItem,
        catalogAvailable: catalog !== null,
        item,
      }),
    };
  }

  if (nested) {
    return {
      status: 'unknown',
      missingReason: `嵌套模块/类型不参与静态目录 join（${item.section}:${item.dataID.toString()}）。`,
    };
  }

  if (baseMatches && catalogItem !== undefined && !catalogIsUsable) {
    return {
      status: 'unknown',
      missingReason:
        catalog === null
          ? '静态目录不可用。'
          : `目录版本不匹配（${catalog.gameVersion} vs 期望版本），满级状态不可信。`,
    };
  }

  if (catalogItem !== undefined && baseMatches) {
    if (stageMax === null) {
      return {
        status: 'unverified',
        missingReason:
          '快照缺少 prerequisite 解锁建筑记录（或等级不足：大本营/实验室/英雄殿堂/铁匠铺等），无法验证当前阶段上限。',
      };
    }
    const effectiveMax = stageMax ?? catalogItem.maxLevel;
    if ((item.level ?? -1) >= effectiveMax) {
      return { status: 'maxed', missingReason: null };
    }
    return { status: 'complete', missingReason: null };
  }

  if (catalogItem !== undefined) {
    return {
      status: 'unknown',
      missingReason: `目录物品与投影基地不匹配（${item.section}:${item.dataID.toString()}）。`,
    };
  }

  if (catalog === null) {
    return { status: 'unknown', missingReason: '静态目录不可用。' };
  }

  return {
    status: 'unknown',
    missingReason: `目录未收录（${item.section}:${item.dataID.toString()}）。`,
  };
}

function resolveCurrentLevelAssets(input: {
  readonly baseMatches: boolean;
  readonly catalogItem: CatalogItem | undefined;
  readonly currentLevel: number | null;
}): { readonly visual: CatalogItem['levelVisual']; readonly icon: CatalogItem['icon'] } {
  const { baseMatches, catalogItem, currentLevel } = input;
  if (!baseMatches || catalogItem === undefined || currentLevel === null || currentLevel === undefined) {
    return { visual: null, icon: null };
  }
  const matched = catalogItem.levels.find((level) => level.level === currentLevel);
  return {
    visual: matched?.levelVisual ?? null,
    icon: matched?.icon ?? null,
  };
}

function missingReasonForStatus(input: {
  readonly baseMatches: boolean;
  readonly catalogItem: CatalogItem | undefined;
  readonly catalogAvailable: boolean;
  readonly item: AccountItem;
}): string | null {
  const { baseMatches, catalogItem, catalogAvailable, item } = input;
  if (!baseMatches) {
    if (catalogItem !== undefined) {
      return `目录物品与投影基地不匹配（${item.section}:${item.dataID.toString()}）。`;
    }
    if (catalogAvailable) {
      return `目录未收录（${item.section}:${item.dataID.toString()}）。`;
    }
    return '静态目录不可用。';
  }
  return null;
}

function computeProgressCoverage(
  buildingUniverseAvailable: boolean,
  snapshot: AccountSnapshot | null,
  catalog: GameCatalog | null | undefined,
): ProgressUniverseCoverage {
  if (!buildingUniverseAvailable) {
    return { kind: 'unavailable' };
  }
  if (snapshot === null) {
    return { kind: 'unavailable' };
  }

  const missingSections = new Set(
    [...PROGRESS_SECTIONS].filter((section) => !(section in snapshot.objectSections)),
  );
  const modeledCategories = new Set<TrackerCategory>();
  for (const section of catalog?.universeSections() ?? []) {
    if (section.endsWith('2')) {
      continue;
    }
    const category = trackerCategoryFromSection(section);
    if (category !== undefined) {
      modeledCategories.add(category);
    }
  }
  const unmodeledCategories = new Set(
    ALL_TRACKER_CATEGORIES.filter((category) => !modeledCategories.has(category)),
  );

  if (missingSections.size === 0 && unmodeledCategories.size === 0) {
    return { kind: 'complete' };
  }

  return {
    kind: 'partial',
    missingSections,
    unmodeledCategories,
  };
}

function stubManualCoverage(observedItemCount: number): ManualTrackerCoverage {
  return {
    observedItemCount,
    manualItemCount: 0,
    effectiveItemCount: observedItemCount,
    activeRecordCount: 0,
    unknownItemCount: 0,
    state: 'unavailable',
    diagnostics: ['未提供本地手动状态。'],
  };
}

function aggregateKey(record: VillageItemState): string {
  const root = record.isNested ? rootIdOfItemId(record.id) : '';
  const level = record.currentLevel === null ? 'nil' : String(record.currentLevel);
  return `${record.section}:${record.dataID.toString()}:${level}:${record.isNested ? 'nested' : 'flat'}:${root}`;
}

function isNestedItem(item: AccountItem): boolean {
  return item.id.includes('.types.') || item.id.includes('.modules.');
}

function catalogBaseMatches(catalogItem: CatalogItem, base: TrackerBase): boolean {
  switch (catalogItem.base) {
    case 'home':
      return base === 'home';
    case 'builder':
      return base === 'builder';
    default:
      return false;
  }
}

function playerUnlockLevelForRequirement(
  unlocks: PlayerUnlockLevels,
  requirement: UpgradeRequirement,
): number | null {
  switch (requirement.kind) {
    case 'townHall':
      return unlocks.townHall;
    case 'builderHall':
      return unlocks.builderHall;
    case 'laboratory':
      return unlocks.laboratory;
    case 'starLaboratory':
      return unlocks.starLaboratory;
    case 'heroHall':
      return unlocks.heroHall;
    case 'blacksmith':
      return unlocks.blacksmith;
  }
}

function accountItemNameLabel(item: AccountItem): string {
  return `#${item.dataID.toString()}`;
}

function makeVillageItemState(state: VillageItemState): VillageItemState {
  return state;
}

function withRemainingSeconds(item: VillageItemState, remainingSeconds: bigint | null): VillageItemState {
  return {
    ...item,
    remainingSeconds,
  };
}

function makeDiagnostic(
  severity: AccountDataDiagnostic['severity'],
  path: string,
  message: string,
): AccountDataDiagnostic {
  return {
    id: generateUuid(),
    severity,
    path,
    message,
  };
}

function saturatingIntAdd(left: number, right: number): { readonly sum: number; readonly overflowed: boolean } {
  const next = left + right;
  if (!Number.isSafeInteger(next) || next < left) {
    return { sum: INT_MAX, overflowed: true };
  }
  return { sum: next, overflowed: false };
}

function safeFloorInt64(intervalMs: number): bigint | null {
  if (!Number.isFinite(intervalMs)) {
    return null;
  }
  const floored = Math.floor(intervalMs / 1000);
  if (!Number.isSafeInteger(floored)) {
    return null;
  }
  const max = BigInt(Number.MAX_SAFE_INTEGER);
  const min = -max - 1n;
  const value = BigInt(floored);
  if (value < min || value > max) {
    return null;
  }
  return value;
}
