import {
  createGameCatalog,
  createManualItemStateForStatus,
  createManualLevelDistributionFromPairs,
  createManualUpgradeCoreState,
  createVillageProfile,
  projectVillageCatalog,
  trackerItemKeyRoot,
  type AccountItem,
  type AccountSnapshot,
  type CatalogAssetRef,
  type CatalogItem,
  type CatalogLevel,
  type CatalogUpgradeCost,
  type EffectiveVillageItemState,
} from '@coc-helper/domain';
import { describe, expect, it } from 'vitest';

import { toVillageItemStateDto } from './projection-dto-mappers';

const IMPORTED_AT_MS = 1_700_000_000_000;
const ITEM_DATA_ID = 1_000_001n;
const GOLD_COST: CatalogUpgradeCost = {
  resource: 'gold',
  amount: 1_000n,
  rawResource: 'Gold',
  rawAmount: '1,000',
  parseFailed: false,
};

function asset(name: string): CatalogAssetRef {
  return {
    container: 'sc/buildings.sc',
    exportName: name,
    renderedPath: `icons/buildings/${name}.png`,
    missingReason: null,
  };
}

function level(
  levelNumber: number,
  durationSeconds: bigint,
  upgradeCosts: readonly CatalogUpgradeCost[] | null = null,
): CatalogLevel {
  return {
    level: levelNumber,
    durationSeconds,
    upgradeCosts,
    requiredTownHallLevel: null,
    requiredLaboratoryLevel: null,
    requiredHeroTavernLevel: null,
    requiredBlacksmithLevel: null,
    icon: asset(`cannon_icon_lvl${levelNumber}`),
    levelVisual: asset(`cannon_lvl${levelNumber}`),
    missingReason: null,
  };
}

function catalog(
  levels: readonly CatalogLevel[] = [level(1, 60n), level(2, 300n)],
): ReturnType<typeof createGameCatalog> {
  const item: CatalogItem = {
    section: 'buildings',
    category: 'buildings',
    dataID: ITEM_DATA_ID,
    base: 'home',
    baseMissingReason: null,
    name: '加农炮',
    maxLevel: levels[levels.length - 1]!.level,
    icon: asset('cannon_icon'),
    levelVisual: asset('cannon'),
    missingReason: null,
    displayCategory: 'defense',
    lifecycle: null,
    levels,
  };
  return createGameCatalog({ gameVersion: '18.400.13', items: [item] });
}

function accountItem(): AccountItem {
  return {
    id: 'buildings:0',
    section: 'buildings',
    dataID: ITEM_DATA_ID,
    level: 1,
    count: 1,
    timerSeconds: 300n,
    remainingSeconds: 200n,
    helperTimerSeconds: null,
    remainingHelperSeconds: null,
    helperCooldownSeconds: null,
    remainingHelperCooldownSeconds: null,
    helperRecurrent: false,
    gearUp: null,
    weapon: null,
    types: [],
    modules: [],
  };
}

function snapshot(item: AccountItem = accountItem()): AccountSnapshot {
  return {
    tag: '#DTO',
    capturedAtMs: null,
    importedAtMs: IMPORTED_AT_MS,
    ageSeconds: null,
    originalText: '',
    objectSections: { buildings: [item] },
    numericSections: {},
    boosts: {},
    unknownTopLevelKeys: [],
    diagnostics: [],
  };
}

