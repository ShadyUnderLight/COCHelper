import type { GameCatalog } from '../catalog/game-catalog';
import type { CraftTableCatalog } from '../catalog/craft-table';
import type { SeasonalPhaseTable } from '../catalog/seasonal-phase';
import { EMPTY_SEASONAL_PHASE_TABLE } from '../catalog/seasonal-phase';
import {
  manualActiveRecords,
  manualEffectiveItemState,
  manualItemState,
  trackerItemKeyRoot,
  trackerItemKeyStableId,
  type ManualUpgradeCore,
  type TrackerItemKey,
} from '../manual/types';
import { projectVillageCatalog } from './catalog-projection';
import type { EffectiveVillageItemState } from './effective-projection';
import type { VillageProgressMetrics } from './progress-metrics';
import type { TrackerBase } from './tracker';
import { isUpgrading, needsReimport, type VillageCatalogProjection, type VillageItemState } from './types';
import type { VillageProfile } from '../import/types';
import type { VillageProjectionProvider } from './types';

export type UpgradeDisplayRecord = {
  readonly id: string;
  readonly villageID: string;
  readonly villageName: string;
  readonly villageTag: string | null;
  readonly base: TrackerBase;
  readonly item: VillageItemState;
  readonly catalogVersion: string | null;
  readonly villageMetrics: VillageProgressMetrics;
};

export function upgradeDisplayRecordRemainingSeconds(
  record: UpgradeDisplayRecord,
): bigint | null | undefined {
  return record.item.remainingSeconds;
}

export function upgradeDisplayRecordRemainingSecondsAt(
  record: UpgradeDisplayRecord,
  nowMs: number,
): bigint | null | undefined {
  return effectiveRemainingSeconds(record.item, nowMs);
}

export function upgradeDisplayRecordCompletionDateMs(
  record: UpgradeDisplayRecord,
  nowMs: number,
): number | null {
  const remaining = effectiveRemainingSeconds(record.item, nowMs);
  if (remaining === null || remaining === undefined || remaining <= 0n) {
    return null;
  }
  return nowMs + Number(remaining) * 1000;
}

export type UpgradeRecentCompletion = {
  readonly villageID: string;
  readonly itemKey: TrackerItemKey;
  readonly itemName: string;
  readonly targetLevel: number;
  readonly quantity: bigint;
  readonly completedAtMs: number;
  readonly id: string;
};

export function upgradeRecentCompletionId(completion: UpgradeRecentCompletion): string {
  return `${trackerItemKeyStableId(completion.itemKey)}:${completion.targetLevel}:${completion.completedAtMs}`;
}

export type UpgradeOverviewState = {
  readonly manualActiveCount: number;
  readonly importedActiveCount: number;
  readonly deduplicatedDisplayCount: number;
  readonly manualCompletedCount: number;
  readonly completedRecently: readonly UpgradeRecentCompletion[];
  readonly activeRecords: readonly UpgradeDisplayRecord[];
  readonly attentionRecords: readonly UpgradeDisplayRecord[];
  readonly needsReimportRecords: readonly UpgradeDisplayRecord[];
};

export type UpgradeOverviewRender = {
  readonly active: readonly UpgradeDisplayRecord[];
  readonly pending: readonly UpgradeDisplayRecord[];
  readonly state: UpgradeOverviewState;
};

const DEFAULT_RECENTLY_COMPLETED_WINDOW_MS = 7 * 24 * 3600 * 1000;

export function defaultVillageProjectionProvider(input: {
  readonly catalog: GameCatalog | null | undefined;
  readonly craftTableCatalog?: CraftTableCatalog | null;
  readonly seasonalPhases: SeasonalPhaseTable;
  readonly manualUpgradeCores: Readonly<Record<string, ManualUpgradeCore>>;
}): VillageProjectionProvider {
  return (village, base, nowMs) =>
    projectVillageCatalog({
      village,
      catalog: input.catalog,
      seasonalPhases: input.seasonalPhases,
      craftTableCatalog: input.craftTableCatalog,
      base,
      nowMs,
      manualUpgradeCore: input.manualUpgradeCores[village.id] ?? null,
    });
}

