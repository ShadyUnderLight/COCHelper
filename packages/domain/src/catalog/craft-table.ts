import { decodeCatalogManifest, decodeJsonFile } from './json-decode';
import type { CatalogManifest } from './types';

export type CraftTableDefenseSpec = {
  readonly dataID: bigint;
  readonly name: string;
  readonly sourceName: string;
  readonly specialAbility: string;
  readonly moduleIDs: readonly bigint[];
  readonly totalModuleLevelThresholds: readonly number[];
  readonly lifecycle: 'permanent' | 'seasonalCandidate' | null;
};

export type CraftTableModuleSpec = {
  readonly dataID: bigint;
  readonly name: string;
  readonly sourceName: string;
  readonly lifecycle: 'permanent' | 'seasonalCandidate' | null;
};

export type CraftTableCatalog = {
  readonly schemaVersion: number;
  readonly gameVersion: string;
  readonly buildTag: string;
  readonly locale: string;
  readonly source: string;
  readonly defenses: readonly CraftTableDefenseSpec[];
  readonly modules: readonly CraftTableModuleSpec[];
  readonly defense: (dataID: bigint) => CraftTableDefenseSpec | undefined;
  readonly module: (dataID: bigint) => CraftTableModuleSpec | undefined;
};

export function createCraftTableCatalog(input: {
  readonly schemaVersion: number;
  readonly gameVersion: string;
  readonly buildTag: string;
  readonly locale: string;
  readonly source: string;
  readonly defenses: readonly CraftTableDefenseSpec[];
  readonly modules: readonly CraftTableModuleSpec[];
}): CraftTableCatalog {
  const defenses = [...input.defenses];
  const modules = [...input.modules];
  return {
    schemaVersion: input.schemaVersion,
    gameVersion: input.gameVersion,
    buildTag: input.buildTag,
    locale: input.locale,
    source: input.source,
    defenses,
    modules,
    defense(dataID: bigint) {
      return defenses.find((defense) => defense.dataID === dataID);
    },
    module(dataID: bigint) {
      return modules.find((module) => module.dataID === dataID);
    },
  };
}

export function decodeCraftTableCatalog(text: string): CraftTableCatalog {
  const payload = JSON.parse(text) as {
    schemaVersion: number;
    gameVersion: string;
    buildTag: string;
    locale?: string;
    source?: string;
    defenses: Array<Record<string, unknown>>;
    modules: Array<Record<string, unknown>>;
  };
  return createCraftTableCatalog({
    schemaVersion: payload.schemaVersion,
    gameVersion: payload.gameVersion,
    buildTag: payload.buildTag,
    locale: payload.locale ?? 'zh-CN',
    source: payload.source ?? '',
    defenses: payload.defenses.map(decodeDefense),
    modules: payload.modules.map(decodeModule),
  });
}

function decodeDefense(raw: Record<string, unknown>): CraftTableDefenseSpec {
  return {
    dataID: BigInt(raw.dataID as number | string | bigint),
    name: String(raw.name),
    sourceName: String(raw.sourceName),
    specialAbility: String(raw.specialAbility),
    moduleIDs: (raw.moduleIDs as Array<number | string>).map((value) => BigInt(value)),
    totalModuleLevelThresholds: (raw.totalModuleLevelThresholds as number[]).map(Number),
    lifecycle: decodeLifecycle(raw.lifecycle),
  };
}

function decodeModule(raw: Record<string, unknown>): CraftTableModuleSpec {
  return {
    dataID: BigInt(raw.dataID as number | string | bigint),
    name: String(raw.name),
    sourceName: String(raw.sourceName),
    lifecycle: decodeLifecycle(raw.lifecycle),
  };
}

function decodeLifecycle(value: unknown): 'permanent' | 'seasonalCandidate' | null {
  if (value === 'permanent' || value === 'seasonalCandidate') {
    return value;
  }
  return null;
}

export function loadCraftTableCatalog(input: {
  readonly version: string;
  readonly manifestText: string;
  readonly craftText: string;
}): CraftTableCatalog | null {
  let catalog: CraftTableCatalog;
  try {
    catalog = decodeCraftTableCatalog(input.craftText);
  } catch {
    return null;
  }
  let manifest: CatalogManifest;
  try {
    manifest = decodeJsonFile(input.manifestText, decodeCatalogManifest);
  } catch {
    return null;
  }
  if (
    catalog.schemaVersion !== 1 ||
    catalog.gameVersion !== input.version ||
    manifest.schemaVersion !== 3 ||
    manifest.gameVersion !== catalog.gameVersion ||
    // E0-03/Issue #303：hash 绑定撤销后，buildTag 等值是防不同版本数据
    // 静默套用的业务门（同 gameVersion 不同 buildTag 必须拒绝）。
    manifest.buildTag !== catalog.buildTag
  ) {
    return null;
  }
  return createCraftTableCatalog({ ...catalog });
}
