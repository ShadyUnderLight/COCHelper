import { describe, expect, it } from 'vitest';

import { projectBuildingGroupsFromProjection } from './building-group-projection';
import {
  aggregateVillageItems,
  liveRemainingSeconds,
  projectVillageCatalog,
  refreshTimerDelta,
  refreshingTimers,
} from './catalog-projection';
import { createGameCatalog } from '../catalog/game-catalog';
import { createCraftTableCatalog, type CraftTableModuleLevelSpec } from '../catalog/craft-table';
import {
  createSyntheticCatalog,
  makeAccountItem,
  makeTestVillage,
  TEST_IMPORTED_AT_MS,
} from './test-fixtures';
import {
  createManualItemStateForStatus,
  createManualLevelDistributionFromPairs,
  createManualUpgradeCoreState,
} from '../manual/core';
import { trackerItemKeyRoot } from '../manual/types';
import type { EffectiveVillageItemState } from './effective-projection';
import { villageDetailTotalCompletion } from './village-detail-projection';
import { CRAFT_TABLE_DATA_ID } from './display-category';

const catalog = createSyntheticCatalog();
const CRAFT_MODULE_DATA_ID = 102_000_033n;
const CRAFT_MODULE_LEVELS: readonly CraftTableModuleLevelSpec[] = [
  { level: 1, requiredTownHallLevel: 12 },
  { level: 2, requiredTownHallLevel: 12 },
  { level: 3, requiredTownHallLevel: 13 },
  { level: 4, requiredTownHallLevel: 14 },
  { level: 5, requiredTownHallLevel: 15 },
  { level: 6, requiredTownHallLevel: 16 },
  { level: 7, requiredTownHallLevel: 17 },
  { level: 8, requiredTownHallLevel: 18 },
  { level: 9, requiredTownHallLevel: 18 },
  { level: 10, requiredTownHallLevel: 18 },
];

function craftTableCatalog(moduleLevels = CRAFT_MODULE_LEVELS) {
  return createCraftTableCatalog({
    schemaVersion: 1,
    gameVersion: '18.400.13',
    buildTag: '18_400_7',
    locale: 'zh-CN',
    source: 'test fixture',
    defenses: [
      {
        dataID: 103_000_011n,
        name: '火热蜡烛',
        sourceName: 'Roaster',
        specialAbility: 'SeasonalDefenseRoaster',
        moduleIDs: [102_000_033n, 102_000_034n, 102_000_035n],
        totalModuleLevelThresholds: [9, 18, 27],
        lifecycle: null,
      },
      {
        dataID: 103_000_012n,
        name: '英雄猎台',
        sourceName: 'HeroHunter',
        specialAbility: 'SeasonalDefenseHeroHunter',
        moduleIDs: [102_000_036n, 102_000_037n, 102_000_038n],
        totalModuleLevelThresholds: [9, 18, 27],
        lifecycle: null,
      },
      {
        dataID: 103_000_013n,
        name: '蛋糕投掷器',
        sourceName: 'CakeThrower',
        specialAbility: 'SeasonalDefenseCakeThrower',
        moduleIDs: [102_000_039n, 102_000_040n, 102_000_041n],
        totalModuleLevelThresholds: [9, 18, 27],
        lifecycle: null,
      },
    ],
    modules: [
      {
        dataID: CRAFT_MODULE_DATA_ID,
        name: '火热蜡烛生命值模组',
        sourceName: 'RoasterHealth',
        statTypes: ['Hitpoints'],
        displayTitles: ['生命值'],
        maxLevel: 10,
        levels: moduleLevels,
        lifecycle: null,
      },
      ...[
        { dataID: 102_000_036n, name: '英雄猎台生命值模组' },
        { dataID: 102_000_039n, name: '蛋糕投掷器生命值模组' },
      ].map(({ dataID, name }) => ({
        dataID,
        name,
        sourceName: name,
        specialAbility: 'testAbility',
        statTypes: ['HitPoints'],
        displayTitles: ['生命值'],
        maxLevel: 10,
        levels: CRAFT_MODULE_LEVELS,
        lifecycle: null,
      })),
    ],
  });
}

