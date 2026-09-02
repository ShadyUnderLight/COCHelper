import { stableEqual } from './json-decode';
import type { OfficialCapitalRaidSeason } from './models/capital-raid';
import type { OfficialPaginatedPage } from './models/paginated-page';
import {
  classifyCapitalRaidBoundaryOverlap,
  hasUniqueExactPayloadBoundaryAnchor,
  canSafelyMatchCapitalRaidSeasons,
} from './capital-raid-matcher';
import { capitalRaidSeasonsEqual } from './models/capital-raid';
import { capitalRaidTripleKey } from './capital-raid-row-identity';

export function paginationHasMore(
  requestedCursor: string | undefined,
  responseAfter: string | undefined,
): boolean {
  if (responseAfter === undefined) {
    return false;
  }
  return responseAfter !== requestedCursor;
}

export function mergedPaginationItems<Item>(
  existing: readonly Item[],
  newPage: readonly Item[],
  equals: (left: Item, right: Item) => boolean = Object.is,
): Item[] {
  const merged = [...existing];
  for (const item of newPage) {
    if (!merged.some((entry) => equals(entry, item))) {
      merged.push(item);
    }
  }
  return merged;
}

export function mergedPaginationPage<Item>(
  existing: OfficialPaginatedPage<Item> | undefined,
  fetched: OfficialPaginatedPage<Item>,
  equals: (left: Item, right: Item) => boolean = Object.is,
): OfficialPaginatedPage<Item> {
  if (existing === undefined) {
    return fetched;
  }
  const stalled =
    fetched.after !== undefined && existing.after !== undefined && fetched.after === existing.after;
  return {
    items: mergedPaginationItems(existing.items, fetched.items, equals),
    before: fetched.before ?? existing.before,
    after: stalled ? undefined : fetched.after,
  };
}

export type CapitalRaidLoadMoreReconciliation = 'identityPreserving' | 'ambiguous';

export type CapitalRaidLoadMoreResult = {
  readonly page: OfficialPaginatedPage<OfficialCapitalRaidSeason>;
  readonly reconciliation: CapitalRaidLoadMoreReconciliation;
};

export function mergedCapitalRaidLoadMorePage(
  existing: OfficialPaginatedPage<OfficialCapitalRaidSeason>,
  fetched: OfficialPaginatedPage<OfficialCapitalRaidSeason>,
): CapitalRaidLoadMoreResult {
  const stalled =
    fetched.after !== undefined && existing.after !== undefined && fetched.after === existing.after;
  const { items, reconciliation } = mergedCapitalRaidLoadMoreItems(existing.items, fetched.items);
  return {
    page: {
      items,
      before: fetched.before ?? existing.before,
      after: stalled ? undefined : fetched.after,
    },
    reconciliation,
  };
}

export function mergedCapitalRaidLoadMoreItems(
  existing: readonly OfficialCapitalRaidSeason[],
  newPage: readonly OfficialCapitalRaidSeason[],
): {
  readonly items: OfficialCapitalRaidSeason[];
  readonly reconciliation: CapitalRaidLoadMoreReconciliation;
} {
  if (newPage.length === 0) {
    return { items: [...existing], reconciliation: 'identityPreserving' };
  }

  if (existing.length === 1 && newPage.length === 1) {
    if (canSafelyMatchCapitalRaidSeasons(existing, newPage)) {
      return { items: [...newPage], reconciliation: 'identityPreserving' };
    }
    if (mapsEqual(tripleKeyCounts(existing), tripleKeyCounts(newPage))) {
      return { items: [...newPage], reconciliation: 'ambiguous' };
    }
    return appendCapitalRaidItems(existing, newPage);
  }

  if (
    existing.length === newPage.length &&
    existing.length > 1 &&
    capitalRaidTripleKey(existing[0]!) === capitalRaidTripleKey(newPage[0]!) &&
    canSafelyMatchCapitalRaidSeasons(existing, newPage)
  ) {
    return { items: [...newPage], reconciliation: 'identityPreserving' };
  }

  if (
    existing.length === newPage.length &&
    existing.length > 1 &&
    capitalRaidTripleKey(existing[existing.length - 1]!) === capitalRaidTripleKey(newPage[0]!) &&
    hasPositionalTripleOverlap(existing, newPage, existing.length) &&
    mapsEqual(tripleKeyCounts(existing), tripleKeyCounts(newPage)) &&
    classifyCapitalRaidBoundaryOverlap(existing, newPage) === 'ambiguous'
  ) {
    return { items: [...newPage], reconciliation: 'ambiguous' };
  }

  const maxOverlap = Math.min(existing.length, newPage.length);
  for (let overlap = maxOverlap; overlap >= 1; overlap -= 1) {
    if (!isPaginationOverlapCandidate(existing, newPage, overlap)) {
      continue;
    }
    const suffix = existing.slice(existing.length - overlap);
    const prefix = newPage.slice(0, overlap);
    switch (classifyCapitalRaidBoundaryOverlap(suffix, prefix)) {
      case 'notCandidate':
        continue;
      case 'ambiguous':
        return {
          items: [...existing.slice(0, existing.length - overlap), ...newPage],
          reconciliation: 'ambiguous',
        };
      case 'matched':
        if (!shouldApplyOverlapCandidate(existing, newPage, overlap)) {
          continue;
        }
        return mergeWithOverlap(existing, newPage, overlap, 'identityPreserving');
      default:
        continue;
    }
  }

  return appendCapitalRaidItems(existing, newPage);
}

