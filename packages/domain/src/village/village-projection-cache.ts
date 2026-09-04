import type { GameCatalog } from '../catalog/game-catalog';
import type { CraftTableCatalog } from '../catalog/craft-table';
import type { SeasonalPhaseTable, PhaseBucket } from '../catalog/seasonal-phase';
import type { ManualUpgradeCore } from '../manual/types';
import {
  projectBuildingGroupsFromProjection,
  type BuildingGroup,
} from './building-group-projection';
import { projectVillageCatalog, refreshingTimers } from './catalog-projection';
import {
  projectCraftTable,
  refreshingCraftTableModules,
  type CraftTableDefenseState,
} from './craft-table-projection';
import type { TrackerBase } from './tracker';
import type { VillageCatalogProjection } from './types';
import type { VillageProfile } from '../import/types';

export type VillageProjectionCacheRenderResult = {
  readonly projection: VillageCatalogProjection;
  readonly buildingGroups: readonly BuildingGroup[];
  readonly craftTable: readonly CraftTableDefenseState[];
  readonly projectionGeneration: bigint;
};

type CacheKey = {
  readonly villageID: string;
  readonly villageName: string;
  // Issue #304：显式 generation 替代内容 fingerprint。
  // 调用方在快照导入/清除、manual mutation/reconcile、村庄变更时递增，
  // tick 内保持稳定以命中缓存。不得用时间/摘要伪装内容身份。
  readonly snapshotGeneration: number;
  readonly base: TrackerBase;
  readonly manualGeneration: number | null;
  readonly catalogEpoch: number;
  readonly catalogVersion: string | null;
  readonly phaseBucket: PhaseBucket;
};

type CacheEntry = {
  readonly builtAtMs: number;
  readonly importedAtMs: number;
  readonly projection: VillageCatalogProjection;
  readonly craftTable: readonly CraftTableDefenseState[];
  readonly projectionGeneration: bigint;
  lastUsedAtMs: number;
};

export class VillageProjectionCache {
  readonly maxEntries: number;

  private entries = new Map<string, CacheEntry>();
  private nextProjectionGeneration = 1n;
  private _buildCount = 0;
  private _hitCount = 0;

  constructor(maxEntries = 64) {
    this.maxEntries = Math.max(1, maxEntries);
  }

  get buildCount(): number {
    return this._buildCount;
  }

  get hitCount(): number {
    return this._hitCount;
  }

  render(input: {
    readonly village: VillageProfile;
    readonly catalog: GameCatalog | null | undefined;
    readonly craftTableCatalog: CraftTableCatalog | null | undefined;
    readonly seasonalPhases: SeasonalPhaseTable;
    readonly base: TrackerBase;
    readonly nowMs: number;
    readonly manualUpgradeCore: ManualUpgradeCore | null | undefined;
    readonly catalogEpoch: number;
    readonly snapshotGeneration: number;
    readonly manualGeneration: number | null;
  }): VillageProjectionCacheRenderResult {
    const snapshot = input.village.accountSnapshot ?? null;
    if (snapshot === null) {
      const projection = projectVillageCatalog({
        village: input.village,
        catalog: input.catalog,
        seasonalPhases: input.seasonalPhases,
        craftTableCatalog: input.craftTableCatalog,
        base: input.base,
        nowMs: input.nowMs,
        manualUpgradeCore: input.manualUpgradeCore,
      });
      return {
        projection,
        buildingGroups: projectBuildingGroupsFromProjection({
          projection,
          catalog: input.catalog,
          base: input.base,
          manualUpgradeCore: input.manualUpgradeCore,
        }),
        craftTable: [],
        projectionGeneration: this.allocateProjectionGeneration(),
      };
    }

    const key: CacheKey = {
      villageID: input.village.id,
      villageName: input.village.name,
      snapshotGeneration: input.snapshotGeneration,
      base: input.base,
      manualGeneration: input.manualGeneration,
      catalogEpoch: input.catalogEpoch,
      catalogVersion: input.catalog?.gameVersion ?? null,
      phaseBucket: input.seasonalPhases.bucket(input.nowMs),
    };
    const serializedKey = serializeCacheKey(key);
    const entry = this.entries.get(serializedKey);
    if (entry !== undefined) {
      const refreshed = refreshingTimers(entry.projection, {
        nowMs: input.nowMs,
        builtAtMs: entry.builtAtMs,
        importedAtMs: entry.importedAtMs,
      });
      const craftRefreshed = refreshingCraftTableModules(entry.craftTable, {
        nowMs: input.nowMs,
        builtAtMs: entry.builtAtMs,
        importedAtMs: entry.importedAtMs,
      });
      if (refreshed.expired || craftRefreshed.expired) {
        return this.buildAndStore({
          ...input,
          importedAtMs: snapshot.importedAtMs,
          key,
          serializedKey,
        });
      }
      this._hitCount += 1;
      entry.lastUsedAtMs = input.nowMs;
      return {
        projection: refreshed.projection,
        buildingGroups: projectBuildingGroupsFromProjection({
          projection: refreshed.projection,
          catalog: input.catalog,
          base: input.base,
          manualUpgradeCore: input.manualUpgradeCore,
        }),
        craftTable: craftRefreshed.modules,
        projectionGeneration: entry.projectionGeneration,
      };
    }

    return this.buildAndStore({
      ...input,
      importedAtMs: snapshot.importedAtMs,
      key,
      serializedKey,
    });
  }

