import { describe, expect, it } from 'vitest';

import { EMPTY_SEASONAL_PHASE_TABLE } from '../catalog/seasonal-phase';
import { VillageProjectionCache } from './village-projection-cache';
import {
  createSyntheticCatalog,
  makeAccountItem,
  makeTestVillage,
  TEST_IMPORTED_AT_MS,
} from './test-fixtures';

const catalog = createSyntheticCatalog();

describe('VillageProjectionCache', () => {
  it('相同 key 命中缓存', () => {
    const cache = new VillageProjectionCache(8);
    const village = makeTestVillage({
      buildings: [makeAccountItem({ section: 'buildings', dataID: 1_000_001n, level: 1 })],
    });
    const input = {
      village,
      catalog,
      craftTableCatalog: null,
      seasonalPhases: EMPTY_SEASONAL_PHASE_TABLE,
      base: 'home' as const,
      nowMs: TEST_IMPORTED_AT_MS,
      manualUpgradeCore: null,
      catalogEpoch: 1,
    };
    cache.render(input);
    cache.render(input);
    expect(cache.buildCount).toBe(1);
    expect(cache.hitCount).toBe(1);
  });

  it('now tick 刷新 remaining 不重建静态投影', () => {
    const cache = new VillageProjectionCache(8);
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
    const input = {
      village,
      catalog,
      craftTableCatalog: null,
      seasonalPhases: EMPTY_SEASONAL_PHASE_TABLE,
      base: 'home' as const,
      nowMs: TEST_IMPORTED_AT_MS,
      manualUpgradeCore: null,
      catalogEpoch: 1,
    };
    const first = cache.render(input);
    const second = cache.render({ ...input, nowMs: TEST_IMPORTED_AT_MS + 30_000 });
    expect(cache.buildCount).toBe(1);
    expect(second.projection.items[0]?.remainingSeconds).toBe(170n);
    expect(first.projectionGeneration).toBe(second.projectionGeneration);
  });
});
