import type { OfficialCapitalRaidSeason } from './models/capital-raid';

/** 突袭周末行身份生成（对齐 CapitalRaidRowIdentity.swift）。 */
export type CapitalRaidSeasonRow = {
  readonly id: string;
  readonly season: OfficialCapitalRaidSeason;
};

export function capitalRaidTripleKey(season: OfficialCapitalRaidSeason): string {
  const start = season.startTime ?? '';
  const end = season.endTime ?? '';
  const state = season.state ?? '';
  return `${start}|${end}|${state}`;
}

export function capitalRaidRowsForSeasons(
  seasons: readonly OfficialCapitalRaidSeason[],
): readonly CapitalRaidSeasonRow[] {
  const counts = new Map<string, number>();
  const result: CapitalRaidSeasonRow[] = [];
  for (const season of seasons) {
    const key = capitalRaidTripleKey(season);
    const seq = counts.get(key) ?? 0;
    counts.set(key, seq + 1);
    result.push({ id: `${key}#${seq}`, season });
  }
  return result;
}

export function capitalRaidRowsForPage(page: {
  readonly page: { readonly items: readonly OfficialCapitalRaidSeason[] };
}): readonly CapitalRaidSeasonRow[] {
  return capitalRaidRowsForSeasons(page.page.items);
}
