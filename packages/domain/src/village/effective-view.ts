import type { CatalogDurationState } from '../catalog/duration-state';
import type { EffectiveVillageItemState } from './effective-projection';
import { isUpgrading, type VillageItemState, type VillageNextUpgrade } from './types';
import { isEffectivelyMaxed } from './village-detail-projection';

/**
 * 单条目的 authoritative 有效视图（复刻 Swift `VillageItemState`
 * effective* 计算属性：`effectiveCurrentLevel` / `effectiveTargetLevel` /
 * `effectiveNextUpgrade` / `effectiveNextLevelDurationState`）。
 *
 * 无 sidecar 时整体回退 raw 快照字段（与 Swift `guard let effectiveState`
 *Fallback 一致），因此 renderer 可以无分支消费：等级、升级、时长永远读
 * 本视图，不再碰 raw `currentLevel / nextLevel / nextUpgrade / duration`。
 * fail-closed 状态（unknown/conflict/needsReimport/unavailable）不暴露
 * 可信升级目标与时长（Swift 同语义）。
 */
export type EffectiveItemView = {
  readonly currentLevel: number | null;
  readonly targetLevel: number | null;
  readonly nextUpgrade: VillageNextUpgrade | null;
  readonly durationState: CatalogDurationState | null;
  readonly diagnostic: string | null;
  /** 复刻 `isEffectivelyMaxed`（含 effectiveCompletedDistribution known 门）。 */
  readonly isMaxed: boolean;
};

export function effectiveItemView(item: VillageItemState): EffectiveItemView {
  const state = item.effectiveState as EffectiveVillageItemState | undefined;
  if (state === undefined) {
    return {
      currentLevel: item.currentLevel,
      targetLevel: item.nextLevel,
      nextUpgrade: item.nextUpgrade,
      durationState: item.nextLevelDurationState,
      diagnostic: null,
      isMaxed: isEffectivelyMaxed(item),
    };
  }
  const currentLevel =
    state.effectiveCompletedLevel ?? state.importedCurrentLevel ?? item.currentLevel;
  switch (state.status) {
    case 'manualActive': {
      const target = state.activeTargetLevel ?? null;
      if (target === null) {
        return {
          currentLevel,
          targetLevel: null,
          nextUpgrade: { kind: 'unknown' },
          durationState: null,
          diagnostic: state.diagnostic,
          isMaxed: isEffectivelyMaxed(item),
        };
      }
      return {
        currentLevel,
        targetLevel: target,
        nextUpgrade: {
          kind: 'inProgressFact',
          level: target,
          durationSeconds: inProgressFactDuration(state.catalogDurationState),
        },
        durationState: state.catalogDurationState,
        diagnostic: state.diagnostic,
        isMaxed: isEffectivelyMaxed(item),
      };
    }
    case 'observed':
    case 'importedActive':
      return {
        currentLevel,
        targetLevel: item.nextLevel,
        nextUpgrade: item.nextUpgrade,
        durationState: state.catalogDurationState ?? item.nextLevelDurationState,
        diagnostic: state.diagnostic,
        isMaxed: isEffectivelyMaxed(item),
      };
    case 'manualCompleted':
      return {
        currentLevel,
        targetLevel: targetLevelFromCatalogUpgrade(state.catalogNextUpgrade),
        nextUpgrade: state.catalogNextUpgrade ?? { kind: 'unknown' },
        durationState: state.catalogDurationState,
        diagnostic: state.diagnostic,
        isMaxed: isEffectivelyMaxed(item),
      };
    case 'unknown':
    case 'conflict':
    case 'needsReimport':
      return {
        currentLevel,
        targetLevel: null,
        nextUpgrade: { kind: 'unknown' },
        durationState: null,
        diagnostic: state.diagnostic,
        isMaxed: isEffectivelyMaxed(item),
      };
    case 'unavailable':
      return {
        currentLevel,
        targetLevel: null,
        nextUpgrade: null,
        durationState: null,
        diagnostic: state.diagnostic,
        isMaxed: isEffectivelyMaxed(item),
      };
    default: {
      const exhaustive: never = state.status;
      throw new Error(`未知有效状态：${String(exhaustive)}`);
    }
  }
}

function inProgressFactDuration(state: CatalogDurationState | null): bigint | null {
  if (state === null) {
    return null;
  }
  switch (state.kind) {
    case 'timed':
      return state.seconds;
    case 'instant':
      return 0n;
    default:
      return null;
  }
}

function targetLevelFromCatalogUpgrade(upgrade: VillageNextUpgrade | null): number | null {
  if (upgrade === null) {
    return null;
  }
  switch (upgrade.kind) {
    case 'available':
      return upgrade.level;
    case 'requires':
      return upgrade.nextLevel;
    default:
      return null;
  }
}

/**
 * 详情缺失说明（复刻 Swift `missingNote` 顺序：isNested → deprecated →
 * effective conflict/needsReimport/unknown → unverified → unknown →
 * upgrading + missingReason）。升级中 + missingReason 分支防止升级里的
 * 目录异常被正常详情 UI 吞掉；调用方仍按 effective 视图展示等级/升级/
 * 时长（fail-closed 状态下 domain 已置空目标与时长）。
 */
export function effectiveDetailMissingReason(item: VillageItemState): string | null {
  if (item.isNested) {
    return '该项目属于内部子项目，暂不提供逐级升级数据。';
  }
  if (item.catalogItemMissingReason === 'deprecated_in_source') {
    return '该条目在源目录中标记为已废弃（仅作历史数据展示，不参与当前内容）。';
  }
  const state = item.effectiveState as EffectiveVillageItemState | undefined;
  if (state !== undefined) {
    switch (state.status) {
      case 'conflict':
        return state.diagnostic ?? '本地手动状态冲突，暂无法确认当前等级。';
      case 'needsReimport':
        return '导入计时已结束，重新导入快照后才能确认当前等级。';
      case 'unknown':
        if (item.status !== 'unknown' && item.status !== 'unverified') {
          return state.diagnostic ?? '本地有效状态未知，暂无法确认当前等级。';
        }
        break;
      default:
        break;
    }
  }
  if (item.status === 'unverified') {
    return item.missingReason ?? '快照缺少 prerequisite 解锁建筑记录，无法验证当前阶段上限。';
  }
  if (item.status === 'unknown') {
    return item.missingReason ?? '该项目暂无逐级升级数据。';
  }
  if (isEffectivelyUpgradingNow(item, state) && item.missingReason !== null) {
    return item.missingReason;
  }
  return null;
}

function isEffectivelyUpgradingNow(
  item: VillageItemState,
  state: EffectiveVillageItemState | undefined,
): boolean {
  if (state !== undefined) {
    return state.status === 'manualActive' || state.status === 'importedActive';
  }
  return isUpgrading(item);
}
