import {
  mergedCapitalRaidLoadMorePage,
  mergedPaginationItems,
  mergedPaginationPage,
  paginationHasMore,
} from './pagination-logic';
import type { OfficialCapitalRaidSeason } from './models/capital-raid';
import { describe, expect, it } from 'vitest';

type Entry = { readonly endTime: string | undefined };

function entry(id: string): Entry {
  return { endTime: `2026${id}` };
}

function makeSeason(input: {
  readonly start?: string;
  readonly end?: string;
  readonly loot?: number;
}): OfficialCapitalRaidSeason {
  return {
    state: 'ended',
    startTime: input.start ?? '20260701T080000.000Z',
    endTime: input.end ?? '20260703T080000.000Z',
    capitalTotalLoot: input.loot ?? 100_000,
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

describe('PaginationLogic', () => {
  it('hasMore 真值表', () => {
    expect(paginationHasMore('C1', 'C1')).toBe(false);
    expect(paginationHasMore('C1', undefined)).toBe(false);
    expect(paginationHasMore(undefined, 'C2')).toBe(true);
    expect(paginationHasMore('C1', 'C2')).toBe(true);
  });
});

describe('PaginationMerge', () => {
  it('去重追加', () => {
    const merged = mergedPaginationItems(
      [entry('01'), entry('02')],
      [entry('02'), entry('03')],
      (a, b) => a.endTime === b.endTime,
    );
    expect(merged.map((item) => item.endTime)).toEqual(['202601', '202602', '202603']);
  });

  it('首屏替换空状态', () => {
    const fetched = { items: [entry('01')], before: 'B', after: 'A' };
    expect(mergedPaginationPage(undefined, fetched)).toEqual(fetched);
  });

  it('游标停滞清空 after', () => {
    const existing = { items: [entry('01')], before: 'B', after: 'SAME' };
    const fetched = { items: [entry('02')], before: 'B', after: 'SAME' };
    const merged = mergedPaginationPage(existing, fetched, (a, b) => a.endTime === b.endTime);
    expect(merged.after).toBeUndefined();
    expect(paginationHasMore('SAME', merged.after)).toBe(false);
  });
});

describe('CapitalRaidPaginationMerge', () => {
  it('1+1 更新 payload', () => {
    const existing = { items: [makeSeason({ loot: 100_000 })], before: undefined, after: 'CURSOR' };
    const fetched = { items: [makeSeason({ loot: 999_999 })], before: undefined, after: 'CURSOR2' };
    const result = mergedCapitalRaidLoadMorePage(existing, fetched);
    expect(result.page.items).toHaveLength(1);
    expect(result.page.items[0]?.capitalTotalLoot).toBe(999_999);
    expect(result.reconciliation).toBe('identityPreserving');
  });
});
