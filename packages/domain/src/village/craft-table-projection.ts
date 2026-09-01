import type { AccountItem, AccountSnapshot } from '../account';
import type { CraftTableCatalog } from '../catalog/craft-table';
import type { CatalogAvailability, SeasonalPhaseTable } from '../catalog/seasonal-phase';
import { CRAFT_TABLE_DATA_ID } from './display-category';
import { liveRemainingSeconds, refreshTimerDelta } from './catalog-projection';
import type { TrackerBase } from './tracker';
import type { VillageProfile } from '../import/types';

export type CraftTableModuleStatus = 'recorded' | 'upgrading' | 'maxed' | 'unknown';

export type CraftTableModuleState = {
  readonly id: string;
  readonly dataID: bigint;
  readonly name: string;
  readonly statTypes: readonly string[];
  readonly displayTitles: readonly string[];
  readonly currentLevel: number | null;
  readonly maxLevel: number | null;
  readonly status: CraftTableModuleStatus;
  readonly timerSeconds: bigint | null;
  readonly remainingSeconds: bigint | null;
  readonly missingReason: string | null;
};

export type CraftTableDefenseState = {
  readonly id: string;
  readonly dataID: bigint;
  readonly name: string;
  readonly currentLevel: number | null;
  readonly availability: CatalogAvailability;
  readonly modules: readonly CraftTableModuleState[];
};

export function projectCraftTable(input: {
  readonly village: VillageProfile;
  readonly catalog: CraftTableCatalog | null | undefined;
  readonly base: TrackerBase;
  readonly seasonalPhases: SeasonalPhaseTable;
  readonly nowMs: number;
}): CraftTableDefenseState[] {
  if (input.base !== 'home') {
    return [];
  }
  const snapshot = input.village.accountSnapshot;
  if (snapshot === null || snapshot === undefined) {
    return [];
  }
  const craftTable = snapshot.objectSections.buildings?.find(
    (item) => item.dataID === CRAFT_TABLE_DATA_ID,
  );
  if (craftTable === undefined) {
    return [];
  }

  return craftTable.types.map((defense) => {
    const defenseSpec = input.catalog?.defense(defense.dataID);
    const modules = defense.modules.map((module) =>
      makeCraftTableModule({
        item: module,
        parentID: defense.id,
        snapshot,
        catalog: input.catalog,
        nowMs: input.nowMs,
      }),
    );
    const observedIDs = new Set(defense.modules.map((module) => module.dataID));
    for (const moduleID of defenseSpec?.moduleIDs ?? []) {
      if (!observedIDs.has(moduleID)) {
        modules.push(
          makeMissingCraftTableModule({
            dataID: moduleID,
            parentID: defense.id,
            catalog: input.catalog,
          }),
        );
      }
    }
    return {
      id: defense.id,
      dataID: defense.dataID,
      name: defenseSpec?.name ?? accountItemName(defense),
      currentLevel: defense.level,
      availability: input.seasonalPhases.availability(
        `buildings:${defense.dataID}`,
        defenseSpec?.lifecycle ?? null,
        input.nowMs,
      ),
      modules,
    };
  });
}

export function craftTableModuleWithRemainingSeconds(
  module: CraftTableModuleState,
  remainingSeconds: bigint | null,
): CraftTableModuleState {
  return { ...module, remainingSeconds };
}

export function refreshingCraftTableModules(
  modules: readonly CraftTableDefenseState[],
  input: {
    readonly nowMs: number;
    readonly builtAtMs: number;
    readonly importedAtMs: number;
  },
): { readonly modules: CraftTableDefenseState[]; readonly expired: boolean } {
  const delta = refreshTimerDelta(input.nowMs, input.builtAtMs, input.importedAtMs);
  let expired = false;
  const refreshed = modules.map((defense) => ({
    ...defense,
    modules: defense.modules.map((module) => {
      if (module.remainingSeconds === null || module.remainingSeconds <= 0n) {
        return module;
      }
      const newRemaining =
        module.remainingSeconds - delta >= 0n ? module.remainingSeconds - delta : 0n;
      if (newRemaining === 0n) {
        expired = true;
      }
      return craftTableModuleWithRemainingSeconds(module, newRemaining);
    }),
  }));
  return { modules: refreshed, expired };
}

function makeCraftTableModule(input: {
  readonly item: AccountItem;
  readonly parentID: string;
  readonly snapshot: AccountSnapshot;
  readonly catalog: CraftTableCatalog | null | undefined;
  readonly nowMs: number;
}): CraftTableModuleState {
  const spec = input.catalog?.module(input.item.dataID);
  const remaining = liveRemainingSeconds(input.item, input.snapshot, input.nowMs);
  let status: CraftTableModuleStatus;
  if ((remaining ?? 0n) > 0n) {
    status = 'upgrading';
  } else if (spec !== undefined) {
    status = 'recorded';
  } else {
    status = 'unknown';
  }
  return {
    id: input.item.id,
    dataID: input.item.dataID,
    name: spec?.name ?? accountItemName(input.item),
    statTypes: [],
    displayTitles: [],
    currentLevel: input.item.level,
    maxLevel: null,
    status,
    timerSeconds: input.item.timerSeconds,
    remainingSeconds: remaining,
    missingReason: spec === undefined ? '版本化精制台目录未收录该模组' : null,
  };
}

function makeMissingCraftTableModule(input: {
  readonly dataID: bigint;
  readonly parentID: string;
  readonly catalog: CraftTableCatalog | null | undefined;
}): CraftTableModuleState {
  const spec = input.catalog?.module(input.dataID);
  return {
    id: `${input.parentID}:module:${input.dataID}`,
    dataID: input.dataID,
    name: spec?.name ?? `未记录模组 #${input.dataID}`,
    statTypes: [],
    displayTitles: [],
    currentLevel: null,
    maxLevel: null,
    status: 'unknown',
    timerSeconds: null,
    remainingSeconds: null,
    missingReason: '快照未包含该模组',
  };
}

function accountItemName(item: AccountItem): string {
  return `#${item.dataID.toString()}`;
}
