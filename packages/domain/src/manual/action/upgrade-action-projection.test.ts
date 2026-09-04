import { describe, expect, it } from 'vitest';

import { createGameCatalog } from '../../catalog/game-catalog';
import type { CatalogItem, CatalogLevel } from '../../catalog/types';
import type { EffectiveVillageItemState } from '../../village/effective-projection';
import type { VillageItemState } from '../../village/types';
import {
  createManualUpgradeCoreState,
  createManualItemStateForStatus,
  createManualLevelDistributionFromPairs,
} from '../core';
import { trackerItemKeyRoot } from '../types';
import {
  projectUpgradeActionForItem,
  upgradeActionCoverageForItem,
} from './upgrade-action-projection';

const baseline = {
  revision: 'snapshot-1',
  lineageID: 'village-1',
};
const key = trackerItemKeyRoot('home', 'buildings', 1_000_002n);

function level(levelNumber: number): CatalogLevel {
  return {
    level: levelNumber,
    durationSeconds: 60n,
    upgradeCosts: [
      {
        resource: 'Gold',
        amount: 100n,
        rawResource: 'Gold',
        rawAmount: null,
        parseFailed: false,
      },
    ],
    requiredTownHallLevel: null,
    requiredLaboratoryLevel: null,
    requiredHeroTavernLevel: null,
    requiredBlacksmithLevel: null,
    icon: null,
    levelVisual: null,
    missingReason: null,
  };
}

function catalogItem(): CatalogItem {
  return {
    section: 'buildings',
    category: 'buildings',
    dataID: 1_000_002n,
    base: 'home',
    baseMissingReason: null,
    name: '加农炮',
    maxLevel: 3,
    icon: null,
    levelVisual: null,
    missingReason: null,
    displayCategory: 'defense',
    lifecycle: 'permanent',
    levels: [level(1), level(2), level(3)],
  };
}

function catalog() {
  return createGameCatalog({
    gameVersion: '18.400.13',
    items: [catalogItem()],
    manifest: {
      schemaVersion: 3,
      gameVersion: '18.400.13',
      buildTag: 'test',
      locale: 'zh-CN',
    },
  });
}

function item(
  partial: Partial<VillageItemState> & Pick<VillageItemState, 'effectiveState'>,
): VillageItemState {
  return {
    id: 'buildings:1',
    section: 'buildings',
    dataID: 1_000_002n,
    base: 'home',
    name: '加农炮',
    category: 'buildings',
    currentLevel: 1,
    count: 1,
    timerSeconds: null,
    remainingSeconds: null,
    nextLevel: 2,
    nextLevelDurationSeconds: 60n,
    nextLevelDurationState: { kind: 'timed', seconds: 60n },
    maxLevel: 3,
    currentStageMaxLevel: 3,
    nextUpgrade: { kind: 'available', level: 2, durationSeconds: 60n },
    status: 'complete',
    missingReason: null,
    catalogItemMissingReason: null,
    availability: { kind: 'permanent' },
    icon: null,
    levelVisual: null,
    currentLevelIcon: null,
    currentLevelVisual: null,
    isNested: false,
    displayCategory: 'defense',
    effectiveState: partial.effectiveState,
    ...partial,
  };
}

function observedEffective(): EffectiveVillageItemState {
  return {
    itemKey: key,
    rawItemID: 'buildings:0',
    importedCurrentLevel: 1,
    importedCount: 1,
    importedInstanceWeight: 1n,
    importedCountOverflowed: false,
    importedCountQuality: 'known',
    importedTimerSeconds: null,
    importedRemainingSeconds: null,
    importedDistribution: createManualLevelDistributionFromPairs([[1, 1n]]),
    manualCompletedDistribution: createManualLevelDistributionFromPairs([]),
    activeManualRecords: [],
    activeTargetDistribution: createManualLevelDistributionFromPairs([]),
    effectiveCompletedDistribution: createManualLevelDistributionFromPairs([[1, 1n]]),
    status: 'observed',
    provenance: ['observed'],
    diagnostic: null,
    catalogDurationState: { kind: 'timed', seconds: 60n },
    catalogCosts: level(2).upgradeCosts,
    catalogNextUpgrade: { kind: 'available', level: 2, durationSeconds: 60n },
    currentStageMaxLevel: 3,
    globalMaxLevel: 3,
    effectiveCompletedLevel: 1,
    activeTargetLevel: null,
  };
}

