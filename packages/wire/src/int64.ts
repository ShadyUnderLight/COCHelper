import { INT64_MAX, INT64_MIN } from './json-number';
import type { CanonicalJsonValue } from './json-value';

/** Swift `Int64(String)`：可选正负号、允许前导零，溢出则失败。 */
export function parseSwiftInt64(raw: string): bigint | undefined {
  if (!/^[+-]?\d+$/.test(raw)) {
    return undefined;
  }
  const value = BigInt(raw);
  if (value < INT64_MIN || value > INT64_MAX) {
    return undefined;
  }
  return value;
}

/** 对齐 Swift `Int64(exactly: Double)`：必须是有限整值且落入 Int64 范围。 */
function int64ExactlyFromDouble(value: number): bigint | undefined {
  if (!Number.isFinite(value) || value !== Math.round(value)) {
    return undefined;
  }
  const exact = BigInt(value);
  if (exact < INT64_MIN || exact > INT64_MAX) {
    return undefined;
  }
  if (Number(exact) !== value) {
    return undefined;
  }
  return exact;
}

/** WA-6b：只接受 number token，且 `Int64(raw)` 成功。 */
export function parseCanonicalizerInt64(value: CanonicalJsonValue | undefined): bigint | undefined {
  if (value === undefined || value.kind !== 'number') {
    return undefined;
  }
  return parseSwiftInt64(value.value);
}

export type LegacyInt64Result =
  | { readonly ok: true; readonly value: bigint }
  | { readonly ok: false; readonly reason: 'missing' | 'typeMismatch' };

/**
 * WA-6c：直接 Int64 → finite 整 Double → String。
 * 字符串形式接受 `+0000002` 等非规范输入。
 */
export function parseLegacyInt64(value: CanonicalJsonValue | undefined): LegacyInt64Result {
  if (value === undefined || value.kind === 'null') {
    return { ok: false, reason: 'missing' };
  }
  if (value.kind === 'number') {
    const direct = parseSwiftInt64(value.value);
    if (direct !== undefined) {
      return { ok: true, value: direct };
    }
    const exact = int64ExactlyFromDouble(Number(value.value));
    if (exact !== undefined) {
      return { ok: true, value: exact };
    }
    return { ok: false, reason: 'typeMismatch' };
  }
  if (value.kind === 'string') {
    const parsed = parseSwiftInt64(value.value);
    if (parsed === undefined) {
      return { ok: false, reason: 'typeMismatch' };
    }
    return { ok: true, value: parsed };
  }
  return { ok: false, reason: 'typeMismatch' };
}

export type CatalogDataIdKey =
  { readonly ok: true; readonly section: string; readonly dataID: bigint } | { readonly ok: false };

/**
 * WA-6a：`section:dataID`，split(":") maxSplits 1；canonical 重序列化必须逐字符相等。
 * 拒绝 `+0000002` / 前导零。
 */
export function parseCatalogDataIdKey(key: string): CatalogDataIdKey {
  const separator = key.indexOf(':');
  if (separator <= 0 || key.indexOf(':', separator + 1) !== -1) {
    return { ok: false };
  }
  // Swift `split(..., maxSplits: 1)` 只切一次；此处等价于恰好两段。
  const section = key.slice(0, separator);
  const rawId = key.slice(separator + 1);
  if (section.length === 0) {
    return { ok: false };
  }
  const dataID = parseSwiftInt64(rawId);
  if (dataID === undefined) {
    return { ok: false };
  }
  if (key !== `${section}:${dataID.toString()}`) {
    return { ok: false };
  }
  return { ok: true, section, dataID };
}
