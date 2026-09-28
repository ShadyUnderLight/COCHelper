import { describe, expect, it } from 'vitest';

import { createCraftTableCatalog } from '../catalog/craft-table';
import { EMPTY_SEASONAL_PHASE_TABLE } from '../catalog/seasonal-phase';
import { makeAccountItem, makeTestVillage, TEST_IMPORTED_AT_MS } from './test-fixtures';
import { CRAFT_TABLE_DATA_ID } from './display-category';
import { projectCraftTable } from './craft-table-projection';

const MODULE_DATA_ID = 102_000_033n;

function projectModule(level: number, townHallLevel: number | null) {
  const module = makeAccountItem({
    section: 'buildings',
    dataID: MODULE_DATA_ID,
    level,
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
      dataID: CRAFT_TABLE_DATA_ID,
      level: 1,
      types: [defense],
      path: '0',
    }),
  ];
  if (townHallLevel !== null) {
    buildings.push(
      makeAccountItem({
        section: 'buildings',
        dataID: 1_000_001n,
        level: townHallLevel,
        path: '1',
      }),
    );
  }
  const catalog = createCraftTableCatalog({
    schemaVersion: 1,
    gameVersion: '18.400.13',
    buildTag: '18_400_7',
    locale: 'zh-CN',
    source: 'test fixture',
    defenses: [],
    modules: [
      {
        dataID: MODULE_DATA_ID,
        name: '模组',
        sourceName: 'Module',
        statTypes: ['Hitpoints'],
        displayTitles: ['生命值'],
        maxLevel: 3,
        levels: [
          { level: 1, requiredTownHallLevel: 1 },
          { level: 2, requiredTownHallLevel: 2 },
          { level: 3, requiredTownHallLevel: 3 },
        ],
        lifecycle: null,
      },
    ],
  });
  const projected = projectCraftTable({
    village: makeTestVillage({ buildings }),
    catalog,
    base: 'home',
    seasonalPhases: EMPTY_SEASONAL_PHASE_TABLE,
    nowMs: TEST_IMPORTED_AT_MS,
  });
  return projected[0]?.modules[0];
}

describe('CraftTableProjection', () => {
  it('公开模组投影也提供目录上限和大本营阶段状态', () => {
    const module = projectModule(2, 2);

    expect(module?.status).toBe('maxed');
    expect(module?.maxLevel).toBe(3);
    expect(module?.currentStageMaxLevel).toBe(2);
    expect(module?.statTypes).toEqual(['Hitpoints']);
    expect(module?.displayTitles).toEqual(['生命值']);
  });

  it('公开模组投影在缺少大本营等级时保持未知', () => {
    const module = projectModule(2, null);

    expect(module?.status).toBe('unknown');
    expect(module?.missingReason).toContain('缺少大本营等级');
  });
});