describe('UpgradeActionProjection', () => {
  it('unknown/conflict 不可 start', () => {
    for (const status of ['unknown', 'conflict'] as const) {
      const action = projectUpgradeActionForItem({
        item: item({ effectiveState: { ...observedEffective(), status } }),
        catalog: catalog(),
        catalogIsUsable: true,
        manualUpgradeCore: createManualUpgradeCoreState({
          itemStates: [
            createManualItemStateForStatus({
              itemKey: key,
              baselineReference: baseline,
              imported: createManualLevelDistributionFromPairs([[1, 1n]]),
              manual: createManualLevelDistributionFromPairs([]),
              status: status === 'unknown' ? 'unknown' : 'conflict',
            }),
          ],
        }),
        coverage: 'complete',
        nowMs: 1_000_000,
      });
      expect(action?.isStartable).toBe(false);
    }
  });

  it('importedActive 不可 start', () => {
    const action = projectUpgradeActionForItem({
      item: item({ effectiveState: { ...observedEffective(), status: 'importedActive' } }),
      catalog: catalog(),
      catalogIsUsable: true,
      manualUpgradeCore: createManualUpgradeCoreState({
        itemStates: [
          createManualItemStateForStatus({
            itemKey: key,
            baselineReference: baseline,
            imported: createManualLevelDistributionFromPairs([[1, 1n]]),
            manual: createManualLevelDistributionFromPairs([]),
            status: 'observed',
          }),
        ],
      }),
      coverage: 'complete',
      nowMs: 1_000_000,
    });
    expect(action?.isStartable).toBe(false);
    expect(action?.disabledReason).toContain('导入计时');
  });

  it('manualActive 不产出 action', () => {
    const action = projectUpgradeActionForItem({
      item: item({ effectiveState: { ...observedEffective(), status: 'manualActive' } }),
      catalog: catalog(),
      catalogIsUsable: true,
      manualUpgradeCore: createManualUpgradeCoreState(),
      coverage: 'complete',
      nowMs: 1_000_000,
    });
    expect(action).toBeNull();
  });

  it('无 manual core 时产出 disabled action', () => {
    const action = projectUpgradeActionForItem({
      item: item({ effectiveState: observedEffective() }),
      catalog: catalog(),
      catalogIsUsable: true,
      manualUpgradeCore: null,
      coverage: 'complete',
      nowMs: 1_000_000,
    });
    expect(action).not.toBeNull();
    expect(action?.isStartable).toBe(false);
    expect(action?.disabledReason).toContain('未提供本地 tracker 状态');
  });

  it('coverage partial/unavailable fail-closed', () => {
    const core = createManualUpgradeCoreState({
      itemStates: [
        createManualItemStateForStatus({
          itemKey: key,
          baselineReference: baseline,
          imported: createManualLevelDistributionFromPairs([[1, 1n]]),
          manual: createManualLevelDistributionFromPairs([]),
          status: 'observed',
        }),
      ],
    });
    for (const coverage of ['partial', 'unavailable'] as const) {
      const action = projectUpgradeActionForItem({
        item: item({ effectiveState: observedEffective() }),
        catalog: catalog(),
        catalogIsUsable: true,
        manualUpgradeCore: core,
        coverage,
        nowMs: 1_000_000,
      });
      expect(action?.isStartable).toBe(false);
    }
  });

  it('observed + complete coverage 可 start', () => {
    const action = projectUpgradeActionForItem({
      item: item({ effectiveState: observedEffective() }),
      catalog: catalog(),
      catalogIsUsable: true,
      manualUpgradeCore: createManualUpgradeCoreState({
        itemStates: [
          createManualItemStateForStatus({
            itemKey: key,
            baselineReference: baseline,
            imported: createManualLevelDistributionFromPairs([[1, 1n]]),
            manual: createManualLevelDistributionFromPairs([]),
            status: 'observed',
          }),
        ],
      }),
      coverage: 'complete',
      nowMs: 1_000_000,
    });
    expect(action?.isStartable).toBe(true);
    expect(action?.fromLevel).toBe(1);
    expect(action?.targetLevel).toBe(2);
    expect(action?.baselineReference).toEqual(baseline);
  });

  it('coverage 对 item section 收窄 partial', () => {
    const villageItem: VillageItemState = {
      id: 'buildings:1',
      section: 'buildings',
      dataID: 1n,
      base: 'home',
      name: '加农炮',
      category: 'buildings',
      currentLevel: 1,
      count: 1,
      timerSeconds: null,
      remainingSeconds: null,
      nextLevel: 2,
      nextLevelDurationSeconds: 60n,
      nextLevelDurationState: { kind: 'timed', seconds: 60n },
      maxLevel: 3,
      currentStageMaxLevel: 3,
      nextUpgrade: { kind: 'available', level: 2, durationSeconds: 60n },
      status: 'complete',
      missingReason: null,
      catalogItemMissingReason: null,
      availability: { kind: 'permanent' },
      icon: null,
      levelVisual: null,
      currentLevelIcon: null,
      currentLevelVisual: null,
      isNested: false,
      displayCategory: 'defense',
    };
    expect(
      upgradeActionCoverageForItem(villageItem, {
        kind: 'partial',
        missingSections: new Set(['units']),
        unmodeledCategories: new Set(),
      }),
    ).toBe('complete');
    expect(
      upgradeActionCoverageForItem(villageItem, {
        kind: 'partial',
        missingSections: new Set(['buildings']),
        unmodeledCategories: new Set(),
      }),
    ).toBe('partial');
  });
});
