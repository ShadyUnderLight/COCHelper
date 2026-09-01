import { describe, expect, it } from 'vitest';

import {
  aggregateVillageItems,
  liveRemainingSeconds,
  projectVillageCatalog,
  refreshTimerDelta,
  refreshingTimers,
} from './catalog-projection';
import {
  createSyntheticCatalog,
  makeAccountItem,
  makeTestVillage,
  TEST_IMPORTED_AT_MS,
} from './test-fixtures';

const catalog = createSyntheticCatalog();

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
      buildings: [makeAccountItem({ section: 'buildings', dataID: 1_000_007n, level: 1, path: 'lab' })],
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
