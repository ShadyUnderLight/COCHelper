import { parseLegacyInt64, parseJson, type CanonicalJsonValue } from '@coc-helper/wire';

import {
  COVERAGE_CONTRACT_FIELD,
  NUMERIC_SECTION_NAMES,
  OBJECT_SECTION_NAMES,
  type AccountSnapshotImportError,
} from './types';

export type RawAccountItem = {
  readonly dataID: bigint;
  readonly level: number | null;
  readonly count: number | null;
  readonly timerSeconds: bigint | null;
  readonly helperTimerSeconds: bigint | null;
  readonly helperCooldownSeconds: bigint | null;
  readonly helperRecurrent: boolean;
  readonly gearUp: number | null;
  readonly weapon: number | null;
  readonly types: readonly RawAccountItem[];
  readonly modules: readonly RawAccountItem[];
};

export type RawAccountDocument = {
  readonly tag: string | null;
  readonly timestamp: bigint | null;
  readonly objectSections: Readonly<Record<string, readonly RawAccountItem[]>>;
  readonly numericSections: Readonly<Record<string, readonly bigint[]>>;
  readonly boosts: Readonly<Record<string, bigint>>;
  readonly unknownTopLevelKeys: readonly string[];
};

export function decodeRawAccountDocument(
  preparedText: string,
): RawAccountDocument | AccountSnapshotImportError {
  let root: CanonicalJsonValue;
  try {
    root = parseJson(preparedText);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { kind: 'invalidJSON', message: `${message}。` };
  }

  if (root.kind !== 'object') {
    return { kind: 'invalidJSON', message: '顶层必须是对象。' };
  }

  let tag: string | null = null;
  let timestamp: bigint | null = null;
  const objectSections: Record<string, RawAccountItem[]> = {};
  const numericSections: Record<string, bigint[]> = {};
  const boosts: Record<string, bigint> = {};
  const unknownTopLevelKeys: string[] = [];

  for (const key of Object.keys(root.fields).sort()) {
    const value = root.fields[key]!;
    switch (key) {
      case 'tag':
        tag = decodeOptionalString(value);
        break;
      case 'timestamp': {
        const decoded = decodeTimestamp(value, key);
        if (isImportError(decoded)) {
          return decoded;
        }
        timestamp = decoded;
        break;
      }
      case 'boosts': {
        const decoded = decodeBoosts(value);
        if (isImportError(decoded)) {
          return decoded;
        }
        if (decoded !== undefined) {
          Object.assign(boosts, decoded);
        }
        break;
      }
      case COVERAGE_CONTRACT_FIELD:
        break;
      default:
        if (OBJECT_SECTION_NAMES.has(key)) {
          const decoded = decodeObjectSection(value, key);
          if (isImportError(decoded)) {
            return decoded;
          }
          objectSections[key] = decoded;
        } else if (NUMERIC_SECTION_NAMES.has(key)) {
          const decoded = decodeNumericSection(value, key);
          if (isImportError(decoded)) {
            return decoded;
          }
          numericSections[key] = decoded;
        } else {
          unknownTopLevelKeys.push(key);
        }
        break;
    }
  }

  return {
    tag,
    timestamp,
    objectSections,
    numericSections,
    boosts,
    unknownTopLevelKeys,
  };
}

function decodeTimestamp(
  value: CanonicalJsonValue,
  path: string,
): bigint | null | AccountSnapshotImportError {
  const result = parseLegacyInt64(value);
  if (result.ok) {
    return result.value;
  }
  if (result.reason === 'missing') {
    return null;
  }
  return {
    kind: 'invalidJSON',
    message: `字段必须是整数（${path}）。`,
  };
}

function decodeOptionalString(value: CanonicalJsonValue): string | null {
  if (value.kind === 'null') {
    return null;
  }
  if (value.kind === 'string') {
    return value.value;
  }
  return null;
}

function decodeBoosts(
  value: CanonicalJsonValue,
): Readonly<Record<string, bigint>> | AccountSnapshotImportError | undefined {
  if (value.kind === 'null') {
    return undefined;
  }
  if (value.kind !== 'object') {
    return { kind: 'invalidJSON', message: 'boosts 必须是对象。' };
  }
  const boosts: Record<string, bigint> = {};
  for (const key of Object.keys(value.fields).sort()) {
    const decoded = decodeInt64Field(value.fields[key]!, `boosts.${key}`);
    if (isImportError(decoded)) {
      return decoded;
    }
    if (decoded !== null) {
      boosts[key] = decoded;
    }
  }
  return boosts;
}