function mergeWithOverlap(
  existing: readonly OfficialCapitalRaidSeason[],
  newPage: readonly OfficialCapitalRaidSeason[],
  overlap: number,
  reconciliation: CapitalRaidLoadMoreReconciliation,
): {
  readonly items: OfficialCapitalRaidSeason[];
  readonly reconciliation: CapitalRaidLoadMoreReconciliation;
} {
  const merged = [...existing.slice(0, existing.length - overlap), ...newPage];
  const prior = existing.slice(0, existing.length - overlap);
  const tail = newPage.slice(overlap);
  const priorTripleKeys = new Set(prior.map((item) => capitalRaidTripleKey(item)));
  const hasTailIdentityCollision = tail.some((item) =>
    priorTripleKeys.has(capitalRaidTripleKey(item)),
  );
  return {
    items: merged,
    reconciliation: hasTailIdentityCollision ? 'ambiguous' : reconciliation,
  };
}

function appendCapitalRaidItems(
  existing: readonly OfficialCapitalRaidSeason[],
  newPage: readonly OfficialCapitalRaidSeason[],
): {
  readonly items: OfficialCapitalRaidSeason[];
  readonly reconciliation: CapitalRaidLoadMoreReconciliation;
} {
  const merged = [...existing];
  for (const item of newPage) {
    if (!merged.some((entry) => capitalRaidSeasonsEqual(entry, item))) {
      merged.push(item);
    }
  }
  return { items: merged, reconciliation: 'identityPreserving' };
}

function shouldApplyOverlapCandidate(
  existing: readonly OfficialCapitalRaidSeason[],
  newPage: readonly OfficialCapitalRaidSeason[],
  overlap: number,
): boolean {
  if (newPage.length > overlap) {
    return true;
  }
  if (newPage.length !== overlap) {
    return false;
  }
  if (hasUniqueExactPayloadBoundaryAnchor(existing, newPage, overlap)) {
    return true;
  }
  const suffix = existing.slice(existing.length - overlap);
  for (const triple of new Set(suffix.map((season) => capitalRaidTripleKey(season)))) {
    const countInExisting = tripleOccurrenceCount(triple, existing);
    const countInSuffix = tripleOccurrenceCount(triple, suffix);
    if (countInExisting !== countInSuffix) {
      return false;
    }
  }
  return true;
}

function tripleOccurrenceCount(
  triple: string,
  seasons: readonly OfficialCapitalRaidSeason[],
): number {
  return seasons.reduce(
    (count, season) => count + (capitalRaidTripleKey(season) === triple ? 1 : 0),
    0,
  );
}

function isPaginationOverlapCandidate(
  existing: readonly OfficialCapitalRaidSeason[],
  newPage: readonly OfficialCapitalRaidSeason[],
  overlap: number,
): boolean {
  if (overlap <= 0) {
    return false;
  }
  if (!hasPositionalTripleOverlap(existing, newPage, overlap)) {
    return false;
  }
  const priorEnd = existing.length - overlap;
  if (priorEnd <= 0) {
    return false;
  }
  if (hasUniqueExactPayloadBoundaryAnchor(existing, newPage, overlap)) {
    return true;
  }
  const priorCounts = tripleKeyCounts(existing.slice(0, priorEnd));
  const suffixCounts = tripleKeyCounts(existing.slice(existing.length - overlap));
  for (const [triple, suffixCount] of suffixCounts) {
    if ((priorCounts.get(triple) ?? 0) >= suffixCount) {
      return false;
    }
  }
  return true;
}

function hasPositionalTripleOverlap(
  existing: readonly OfficialCapitalRaidSeason[],
  newPage: readonly OfficialCapitalRaidSeason[],
  overlap: number,
): boolean {
  if (overlap <= 0) {
    return false;
  }
  for (let index = 0; index < overlap; index += 1) {
    const existingIndex = existing.length - overlap + index;
    if (capitalRaidTripleKey(existing[existingIndex]!) !== capitalRaidTripleKey(newPage[index]!)) {
      return false;
    }
  }
  return true;
}

function tripleKeyCounts(seasons: readonly OfficialCapitalRaidSeason[]): Map<string, number> {
  const counts = new Map<string, number>();
  for (const season of seasons) {
    const key = capitalRaidTripleKey(season);
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

function mapsEqual(left: Map<string, number>, right: Map<string, number>): boolean {
  const keys = new Set([...left.keys(), ...right.keys()]);
  for (const key of keys) {
    if ((left.get(key) ?? 0) !== (right.get(key) ?? 0)) {
      return false;
    }
  }
  return true;
}

export function warLogEntriesEqual(
  left: { readonly endTime?: string | undefined },
  right: { readonly endTime?: string | undefined },
): boolean {
  return stableEqual(left, right);
}
