import { parseCanonicalizerInt64, parseJson, type CanonicalJsonValue } from '@coc-helper/wire';

import type {
  CatalogAssetRef,
  CatalogCounts,
  CatalogGeneratedFile,
  CatalogItem,
  CatalogLevel,
  CatalogLifecycle,
  CatalogManifest,
  CatalogUpgradeCost,
} from './types';

function requireField(
  fields: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  label: string,
): CanonicalJsonValue {
  const value = fields[key];
  if (value === undefined) {
    throw new TypeError(`${label}.${key} 缺失。`);
  }
  return value;
}

function requireObject(
  value: CanonicalJsonValue,
  label: string,
): Extract<CanonicalJsonValue, { kind: 'object' }> {
  if (value.kind !== 'object') {
    throw new TypeError(`${label} 必须是 object。`);
  }
  return value;
}

function optionalString(value: CanonicalJsonValue | undefined): string | null {
  if (value === undefined || value.kind === 'null') {
    return null;
  }
  if (value.kind !== 'string') {
    throw new TypeError('期望 string 或 null。');
  }
  return value.value;
}

function requireString(value: CanonicalJsonValue | undefined, label: string): string {
  if (value === undefined || value.kind !== 'string') {
    throw new TypeError(`${label} 必须是 string。`);
  }
  return value.value;
}

function optionalInt(value: CanonicalJsonValue | undefined): number | null {
  if (value === undefined || value.kind === 'null') {
    return null;
  }
  if (value.kind !== 'number') {
    throw new TypeError('期望 number 或 null。');
  }
  const parsed = Number(value.value);
  if (!Number.isInteger(parsed)) {
    throw new TypeError('期望整数。');
  }
  return parsed;
}

function requireInt(value: CanonicalJsonValue | undefined, label: string): number {
  const parsed = optionalInt(value);
  if (parsed === null) {
    throw new TypeError(`${label} 必须是 number。`);
  }
  return parsed;
}

function optionalInt64(value: CanonicalJsonValue | undefined): bigint | null {
  if (value === undefined || value.kind === 'null') {
    return null;
  }
  const parsed = parseCanonicalizerInt64(value);
  if (parsed === undefined) {
    throw new TypeError('期望整数或 null。');
  }
  return parsed;
}

function optionalBool(value: CanonicalJsonValue | undefined): boolean | null {
  if (value === undefined || value.kind === 'null') {
    return null;
  }
  if (value.kind !== 'bool') {
    throw new TypeError('期望 bool 或 null。');
  }
  return value.value;
}

function decodeAssetRef(value: CanonicalJsonValue | undefined): CatalogAssetRef | null {
  if (value === undefined || value.kind === 'null') {
    return null;
  }
  const object = requireObject(value, 'CatalogAssetRef');
  return {
    container: optionalString(object.fields.container),
    exportName: optionalString(object.fields.exportName),
    renderedPath: optionalString(object.fields.renderedPath),
    missingReason: optionalString(object.fields.missingReason),
  };
}

function decodeUpgradeCost(value: CanonicalJsonValue): CatalogUpgradeCost {
  const object = requireObject(value, 'CatalogUpgradeCost');
  return {
    resource: requireString(object.fields.resource, 'resource'),
    amount: optionalInt64(object.fields.amount),
    rawResource: optionalString(object.fields.rawResource),
    rawAmount: optionalString(object.fields.rawAmount),
    parseFailed: optionalBool(object.fields.parseFailed) ?? false,
  };
}

function decodeLevel(value: CanonicalJsonValue): CatalogLevel {
  const object = requireObject(value, 'CatalogLevel');
  const upgradeCostsRaw = object.fields.upgradeCosts;
  let upgradeCosts: readonly CatalogUpgradeCost[] | null = null;
  if (upgradeCostsRaw !== undefined && upgradeCostsRaw.kind !== 'null') {
    if (upgradeCostsRaw.kind !== 'array') {
      throw new TypeError('upgradeCosts 必须是 array 或 null。');
    }
    upgradeCosts = upgradeCostsRaw.items.map(decodeUpgradeCost);
  }
  return {
    level: requireInt(object.fields.level, 'level'),
    durationSeconds: optionalInt64(object.fields.durationSeconds),
    upgradeCosts,
    requiredTownHallLevel: optionalInt(object.fields.requiredTownHallLevel),
    requiredLaboratoryLevel: optionalInt(object.fields.requiredLaboratoryLevel),
    requiredHeroTavernLevel: optionalInt(object.fields.requiredHeroTavernLevel),
    requiredBlacksmithLevel: optionalInt(object.fields.requiredBlacksmithLevel),
    icon: decodeAssetRef(object.fields.icon),
    levelVisual: decodeAssetRef(object.fields.levelVisual),
    missingReason: optionalString(object.fields.missingReason),
  };
}

function decodeLifecycle(value: CanonicalJsonValue | undefined): CatalogLifecycle | null {
  const raw = optionalString(value);
  if (raw === null) {
    return null;
  }
  if (raw === 'permanent' || raw === 'seasonalCandidate') {
    return raw;
  }
  throw new TypeError(`未知 lifecycle: ${raw}`);
}