function projectCraftTableModule(input: {
  readonly level: number | null;
  readonly townHallLevel?: number;
  readonly moduleLevels?: readonly CraftTableModuleLevelSpec[];
  readonly timerSeconds?: bigint | null;
  readonly remainingSeconds?: bigint | null;
  readonly rootDataID?: bigint;
}) {
  const module = makeAccountItem({
    section: 'buildings',
    dataID: CRAFT_MODULE_DATA_ID,
    level: input.level,
    timerSeconds: input.timerSeconds,
    remainingSeconds: input.remainingSeconds,
    path: '0.types.0.modules.0',
  });
  const defense = makeAccountItem({
    section: 'buildings',
    dataID: 103_000_000n,
    level: 1,
    modules: [module],
    path: '0.types.0',
  });
  const buildings = [
    makeAccountItem({
      section: 'buildings',
      dataID: input.rootDataID ?? CRAFT_TABLE_DATA_ID,
      level: 1,
      types: [defense],
      path: '0',
    }),
  ];
  if (input.townHallLevel !== undefined) {
    buildings.push(
      makeAccountItem({
        section: 'buildings',
        dataID: 1_000_001n,
        level: input.townHallLevel,
        path: '1',
      }),
    );
  }

  const projection = projectVillageCatalog({
    village: makeTestVillage({ buildings }),
    catalog,
    craftTableCatalog: craftTableCatalog(input.moduleLevels),
    base: 'home',
    nowMs: TEST_IMPORTED_AT_MS,
  });
  return projection.items.find((item) => item.dataID === CRAFT_MODULE_DATA_ID);
}

