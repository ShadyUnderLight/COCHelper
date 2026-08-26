import { isCanonicalUuidString, parseUuid, type UuidString } from '@coc-helper/wire';

/** 可注入的 Unix epoch 毫秒时钟。 */
export interface Clock {
  nowMs(): number;
}

/** 可注入的 UUID 来源，用于需要可复现身份的领域操作。 */
export interface UuidSource {
  next(): UuidString;
}

/** 不依赖数组位置、展示名称或本地化文本的确定性可打印 stable ID。 */
export type StableId = string & { readonly __brand: 'StableId' };

declare const lineageIdBrand: unique symbol;

/** 进入历史完整性材料的 lineage UUID。 */
export type LineageId = UuidString & { readonly [lineageIdBrand]: true };

/**
 * 使用 Swift TrackerItemKey 相同的 `|` 分隔规则构造稳定键。
 * bigint 组件始终以十进制文本写入，避免经过 JS number 丢失精度。
 */
export function makeStableId(parts: readonly (string | bigint)[]): StableId {
  if (parts.length === 0) {
    throw new RangeError('StableId 至少需要一个组件。');
  }
  const values = parts.map((part, index) => {
    if (typeof part !== 'string' && typeof part !== 'bigint') {
      throw new TypeError('StableId 组件必须是 string 或 bigint。');
    }
    const value = typeof part === 'bigint' ? part.toString() : part;
    if (index === 0 && value.length === 0) {
      throw new RangeError('StableId 的首个组件不能为空。');
    }
    if (value.includes('|') || hasControlCharacter(value)) {
      throw new RangeError('StableId 组件不得包含分隔符或控制字符。');
    }
    return value;
  });
  return values.join('|') as StableId;
}

export function isStableId(value: unknown): value is StableId {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    !value.startsWith('|') &&
    !hasControlCharacter(value)
  );
}

export function createLineageId(source: UuidSource): LineageId {
  const value = source.next();
  if (!isCanonicalUuidString(value)) {
    throw new RangeError('UuidSource 必须返回大写连字符 UUID。');
  }
  return value as LineageId;
}

export function parseLineageId(raw: string): LineageId | undefined {
  const value = parseUuid(raw);
  return value === undefined ? undefined : (value as LineageId);
}

export function isLineageId(value: unknown): value is LineageId {
  return typeof value === 'string' && isCanonicalUuidString(value);
}

function hasControlCharacter(value: string): boolean {
  return Array.from(value).some((character) => {
    const code = character.charCodeAt(0);
    return code <= 0x1f || code === 0x7f;
  });
}