function decodeObjectSection(
  value: CanonicalJsonValue,
  section: string,
): RawAccountItem[] | AccountSnapshotImportError {
  if (value.kind === 'null') {
    return [];
  }
  if (value.kind !== 'array') {
    return { kind: 'invalidJSON', message: `${section} 必须是数组。` };
  }
  const items: RawAccountItem[] = [];
  for (let index = 0; index < value.items.length; index += 1) {
    const decoded = decodeRawAccountItem(value.items[index]!, `${section}[${index}]`);
    if (isImportError(decoded)) {
      return decoded;
    }
    items.push(decoded);
  }
  return items;
}

function decodeNumericSection(
  value: CanonicalJsonValue,
  section: string,
): bigint[] | AccountSnapshotImportError {
  if (value.kind === 'null') {
    return [];
  }
  if (value.kind !== 'array') {
    return { kind: 'invalidJSON', message: `${section} 必须是数组。` };
  }
  const values: bigint[] = [];
  for (let index = 0; index < value.items.length; index += 1) {
    const decoded = decodeInt64Field(value.items[index]!, `${section}[${index}]`);
    if (isImportError(decoded)) {
      return decoded;
    }
    if (decoded === null) {
      return { kind: 'invalidJSON', message: `字段必须是整数（${section}[${index}]）。` };
    }
    values.push(decoded);
  }
  return values;
}

function decodeRawAccountItem(
  value: CanonicalJsonValue,
  path: string,
): RawAccountItem | AccountSnapshotImportError {
  if (value.kind !== 'object') {
    return { kind: 'invalidJSON', message: `${path} 必须是对象。` };
  }

  const dataResult = parseLegacyInt64(value.fields.data);
  if (!dataResult.ok) {
    return {
      kind: 'invalidJSON',
      message: `缺少字段 data（${path}）。`,
    };
  }

  const types: RawAccountItem[] = [];
  const typesValue = value.fields.types;
  if (typesValue !== undefined && typesValue.kind !== 'null') {
    if (typesValue.kind !== 'array') {
      return { kind: 'invalidJSON', message: `${path}.types 必须是数组。` };
    }
    for (let index = 0; index < typesValue.items.length; index += 1) {
      const decoded = decodeRawAccountItem(typesValue.items[index]!, `${path}.types.${index}`);
      if (isImportError(decoded)) {
        return decoded;
      }
      types.push(decoded);
    }
  }

  const modules: RawAccountItem[] = [];
  const modulesValue = value.fields.modules;
  if (modulesValue !== undefined && modulesValue.kind !== 'null') {
    if (modulesValue.kind !== 'array') {
      return { kind: 'invalidJSON', message: `${path}.modules 必须是数组。` };
    }
    for (let index = 0; index < modulesValue.items.length; index += 1) {
      const decoded = decodeRawAccountItem(modulesValue.items[index]!, `${path}.modules.${index}`);
      if (isImportError(decoded)) {
        return decoded;
      }
      modules.push(decoded);
    }
  }

  return {
    dataID: dataResult.value,
    level: decodeOptionalInt(value.fields.lvl),
    count: decodeOptionalInt(value.fields.cnt),
    timerSeconds: decodeOptionalInt64(value.fields.timer),
    helperTimerSeconds: decodeOptionalInt64(value.fields.helper_timer),
    helperCooldownSeconds: decodeOptionalInt64(value.fields.helper_cooldown),
    helperRecurrent:
      value.fields.helper_recurrent?.kind === 'bool' ? value.fields.helper_recurrent.value : false,
    gearUp: decodeOptionalInt(value.fields.gear_up),
    weapon: decodeOptionalInt(value.fields.weapon),
    types,
    modules,
  };
}

function decodeOptionalInt(value: CanonicalJsonValue | undefined): number | null {
  if (value === undefined || value.kind === 'null') {
    return null;
  }
  if (value.kind === 'number') {
    const parsed = Number(value.value);
    if (Number.isFinite(parsed) && Number.isInteger(parsed)) {
      return parsed;
    }
  }
  return null;
}

function decodeOptionalInt64(value: CanonicalJsonValue | undefined): bigint | null {
  if (value === undefined || value.kind === 'null') {
    return null;
  }
  const result = parseLegacyInt64(value);
  return result.ok ? result.value : null;
}

function decodeInt64Field(
  value: CanonicalJsonValue,
  path: string,
): bigint | null | AccountSnapshotImportError {
  const result = parseLegacyInt64(value);
  if (result.ok) {
    return result.value;
  }
  if (result.reason === 'missing') {
    return null;
  }
  return {
    kind: 'invalidJSON',
    message: `字段必须是整数（${path}）。`,
  };
}

function isImportError(value: unknown): value is AccountSnapshotImportError {
  return typeof value === 'object' && value !== null && 'kind' in value;
}