export function decodeCatalogItem(value: CanonicalJsonValue): CatalogItem {
  const object = requireObject(value, 'CatalogItem');
  const levelsRaw = object.fields.levels;
  if (levelsRaw === undefined || levelsRaw.kind !== 'array') {
    throw new TypeError('levels 必须是 array。');
  }
  const dataID = parseCanonicalizerInt64(object.fields.dataID);
  if (dataID === undefined) {
    throw new TypeError('dataID 必须是整数。');
  }
  return {
    section: requireString(object.fields.section, 'section'),
    category: requireString(object.fields.category, 'category'),
    dataID,
    base: optionalString(object.fields.base),
    baseMissingReason: optionalString(object.fields.baseMissingReason),
    name: requireString(object.fields.name, 'name'),
    maxLevel: requireInt(object.fields.maxLevel, 'maxLevel'),
    icon: decodeAssetRef(object.fields.icon),
    levelVisual: decodeAssetRef(object.fields.levelVisual),
    missingReason: optionalString(object.fields.missingReason),
    displayCategory: optionalString(object.fields.displayCategory),
    lifecycle: decodeLifecycle(object.fields.lifecycle),
    levels: levelsRaw.items.map(decodeLevel),
  };
}

function decodeGeneratedFile(value: CanonicalJsonValue): CatalogGeneratedFile {
  const object = requireObject(value, 'CatalogGeneratedFile');
  return {
    path: requireString(object.fields.path, 'path'),
    sha256: optionalString(object.fields.sha256) ?? undefined,
    size: optionalInt(object.fields.size) ?? undefined,
    kind: optionalString(object.fields.kind) ?? undefined,
    entries: optionalInt(object.fields.entries) ?? undefined,
  };
}

function decodeCounts(value: CanonicalJsonValue): CatalogCounts {
  const object = requireObject(value, 'CatalogCounts');
  return {
    items: requireInt(object.fields.items, 'items'),
    levels: requireInt(object.fields.levels, 'levels'),
    missingIcons: optionalInt(object.fields.missingIcons) ?? undefined,
    missingTime: optionalInt(object.fields.missingTime) ?? undefined,
    timed: optionalInt(object.fields.timed) ?? undefined,
    instant: optionalInt(object.fields.instant) ?? undefined,
    notApplicable: optionalInt(object.fields.notApplicable) ?? undefined,
    initialLevel: optionalInt(object.fields.initialLevel) ?? undefined,
    sourceMissing: optionalInt(object.fields.sourceMissing) ?? undefined,
    parseFailed: optionalInt(object.fields.parseFailed) ?? undefined,
  };
}

export function decodeCatalogManifest(value: CanonicalJsonValue): CatalogManifest {
  const object = requireObject(value, 'CatalogManifest');
  const generatedFilesRaw = object.fields.generatedFiles;
  if (generatedFilesRaw === undefined || generatedFilesRaw.kind !== 'array') {
    throw new TypeError('generatedFiles 必须是 array。');
  }
  return {
    schemaVersion: requireInt(object.fields.schemaVersion, 'schemaVersion'),
    gameVersion: requireString(object.fields.gameVersion, 'gameVersion'),
    buildTag: requireString(object.fields.buildTag, 'buildTag'),
    locale: requireString(object.fields.locale, 'locale'),
    sourceFingerprint: requireString(object.fields.sourceFingerprint, 'sourceFingerprint'),
    generatedFiles: generatedFilesRaw.items.map(decodeGeneratedFile),
    counts: decodeCounts(requireField(object.fields, 'counts', 'CatalogManifest')),
  };
}

export function decodeCatalogPayload(text: string): {
  readonly gameVersion: string;
  readonly items: readonly CatalogItem[];
  readonly instanceCounts: Readonly<Record<string, readonly number[]>> | null;
} {
  const root = parseJson(text);
  const object = requireObject(root, 'catalog payload');
  const itemsRaw = object.fields.items;
  if (itemsRaw === undefined || itemsRaw.kind !== 'array') {
    throw new TypeError('items 必须是 array。');
  }
  let instanceCounts: Readonly<Record<string, readonly number[]>> | null = null;
  const countsRaw = object.fields.instanceCounts;
  if (countsRaw !== undefined && countsRaw.kind !== 'null') {
    if (countsRaw.kind !== 'object') {
      throw new TypeError('instanceCounts 必须是 object 或 null。');
    }
    const decoded: Record<string, readonly number[]> = Object.create(null);
    for (const [key, entry] of Object.entries(countsRaw.fields) as Array<
      [string, CanonicalJsonValue]
    >) {
      if (entry.kind !== 'array') {
        throw new TypeError(`instanceCounts.${key} 必须是 array。`);
      }
      decoded[key] = entry.items.map((item) => {
        const value = optionalInt(item);
        if (value === null) {
          throw new TypeError(`instanceCounts.${key} 元素必须是整数。`);
        }
        return value;
      });
    }
    instanceCounts = decoded;
  }
  return {
    gameVersion: requireString(object.fields.gameVersion, 'gameVersion'),
    items: itemsRaw.items.map(decodeCatalogItem),
    instanceCounts,
  };
}

export function decodeJsonFile<T>(text: string, decode: (value: CanonicalJsonValue) => T): T {
  return decode(parseJson(text));
}
