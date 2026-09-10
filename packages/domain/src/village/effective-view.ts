import type { CatalogDurationState } from '../catalog/duration-state';
import type { EffectiveVillageItemState } from './effective-projection';
import type { VillageItemState, VillageNextUpgrade } from './types';
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