describe('projection DTO effective state mapping', () => {
  it('真实 projection 的 globalMaxed 和 effective duration 经过 mapper 仍保持 fail-closed', () => {
    const itemKey = trackerItemKeyRoot('home', 'buildings', ITEM_DATA_ID);
    const manualUpgradeCore = createManualUpgradeCoreState({
      itemStates: [
        createManualItemStateForStatus({
          itemKey,
          baselineReference: { revision: 'snapshot-1', lineageID: null },
          imported: createManualLevelDistributionFromPairs([[1, 1n]]),
          manual: createManualLevelDistributionFromPairs([[2, 1n]]),
          status: 'manualCompleted',
          sourceTimestampMs: IMPORTED_AT_MS,
        }),
      ],
    });
    const village = createVillageProfile({
      id: '00000000-0000-0000-0000-0000000000aa',
      name: 'DTO 测试村',
      accountSnapshot: snapshot(),
    });
    const projection = projectVillageCatalog({
      village,
      catalog: catalog(),
      base: 'home',
      nowMs: IMPORTED_AT_MS,
      manualUpgradeCore,
    });

    const dto = toVillageItemStateDto(projection.items[0]!);

    expect(dto.currentLevel).toBe(1);
    expect(dto.effectiveCurrentLevel).toBe(2);
    expect(dto.currentLevelVisual?.renderedPath).toBe('icons/buildings/cannon_lvl1.png');
    expect(dto.effectiveNextUpgrade).toEqual({ kind: 'globalMaxed' });
    expect(dto.effectiveNextLevelDurationState).toBeNull();
  });

  it('manualCompleted 且 effective 等级不唯一时不泄漏 raw 时长与成本', () => {
    const itemKey = trackerItemKeyRoot('home', 'buildings', ITEM_DATA_ID);
    const manualUpgradeCore = createManualUpgradeCoreState({
      itemStates: [
        createManualItemStateForStatus({
          itemKey,
          baselineReference: { revision: 'snapshot-1', lineageID: null },
          imported: createManualLevelDistributionFromPairs([[1, 2n]]),
          manual: createManualLevelDistributionFromPairs([
            [1, 1n],
            [2, 1n],
          ]),
          status: 'manualCompleted',
          sourceTimestampMs: IMPORTED_AT_MS,
        }),
      ],
    });
    const village = createVillageProfile({
      id: '00000000-0000-0000-0000-0000000000ab',
      name: 'DTO mixed 测试村',
      accountSnapshot: snapshot({ ...accountItem(), count: 2 }),
    });
    const projection = projectVillageCatalog({
      village,
      catalog: catalog([level(1, 60n, [GOLD_COST]), level(2, 300n, [GOLD_COST])]),
      base: 'home',
      nowMs: IMPORTED_AT_MS,
      manualUpgradeCore,
    });

    const projected = projection.items[0]!;
    const sidecar = projected.effectiveState as EffectiveVillageItemState;
    // 数量守恒（imported Lv1×2 → manual Lv1×1 + Lv2×1）但等级不唯一：
    // projection 层必须 fail closed，duration 与 costs 都不得回退 raw。
    expect(sidecar.status).toBe('manualCompleted');
    expect(sidecar.effectiveCompletedLevel).toBeNull();
    expect(sidecar.catalogNextUpgrade).toEqual({ kind: 'unknown' });
    expect(sidecar.catalogDurationState).toBeNull();
    expect(sidecar.catalogCosts).toBeNull();

    const dto = toVillageItemStateDto(projected);
    expect(dto.effectiveStatus).toBe('manualCompleted');
    expect(dto.effectiveNextUpgrade).toEqual({ kind: 'unknown' });
    expect(dto.effectiveTargetLevel).toBeNull();
    expect(dto.effectiveNextLevelDurationState).toBeNull();
  });

  it('manualCompleted 且 effective 等级唯一时保留 effective duration 与成本', () => {
    const itemKey = trackerItemKeyRoot('home', 'buildings', ITEM_DATA_ID);
    const manualUpgradeCore = createManualUpgradeCoreState({
      itemStates: [
        createManualItemStateForStatus({
          itemKey,
          baselineReference: { revision: 'snapshot-1', lineageID: null },
          imported: createManualLevelDistributionFromPairs([[2, 1n]]),
          manual: createManualLevelDistributionFromPairs([[2, 1n]]),
          status: 'manualCompleted',
          sourceTimestampMs: IMPORTED_AT_MS,
        }),
      ],
    });
    const village = createVillageProfile({
      id: '00000000-0000-0000-0000-0000000000ac',
      name: 'DTO available 测试村',
      accountSnapshot: snapshot(),
    });
    const projection = projectVillageCatalog({
      village,
      catalog: catalog([level(1, 60n), level(2, 300n), level(3, 900n, [GOLD_COST])]),
      base: 'home',
      nowMs: IMPORTED_AT_MS,
      manualUpgradeCore,
    });

    const projected = projection.items[0]!;
    const sidecar = projected.effectiveState as EffectiveVillageItemState;
    // 单一 effective 等级（Lv2）时必须继续取得 effective catalog Lv3 的
    // duration/costs：防止 fail-closed 分支被误改成“所有 manualCompleted
    // 都清空时长”。raw 快照仍是 Lv1（next=2，300s），若回退 raw 会得到
    // 2/300 而不是 3/900。
    expect(sidecar.status).toBe('manualCompleted');
    expect(sidecar.effectiveCompletedLevel).toBe(2);
    expect(sidecar.catalogNextUpgrade).toEqual({
      kind: 'available',
      level: 3,
      durationSeconds: 900n,
    });
    expect(sidecar.catalogDurationState).toEqual({ kind: 'timed', seconds: 900n });
    expect(sidecar.catalogCosts).toEqual([GOLD_COST]);

    const dto = toVillageItemStateDto(projected);
    expect(dto.effectiveStatus).toBe('manualCompleted');
    expect(dto.effectiveCurrentLevel).toBe(2);
    expect(dto.effectiveTargetLevel).toBe(3);
    expect(dto.effectiveNextUpgrade).toEqual({
      kind: 'available',
      level: 3,
      durationSeconds: 900,
    });
    expect(dto.effectiveNextLevelDurationState).toEqual({ kind: 'timed', seconds: 900 });
  });
});
