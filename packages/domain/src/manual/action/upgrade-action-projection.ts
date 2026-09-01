import { catalogDurationState, type CatalogDurationState } from '../../catalog/duration-state';
import type { GameCatalog } from '../../catalog/game-catalog';
import type { CatalogUpgradeCost } from '../../catalog/types';
import {
  type BuildingGroup,
  type BuildingGroupUpgradeAction,
} from '../../village/building-group-projection';
import type { EffectiveVillageItemState } from '../../village/effective-projection';
import type { TrackerCategory } from '../../village/tracker';
import { upgradeRequirementLabel } from '../../village/upgrade-requirement';
import type { ProgressUniverseCoverage, VillageItemState } from '../../village/types';
import {
  manualEffectiveItemState,
  manualItemState,
  manualLevelDistributionQuantityAt,
  trackerItemKeyRoot,
  type ManualBaselineReference,
  type ManualCatalogProvenance,
  type ManualUpgradeCore,
  type TrackerItemKey,
} from '../types';
import {
  createUpgradeAction,
  type UpgradeAction,
  type UpgradeActionCoverage,
  type UpgradeDisplayFilter,
  type UpgradeDisplaySort,
  type UpgradeDisplayStateFilter,
} from './upgrade-action-types';

export {
  createUpgradeAction,
  upgradeActionId,
  type UpgradeAction,
  type UpgradeActionCoverage,
  type UpgradeDisplayFilter,
  type UpgradeDisplaySort,
  type UpgradeDisplayStateFilter,
} from './upgrade-action-types';

export function manualCatalogProvenanceFromCatalog(catalog: GameCatalog): ManualCatalogProvenance {
  return {
    gameVersion: catalog.gameVersion,
    buildTag: catalog.manifest?.buildTag ?? null,
    sourceFingerprint: catalog.manifest?.sourceFingerprint ?? null,
    manifestSchemaVersion: catalog.manifest?.schemaVersion ?? null,
  };
}

export function upgradeActionCoverageForItem(
  item: VillageItemState,
  progressCoverage: ProgressUniverseCoverage,
): UpgradeActionCoverage {
  switch (progressCoverage.kind) {
    case 'complete':
      return 'complete';
    case 'unavailable':
      return 'unavailable';
    case 'partial': {
      const section = item.section.endsWith('2') ? item.section.slice(0, -1) : item.section;
      return progressCoverage.missingSections.has(section) ? 'partial' : 'complete';
    }
  }
}

