import type { OfficialCapitalRaidSeason } from './models/capital-raid';
import { capitalRaidSeasonsEqual } from './models/capital-raid';
import { capitalRaidTripleKey } from './capital-raid-row-identity';

export type BoundaryOverlapMatch = 'matched' | 'ambiguous' | 'notCandidate';

/** Capital Raid 赛季 identity 匹配（对齐 CapitalRaidSeasonMatcher.swift）。 */
export function classifyCapitalRaidBoundaryOverlap(
  oldSeasons: readonly OfficialCapitalRaidSeason[],
  newSeasons: readonly OfficialCapitalRaidSeason[],
): BoundaryOverlapMatch {
  if (oldSeasons.length !== newSeasons.length) {
    return 'notCandidate';
  }
  if (!tripleKeyCountsEqual(oldSeasons, newSeasons)) {
    return 'notCandidate';
  }
  return matchCapitalRaidOldIndices(oldSeasons, newSeasons) !== undefined ? 'matched' : 'ambiguous';
}

export function canSafelyMatchCapitalRaidSeasons(
  oldSeasons: readonly OfficialCapitalRaidSeason[],
  newSeasons: readonly OfficialCapitalRaidSeason[],
): boolean {
  return matchCapitalRaidOldIndices(oldSeasons, newSeasons) !== undefined;
}

export function matchCapitalRaidOldIndices(
  oldSeasons: readonly OfficialCapitalRaidSeason[],
  newSeasons: readonly OfficialCapitalRaidSeason[],
): readonly number[] | undefined {
  if (oldSeasons.length !== newSeasons.length) {
    return undefined;
  }
  if (!tripleKeyCountsEqual(oldSeasons, newSeasons)) {
    return undefined;
  }

  const oldByTriple = groupByTriple(oldSeasons);
  const newByTriple = groupByTriple(newSeasons);
  const assignment = new Map<number, number>();

  for (const triple of [...oldByTriple.keys()].sort()) {
    const oldGroup = oldByTriple.get(triple);
    const newGroup = newByTriple.get(triple);
    if (oldGroup === undefined || newGroup === undefined) {
      return undefined;
    }
    if (oldGroup.length !== newGroup.length) {
      return undefined;
    }
    if (oldGroup.length === 1) {
      assignment.set(newGroup[0]!.index, oldGroup[0]!.index);
      continue;
    }
    if (
      !matchDuplicateTripleGroup(
        oldGroup,
        newGroup,
        assignment,
      )
    ) {
      return undefined;
    }
  }

  if (assignment.size !== newSeasons.length) {
    return undefined;
  }
  return newSeasons.map((_, index) => assignment.get(index)!);
}

export function matchTruncatedCapitalRaidRefreshOldIndices(
  oldSeasons: readonly OfficialCapitalRaidSeason[],
  newSeasons: readonly OfficialCapitalRaidSeason[],
): readonly number[] | undefined {
  if (newSeasons.length === 0) {
    return undefined;
  }

  const oldByTriple = groupByTriple(oldSeasons);
  const newByTriple = groupByTriple(newSeasons);
  const assignment = new Map<number, number>();

  for (const triple of [...newByTriple.keys()].sort()) {
    const oldGroup = oldByTriple.get(triple);
    const newGroup = newByTriple.get(triple);
    if (oldGroup === undefined || newGroup === undefined) {
      return undefined;
    }
    if (newGroup.length > oldGroup.length) {
      return undefined;
    }
    if (newGroup.length === oldGroup.length) {
      if (oldGroup.length === 1) {
        assignment.set(newGroup[0]!.index, oldGroup[0]!.index);
      } else if (
        !matchDuplicateTripleGroup(oldGroup, newGroup, assignment)
      ) {
        return undefined;
      }
    } else if (
      !matchTruncatedDuplicateTripleGroup(oldGroup, newGroup, assignment)
    ) {
      return undefined;
    }
  }

  if (assignment.size !== newSeasons.length) {
    return undefined;
  }
  return newSeasons.map((_, index) => assignment.get(index)!);
}

export function hasUniqueExactPayloadBoundaryAnchor(
  oldSeasons: readonly OfficialCapitalRaidSeason[],
  newSeasons: readonly OfficialCapitalRaidSeason[],
  overlap: number,
): boolean {
  if (overlap <= 0 || oldSeasons.length < overlap || newSeasons.length < overlap) {
    return false;
  }
  const suffixStart = oldSeasons.length - overlap;
  const prefix = newSeasons.slice(0, overlap);
  for (let prefixIndex = 0; prefixIndex < prefix.length; prefixIndex += 1) {
    const newSeason = prefix[prefixIndex]!;
    const exactMatchIndices = oldSeasons
      .map((season, index) => (capitalRaidSeasonsEqual(season, newSeason) ? index : -1))
      .filter((index) => index >= 0);
    if (exactMatchIndices.length !== 1) {
      continue;
    }
    const matchedIndex = exactMatchIndices[0]!;
    if (matchedIndex === suffixStart + prefixIndex) {
      return true;
    }
  }
  return false;
}

