import { describe, expect, it } from 'vitest';

import type { EffectiveVillageItemState } from './effective-projection';
import { effectiveItemView } from './effective-view';
import { trackerItemKeyRoot } from '../manual/types';
import type { VillageItemState } from './types';

function item(overrides: Partial<VillageItemState> = {}): VillageItemState {
  return {
    id: 'item-1',
    section: 'buildings',
    dataID: 1000001n,
    base: 'home',
    name: '加农炮',
    category: 'buildings',
    currentLevel: 5,
    count: 1,
    timerSeconds: null,
    remainingSeconds: null,
    nextLevel: 6,
    nextLevelDurationSeconds: 3600n,
    nextLevelDurationState: { kind: 'timed', seconds: 3600n },
    maxLevel: 10,
    currentStageMaxLevel: 10,
    nextUpgrade: { kind: 'available', level: 6, durationSeconds: 3600n },
    status: 'upgrading',
    missingReason: null,
    catalogItemMissingReason: null,
    availability: { kind: 'permanent' },
    icon: null,
    levelVisual: null,
    currentLevelIcon: null,
    currentLevelVisual: null,
    isNested: false,
    displayCategory: 'defense',
    ...overrides,
  };
}

function sidecar(
  status: EffectiveVillageItemState['status'],
  overrides: Partial<EffectiveVillageItemState> = {},
): EffectiveVillageItemState {
  return {
    itemKey: trackerItemKeyRoot('home', 'buildings', 1000001n),
    rawItemID: 'item-1',
    importedCurrentLevel: 5,
    importedCount: 1,
    importedInstanceWeight: 1n,
    importedCountOverflowed: false,
    importedCountQuality: 'known',
    importedTimerSeconds: null,
    importedRemainingSeconds: null,
    importedDistribution: null,
    manualCompletedDistribution: null,
    activeManualRecords: [],
    activeTargetDistribution: {
      levels: [],
      quantityAt: () => 0n,
      totalQuantity: 0n,
      isEmpty: true,
    },
    effectiveCompletedDistribution: null,
    status,
    provenance: [],
    diagnostic: null,
    catalogDurationState: null,
    catalogCosts: null,
    catalogNextUpgrade: null,
    currentStageMaxLevel: null,
    globalMaxLevel: null,
    effectiveCompletedLevel: null,
    activeTargetLevel: null,
    ...overrides,
  };
}