export function upgradeOverviewRender(input: {
  readonly villages: readonly VillageProfile[];
  readonly catalog: GameCatalog | null | undefined;
  readonly craftTableCatalog?: CraftTableCatalog | null;
  readonly seasonalPhases?: SeasonalPhaseTable;
  readonly manualUpgradeCores?: Readonly<Record<string, ManualUpgradeCore>>;
  readonly nowMs?: number;
  readonly recentlyCompletedWindowMs?: number;
  readonly projectionProvider?: VillageProjectionProvider;
}): UpgradeOverviewRender {
  const seasonalPhases = input.seasonalPhases ?? EMPTY_SEASONAL_PHASE_TABLE;
  const manualUpgradeCores = input.manualUpgradeCores ?? {};
  const nowMs = input.nowMs ?? Date.now();
  const projectionProvider =
    input.projectionProvider ??
    defaultVillageProjectionProvider({
      catalog: input.catalog,
      craftTableCatalog: input.craftTableCatalog,
      seasonalPhases,
      manualUpgradeCores,
    });

  const records = allUpgradeOverviewRecords({
    villages: input.villages,
    catalog: input.catalog,
    craftTableCatalog: input.craftTableCatalog,
    seasonalPhases,
    manualUpgradeCores,
    nowMs,
    projectionProvider,
  });
  const active = records
    .filter((record) => isEffectivelyUpgrading(record.item))
    .sort((left, right) => activeOrder(left, right, nowMs));
  const pending = records
    .filter((record) => effectivelyNeedsReimport(record.item))
    .sort(pendingOrder);
  const state = upgradeOverviewStateCore({
    records,
    manualUpgradeCores,
    catalog: input.catalog,
    nowMs,
    recentlyCompletedWindowMs:
      input.recentlyCompletedWindowMs ?? DEFAULT_RECENTLY_COMPLETED_WINDOW_MS,
  });
  return { active, pending, state };
}

export function upgradeOverviewActiveRecords(input: {
  readonly villages: readonly VillageProfile[];
  readonly catalog: GameCatalog | null | undefined;
  readonly craftTableCatalog?: CraftTableCatalog | null;
  readonly seasonalPhases?: SeasonalPhaseTable;
  readonly manualUpgradeCores?: Readonly<Record<string, ManualUpgradeCore>>;
  readonly nowMs?: number;
}): readonly UpgradeDisplayRecord[] {
  return upgradeOverviewRecords(input).active;
}

export function upgradeOverviewRecords(input: {
  readonly villages: readonly VillageProfile[];
  readonly catalog: GameCatalog | null | undefined;
  readonly craftTableCatalog?: CraftTableCatalog | null;
  readonly seasonalPhases?: SeasonalPhaseTable;
  readonly manualUpgradeCores?: Readonly<Record<string, ManualUpgradeCore>>;
  readonly nowMs?: number;
}): { readonly active: readonly UpgradeDisplayRecord[]; readonly pending: readonly UpgradeDisplayRecord[] } {
  const seasonalPhases = input.seasonalPhases ?? EMPTY_SEASONAL_PHASE_TABLE;
  const manualUpgradeCores = input.manualUpgradeCores ?? {};
  const nowMs = input.nowMs ?? Date.now();
  const records = allUpgradeOverviewRecords({
    villages: input.villages,
    catalog: input.catalog,
    craftTableCatalog: input.craftTableCatalog,
    seasonalPhases,
    manualUpgradeCores,
    nowMs,
    projectionProvider: defaultVillageProjectionProvider({
      catalog: input.catalog,
      craftTableCatalog: input.craftTableCatalog,
      seasonalPhases,
      manualUpgradeCores,
    }),
  });
  return {
    active: records
      .filter((record) => isEffectivelyUpgrading(record.item))
      .sort((left, right) => activeOrder(left, right, nowMs)),
    pending: records
      .filter((record) => effectivelyNeedsReimport(record.item))
      .sort(pendingOrder),
  };
}

