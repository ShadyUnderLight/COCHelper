import type { OfficialPaginatedPage } from './models/paginated-page';

/** 分页累计缓存保留上限（对齐 CacheRetentionPolicy.swift）。 */
export const MAX_WAR_LOG_ITEMS_PER_TAG = 200;
export const MAX_CAPITAL_SEASONS_PER_TAG = 240;

export function trimmedTail<T>(items: readonly T[], limit: number): T[] {
  if (limit <= 0 || items.length <= limit) {
    return [...items];
  }
  return items.slice(0, limit);
}

export function trimmedPage<Item>(
  page: OfficialPaginatedPage<Item>,
  limit: number,
): OfficialPaginatedPage<Item> {
  if (limit <= 0 || page.items.length <= limit) {
    return page;
  }
  return {
    items: page.items.slice(0, limit),
    before: page.before,
    after: page.after,
  };
}

/** 累计条目数是否已达保留上限（用于 load-more / row cache 门禁）。 */
export function isCapReached(itemCount: number, limit: number): boolean {
  return limit > 0 && itemCount >= limit;
}

export function retentionNormalizedWarLogLimit(): number {
  return MAX_WAR_LOG_ITEMS_PER_TAG;
}

export function retentionNormalizedCapitalLimit(): number {
  return MAX_CAPITAL_SEASONS_PER_TAG;
}
