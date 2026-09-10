import { describe, expect, it } from 'vitest';

import type { EffectiveVillageItemState } from './effective-projection';
import { effectiveDetailMissingReason, effectiveItemView } from './effective-view';
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

describe('effectiveDetailMissingReason', () => {
  it('isNested 优先', () => {
    expect(effectiveDetailMissingReason(item({ isNested: true }))).toBe(
      '该项目属于内部子项目，暂不提供逐级升级数据。',
    );
  });
  it('deprecated 优先于 effective conflict', () => {
    expect(
      effectiveDetailMissingReason(
        item({
          catalogItemMissingReason: 'deprecated_in_source',
          effectiveState: sidecar('conflict'),
        }),
      ),
    ).toBe('该条目在源目录中标记为已废弃（仅作历史数据展示，不参与当前内容）。');
  });
  it('conflict 用 diagnostic，无则通用文案', () => {
    expect(effectiveDetailMissingReason(item({ effectiveState: sidecar('conflict') }))).toBe(
      '本地手动状态冲突，暂无法确认当前等级。',
    );
    expect(
      effectiveDetailMissingReason(
        item({ effectiveState: sidecar('conflict', { diagnostic: '版本不一致' }) }),
      ),
    ).toBe('版本不一致');
  });
  it('needsReimport', () => {
    expect(effectiveDetailMissingReason(item({ effectiveState: sidecar('needsReimport') }))).toBe(
      '导入计时已结束，重新导入快照后才能确认当前等级。',
    );
  });
  it('unknown-effective（raw 非 unknown/unverified）用 diagnostic 或通用文案', () => {
    expect(effectiveDetailMissingReason(item({ effectiveState: sidecar('unknown') }))).toBe(
      '本地有效状态未知，暂无法确认当前等级。',
    );
  });
  it('raw unverified 透出 missingReason，无则默认文案', () => {
    expect(
      effectiveDetailMissingReason(item({ status: 'unverified', missingReason: '缺解锁建筑' })),
    ).toBe('缺解锁建筑');
    expect(effectiveDetailMissingReason(item({ status: 'unverified' }))).toBe(
      '快照缺少 prerequisite 解锁建筑记录，无法验证当前阶段上限。',
    );
  });
  it('raw unknown 透出 missingReason，无则默认文案', () => {
    expect(effectiveDetailMissingReason(item({ status: 'unknown' }))).toBe(
      '该项目暂无逐级升级数据。',
    );
  });
  it('升级中 + unknown dataID：显示目录未收录原因', () => {
    expect(
      effectiveDetailMissingReason(
        item({
          status: 'upgrading',
          currentLevel: null,
          nextLevel: null,
          remainingSeconds: 5n,
          missingReason: '目录未收录（buildings:9999999）。',
        }),
      ),
    ).toBe('目录未收录（buildings:9999999）。');
  });
  it('升级中 + mismatch + manual sidecar：显示 mismatch 原因', () => {
    expect(
      effectiveDetailMissingReason(
        item({
          status: 'upgrading',
          remainingSeconds: 5n,
          missingReason: '版本不匹配：快照 v1，目录 v2。',
          effectiveState: sidecar('manualActive', { activeTargetLevel: 9 }),
        }),
      ),
    ).toBe('版本不匹配：快照 v1，目录 v2。');
  });
  it('升级中无 missingReason → null；available → null', () => {
    expect(effectiveDetailMissingReason(item({ remainingSeconds: 5n }))).toBeNull();
    expect(effectiveDetailMissingReason(item({ status: 'available' }))).toBeNull();
  });
});
