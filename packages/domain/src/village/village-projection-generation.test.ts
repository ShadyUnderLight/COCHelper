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

function baseInput(generation: { snapshot: number; manual: number | null }) {
  const village = makeTestVillage({
    buildings: [makeAccountItem({ section: 'buildings', dataID: 1_000_001n, level: 1 })],
  });
  return {
    village,
    catalog,
    craftTableCatalog: null,
    seasonalPhases: EMPTY_SEASONAL_PHASE_TABLE,
    base: 'home' as const,
    nowMs: TEST_IMPORTED_AT_MS,
    manualUpgradeCore: null,
    catalogEpoch: 1,
    snapshotGeneration: generation.snapshot,
    manualGeneration: generation.manual,
  };
}

describe('VillageProjectionCache generation (Issue #304)', () => {
  it('相同 generation 命中，不同 snapshotGeneration 重建', () => {
    const cache = new VillageProjectionCache(8);
    const first = baseInput({ snapshot: 1, manual: null });
    cache.render(first as never);
    cache.render(first as never);
    expect(cache.buildCount).toBe(1);
    expect(cache.hitCount).toBe(1);

    // 显式递增 generation 必须 miss 重建（旧 fingerprint key 会错误命中）。
    cache.render({ ...first, snapshotGeneration: 2 } as never);
    expect(cache.buildCount).toBe(2);
  });

  it('manualGeneration 递增必须重建', () => {
    const cache = new VillageProjectionCache(8);
    const first = baseInput({ snapshot: 1, manual: null });
    cache.render(first as never);
    cache.render({ ...first, manualGeneration: 1 } as never);
    expect(cache.buildCount).toBe(2);
  });
});
