import { sha256Fingerprint } from '@coc-helper/wire';

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
  readonly sourceFingerprint: string | null;
  readonly defenses: readonly CraftTableDefenseSpec[];
  readonly modules: readonly CraftTableModuleSpec[];
  readonly defense: (dataID: bigint) => CraftTableDefenseSpec | undefined;
  readonly module: (dataID: bigint) => CraftTableModuleSpec | undefined;
};

export function craftTableIntegrityOk(
  manifestData: Uint8Array | string,
  craftData: Uint8Array | string,
): boolean {
  let manifest: CatalogManifest;
  try {
    manifest = decodeJsonFile(toText(manifestData), decodeCatalogManifest);
  } catch {
    return false;
  }
  if (!validSourceFingerprint(manifest.sourceFingerprint)) {
    return false;
  }
  const craftEntries = manifest.generatedFiles.filter(
    (file) => file.path === 'craft_table_catalog.json',
  );
  if (craftEntries.length !== 1) {
    return false;
  }
  const entry = craftEntries[0]!;
  if (
    entry.sha256 === undefined ||
    !entry.sha256.startsWith('sha256:') ||
    entry.size === undefined
  ) {
    return false;
  }
  const craftBytes = toBytes(craftData);
  if (entry.size !== craftBytes.length) {
    return false;
  }
  const actual = sha256Fingerprint(craftBytes).slice('sha256:'.length);
  const declared = entry.sha256.slice('sha256:'.length);
  return declared === actual;
}

function toText(data: Uint8Array | string): string {
  return typeof data === 'string' ? data : new TextDecoder().decode(data);
}

function toBytes(data: Uint8Array | string): Uint8Array {
  return typeof data === 'string' ? new TextEncoder().encode(data) : data;
}

function validSourceFingerprint(value: string): boolean {
  const hex = value.slice('sha256:'.length);
  return value.startsWith('sha256:') && hex.length === 64 && /^[0-9a-fA-F]+$/.test(hex);
}

export function createCraftTableCatalog(input: {
  readonly schemaVersion: number;
  readonly gameVersion: string;
  readonly buildTag: string;
  readonly locale: string;
  readonly source: string;
  readonly sourceFingerprint?: string | null;
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
    sourceFingerprint: input.sourceFingerprint ?? null,
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
  if (!craftTableIntegrityOk(input.manifestText, input.craftText)) {
    return null;
  }
  const catalog = decodeCraftTableCatalog(input.craftText);
  let manifest: CatalogManifest;
  try {
    manifest = decodeJsonFile(input.manifestText, decodeCatalogManifest);
  } catch {
    return null;
  }
  if (
    catalog.schemaVersion !== 1 ||
    catalog.gameVersion !== input.version ||
    manifest.gameVersion !== catalog.gameVersion
  ) {
    return null;
  }
  return createCraftTableCatalog({
    ...catalog,
    sourceFingerprint: manifest.sourceFingerprint,
  });
}