export function upgradeOverviewState(input: {
  readonly villages: readonly VillageProfile[];
  readonly catalog: GameCatalog | null | undefined;
  readonly craftTableCatalog?: CraftTableCatalog | null;
  readonly seasonalPhases?: SeasonalPhaseTable;
  readonly manualUpgradeCores?: Readonly<Record<string, ManualUpgradeCore>>;
  readonly nowMs?: number;
  readonly recentlyCompletedWindowMs?: number;
}): UpgradeOverviewState {
  const seasonalPhases = input.seasonalPhases ?? EMPTY_SEASONAL_PHASE_TABLE;
  const manualUpgradeCores = input.manualUpgradeCores ?? {};
  const nowMs = input.nowMs ?? Date.now();
  const records = allUpgradeOverviewRecords({
    villages: input.villages,
    catalog: input.catalog,
    craftTableCatalog: input.craftTableCatalog,
    seasonalPhases,
    manualUpgradeCores,
    nowMs,
    projectionProvider: defaultVillageProjectionProvider({
      catalog: input.catalog,
      craftTableCatalog: input.craftTableCatalog,
      seasonalPhases,
      manualUpgradeCores,
    }),
  });
  return upgradeOverviewStateCore({
    records,
    manualUpgradeCores,
    catalog: input.catalog,
    nowMs,
    recentlyCompletedWindowMs:
      input.recentlyCompletedWindowMs ?? DEFAULT_RECENTLY_COMPLETED_WINDOW_MS,
  });
}

function allUpgradeOverviewRecords(input: {
  readonly villages: readonly VillageProfile[];
  readonly catalog: GameCatalog | null | undefined;
  readonly craftTableCatalog?: CraftTableCatalog | null;
  readonly seasonalPhases: SeasonalPhaseTable;
  readonly manualUpgradeCores: Readonly<Record<string, ManualUpgradeCore>>;
  readonly nowMs: number;
  readonly projectionProvider: VillageProjectionProvider;
}): UpgradeDisplayRecord[] {
  return input.villages.flatMap((village) =>
    (['home', 'builder'] as const).flatMap((base) => {
      const projection = input.projectionProvider(village, base, input.nowMs);
      const tracked = projection.items.filter((item) => item.status !== 'unavailable');
      const displayRecords = tracked.filter((item) => item.status !== 'available');
      const metrics = projection.progressMetrics as VillageProgressMetrics;
      return displayRecords.map((item) => ({
        id: `${village.id}:${base}:${item.id}`,
        villageID: village.id,
        villageName: village.name,
        villageTag: village.tag ?? village.accountSnapshot?.tag ?? null,
        base,
        item,
        catalogVersion: projection.catalogVersion,
        villageMetrics: metrics,
      }));
    }),
  );
}

function upgradeOverviewStateCore(input: {
  readonly records: readonly UpgradeDisplayRecord[];
  readonly manualUpgradeCores: Readonly<Record<string, ManualUpgradeCore>>;
  readonly catalog: GameCatalog | null | undefined;
  readonly nowMs: number;
  readonly recentlyCompletedWindowMs: number;
}): UpgradeOverviewState {
  const active = input.records
    .filter((record) => isEffectivelyUpgrading(record.item))
    .sort((left, right) => activeOrder(left, right, input.nowMs));
  const needsReimportRecords = input.records
    .filter((record) => effectivelyNeedsReimport(record.item))
    .sort(pendingOrder);
  const attention = input.records.filter((record) => {
    const status = (record.item.effectiveState as EffectiveVillageItemState | undefined)?.status;
    return status === 'conflict' || status === 'unknown' || status === 'needsReimport';
  });

  const manualActiveCount = Object.values(input.manualUpgradeCores).reduce(
    (sum, core) => sum + manualActiveRecords(core).length,
    0,
  );
  const manualCompletedCount = Object.values(input.manualUpgradeCores).reduce(
    (sum, core) => sum + core.records.filter((record) => record.status === 'completed').length,
    0,
  );

  let importedActiveCount = 0;
  let deduplicatedDisplayCount = 0;
  const activeByKey = new Map<string, UpgradeDisplayRecord[]>();
  for (const record of active) {
    const key = upgradeOverviewStableKey(record.villageID, record.item);
    const bucket = activeByKey.get(key);
    if (bucket === undefined) {
      activeByKey.set(key, [record]);
    } else {
      bucket.push(record);
    }
  }
  for (const rows of activeByKey.values()) {
    const timerRows = rows.filter((row) => row.item.timerSeconds !== null);
    if (timerRows.length > 0) {
      importedActiveCount += timerRows.length;
      deduplicatedDisplayCount += timerRows.length;
    } else if (rows.length > 0) {
      deduplicatedDisplayCount += 1;
    }
  }

  const cutoffMs = input.nowMs - input.recentlyCompletedWindowMs;
  const completedRecently = Object.entries(input.manualUpgradeCores)
    .flatMap(([villageID, core]) =>
      core.records.flatMap((record) => {
        if (record.status !== 'completed' || record.expectedEndAtMs < cutoffMs) {
          return [];
        }
        const name =
          input.catalog?.item(record.itemKey.rawSection, record.itemKey.dataID)?.name ??
          trackerItemKeyStableId(record.itemKey);
        const completion: UpgradeRecentCompletion = {
          villageID,
          itemKey: record.itemKey,
          itemName: name,
          targetLevel: record.targetLevel,
          quantity: record.quantity,
          completedAtMs: record.expectedEndAtMs,
          id: '',
        };
        return [{ ...completion, id: upgradeRecentCompletionId(completion) }];
      }),
    )
    .sort((left, right) => right.completedAtMs - left.completedAtMs);

  return {
    manualActiveCount,
    importedActiveCount,
    deduplicatedDisplayCount,
    manualCompletedCount,
    completedRecently,
    activeRecords: active,
    attentionRecords: attention,
    needsReimportRecords,
  };
}