export function projectUpgradeActionForItem(input: {
  readonly item: VillageItemState;
  readonly catalog: GameCatalog | null;
  readonly catalogIsUsable: boolean;
  readonly manualUpgradeCore: ManualUpgradeCore | null;
  readonly coverage: UpgradeActionCoverage;
  readonly nowMs: number;
}): UpgradeAction | null {
  const { item } = input;
  if (item.isNested || item.status === 'unavailable') {
    return null;
  }

  const reasons: string[] = [];
  const diagnostics: string[] = [];
  const effective = effectiveState(item);
  const itemKey = itemKeyForAction(item);
  const sourceLevel =
    effective?.effectiveCompletedLevel ??
    effective?.importedCurrentLevel ??
    item.currentLevel ??
    null;

  switch (input.coverage) {
    case 'complete':
      break;
    case 'partial':
      reasons.push('覆盖不完整，不能安全启动本地升级。');
      break;
    case 'unavailable':
      reasons.push('覆盖状态不可用，不能安全启动本地升级。');
      break;
  }

  if (effective !== undefined) {
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
  }

  if (!input.catalogIsUsable || input.catalog === null) {
    reasons.push('目录不可用，不能生成升级操作。');
    return makeUpgradeAction({
      item,
      itemKey,
      fromLevel: sourceLevel,
      targetLevel: null,
      durationState: null,
      frozenCosts: null,
      catalog: null,
      baseline:
        input.manualUpgradeCore === null
          ? null
          : (manualItemState(input.manualUpgradeCore, itemKey)?.baselineReference ?? null),
      reasons,
      diagnostics,
    });
  }

  if (effective?.status === 'manualActive') {
    return null;
  }

  const nextUpgrade = effective?.catalogNextUpgrade ?? item.nextUpgrade;
  let targetLevel: number | null = null;
  switch (nextUpgrade?.kind) {
    case 'available':
      targetLevel = nextUpgrade.level;
      break;
    case 'requires': {
      targetLevel = nextUpgrade.nextLevel;
      let message = '目标等级超过当前阶段上限。';
      if (nextUpgrade.requirements.length > 0) {
        message +=
          '解锁条件：' +
          nextUpgrade.requirements
            .map((requirement) => upgradeRequirementLabel(requirement, item.base))
            .join('、');
      }
      reasons.push(message);
      break;
    }
    case 'globalMaxed':
      reasons.push('已达到目录最高等级。');
      break;
    case 'inProgressFact':
      break;
    case 'unverified':
      reasons.push('无法验证阶段上限。');
      break;
    case 'unknown':
    case undefined:
      reasons.push('目录未收录或目标等级不可达。');
      break;
  }

  const catalogItem = input.catalog.item(item.section, item.dataID);
  const catalogLevel =
    targetLevel === null
      ? undefined
      : catalogItem?.levels.find((level) => level.level === targetLevel);
  const durationState =
    catalogLevel === undefined
      ? null
      : catalogDurationState(catalogLevel.durationSeconds, catalogLevel.missingReason);
  if (durationState?.kind !== 'timed' && durationState?.kind !== 'instant') {
    reasons.push('目标升级时长不可用。');
  }
  const frozenCosts = catalogLevel?.upgradeCosts ?? null;
  if (frozenCosts?.some((cost) => cost.parseFailed) === true) {
    diagnostics.push('目标升级费用含解析失败项，启动时保留 raw 费用证据。');
  } else if (frozenCosts === null) {
    diagnostics.push('目标升级费用未知，启动时保留 unknown cost 状态。');
  }

  const stageMax = effective?.currentStageMaxLevel ?? item.currentStageMaxLevel;
  const globalMax = effective?.globalMaxLevel ?? item.maxLevel;
  if (targetLevel !== null && stageMax !== null && targetLevel > stageMax) {
    reasons.push('目标等级超过当前阶段上限。');
  }
  if (targetLevel !== null && globalMax !== null && targetLevel > globalMax) {
    reasons.push('目标等级超过目录全局上限。');
  }

  if (input.manualUpgradeCore === null) {
    reasons.push('未提供本地 tracker 状态，不能直接执行升级。');
  } else {
    const manualState = manualItemState(input.manualUpgradeCore, itemKey);
    if (manualState !== undefined) {
      switch (manualState.status) {
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
      const distribution = manualEffectiveItemState(
        input.manualUpgradeCore,
        itemKey,
      )?.effectiveCompletedDistribution;
      if (
        distribution !== undefined &&
        distribution !== null &&
        sourceLevel !== null &&
        manualLevelDistributionQuantityAt(distribution, sourceLevel) < 1n
      ) {
        reasons.push('本地 tracker 的可用数量不足。');
      }
    } else {
      reasons.push('本地 tracker 没有对应的 itemState。');
    }
  }

  const baseline =
    input.manualUpgradeCore === null
      ? null
      : (manualItemState(input.manualUpgradeCore, itemKey)?.baselineReference ?? null);
  return makeUpgradeAction({
    item,
    itemKey,
    fromLevel: sourceLevel,
    targetLevel,
    durationState,
    frozenCosts,
    catalog: input.catalog,
    baseline,
    reasons,
    diagnostics,
  });
}

export function projectUpgradeActionsForBuildingGroup(input: {
  readonly group: BuildingGroup;
  readonly catalog: GameCatalog | null;
}): readonly UpgradeAction[] {
  return input.group.trackerState.actions.map((action) =>
    adaptBuildingGroupUpgradeAction({
      buildingAction: action,
      itemKey: input.group.trackerState.itemKey,
      itemName: input.group.name,
      catalog: input.catalog,
    }),
  );
}

export function upgradeDisplayStateOfItem(item: VillageItemState): UpgradeDisplayStateFilter {
  const effective = effectiveState(item);
  if (effective !== undefined) {
    switch (effective.status) {
      case 'manualActive':
        return 'manualActive';
      case 'importedActive':
        return 'importedActive';
      case 'manualCompleted':
        return 'completed';
      case 'needsReimport':
        return 'needsReimport';
      case 'conflict':
      case 'unknown':
      case 'unavailable':
        return 'unknown';
      case 'observed':
        return isEffectivelyMaxed(item) ? 'completed' : 'available';
    }
  }
  if (needsReimport(item)) {
    return 'needsReimport';
  }
  switch (item.status) {
    case 'upgrading':
      return 'importedActive';
    case 'maxed':
      return 'completed';
    case 'complete':
      return 'available';
    case 'unknown':
    case 'unverified':
    case 'unavailable':
    case 'available':
      return 'unknown';
  }
}

export function filterUpgradeDisplayItems(
  items: readonly VillageItemState[],
  filter: UpgradeDisplayFilter,
  nowMs: number,
): VillageItemState[] {
  let result = [...items];
  if (filter.base !== undefined) {
    result = result.filter((item) => item.base === filter.base);
  }
  if (filter.category !== undefined) {
    result = result.filter((item) => item.category === filter.category);
  }
  if (filter.state !== undefined) {
    result = result.filter((item) => upgradeDisplayStateOfItem(item) === filter.state);
  }
  if (filter.text !== undefined && filter.text.length > 0) {
    const needle = normalizeSearchText(filter.text);
    result = result.filter(
      (item) =>
        normalizeSearchText(item.name).includes(needle) ||
        item.dataID.toString().includes(filter.text!) ||
        item.section.includes(filter.text!),
    );
  }
  const sort = filter.sort ?? 'categoryName';
  result.sort((left, right) => compareForSort(left, right, sort, nowMs));
  return result;
}

function adaptBuildingGroupUpgradeAction(input: {
  readonly buildingAction: BuildingGroupUpgradeAction;
  readonly itemKey: TrackerItemKey;
  readonly itemName: string;
  readonly catalog: GameCatalog | null;
}): UpgradeAction {
  const action = createUpgradeAction({
    itemKey: input.itemKey,
    itemName: input.itemName,
    base: input.itemKey.base,
    fromLevel: input.buildingAction.fromLevel,
    targetLevel: input.buildingAction.targetLevel,
    quantity: input.buildingAction.quantity,
    durationState: input.buildingAction.durationState,
    frozenCosts: input.buildingAction.upgradeCosts,
    catalogProvenance:
      input.catalog === null ? null : manualCatalogProvenanceFromCatalog(input.catalog),
    baselineReference: input.buildingAction.baselineReference,
    isStartable: input.buildingAction.isStartable,
    disabledReason: input.buildingAction.diagnostic,
    diagnostics: input.buildingAction.diagnostic === null ? [] : [input.buildingAction.diagnostic],
    sourceKind: 'group',
  });
  return action;
}

function makeUpgradeAction(input: {
  readonly item: VillageItemState;
  readonly itemKey: TrackerItemKey;
  readonly fromLevel: number | null;
  readonly targetLevel: number | null;
  readonly durationState: CatalogDurationState | null;
  readonly frozenCosts: readonly CatalogUpgradeCost[] | null;
  readonly catalog: GameCatalog | null;
  readonly baseline: ManualBaselineReference | null;
  readonly reasons: readonly string[];
  readonly diagnostics: readonly string[];
}): UpgradeAction {
  const startable =
    input.reasons.length === 0 &&
    input.fromLevel !== null &&
    input.targetLevel !== null &&
    input.baseline !== null &&
    isUsableDuration(input.durationState);
  return createUpgradeAction({
    itemKey: input.itemKey,
    itemName: input.item.name,
    base: input.item.base,
    fromLevel: input.fromLevel,
    targetLevel: input.targetLevel,
    quantity: 1n,
    durationState: input.durationState,
    frozenCosts: input.frozenCosts,
    catalogProvenance:
      input.catalog === null ? null : manualCatalogProvenanceFromCatalog(input.catalog),
    baselineReference: input.baseline,
    isStartable: startable,
    disabledReason: input.reasons.length === 0 ? null : input.reasons.join('；'),
    diagnostics: input.diagnostics,
    sourceKind: 'row',
  });
}

function isUsableDuration(state: CatalogDurationState | null): boolean {
  return state?.kind === 'timed' || state?.kind === 'instant';
}

function effectiveState(item: VillageItemState): EffectiveVillageItemState | undefined {
  return item.effectiveState as EffectiveVillageItemState | undefined;
}

function itemKeyForAction(item: VillageItemState): TrackerItemKey {
  const effective = effectiveState(item);
  if (effective !== undefined) {
    return effective.itemKey;
  }
  return trackerItemKeyRoot(item.base, item.section, item.dataID);
}

function needsReimport(item: VillageItemState): boolean {
  return item.timerSeconds !== null && item.remainingSeconds === 0n;
}

function isEffectivelyMaxed(item: VillageItemState): boolean {
  const effective = effectiveState(item);
  if (effective?.status === 'manualCompleted') {
    return true;
  }
  return item.status === 'maxed';
}

function latestManualActivityMs(item: VillageItemState): number | null {
  const effective = effectiveState(item);
  if (effective === undefined || effective.activeManualRecords.length === 0) {
    return null;
  }
  return Math.max(...effective.activeManualRecords.map((record) => record.startedAtMs));
}

function effectiveRemainingSeconds(item: VillageItemState, nowMs: number): bigint | null {
  const state = effectiveState(item);
  if (state === undefined) {
    return item.remainingSeconds;
  }
  switch (state.status) {
    case 'manualActive': {
      if (state.activeManualRecords.length !== 1) {
        return null;
      }
      const active = state.activeManualRecords[0];
      if (active === undefined) {
        return null;
      }
      const intervalMs = active.expectedEndAtMs - nowMs;
      if (!Number.isFinite(intervalMs)) {
        return null;
      }
      const seconds = Math.floor(intervalMs / 1000);
      return BigInt(Math.max(0, seconds));
    }
    case 'importedActive':
      return item.remainingSeconds;
    case 'observed':
    case 'manualCompleted':
    case 'needsReimport':
    case 'unknown':
    case 'conflict':
    case 'unavailable':
      return null;
  }
}

function compareForSort(
  left: VillageItemState,
  right: VillageItemState,
  sort: UpgradeDisplaySort,
  nowMs: number,
): number {
  switch (sort) {
    case 'remaining': {
      const l = effectiveRemainingSeconds(left, nowMs);
      const r = effectiveRemainingSeconds(right, nowMs);
      if (l !== null && r !== null && l !== r) {
        return l < r ? -1 : 1;
      }
      if (l === null && r !== null) {
        return 1;
      }
      if (l !== null && r === null) {
        return -1;
      }
      return nameTieBreak(left, right);
    }
    case 'categoryName': {
      const l = categorySortOrder(left.category);
      const r = categorySortOrder(right.category);
      if (l !== r) {
        return l - r;
      }
      return nameTieBreak(left, right);
    }
    case 'level': {
      const l = effectiveCurrentLevel(left);
      const r = effectiveCurrentLevel(right);
      if (l !== null && r !== null && l !== r) {
        return l - r;
      }
      if (l === null && r !== null) {
        return 1;
      }
      if (l !== null && r === null) {
        return -1;
      }
      return nameTieBreak(left, right);
    }
    case 'stageMax': {
      const l = left.currentStageMaxLevel ?? left.maxLevel;
      const r = right.currentStageMaxLevel ?? right.maxLevel;
      if (l !== null && r !== null && l !== r) {
        return l - r;
      }
      if (l === null && r !== null) {
        return 1;
      }
      if (l !== null && r === null) {
        return -1;
      }
      return nameTieBreak(left, right);
    }
    case 'recentlyChanged': {
      const l = latestManualActivityMs(left);
      const r = latestManualActivityMs(right);
      if (l !== null && r !== null && l !== r) {
        return r - l;
      }
      if (l === null && r !== null) {
        return 1;
      }
      if (l !== null && r === null) {
        return -1;
      }
      return nameTieBreak(left, right);
    }
  }
}

function effectiveCurrentLevel(item: VillageItemState): number | null {
  const effective = effectiveState(item);
  return (
    effective?.effectiveCompletedLevel ??
    effective?.importedCurrentLevel ??
    item.currentLevel ??
    null
  );
}

function categorySortOrder(category: TrackerCategory | null): number {
  const order: TrackerCategory[] = [
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
  if (category === null) {
    return order.length;
  }
  const index = order.indexOf(category);
  return index === -1 ? order.length : index;
}

function normalizeSearchText(text: string): string {
  return text.normalize('NFKD').toLocaleLowerCase();
}

function nameTieBreak(left: VillageItemState, right: VillageItemState): number {
  const order = left.name.localeCompare(right.name, 'zh-Hans-CN');
  if (order !== 0) {
    return order;
  }
  return left.id.localeCompare(right.id);
}
