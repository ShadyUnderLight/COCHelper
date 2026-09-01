import type { GameCatalog } from '../catalog/game-catalog';
import type { SeasonalPhaseTable, PhaseBucket } from '../catalog/seasonal-phase';
import type { ManualUpgradeCore } from '../manual/types';
import type { BuildingGroup } from './building-group-projection';
import type { TrackerBase } from './tracker';
import type { VillageProfile } from '../import/types';
import {
  buildVillageDetailFlatRows,
  groupBuildingGroupsByInstanceID,
  type VillageDetailFlatRow,
} from './village-detail-flat-row';
import type { VillageCategoryCompletion, VillageDetailGroup } from './village-detail-projection';
import type { VillageProjectionCacheRenderResult } from './village-projection-cache';

export type UpgradeDisplayStateFilter =
  'available' | 'manualActive' | 'importedActive' | 'completed' | 'needsReimport' | 'unknown';

export type UpgradeDisplaySort =
  'remaining' | 'categoryName' | 'level' | 'stageMax' | 'recentlyChanged';

export type VillageDetailFlatRowRenderIdentityKey = {
  readonly villageID: string;
  readonly villageName: string;
  readonly snapshotFingerprint: string;
  readonly base: TrackerBase;
  readonly manualFingerprint: string | null;
  readonly catalogEpoch: number;
  readonly catalogVersion: string | null;
  readonly phaseBucket: PhaseBucket;
  readonly projectionGeneration: bigint;
};

export type VillageDetailFlatRowFilterKey = {
  readonly searchText: string;
  readonly stateFilter: UpgradeDisplayStateFilter | null;
  readonly sortOrder: UpgradeDisplaySort;
  readonly categoryFilterKey: string;
};

type CacheEntry = {
  readonly rows: readonly VillageDetailFlatRow[];
  readonly groupByInstanceID: Record<string, BuildingGroup>;
};

type CacheKey = {
  readonly render: VillageDetailFlatRowRenderIdentityKey;
  readonly filter: VillageDetailFlatRowFilterKey;
};

export function createVillageDetailFlatRowRenderIdentityKey(input: {
  readonly village: VillageProfile;
  readonly render: VillageProjectionCacheRenderResult;
  readonly base: TrackerBase;
  readonly nowMs: number;
  readonly manualUpgradeCore: ManualUpgradeCore | null | undefined;
  readonly catalogEpoch: number;
  readonly catalog: GameCatalog | null | undefined;
  readonly seasonalPhases: SeasonalPhaseTable;
}): VillageDetailFlatRowRenderIdentityKey | null {
  const snapshot = input.village.accountSnapshot;
  if (snapshot === null || snapshot === undefined) {
    return null;
  }
  return {
    villageID: input.village.id,
    villageName: input.village.name,
    snapshotFingerprint: snapshot.contentFingerprint,
    base: input.base,
    manualFingerprint: input.manualUpgradeCore?.contentFingerprint ?? null,
    catalogEpoch: input.catalogEpoch,
    catalogVersion: input.catalog?.gameVersion ?? null,
    phaseBucket: input.seasonalPhases.bucket(input.nowMs),
    projectionGeneration: input.render.projectionGeneration,
  };
}

export class VillageDetailFlatRowCache {
  private entry: CacheEntry | null = null;
  private entryKey: CacheKey | null = null;
  private _buildCount = 0;
  private _hitCount = 0;

  get buildCount(): number {
    return this._buildCount;
  }

  get hitCount(): number {
    return this._hitCount;
  }

  removeAll(): void {
    this.entry = null;
    this.entryKey = null;
  }

  rows(input: {
    readonly renderKey: VillageDetailFlatRowRenderIdentityKey;
    readonly filterKey: VillageDetailFlatRowFilterKey;
    readonly sortDependsOnNow: boolean;
    readonly displayGroups: readonly VillageDetailGroup[];
    readonly statsByKey: Readonly<Record<string, VillageCategoryCompletion>>;
    readonly buildingGroups: readonly BuildingGroup[];
  }): {
    readonly rows: readonly VillageDetailFlatRow[];
    readonly groupByInstanceID: Record<string, BuildingGroup>;
  } {
    const key: CacheKey = {
      render: input.renderKey,
      filter: input.filterKey,
    };
    if (
      !input.sortDependsOnNow &&
      this.entry !== null &&
      this.entryKey !== null &&
      cacheKeysEqual(this.entryKey, key)
    ) {
      this._hitCount += 1;
      return {
        rows: this.entry.rows,
        groupByInstanceID: this.entry.groupByInstanceID,
      };
    }

    this._buildCount += 1;
    const groupByInstanceID = groupBuildingGroupsByInstanceID(input.buildingGroups);
    const built = buildVillageDetailFlatRows({
      displayGroups: input.displayGroups,
      statsByKey: input.statsByKey,
      groupByInstanceID,
    });
    const newEntry: CacheEntry = { rows: built, groupByInstanceID };
    this.entry = newEntry;
    this.entryKey = key;
    return {
      rows: newEntry.rows,
      groupByInstanceID: newEntry.groupByInstanceID,
    };
  }
}

function cacheKeysEqual(left: CacheKey, right: CacheKey): boolean {
  return (
    renderIdentityKeysEqual(left.render, right.render) &&
    left.filter.searchText === right.filter.searchText &&
    left.filter.stateFilter === right.filter.stateFilter &&
    left.filter.sortOrder === right.filter.sortOrder &&
    left.filter.categoryFilterKey === right.filter.categoryFilterKey
  );
}

function renderIdentityKeysEqual(
  left: VillageDetailFlatRowRenderIdentityKey,
  right: VillageDetailFlatRowRenderIdentityKey,
): boolean {
  return (
    left.villageID === right.villageID &&
    left.villageName === right.villageName &&
    left.snapshotFingerprint === right.snapshotFingerprint &&
    left.base === right.base &&
    left.manualFingerprint === right.manualFingerprint &&
    left.catalogEpoch === right.catalogEpoch &&
    left.catalogVersion === right.catalogVersion &&
    phaseBucketsEqual(left.phaseBucket, right.phaseBucket) &&
    left.projectionGeneration === right.projectionGeneration
  );
}

function phaseBucketsEqual(left: PhaseBucket, right: PhaseBucket): boolean {
  return (
    left.tableIdentity === right.tableIdentity &&
    left.startMs === right.startMs &&
    left.endMs === right.endMs
  );
}