function activeOrder(
  left: UpgradeDisplayRecord,
  right: UpgradeDisplayRecord,
  nowMs: number,
): number {
  const leftRemaining = effectiveRemainingSeconds(left.item, nowMs) ?? BigInt(Number.MAX_SAFE_INTEGER);
  const rightRemaining =
    effectiveRemainingSeconds(right.item, nowMs) ?? BigInt(Number.MAX_SAFE_INTEGER);
  if (leftRemaining !== rightRemaining) {
    return leftRemaining < rightRemaining ? -1 : 1;
  }
  const villageOrder = left.villageName.localeCompare(right.villageName, undefined, {
    sensitivity: 'base',
  });
  if (villageOrder !== 0) {
    return villageOrder;
  }
  if (left.base !== right.base) {
    return left.base < right.base ? -1 : 1;
  }
  return left.id.localeCompare(right.id);
}

function pendingOrder(left: UpgradeDisplayRecord, right: UpgradeDisplayRecord): number {
  const villageOrder = left.villageName.localeCompare(right.villageName, undefined, {
    sensitivity: 'base',
  });
  if (villageOrder !== 0) {
    return villageOrder;
  }
  if (left.base !== right.base) {
    return left.base < right.base ? -1 : 1;
  }
  const nameOrder = left.item.name.localeCompare(right.item.name, undefined, {
    sensitivity: 'base',
  });
  if (nameOrder !== 0) {
    return nameOrder;
  }
  return left.id.localeCompare(right.id);
}

function upgradeOverviewStableKey(villageID: string, item: VillageItemState): string {
  const state = item.effectiveState as EffectiveVillageItemState | undefined;
  const key = state?.itemKey ?? trackerItemKeyRoot(item.base, item.section, item.dataID);
  return `${villageID}:${trackerItemKeyStableId(key)}`;
}

function isEffectivelyUpgrading(item: VillageItemState): boolean {
  const state = item.effectiveState as EffectiveVillageItemState | undefined;
  if (state === undefined) {
    return isUpgrading(item);
  }
  return state.status === 'manualActive' || state.status === 'importedActive';
}

function effectivelyNeedsReimport(item: VillageItemState): boolean {
  const state = item.effectiveState as EffectiveVillageItemState | undefined;
  if (state === undefined) {
    return needsReimport(item);
  }
  if (state.status === 'manualCompleted' || state.status === 'manualActive') {
    return false;
  }
  return needsReimport(item);
}

function effectiveRemainingSeconds(
  item: VillageItemState,
  nowMs: number,
): bigint | null | undefined {
  const state = item.effectiveState as EffectiveVillageItemState | undefined;
  if (state === undefined) {
    return item.remainingSeconds;
  }
  switch (state.status) {
    case 'manualActive': {
      if (state.activeManualRecords.length !== 1) {
        return null;
      }
      const active = state.activeManualRecords[0];
      if (active === undefined) {
        return null;
      }
      const intervalMs = active.expectedEndAtMs - nowMs;
      if (!Number.isFinite(intervalMs)) {
        return null;
      }
      const seconds = Math.floor(intervalMs / 1000);
      if (seconds < Number.MIN_SAFE_INTEGER || seconds >= Number.MAX_SAFE_INTEGER) {
        return null;
      }
      return BigInt(Math.max(0, seconds));
    }
    case 'importedActive':
      return item.remainingSeconds;
    case 'observed':
    case 'manualCompleted':
    case 'needsReimport':
    case 'unknown':
    case 'conflict':
    case 'unavailable':
      return null;
  }
}