describe('effectiveItemView', () => {
  it('无 sidecar 时整体回退 raw', () => {
    const view = effectiveItemView(item());
    expect(view).toEqual({
      currentLevel: 5,
      targetLevel: 6,
      nextUpgrade: { kind: 'available', level: 6, durationSeconds: 3600n },
      durationState: { kind: 'timed', seconds: 3600n },
      diagnostic: null,
      isMaxed: false,
    });
  });

  it('manualCompleted：raw Lv5→6 + effective Lv6/next7，不再暴露 raw 目标', () => {
    const view = effectiveItemView(
      item({
        effectiveState: sidecar('manualCompleted', {
          effectiveCompletedLevel: 6,
          catalogNextUpgrade: { kind: 'available', level: 7, durationSeconds: 7200n },
          catalogDurationState: { kind: 'timed', seconds: 7200n },
        }),
      }),
    );
    expect(view.currentLevel).toBe(6);
    expect(view.targetLevel).toBe(7);
    expect(view.nextUpgrade).toEqual({ kind: 'available', level: 7, durationSeconds: 7200n });
    expect(view.durationState).toEqual({ kind: 'timed', seconds: 7200n });
  });

  it('manualCompleted + catalog requires：target 取 requires 级别', () => {
    const view = effectiveItemView(
      item({
        effectiveState: sidecar('manualCompleted', {
          effectiveCompletedLevel: 6,
          catalogNextUpgrade: {
            kind: 'requires',
            nextLevel: 7,
            requirements: [{ kind: 'townHall', level: 10 }],
            referenceDurationSeconds: null,
          },
          catalogDurationState: { kind: 'timed', seconds: 100n },
        }),
      }),
    );
    expect(view.targetLevel).toBe(7);
    expect(view.nextUpgrade?.kind).toBe('requires');
  });

  it('manualCompleted + catalog 无目标：target null，upgrade unknown', () => {
    const view = effectiveItemView(
      item({ effectiveState: sidecar('manualCompleted', { effectiveCompletedLevel: 6 }) }),
    );
    expect(view.targetLevel).toBeNull();
    expect(view.nextUpgrade).toEqual({ kind: 'unknown' });
    expect(view.durationState).toBeNull();
  });

  it('conflict + raw available/timed：不暴露 raw 升级与时长', () => {
    const view = effectiveItemView(
      item({ effectiveState: sidecar('conflict', { diagnostic: '冲突' }) }),
    );
    expect(view.nextUpgrade).toEqual({ kind: 'unknown' });
    expect(view.durationState).toBeNull();
    expect(view.targetLevel).toBeNull();
    expect(view.diagnostic).toBe('冲突');
    expect(view.currentLevel).toBe(5);
  });

  it('needsReimport / unknown 同样 fail-closed', () => {
    for (const status of ['needsReimport', 'unknown'] as const) {
      const view = effectiveItemView(item({ effectiveState: sidecar(status) }));
      expect(view.nextUpgrade).toEqual({ kind: 'unknown' });
      expect(view.durationState).toBeNull();
      expect(view.targetLevel).toBeNull();
    }
  });

  it('unavailable：upgrade null', () => {
    const view = effectiveItemView(item({ effectiveState: sidecar('unavailable') }));
    expect(view.nextUpgrade).toBeNull();
    expect(view.durationState).toBeNull();
    expect(view.targetLevel).toBeNull();
  });

  it('manualActive 用本地 target，不用 raw nextLevel', () => {
    const view = effectiveItemView(
      item({
        nextLevel: 6,
        effectiveState: sidecar('manualActive', {
          activeTargetLevel: 9,
          catalogDurationState: { kind: 'timed', seconds: 100n },
        }),
      }),
    );
    expect(view.targetLevel).toBe(9);
    expect(view.nextUpgrade).toEqual({ kind: 'inProgressFact', level: 9, durationSeconds: 100n });
    expect(view.durationState).toEqual({ kind: 'timed', seconds: 100n });
  });

  it('manualActive 无 target：upgrade unknown，duration null', () => {
    const view = effectiveItemView(item({ effectiveState: sidecar('manualActive') }));
    expect(view.targetLevel).toBeNull();
    expect(view.nextUpgrade).toEqual({ kind: 'unknown' });
    expect(view.durationState).toBeNull();
  });

  it('manualActive instant 时长折 0n', () => {
    const view = effectiveItemView(
      item({
        effectiveState: sidecar('manualActive', {
          activeTargetLevel: 9,
          catalogDurationState: { kind: 'instant' },
        }),
      }),
    );
    expect(view.nextUpgrade).toEqual({ kind: 'inProgressFact', level: 9, durationSeconds: 0n });
  });

  it('observed：target/nextUpgrade 走 raw，duration 优先 catalog', () => {
    const view = effectiveItemView(
      item({
        effectiveState: sidecar('observed', {
          catalogDurationState: { kind: 'timed', seconds: 100n },
        }),
      }),
    );
    expect(view.targetLevel).toBe(6);
    expect(view.nextUpgrade?.kind).toBe('available');
    expect(view.durationState).toEqual({ kind: 'timed', seconds: 100n });
  });

  it('observed 无 catalog duration：回退 raw duration', () => {
    const view = effectiveItemView(item({ effectiveState: sidecar('observed') }));
    expect(view.durationState).toEqual({ kind: 'timed', seconds: 3600n });
  });

  it('observed + distribution 缺失 + raw 到 cap：isMaxed 仍 false（known 门）', () => {
    const view = effectiveItemView(
      item({
        currentLevel: 10,
        maxLevel: 10,
        effectiveState: sidecar('observed'),
      }),
    );
    expect(view.isMaxed).toBe(false);
  });

  it('observed + 单级 distribution 到 cap：isMaxed true', () => {
    const view = effectiveItemView(
      item({
        currentLevel: 10,
        maxLevel: 10,
        effectiveState: sidecar('observed', {
          effectiveCompletedDistribution: {
            levels: [{ level: 10, quantity: 1n }],
            quantityAt: () => 1n,
            totalQuantity: 1n,
            isEmpty: false,
          },
        }),
      }),
    );
    expect(view.isMaxed).toBe(true);
  });

  it('无 sidecar maxed 状态：isMaxed true', () => {
    expect(effectiveItemView(item({ status: 'maxed' })).isMaxed).toBe(true);
  });

  it('currentLevel 优先 effectiveCompleted，其次 imported，最后 raw', () => {
    expect(
      effectiveItemView(
        item({
          currentLevel: 3,
          effectiveState: sidecar('observed', { effectiveCompletedLevel: 6 }),
        }),
      ).currentLevel,
    ).toBe(6);
    expect(
      effectiveItemView(
        item({ currentLevel: 3, effectiveState: sidecar('observed', { importedCurrentLevel: 4 }) }),
      ).currentLevel,
    ).toBe(4);
  });
});
