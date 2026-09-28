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

export type CraftTableModuleLevelSpec = {
  readonly level: number;
  readonly requiredTownHallLevel: number | null;
};

export type CraftTableModuleSpec = {
  readonly dataID: bigint;
  readonly name: string;
  readonly sourceName: string;
  readonly statTypes: readonly string[];
  readonly displayTitles: readonly string[];
  readonly maxLevel: number;
  readonly levels: readonly CraftTableModuleLevelSpec[];
  readonly lifecycle: 'permanent' | 'seasonalCandidate' | null;
};

export type CraftTableModuleLevelAssessment = {
  readonly currentStageMaxLevel: number | null;
  readonly status: 'complete' | 'maxed' | 'unknown';
  readonly missingReason: string | null;
};

export function craftTableModuleStageMaxLevel(
  module: CraftTableModuleSpec,
  townHallLevel: number | null,
): number | null {
  if (
    townHallLevel === null ||
    !Number.isSafeInteger(module.maxLevel) ||
    module.maxLevel < 1 ||
    module.levels.length !== module.maxLevel
  ) {
    return null;
  }

  const levels = [...module.levels].sort((left, right) => left.level - right.level);
  if (
    !levels.every(
      (level, index) =>
        level.level === index + 1 &&
        level.requiredTownHallLevel !== null &&
        Number.isSafeInteger(level.requiredTownHallLevel) &&
        level.requiredTownHallLevel >= 1,
    )
  ) {
    return null;
  }

  let highest: number | null = null;
  for (const level of levels) {
    const requiredTownHallLevel = level.requiredTownHallLevel;
    if (requiredTownHallLevel === null || requiredTownHallLevel > townHallLevel) {
      break;
    }
    highest = level.level;
  }
  return highest;
}

export function assessCraftTableModuleLevel(
  module: CraftTableModuleSpec,
  currentLevel: number | null,
  townHallLevel: number | null,
): CraftTableModuleLevelAssessment {
  const currentStageMaxLevel = craftTableModuleStageMaxLevel(module, townHallLevel);
  if (
    !Number.isSafeInteger(module.maxLevel) ||
    module.maxLevel < 1 ||
    currentLevel === null ||
    !Number.isSafeInteger(currentLevel) ||
    currentLevel < 1 ||
    currentLevel > module.maxLevel
  ) {
    return {
      currentStageMaxLevel,
      status: 'unknown',
      missingReason: '精工防御模组等级与目录上限不匹配。',
    };
  }

  if (townHallLevel === null) {
    return {
      currentStageMaxLevel: null,
      status: 'unknown',
      missingReason: '快照缺少大本营等级，无法验证精工防御模组的当前阶段上限。',
    };
  }
  if (currentStageMaxLevel === null) {
    return {
      currentStageMaxLevel: null,
      status: 'unknown',
      missingReason: '无法从精工防御目录验证当前大本营等级对应的模组上限。',
    };
  }
  if (currentLevel > currentStageMaxLevel) {
    return {
      currentStageMaxLevel,
      status: 'unknown',
      missingReason: '快照中的精工防御模组等级高于当前大本营允许的目录上限。',
    };
  }
  if (currentLevel === currentStageMaxLevel) {
    return { currentStageMaxLevel, status: 'maxed', missingReason: null };
  }
  return { currentStageMaxLevel, status: 'complete', missingReason: null };
}

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
    statTypes: (raw.statTypes as string[]).map(String),
    displayTitles: (raw.displayTitles as string[]).map(String),
    maxLevel: Number(raw.maxLevel),
    levels: (raw.levels as Array<Record<string, unknown>>).map((level) => ({
      level: Number(level.level),
      requiredTownHallLevel: nullableNumber(level.requiredTownHallLevel),
    })),
    lifecycle: decodeLifecycle(raw.lifecycle),
  };
}

function nullableNumber(value: unknown): number | null {
  return value === null || value === undefined ? null : Number(value);
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