  removeAll(): void {
    this.entries.clear();
  }

  private buildAndStore(input: {
    readonly village: VillageProfile;
    readonly catalog: GameCatalog | null | undefined;
    readonly craftTableCatalog: CraftTableCatalog | null | undefined;
    readonly seasonalPhases: SeasonalPhaseTable;
    readonly base: TrackerBase;
    readonly nowMs: number;
    readonly manualUpgradeCore: ManualUpgradeCore | null | undefined;
    readonly importedAtMs: number;
    readonly key: CacheKey;
    readonly serializedKey: string;
  }): VillageProjectionCacheRenderResult {
    const projection = projectVillageCatalog({
      village: input.village,
      catalog: input.catalog,
      seasonalPhases: input.seasonalPhases,
      craftTableCatalog: input.craftTableCatalog,
      base: input.base,
      nowMs: input.nowMs,
      manualUpgradeCore: input.manualUpgradeCore,
    });
    const craftTable = projectCraftTable({
      village: input.village,
      catalog: input.craftTableCatalog,
      base: input.base,
      seasonalPhases: input.seasonalPhases,
      nowMs: input.nowMs,
    });
    const buildingGroups = projectBuildingGroupsFromProjection({
      projection,
      catalog: input.catalog,
      base: input.base,
      manualUpgradeCore: input.manualUpgradeCore,
    });

    for (const [existingKey, _entry] of this.entries.entries()) {
      const parsed = parseCacheKey(existingKey);
      if (
        parsed !== null &&
        parsed.villageID === input.key.villageID &&
        parsed.base === input.key.base &&
        existingKey !== input.serializedKey
      ) {
        this.entries.delete(existingKey);
        break;
      }
    }

    if (this.entries.size >= this.maxEntries) {
      let oldestKey: string | null = null;
      let oldestUsedAt = Number.POSITIVE_INFINITY;
      for (const [entryKey, entry] of this.entries.entries()) {
        if (entry.lastUsedAtMs < oldestUsedAt) {
          oldestUsedAt = entry.lastUsedAtMs;
          oldestKey = entryKey;
        }
      }
      if (oldestKey !== null) {
        this.entries.delete(oldestKey);
      }
    }

    const projectionGeneration = this.allocateProjectionGeneration();
    this.entries.set(input.serializedKey, {
      builtAtMs: input.nowMs,
      importedAtMs: input.importedAtMs,
      projection,
      craftTable,
      projectionGeneration,
      lastUsedAtMs: input.nowMs,
    });
    this._buildCount += 1;

    return {
      projection,
      buildingGroups,
      craftTable,
      projectionGeneration,
    };
  }

  private allocateProjectionGeneration(): bigint {
    const generation = this.nextProjectionGeneration;
    this.nextProjectionGeneration += 1n;
    return generation;
  }
}

function serializeCacheKey(key: CacheKey): string {
  return JSON.stringify({
    villageID: key.villageID,
    villageName: key.villageName,
    snapshotGeneration: key.snapshotGeneration,
    base: key.base,
    manualGeneration: key.manualGeneration,
    catalogEpoch: key.catalogEpoch,
    catalogVersion: key.catalogVersion,
    phaseBucket: key.phaseBucket,
  });
}

function parseCacheKey(serialized: string): CacheKey | null {
  try {
    return JSON.parse(serialized) as CacheKey;
  } catch {
    return null;
  }
}
