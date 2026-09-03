import {
  canSafelyMatchCapitalRaidSeasons,
  matchCapitalRaidOldIndices,
  matchTruncatedCapitalRaidRefreshOldIndices,
} from './capital-raid-matcher';
import { capitalRaidTripleKey, type CapitalRaidSeasonRow } from './capital-raid-row-identity';
import type { OfficialCapitalRaidPage, OfficialCapitalRaidSeason } from './models/capital-raid';
import type { CapitalRaidLoadMoreReconciliation } from './pagination-logic';

/** 突袭周末 row identity 生命周期缓存（对齐 CapitalRaidRowCache.swift）。 */
export type CapitalRaidRowCacheUpdate =
  | { readonly kind: 'initial'; readonly page: OfficialCapitalRaidPage }
  | { readonly kind: 'refreshSuccess'; readonly page: OfficialCapitalRaidPage }
  | {
      readonly kind: 'loadMoreSuccess';
      readonly page: OfficialCapitalRaidPage;
      readonly reconciliation?: CapitalRaidLoadMoreReconciliation;
    }
  | { readonly kind: 'parserRebuild'; readonly page: OfficialCapitalRaidPage }
  | { readonly kind: 'failureRetain' }
  | { readonly kind: 'clear' };

export class CapitalRaidRowCache {
  private _generation = 0;
  private _rows: CapitalRaidSeasonRow[] = [];
  private _buildCount = 0;
  private nextSequenceByTriple = new Map<string, number>();

  get generation(): number {
    return this._generation;
  }

  get rows(): readonly CapitalRaidSeasonRow[] {
    return this._rows;
  }

  get buildCount(): number {
    return this._buildCount;
  }

  apply(update: CapitalRaidRowCacheUpdate): readonly CapitalRaidSeasonRow[] {
    switch (update.kind) {
      case 'failureRetain':
        return this._rows;
      case 'clear':
        this._generation = 0;
        this._rows = [];
        this.nextSequenceByTriple.clear();
        return this._rows;
      case 'initial':
      case 'parserRebuild':
        this.resetAndBuild(update.page.page.items);
        return this._rows;
      case 'refreshSuccess':
        this.reconcileRefresh(update.page.page.items);
        return this._rows;
      case 'loadMoreSuccess':
        if ((update.reconciliation ?? 'identityPreserving') === 'ambiguous') {
          this.resetAndBuild(update.page.page.items);
        } else {
          this.reconcileLoadMore(update.page.page.items);
        }
        return this._rows;
    }
  }

  private reconcileRefresh(seasons: readonly OfficialCapitalRaidSeason[]): void {
    if (this._rows.length === 0) {
      this.resetAndBuild(seasons);
      return;
    }
    if (seasons.length < this._rows.length) {
      if (seasons.length === 0) {
        this.resetAndBuild(seasons);
        return;
      }
      if (this.canSafelyReconcileTruncatedRefresh(seasons)) {
        this._rows = this.matchedRowsTruncatedRefresh(seasons);
        this.syncNextSequenceFromRows();
        this._buildCount += 1;
        return;
      }
      this.resetAndBuild(seasons);
      return;
    }
    if (seasons.length === this._rows.length) {
      if (this.canSafelyReconcile(seasons)) {
        this._rows = this.matchedRows(seasons);
        this._buildCount += 1;
        return;
      }
      this.resetAndBuild(seasons);
      return;
    }
    this.resetAndBuild(seasons);
  }

  private reconcileLoadMore(seasons: readonly OfficialCapitalRaidSeason[]): void {
    if (this._rows.length === 0) {
      this.resetAndBuild(seasons);
      return;
    }
    if (seasons.length === this._rows.length) {
      if (this.canSafelyReconcile(seasons)) {
        this._rows = this.matchedRows(seasons);
        this._buildCount += 1;
        return;
      }
      this.resetAndBuild(seasons);
      return;
    }
    if (seasons.length <= this._rows.length) {
      this.resetAndBuild(seasons);
      return;
    }
    const prefix = seasons.slice(0, this._rows.length);
    if (this.canSafelyReconcile(prefix)) {
      const updated = this.matchedRows(prefix);
      for (const season of seasons.slice(this._rows.length)) {
        updated.push(this.makeRow(season));
      }
      this._rows = updated;
      this._buildCount += 1;
      return;
    }
    this.resetAndBuild(seasons);
  }

  private resetAndBuild(seasons: readonly OfficialCapitalRaidSeason[]): void {
    this._generation += 1;
    if (this._generation === 0) {
      this._generation = 1;
    }
    this.nextSequenceByTriple.clear();
    this._rows = seasons.map((season) => this.makeRow(season));
    this._buildCount += 1;
  }

  private makeRow(season: OfficialCapitalRaidSeason): CapitalRaidSeasonRow {
    const tripleKey = capitalRaidTripleKey(season);
    const seq = this.nextSequenceByTriple.get(tripleKey) ?? 0;
    this.nextSequenceByTriple.set(tripleKey, seq + 1);
    const id = `raid:g${this._generation}:${tripleKey}#${seq}`;
    return { id, season };
  }

  private syncNextSequenceFromRows(): void {
    this.nextSequenceByTriple.clear();
    for (const row of this._rows) {
      const tripleKey = capitalRaidTripleKey(row.season);
      const seq = parseSequenceFromId(row.id);
      if (seq === undefined) {
        continue;
      }
      this.nextSequenceByTriple.set(
        tripleKey,
        Math.max(this.nextSequenceByTriple.get(tripleKey) ?? 0, seq + 1),
      );
    }
  }

  private canSafelyReconcile(newSeasons: readonly OfficialCapitalRaidSeason[]): boolean {
    return canSafelyMatchCapitalRaidSeasons(
      this._rows.map((row) => row.season),
      newSeasons,
    );
  }

  private canSafelyReconcileTruncatedRefresh(
    newSeasons: readonly OfficialCapitalRaidSeason[],
  ): boolean {
    return (
      matchTruncatedCapitalRaidRefreshOldIndices(
        this._rows.map((row) => row.season),
        newSeasons,
      ) !== undefined
    );
  }

  private matchedRows(newSeasons: readonly OfficialCapitalRaidSeason[]): CapitalRaidSeasonRow[] {
    const oldIndices = matchCapitalRaidOldIndices(
      this._rows.map((row) => row.season),
      newSeasons,
    );
    if (oldIndices === undefined) {
      return newSeasons.map((season) => this.makeRow(season));
    }
    return oldIndices.map((oldIndex, newIndex) => ({
      id: this._rows[oldIndex]!.id,
      season: newSeasons[newIndex]!,
    }));
  }

  private matchedRowsTruncatedRefresh(
    newSeasons: readonly OfficialCapitalRaidSeason[],
  ): CapitalRaidSeasonRow[] {
    const oldIndices = matchTruncatedCapitalRaidRefreshOldIndices(
      this._rows.map((row) => row.season),
      newSeasons,
    );
    if (oldIndices === undefined) {
      return newSeasons.map((season) => this.makeRow(season));
    }
    return oldIndices.map((oldIndex, newIndex) => ({
      id: this._rows[oldIndex]!.id,
      season: newSeasons[newIndex]!,
    }));
  }
}

function parseSequenceFromId(id: string): number | undefined {
  const hashIndex = id.lastIndexOf('#');
  if (hashIndex < 0) {
    return undefined;
  }
  const suffix = id.slice(hashIndex + 1);
  const parsed = Number.parseInt(suffix, 10);
  return Number.isInteger(parsed) ? parsed : undefined;
}
