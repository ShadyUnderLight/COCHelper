import {
  applyOrphanCachePolicy,
  classifyOrphanCacheTag,
  DEFAULT_ORPHAN_CACHE_TTL_MS,
  isOfficialCacheTagReferenced,
  markOrphanIfUnreferenced,
  pruneOrphanTimestamps,
  purgeEligibleCacheTags,
} from './orphan-cache-policy';
import { describe, expect, it } from 'vitest';

describe('orphan cache policy', () => {
  const ttl = DEFAULT_ORPHAN_CACHE_TTL_MS;
  const nowMs = ttl * 3;

  it('仍被村庄或跟踪部落引用的 clan tag → retain', () => {
    expect(
      classifyOrphanCacheTag({
        tag: '#CLAN',
        villageClanTags: ['#CLAN'],
        trackedClanTags: [],
        endpointKind: 'clan',
        nowMs,
      }),
    ).toBe('retain');
    expect(
      isOfficialCacheTagReferenced({
        tag: '#CLAN',
        villageClanTags: [],
        trackedClanTags: ['#CLAN'],
        endpointKind: 'clan',
      }),
    ).toBe(true);
  });

  it('无引用且无 orphanSince → orphan（宽限期）', () => {
    expect(
      classifyOrphanCacheTag({
        tag: '#OLD',
        villageClanTags: [],
        trackedClanTags: [],
        endpointKind: 'clan',
        nowMs,
      }),
    ).toBe('orphan');
  });

  it('无引用且 TTL 到期 → purgeEligible', () => {
    expect(
      classifyOrphanCacheTag({
        tag: '#OLD',
        villageClanTags: [],
        trackedClanTags: [],
        endpointKind: 'clan',
        orphanSinceMs: nowMs - ttl,
        nowMs,
        orphanTtlMs: ttl,
      }),
    ).toBe('purgeEligible');
  });

  it('player endpoint 只看 playerTags', () => {
    expect(
      classifyOrphanCacheTag({
        tag: '#P1',
        villageClanTags: ['#CLAN'],
        trackedClanTags: ['#CLAN'],
        playerTags: ['#P1'],
        endpointKind: 'player',
        nowMs,
      }),
    ).toBe('retain');
    expect(
      classifyOrphanCacheTag({
        tag: '#P2',
        villageClanTags: ['#CLAN'],
        trackedClanTags: [],
        playerTags: ['#P1'],
        endpointKind: 'player',
        orphanSinceMs: nowMs - ttl,
        nowMs,
      }),
    ).toBe('purgeEligible');
  });

  it('purgeEligibleCacheTags 不株连仍被引用的 tag', () => {
    const eligible = purgeEligibleCacheTags({
      cacheTags: ['#KEEP', '#PURGE'],
      villageClanTags: ['#KEEP'],
      trackedClanTags: [],
      endpointKind: 'clan',
      orphanSinceByTag: {
        '#KEEP': nowMs - ttl * 2,
        '#PURGE': nowMs - ttl * 2,
      },
      nowMs,
    });
    expect(eligible).toEqual(['#PURGE']);
  });

  it('applyOrphanCachePolicy 只删除 purgeEligible 条目', () => {
    const next = applyOrphanCachePolicy(
      { '#KEEP': { n: 1 }, '#PURGE': { n: 2 } },
      {
        villageClanTags: ['#KEEP'],
        trackedClanTags: [],
        endpointKind: 'clan',
        orphanSinceByTag: { '#PURGE': nowMs - ttl * 2 },
        nowMs,
      },
    );
    expect(next).toEqual({ '#KEEP': { n: 1 } });
  });

  it('markOrphanIfUnreferenced 与 pruneOrphanTimestamps 往返', () => {
    const marked = markOrphanIfUnreferenced({
      tag: '#GONE',
      villageClanTags: [],
      trackedClanTags: [],
      endpointKind: 'clan',
      orphanSinceByTag: {},
      nowMs,
    });
    expect(marked['#GONE']).toBe(nowMs);

    const restored = markOrphanIfUnreferenced({
      tag: '#GONE',
      villageClanTags: ['#GONE'],
      trackedClanTags: [],
      endpointKind: 'clan',
      orphanSinceByTag: marked,
      nowMs,
    });
    expect(restored['#GONE']).toBeUndefined();
    expect(
      pruneOrphanTimestamps({
        orphanSinceByTag: marked,
        retainedTags: new Set(['#GONE']),
      }),
    ).toEqual({});
  });

  it('无效 TTL fail-closed → orphan，不立即 purge', () => {
    const base = {
      tag: '#OLD',
      villageClanTags: [] as string[],
      trackedClanTags: [] as string[],
      endpointKind: 'clan' as const,
      orphanSinceMs: nowMs - ttl * 2,
      nowMs,
    };
    expect(classifyOrphanCacheTag({ ...base, orphanTtlMs: 0 })).toBe('orphan');
    expect(classifyOrphanCacheTag({ ...base, orphanTtlMs: -1 })).toBe('orphan');
    expect(classifyOrphanCacheTag({ ...base, orphanTtlMs: Number.NaN })).toBe('orphan');

    const eligible = purgeEligibleCacheTags({
      cacheTags: ['#OLD'],
      villageClanTags: [],
      trackedClanTags: [],
      endpointKind: 'clan',
      orphanSinceByTag: { '#OLD': nowMs - ttl * 2 },
      nowMs,
      orphanTtlMs: 0,
    });
    expect(eligible).toEqual([]);
  });

  it('无效 orphanSinceMs fail-closed → orphan', () => {
    expect(
      classifyOrphanCacheTag({
        tag: '#OLD',
        villageClanTags: [],
        trackedClanTags: [],
        endpointKind: 'clan',
        orphanSinceMs: Number.NaN,
        nowMs,
        orphanTtlMs: ttl,
      }),
    ).toBe('orphan');
    expect(
      classifyOrphanCacheTag({
        tag: '#OLD',
        villageClanTags: [],
        trackedClanTags: [],
        endpointKind: 'clan',
        orphanSinceMs: -1,
        nowMs,
        orphanTtlMs: ttl,
      }),
    ).toBe('orphan');
  });
});
