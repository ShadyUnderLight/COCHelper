/** 官方 API JSON 解码辅助（对齐 Swift decodeIfPresent + 未知键审计）。 */

export type JsonRecord = Readonly<Record<string, unknown>>;

export function asRecord(value: unknown, label: string): JsonRecord {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(`${label} 必须是 object。`);
  }
  return value as JsonRecord;
}

export function optionalString(value: unknown): string | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== 'string') {
    throw new TypeError('期望 string 或 null。');
  }
  return value;
}

export function optionalInt(value: unknown): number | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    throw new TypeError('期望整数或 null。');
  }
  return value;
}

export function optionalDouble(value: unknown): number | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new TypeError('期望 number 或 null。');
  }
  return value;
}

export function optionalBool(value: unknown): boolean | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== 'boolean') {
    throw new TypeError('期望 boolean 或 null。');
  }
  return value;
}

export function optionalStringMap(value: unknown): Readonly<Record<string, string>> | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  const record = asRecord(value, 'string map');
  const result: Record<string, string> = Object.create(null);
  for (const [key, entry] of Object.entries(record)) {
    if (typeof entry !== 'string') {
      throw new TypeError(`${key} 必须是 string。`);
    }
    result[key] = entry;
  }
  return result;
}

export function collectUnrecognizedKeys(
  record: JsonRecord,
  knownKeys: ReadonlySet<string>,
): readonly string[] {
  if (Array.isArray(record.unrecognizedKeys)) {
    const stored = record.unrecognizedKeys.filter(
      (entry): entry is string => typeof entry === 'string',
    );
    return [...stored].sort();
  }
  return Object.keys(record)
    .filter((key) => !knownKeys.has(key))
    .sort();
}

export function stableEqual<T>(left: T, right: T): boolean {
  return stableStringify(left) === stableStringify(right);
}

function stableStringify(value: unknown): string {
  if (value === null || typeof value !== 'object') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((entry) => stableStringify(entry)).join(',')}]`;
  }
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record).sort();
  return `{${keys.map((key) => `${JSON.stringify(key)}:${stableStringify(record[key])}`).join(',')}}`;
}