type IndexedSeason = { readonly index: number; readonly season: OfficialCapitalRaidSeason };

function groupByTriple(seasons: readonly OfficialCapitalRaidSeason[]): Map<string, IndexedSeason[]> {
  const groups = new Map<string, IndexedSeason[]>();
  seasons.forEach((season, index) => {
    const key = capitalRaidTripleKey(season);
    const group = groups.get(key) ?? [];
    group.push({ index, season });
    groups.set(key, group);
  });
  return groups;
}

function tripleKeyCountsEqual(
  left: readonly OfficialCapitalRaidSeason[],
  right: readonly OfficialCapitalRaidSeason[],
): boolean {
  const leftCounts = tripleKeyCounts(left);
  const rightCounts = tripleKeyCounts(right);
  const keys = new Set([...leftCounts.keys(), ...rightCounts.keys()]);
  for (const key of keys) {
    if ((leftCounts.get(key) ?? 0) !== (rightCounts.get(key) ?? 0)) {
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

function matchDuplicateTripleGroup(
  oldGroup: readonly IndexedSeason[],
  newGroup: readonly IndexedSeason[],
  assignment: Map<number, number>,
): boolean {
  const oldSorted = [...oldGroup].sort((left, right) => left.index - right.index);
  const newSorted = [...newGroup].sort((left, right) => left.index - right.index);
  if (
    oldSorted.length === newSorted.length &&
    oldSorted.every(
      (oldEntry, index) =>
        oldEntry.index === newSorted[index]!.index &&
        capitalRaidSeasonsEqual(oldEntry.season, newSorted[index]!.season),
    )
  ) {
    for (let index = 0; index < oldSorted.length; index += 1) {
      assignment.set(newSorted[index]!.index, oldSorted[index]!.index);
    }
    return true;
  }

  let unmatchedOld = [...oldGroup];
  let unmatchedNew = [...newGroup];

  while (true) {
    let foundAnchor = false;
    const stillUnmatchedNew: IndexedSeason[] = [];
    for (const newEntry of unmatchedNew) {
      const newOccurrences = occurrenceCount(newEntry.season, unmatchedNew.map((entry) => entry.season));
      if (newOccurrences !== 1) {
        stillUnmatchedNew.push(newEntry);
        continue;
      }
      const oldMatchIndices = unmatchedOld
        .map((entry, index) => (capitalRaidSeasonsEqual(entry.season, newEntry.season) ? index : -1))
        .filter((index) => index >= 0);
      if (oldMatchIndices.length !== 1) {
        stillUnmatchedNew.push(newEntry);
        continue;
      }
      assignment.set(newEntry.index, unmatchedOld[oldMatchIndices[0]!]!.index);
      unmatchedOld = unmatchedOld.filter((_, index) => index !== oldMatchIndices[0]);
      foundAnchor = true;
    }
    unmatchedNew = stillUnmatchedNew;
    if (!foundAnchor) {
      break;
    }
  }

  if (unmatchedOld.length === 0 && unmatchedNew.length === 0) {
    return true;
  }
  if (unmatchedOld.length === 1 && unmatchedNew.length === 1) {
    assignment.set(unmatchedNew[0]!.index, unmatchedOld[0]!.index);
    return true;
  }
  return false;
}

function matchTruncatedDuplicateTripleGroup(
  oldGroup: readonly IndexedSeason[],
  newGroup: readonly IndexedSeason[],
  assignment: Map<number, number>,
): boolean {
  if (newGroup.length >= oldGroup.length) {
    return false;
  }

  let unmatchedOld = [...oldGroup];
  let unmatchedNew = [...newGroup];

  while (true) {
    let foundAnchor = false;
    const stillUnmatchedNew: IndexedSeason[] = [];
    for (const newEntry of unmatchedNew) {
      const newOccurrences = occurrenceCount(newEntry.season, unmatchedNew.map((entry) => entry.season));
      if (newOccurrences !== 1) {
        stillUnmatchedNew.push(newEntry);
        continue;
      }
      const oldMatchIndices = unmatchedOld
        .map((entry, index) => (capitalRaidSeasonsEqual(entry.season, newEntry.season) ? index : -1))
        .filter((index) => index >= 0);
      if (oldMatchIndices.length !== 1) {
        stillUnmatchedNew.push(newEntry);
        continue;
      }
      assignment.set(newEntry.index, unmatchedOld[oldMatchIndices[0]!]!.index);
      unmatchedOld = unmatchedOld.filter((_, index) => index !== oldMatchIndices[0]);
      foundAnchor = true;
    }
    unmatchedNew = stillUnmatchedNew;
    if (!foundAnchor) {
      break;
    }
  }

  return unmatchedNew.length === 0;
}

function occurrenceCount(
  season: OfficialCapitalRaidSeason,
  seasons: readonly OfficialCapitalRaidSeason[],
): number {
  let count = 0;
  for (const candidate of seasons) {
    if (capitalRaidSeasonsEqual(candidate, season)) {
      count += 1;
    }
  }
  return count;
}
