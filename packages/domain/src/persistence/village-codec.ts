import { parseAccountSnapshot } from '../account/parser';
import type { AccountSnapshot } from '../account/types';
import { createVillageProfile, type VillageProfile } from '../import/types';

export const VILLAGE_STORE_SCHEMA = {
  current: 1,
} as const;

export type VillageStoreStatus =
  'missing' | 'available' | 'empty' | 'readOnly' | 'corrupt' | 'unsupported' | 'writeFailed';

export function villageStoreStatusRequiresRecovery(status: VillageStoreStatus): boolean {
  switch (status) {
    case 'readOnly':
    case 'corrupt':
    case 'unsupported':
    case 'writeFailed':
      return true;
    case 'missing':
    case 'available':
    case 'empty':
      return false;
  }
}

export type VillageStoreError =
  | { readonly kind: 'corrupt'; readonly message: string }
  | { readonly kind: 'unsupportedSchema'; readonly version: number }
  | { readonly kind: 'invalid'; readonly message: string }
  | { readonly kind: 'writeFailed'; readonly message: string }
  | { readonly kind: 'unavailable'; readonly message: string };

export type VillageStoreLoadResult =
  | { readonly kind: 'missing' }
  | { readonly kind: 'loaded'; readonly villages: readonly VillageProfile[] }
  | { readonly kind: 'corrupt'; readonly rawData: Uint8Array; readonly message: string }
  | {
      readonly kind: 'unsupportedSchema';
      readonly rawData: Uint8Array;
      readonly schemaVersion: number;
    };

/**
 * Electron 新根落盘格式：不含 officialAPIState。
 * Official API 状态由独立 OfficialStateStore / player-states-v1 管理，避免双权威。
 */
type VillageFileRecordV1 = {
  readonly id: string;
  readonly name: string;
  readonly accountOriginalText: string | null;
  readonly accountImportedAtMs: number | null;
};

/** Electron 新根落盘格式：村庄数组；未来版本靠顶层 schemaVersion 识别。 */
export function encodeVillageStoreBytes(villages: readonly VillageProfile[]): Uint8Array {
  const records: VillageFileRecordV1[] = villages.map((village) => ({
    id: village.id,
    name: village.name,
    accountOriginalText: village.accountSnapshot?.originalText ?? null,
    accountImportedAtMs: village.accountSnapshot?.importedAtMs ?? null,
  }));
  return new TextEncoder().encode(JSON.stringify(records));
}

export function loadVillageStoreBytes(data: Uint8Array | null): VillageStoreLoadResult {
  if (data === null) {
    return { kind: 'missing' };
  }
  const text = new TextDecoder().decode(data);
  if (text.trim().length === 0) {
    return { kind: 'corrupt', rawData: data, message: '村庄存储为空字节。' };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text) as unknown;
  } catch (error) {
    const schemaVersion = advertisedSchemaVersion(text);
    if (schemaVersion !== null && schemaVersion > VILLAGE_STORE_SCHEMA.current) {
      return { kind: 'unsupportedSchema', rawData: data, schemaVersion };
    }
    return {
      kind: 'corrupt',
      rawData: data,
      message: error instanceof Error ? error.message : String(error),
    };
  }

  const schemaVersion = advertisedSchemaVersionFromValue(parsed);
  if (schemaVersion !== null && schemaVersion > VILLAGE_STORE_SCHEMA.current) {
    return { kind: 'unsupportedSchema', rawData: data, schemaVersion };
  }

  if (!Array.isArray(parsed)) {
    return { kind: 'corrupt', rawData: data, message: '村庄存储顶层必须是数组。' };
  }

  try {
    const villages = parsed.map((entry, index) => decodeVillageRecord(entry, index));
    const ids = villages.map((village) => village.id);
    if (new Set(ids).size !== ids.length) {
      return { kind: 'corrupt', rawData: data, message: '村庄列表包含重复的村庄 ID。' };
    }
    return { kind: 'loaded', villages };
  } catch (error) {
    return {
      kind: 'corrupt',
      rawData: data,
      message: error instanceof Error ? error.message : String(error),
    };
  }
}

export function validateVillageStoreBytes(data: Uint8Array | null, label: string): void {
  const result = loadVillageStoreBytes(data);
  switch (result.kind) {
    case 'missing':
    case 'loaded':
      return;
    case 'corrupt':
      throw {
        kind: 'corrupt',
        message: `${label} 无法解码：${result.message}`,
      } satisfies VillageStoreError;
    case 'unsupportedSchema':
      throw {
        kind: 'unsupportedSchema',
        version: result.schemaVersion,
      } satisfies VillageStoreError;
  }
}

function decodeVillageRecord(entry: unknown, index: number): VillageProfile {
  if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
    throw new Error(`村庄 #${String(index)} 不是对象。`);
  }
  const record = entry as Record<string, unknown>;
  const id = record.id;
  const name = record.name;
  if (typeof id !== 'string' || id.length === 0) {
    throw new Error(`村庄 #${String(index)} 缺少合法 id。`);
  }
  if (typeof name !== 'string') {
    throw new Error(`村庄 #${String(index)} 缺少 name。`);
  }

  const accountOriginalText =
    record.accountOriginalText === undefined || record.accountOriginalText === null
      ? null
      : requireString(record.accountOriginalText, 'accountOriginalText');
  const accountImportedAtMs =
    record.accountImportedAtMs === undefined || record.accountImportedAtMs === null
      ? null
      : requireFiniteNumber(record.accountImportedAtMs, 'accountImportedAtMs');

  let accountSnapshot: AccountSnapshot | null = null;
  if (accountOriginalText !== null) {
    const importedAtMs = accountImportedAtMs ?? 0;
    const parsed = parseAccountSnapshot(accountOriginalText, {
      clock: { nowMs: () => importedAtMs },
    });
    if (!parsed.ok) {
      throw new Error(`村庄 ${id} 的账号快照无法解析。`);
    }
    accountSnapshot = parsed.value;
  }

  // 内存 VillageProfile 仍保留字段以兼容现有类型；Electron 新根永不持久化、永不从盘恢复。
  return createVillageProfile({
    id,
    name,
    accountSnapshot,
    officialAPIState: null,
  });
}

function advertisedSchemaVersion(text: string): number | null {
  try {
    return advertisedSchemaVersionFromValue(JSON.parse(text) as unknown);
  } catch {
    return null;
  }
}

function advertisedSchemaVersionFromValue(value: unknown): number | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return null;
  }
  const version = (value as Record<string, unknown>).schemaVersion;
  return typeof version === 'number' && Number.isFinite(version) ? version : null;
}

function requireString(value: unknown, label: string): string {
  if (typeof value !== 'string') {
    throw new Error(`${label} 必须是字符串。`);
  }
  return value;
}

function requireFiniteNumber(value: unknown, label: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error(`${label} 必须是有限数字。`);
  }
  return value;
}
