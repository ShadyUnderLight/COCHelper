import { capitalRaidRowsForSeasons } from './capital-raid-row-identity';
import {
  isCapReached,
  MAX_CAPITAL_SEASONS_PER_TAG,
  MAX_WAR_LOG_ITEMS_PER_TAG,
  trimmedPage,
  trimmedTail,
} from './cache-retention-policy';
import { mergedCapitalRaidLoadMoreItems } from './pagination-logic';
import type { OfficialCapitalRaidSeason } from './models/capital-raid';
import { describe, expect, it } from 'vitest';

function season(id: number): OfficialCapitalRaidSeason {
  return {
    state: 'ended',
    startTime: `s${String(id).padStart(3, '0')}`,
    endTime: 'e',
    capitalTotalLoot: undefined,
    raidsCompleted: undefined,
    totalAttacks: undefined,
    enemyDistrictsDestroyed: undefined,
    offensiveReward: undefined,
    defensiveReward: undefined,
    members: undefined,
    attackLog: undefined,
    defenseLog: undefined,
  };
}

describe('CacheRetentionPolicy', () => {
  it('保头裁尾', () => {
    expect(trimmedTail([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], 6)).toEqual([0, 1, 2, 3, 4, 5]);
  });

  it('limit <= 0 为 no-op', () => {
    expect(trimmedTail([1, 2, 3], 0)).toEqual([1, 2, 3]);
    expect(trimmedTail([1, 2, 3], -1)).toEqual([1, 2, 3]);
  });

  it('trimmedPage 保留游标', () => {
    const page = { items: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], before: 'B1', after: 'A1' };
    const trimmed = trimmedPage(page, 4);
    expect(trimmed.items).toEqual([0, 1, 2, 3]);
    expect(trimmed.before).toBe('B1');
    expect(trimmed.after).toBe('A1');
  });

  it('isCapReached', () => {
    expect(isCapReached(MAX_WAR_LOG_ITEMS_PER_TAG, MAX_WAR_LOG_ITEMS_PER_TAG)).toBe(true);
    expect(isCapReached(MAX_WAR_LOG_ITEMS_PER_TAG - 1, MAX_WAR_LOG_ITEMS_PER_TAG)).toBe(false);
    expect(isCapReached(10, 0)).toBe(false);
  });

  it('裁尾后 row identity 稳定', () => {
    const seasons = Array.from({ length: 30 }, (_, index) => season(index));
    const beforeRows = capitalRaidRowsForSeasons(seasons);
    const trimmed = trimmedTail(seasons, 10);
    const afterRows = capitalRaidRowsForSeasons(trimmed);
    afterRows.forEach((row, index) => {
      expect(row.id).toBe(beforeRows[index]?.id);
    });
  });

  it('裁尾后 merge 无重复', () => {
    let existing = Array.from({ length: 10 }, (_, index) => season(index));
    existing = trimmedTail(existing, 6);
    const fetched = [season(8), season(9), season(10), season(11)];
    const result = mergedCapitalRaidLoadMoreItems(existing, fetched);
    expect(result.items.map((item) => item.startTime)).toEqual([
      's000',
      's001',
      's002',
      's003',
      's004',
      's005',
      's008',
      's009',
      's010',
      's011',
    ]);
    expect(result.reconciliation).toBe('identityPreserving');
  });

  it('上限常量可审计', () => {
    expect(MAX_WAR_LOG_ITEMS_PER_TAG).toBeGreaterThan(0);
    expect(MAX_CAPITAL_SEASONS_PER_TAG).toBeGreaterThan(0);
  });
});