describe('VillageCatalogProjection', () => {
  it('home/builder 基地隔离', () => {
    const village = makeTestVillage({
      buildings: [makeAccountItem({ section: 'buildings', dataID: 1_000_001n, level: 1 })],
      buildings2: [makeAccountItem({ section: 'buildings2', dataID: 1_000_033n, level: 1 })],
    });
    const home = projectVillageCatalog({
      village,
      catalog,
      base: 'home',
      nowMs: TEST_IMPORTED_AT_MS,
    });
    const builder = projectVillageCatalog({
      village,
      catalog,
      base: 'builder',
      nowMs: TEST_IMPORTED_AT_MS,
    });

    expect(home.items).toHaveLength(1);
    expect(home.items[0]?.dataID).toBe(1_000_001n);
    expect(builder.items).toHaveLength(1);
    expect(builder.items[0]?.dataID).toBe(1_000_033n);
    expect(home.items.some((item) => item.section.endsWith('2'))).toBe(false);
    expect(builder.items.every((item) => item.section.endsWith('2'))).toBe(true);
  });

  it('升级中项有 nextLevel 与静态时长', () => {
    const village = makeTestVillage({
      buildings: [
        makeAccountItem({
          section: 'buildings',
          dataID: 1_000_001n,
          level: 1,
          timerSeconds: 300n,
          remainingSeconds: 200n,
        }),
      ],
    });
    const projection = projectVillageCatalog({
      village,
      catalog,
      base: 'home',
      nowMs: TEST_IMPORTED_AT_MS,
    });
    const item = projection.items[0];
    expect(item?.status).toBe('upgrading');
    expect(item?.nextLevel).toBe(2);
    expect(item?.nextLevelDurationSeconds).toBe(300n);
    expect(item?.nextUpgrade?.kind).toBe('inProgressFact');
  });

  it('非升级时 nextLevel 为 null', () => {
    const village = makeTestVillage({
      buildings: [
        makeAccountItem({ section: 'buildings', dataID: 1_000_007n, level: 1, path: 'lab' }),
      ],
      units: [makeAccountItem({ section: 'units', dataID: 4_000_000n, level: 2 })],
    });
    const projection = projectVillageCatalog({
      village,
      catalog,
      base: 'home',
      nowMs: TEST_IMPORTED_AT_MS,
    });
    const item = projection.items.find((entry) => entry.dataID === 4_000_000n);
    expect(item?.status).toBe('complete');
    expect(item?.nextLevel).toBeNull();
  });

  it('满级判定', () => {
    const village = makeTestVillage({
      buildings: [makeAccountItem({ section: 'buildings', dataID: 1_000_001n, level: 2 })],
    });
    const projection = projectVillageCatalog({
      village,
      catalog,
      base: 'home',
      nowMs: TEST_IMPORTED_AT_MS,
    });
    expect(projection.items[0]?.status).toBe('maxed');
  });

  it('精工防御模组低于大本营阶段上限时显示已记录', () => {
    const item = projectCraftTableModule({ level: 1, townHallLevel: 12 });

    expect(item?.status).toBe('complete');
    expect(item?.currentStageMaxLevel).toBe(2);
    expect(item?.maxLevel).toBe(10);
  });

  it('精工防御模组达到大本营阶段上限时显示满级', () => {
    const item = projectCraftTableModule({ level: 2, townHallLevel: 12 });

    expect(item?.status).toBe('maxed');
    expect(item?.currentStageMaxLevel).toBe(2);
  });

  it('精工防御模组全局满级但超过大本营阶段上限时保持未知', () => {
    const item = projectCraftTableModule({ level: 10, townHallLevel: 12 });

    expect(item?.status).toBe('unknown');
    expect(item?.currentStageMaxLevel).toBe(2);
    expect(item?.missingReason).toContain('高于当前大本营');
  });

  it('缺少大本营等级时不确认精工防御模组状态', () => {
    const item = projectCraftTableModule({ level: 1 });
    const globalMaxedWithoutTownHall = projectCraftTableModule({ level: 10 });

    expect(item?.status).toBe('unknown');
    expect(item?.missingReason).toContain('缺少大本营等级');
    expect(globalMaxedWithoutTownHall?.status).toBe('unknown');
    expect(globalMaxedWithoutTownHall?.missingReason).toContain('缺少大本营等级');
  });

  it.each([
    ['超出游戏范围', 19],
    ['零级', 0],
    ['负数', -1],
    ['小数', 1.5],
    ['NaN', Number.NaN],
    ['超出安全整数范围', Number.MAX_SAFE_INTEGER + 1],
  ])('非法大本营等级不确认精工防御模组满级状态：%s', (_name, townHallLevel) => {
    const item = projectCraftTableModule({ level: 10, townHallLevel });

    expect(item?.status).toBe('unknown');
    expect(item?.currentStageMaxLevel).toBeNull();
  });

  it('精工防御模组目录等级缺失或账号等级越界时保持未知', () => {
    const missingLevels = projectCraftTableModule({
      level: 1,
      townHallLevel: 12,
      moduleLevels: [],
    });
    const invalidLevels = projectCraftTableModule({
      level: 1,
      townHallLevel: 12,
      moduleLevels: CRAFT_MODULE_LEVELS.map((level, index) =>
        index === 0 ? { ...level, requiredTownHallLevel: null } : level,
      ),
    });
    const invalidLevel = projectCraftTableModule({ level: 11, townHallLevel: 18 });

    expect(missingLevels?.status).toBe('unknown');
    expect(missingLevels?.missingReason).toContain('验证当前大本营等级');
    expect(invalidLevels?.status).toBe('unknown');
    expect(invalidLevels?.missingReason).toContain('验证当前大本营等级');
    expect(invalidLevel?.status).toBe('unknown');
    expect(invalidLevel?.missingReason).toContain('目录上限');
  });

  it('正在升级的精工防御模组保留升级状态', () => {
    const item = projectCraftTableModule({
      level: 1,
      timerSeconds: 300n,
      remainingSeconds: 200n,
    });

    expect(item?.status).toBe('upgrading');
  });

  it('精工台防御类型作为结构父记录排除，实际模组仍参与追踪', () => {
    const defenseIDs: readonly bigint[] = [103_000_011n, 103_000_012n, 103_000_013n];
    const moduleIDs: readonly bigint[] = [102_000_033n, 102_000_036n, 102_000_039n];
    const defenseTypes = defenseIDs.map((dataID, index) =>
      makeAccountItem({
        section: 'buildings',
        dataID,
        path: `0.types.${index}`,
        modules: [
          makeAccountItem({
            section: 'buildings',
            dataID: moduleIDs[index]!,
            level: 1,
            path: `0.types.${index}.modules.0`,
          }),
        ],
      }),
    );
    defenseTypes.push(
      makeAccountItem({
        section: 'buildings',
        dataID: 103_000_099n,
        level: 1,
        path: '0.types.3',
      }),
    );
    const projection = projectVillageCatalog({
      village: makeTestVillage({
        buildings: [
          makeAccountItem({
            section: 'buildings',
            dataID: CRAFT_TABLE_DATA_ID,
            level: 1,
            path: '0',
            types: defenseTypes,
          }),
          makeAccountItem({ section: 'buildings', dataID: 1_000_001n, level: 12, path: '1' }),
        ],
      }),
      catalog,
      craftTableCatalog: craftTableCatalog(),
      base: 'home',
      nowMs: TEST_IMPORTED_AT_MS,
    });

    expect(projection.items.some((item) => defenseIDs.includes(item.dataID))).toBe(false);
    const projectedModules = projection.items.filter((item) => moduleIDs.includes(item.dataID));
    expect(projectedModules).toHaveLength(3);
    expect(projectedModules.every((item) => item.status === 'complete')).toBe(true);
    expect(projection.items.find((item) => item.dataID === 103_000_099n)?.status).toBe('unknown');
  });

  it('其他建筑下同 ID 的嵌套项不套用精工防御模组目录', () => {
    const item = projectCraftTableModule({
      level: 1,
      townHallLevel: 12,
      rootDataID: 1_000_100n,
    });

    expect(item?.status).toBe('unknown');
    expect(item?.missingReason).toContain('嵌套模块/类型');
  });

  it('真实 effective projection：globalMaxed 清除 raw 回退时长', () => {
    const village = makeTestVillage({
      buildings: [
        makeAccountItem({
          section: 'buildings',
          dataID: 1_000_001n,
          level: 1,
          timerSeconds: 300n,
          remainingSeconds: 200n,
        }),
      ],
    });
    const itemKey = trackerItemKeyRoot('home', 'buildings', 1_000_001n);
    const manualUpgradeCore = createManualUpgradeCoreState({
      itemStates: [
        createManualItemStateForStatus({
          itemKey,
          baselineReference: { revision: 'snapshot-1', lineageID: null },
          imported: createManualLevelDistributionFromPairs([[1, 1n]]),
          manual: createManualLevelDistributionFromPairs([[2, 1n]]),
          status: 'manualCompleted',
          sourceTimestampMs: TEST_IMPORTED_AT_MS,
        }),
      ],
    });
    const projection = projectVillageCatalog({
      village,
      catalog,
      base: 'home',
      nowMs: TEST_IMPORTED_AT_MS,
      manualUpgradeCore,
    });
    const item = projection.items[0];
    const effective = item?.effectiveState as EffectiveVillageItemState | undefined;
    expect(item?.nextLevelDurationState).toEqual({ kind: 'timed', seconds: 300n });
    expect(effective?.status).toBe('manualCompleted');
    expect(effective?.catalogNextUpgrade).toEqual({ kind: 'globalMaxed' });
    expect(effective?.catalogDurationState).toBeNull();
  });

  it('同 key 的导入升级不影响闲置满级实例的详情统计', () => {
    const cannon = catalog.item('buildings', 1_000_001n)!;
    const completeCatalog = createGameCatalog({
      gameVersion: catalog.gameVersion,
      items: [
        {
          ...cannon,
          dataID: 1_000_002n,
          levels: cannon.levels.map((level) => ({
            ...level,
            upgradeCosts:
              level.level === 2
                ? [
                    {
                      resource: 'Gold',
                      amount: 100n,
                      rawResource: 'Gold',
                      rawAmount: null,
                      parseFailed: false,
                    },
                  ]
                : level.upgradeCosts,
          })),
        },
      ],
    });
    const village = makeTestVillage({
      buildings: [
        makeAccountItem({
          section: 'buildings',
          dataID: 1_000_002n,
          level: 1,
          timerSeconds: 300n,
          remainingSeconds: 200n,
          path: '0',
        }),
        makeAccountItem({
          section: 'buildings',
          dataID: 1_000_002n,
          level: 2,
          path: '1',
        }),
        makeAccountItem({
          section: 'buildings',
          dataID: 1_000_001n,
          level: 2,
          path: '2',
        }),
      ],
    });
    const itemKey = trackerItemKeyRoot('home', 'buildings', 1_000_002n);
    const imported = createManualLevelDistributionFromPairs([
      [1, 1n],
      [2, 1n],
    ]);
    const manualUpgradeCore = createManualUpgradeCoreState({
      itemStates: [
        createManualItemStateForStatus({
          itemKey,
          baselineReference: { revision: 'snapshot-1', lineageID: null },
          imported,
          manual: createManualLevelDistributionFromPairs([[1, 2n]]),
          status: 'manualCompleted',
          sourceTimestampMs: TEST_IMPORTED_AT_MS,
        }),
      ],
    });
    const projection = projectVillageCatalog({
      village,
      catalog: completeCatalog,
      base: 'home',
      nowMs: TEST_IMPORTED_AT_MS,
      manualUpgradeCore,
    });
    const detailItems = projection.items.filter((item) => item.dataID === 1_000_002n);
    const completion = villageDetailTotalCompletion(detailItems);
    const groups = projectBuildingGroupsFromProjection({
      projection,
      catalog: completeCatalog,
      base: 'home',
      manualUpgradeCore,
    });
    const group = groups.find((candidate) => candidate.dataID === 1_000_002n)!;

    expect(detailItems).toHaveLength(2);
    expect(detailItems[0]?.effectiveState).toMatchObject({ status: 'importedActive' });
    expect(detailItems[1]?.effectiveState).toMatchObject({ status: 'importedActive' });
    expect(completion.knownCount).toBe(2);
    expect(completion.completedCount).toBe(1);
    expect(group.trackerState.status).toBe('importedActive');
    expect(group.summary.completeness).toBe('complete');
  });

  it('未知 dataID 保留诊断', () => {
    const village = makeTestVillage({
      buildings: [makeAccountItem({ section: 'buildings', dataID: 9_999_999n, level: 1 })],
    });
    const projection = projectVillageCatalog({
      village,
      catalog,
      base: 'home',
      nowMs: TEST_IMPORTED_AT_MS,
    });
    const item = projection.items[0];
    expect(item?.status).toBe('unknown');
    expect(item?.missingReason).toContain('目录未收录');
    expect(item?.dataID).toBe(9_999_999n);
  });

  it('重复建筑按等级聚合 count', () => {
    const village = makeTestVillage({
      buildings: [
        makeAccountItem({ section: 'buildings', dataID: 1_000_001n, level: 1, path: '0' }),
        makeAccountItem({ section: 'buildings', dataID: 1_000_001n, level: 1, path: '1' }),
      ],
    });
    const projection = projectVillageCatalog({
      village,
      catalog,
      base: 'home',
      nowMs: TEST_IMPORTED_AT_MS,
    });
    expect(projection.items).toHaveLength(1);
    expect(projection.items[0]?.count).toBe(2);
    expect(projection.items[0]?.id.startsWith('agg:')).toBe(true);
  });

  it('升级记录不参与聚合', () => {
    const records = aggregateVillageItems([
      {
        id: 'buildings:0',
        section: 'buildings',
        dataID: 1_000_001n,
        base: 'home',
        name: '加农炮',
        category: 'buildings',
        currentLevel: 1,
        count: 1,
        timerSeconds: 300n,
        remainingSeconds: 100n,
        nextLevel: 2,
        nextLevelDurationSeconds: 300n,
        nextLevelDurationState: null,
        maxLevel: 2,
        currentStageMaxLevel: 2,
        nextUpgrade: { kind: 'inProgressFact', level: 2, durationSeconds: 300n },
        status: 'upgrading',
        missingReason: null,
        catalogItemMissingReason: null,
        availability: { kind: 'unconfigured' },
        icon: null,
        levelVisual: null,
        currentLevelIcon: null,
        currentLevelVisual: null,
        isNested: false,
        displayCategory: null,
      },
      {
        id: 'buildings:1',
        section: 'buildings',
        dataID: 1_000_001n,
        base: 'home',
        name: '加农炮',
        category: 'buildings',
        currentLevel: 1,
        count: 1,
        timerSeconds: null,
        remainingSeconds: null,
        nextLevel: null,
        nextLevelDurationSeconds: 300n,
        nextLevelDurationState: null,
        maxLevel: 2,
        currentStageMaxLevel: 2,
        nextUpgrade: { kind: 'available', level: 2, durationSeconds: 300n },
        status: 'complete',
        missingReason: null,
        catalogItemMissingReason: null,
        availability: { kind: 'unconfigured' },
        icon: null,
        levelVisual: null,
        currentLevelIcon: null,
        currentLevelVisual: null,
        isNested: false,
        displayCategory: null,
      },
    ]);
    expect(records).toHaveLength(2);
  });

  it('liveRemainingSeconds 随 now 递减', () => {
    const snapshot = makeTestVillage({
      buildings: [
        makeAccountItem({
          section: 'buildings',
          dataID: 1_000_001n,
          level: 1,
          remainingSeconds: 100n,
        }),
      ],
    }).accountSnapshot!;
    const item = snapshot.objectSections.buildings![0]!;
    expect(liveRemainingSeconds(item, snapshot, TEST_IMPORTED_AT_MS)).toBe(100n);
    expect(liveRemainingSeconds(item, snapshot, TEST_IMPORTED_AT_MS + 30_000)).toBe(70n);
  });

  it('refreshTimerDelta 锚定 importedAt', () => {
    const importedAt = TEST_IMPORTED_AT_MS;
    const builtAt = importedAt + 5_000;
    const now = importedAt + 65_000;
    expect(refreshTimerDelta(now, builtAt, importedAt)).toBe(60n);
  });

  it('refreshingTimers 到期标记 expired', () => {
    const village = makeTestVillage({
      buildings: [
        makeAccountItem({
          section: 'buildings',
          dataID: 1_000_001n,
          level: 1,
          timerSeconds: 100n,
          remainingSeconds: 50n,
        }),
      ],
    });
    const built = projectVillageCatalog({
      village,
      catalog,
      base: 'home',
      nowMs: TEST_IMPORTED_AT_MS,
    });
    const refreshed = refreshingTimers(built, {
      nowMs: TEST_IMPORTED_AT_MS + 50_000,
      builtAtMs: TEST_IMPORTED_AT_MS,
      importedAtMs: TEST_IMPORTED_AT_MS,
    });
    expect(refreshed.expired).toBe(true);
    expect(refreshed.projection.items[0]?.remainingSeconds).toBe(0n);
  });
});
