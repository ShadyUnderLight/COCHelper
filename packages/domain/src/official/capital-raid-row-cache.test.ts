import { CapitalRaidRowCache } from './capital-raid-row-cache';
import type { OfficialCapitalRaidPage, OfficialCapitalRaidSeason } from './models/capital-raid';
import { describe, expect, it } from 'vitest';

function makeSeason(input?: {
  readonly start?: string;
  readonly end?: string;
  readonly state?: string;
  readonly loot?: number;
}): OfficialCapitalRaidSeason {
  return {
    state: input?.state ?? 'ended',
    startTime: input?.start ?? '20260701T080000.000Z',
    endTime: input?.end ?? '20260703T080000.000Z',
    capitalTotalLoot: input?.loot ?? 100_000,
    raidsCompleted: 6,
    totalAttacks: 60,
    enemyDistrictsDestroyed: 120,
    offensiveReward: 5000,
    defensiveReward: 2500,
    members: undefined,
    attackLog: undefined,
    defenseLog: undefined,
  };
}

function makePage(
  seasons: readonly OfficialCapitalRaidSeason[],
  after?: string,
): OfficialCapitalRaidPage {
  return {
    page: { items: [...seasons], before: undefined, after },
    unrecognizedKeys: [],
  };
}

describe('CapitalRaidRowCache', () => {
  it('refresh 详情更新保留 row ID', () => {
    const cache = new CapitalRaidRowCache();
    const a = makeSeason({ loot: 100_000 });
    const b = makeSeason({
      start: '20260702T080000.000Z',
      end: '20260704T080000.000Z',
      loot: 200_000,
    });
    cache.apply({ kind: 'initial', page: makePage([a, b]) });
    const idsBefore = cache.rows.map((row) => row.id);

    const aPrime = makeSeason({ loot: 999_999 });
    cache.apply({ kind: 'refreshSuccess', page: makePage([aPrime, b]) });

    expect(cache.rows.map((row) => row.id)).toEqual(idsBefore);
    expect(cache.rows[0]?.season.capitalTotalLoot).toBe(999_999);
    expect(cache.generation).toBe(1);
  });

  it('load-more 追加不改变旧 row ID', () => {
    const cache = new CapitalRaidRowCache();
    const a = makeSeason({ loot: 100_000 });
    const b = makeSeason({
      start: '20260702T080000.000Z',
      end: '20260704T080000.000Z',
      loot: 200_000,
    });
    cache.apply({ kind: 'initial', page: makePage([a, b], 'CURSOR') });
    const oldIDs = cache.rows.map((row) => row.id);

    const c = makeSeason({
      start: '20260703T080000.000Z',
      end: '20260705T080000.000Z',
      loot: 300_000,
    });
    cache.apply({ kind: 'loadMoreSuccess', page: makePage([a, b, c], 'CURSOR2') });

    expect(cache.rows.map((row) => row.id).slice(0, 2)).toEqual(oldIDs);
    expect(cache.rows).toHaveLength(3);
    expect(cache.rows[2]?.id.endsWith('#0')).toBe(true);
  });

  it('failureRetain 不动 row state', () => {
    const cache = new CapitalRaidRowCache();
    cache.apply({ kind: 'initial', page: makePage([makeSeason()]) });
    const before = cache.rows.map((row) => row.id);
    const generation = cache.generation;
    cache.apply({ kind: 'failureRetain' });
    expect(cache.rows.map((row) => row.id)).toEqual(before);
    expect(cache.generation).toBe(generation);
  });

  it('ambiguous load-more reset generation 并重建 ID', () => {
    const cache = new CapitalRaidRowCache();
    const a = makeSeason({ loot: 100_000 });
    const b = makeSeason({ loot: 100_500 });
    cache.apply({ kind: 'initial', page: makePage([a, b]) });
    const generationBefore = cache.generation;
    const oldIDs = new Set(cache.rows.map((row) => row.id));

    const n = makeSeason({ loot: 50_000 });
    cache.apply({
      kind: 'loadMoreSuccess',
      page: makePage([n, a, b]),
      reconciliation: 'ambiguous',
    });

    expect(cache.generation).toBeGreaterThan(generationBefore);
    expect(cache.rows.some((row) => oldIDs.has(row.id))).toBe(false);
    expect(cache.rows.every((row) => row.id.startsWith(`raid:g${cache.generation}:`))).toBe(true);
  });

  it('reset 后 ID 带 raid:g<generation>: 前缀', () => {
    const cache = new CapitalRaidRowCache();
    cache.apply({ kind: 'initial', page: makePage([makeSeason()]) });
    expect(cache.rows[0]?.id).toMatch(/^raid:g1:/);
  });
});
