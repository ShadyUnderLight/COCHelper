/**
 * CanonicalJsonValue：对齐 Swift `CanonicalJSONValue`（WA-1）。
 * number 载荷是规范化后的 token 字符串，不是 JS number。
 */

export type CanonicalJsonValue =
  | { readonly kind: 'null' }
  | { readonly kind: 'bool'; readonly value: boolean }
  | { readonly kind: 'number'; readonly value: string }
  | { readonly kind: 'string'; readonly value: string }
  | { readonly kind: 'array'; readonly items: readonly CanonicalJsonValue[] }
  | {
      readonly kind: 'object';
      readonly fields: Readonly<Record<string, CanonicalJsonValue>>;
    };

export class JsonParseError extends Error {
  readonly kind = 'malformedJson' as const;

  constructor(message: string) {
    super(message);
    this.name = 'JsonParseError';
  }
}

export function jsonNull(): CanonicalJsonValue {
  return { kind: 'null' };
}

export function jsonBool(value: boolean): CanonicalJsonValue {
  return { kind: 'bool', value };
}

export function jsonNumber(token: string): CanonicalJsonValue {
  return { kind: 'number', value: token };
}

export function jsonString(value: string): CanonicalJsonValue {
  return { kind: 'string', value };
}

export function jsonArray(items: readonly CanonicalJsonValue[]): CanonicalJsonValue {
  return { kind: 'array', items };
}

export function jsonObject(
  fields: Readonly<Record<string, CanonicalJsonValue>>,
): CanonicalJsonValue {
  return { kind: 'object', fields };
}

/**
 * 对象字段表必须用 null-prototype。普通 `{}` 上 `fields['__proto__'] = v`
 * 会走 legacy setter，键不会成为 own property。
 */
export function emptyJsonObjectFields(): Record<string, CanonicalJsonValue> {
  return Object.create(null) as Record<string, CanonicalJsonValue>;
}

/**
 * 对齐 Swift `String.<` / `==`（WA-2）：比较用 NFC 后的 Unicode 标量字典序；
 * 规范化等价（é vs e+combining acute）视为相等。写出时仍使用原始拼写，不改 key。
 */
export function swiftStringCompare(left: string, right: string): number {
  const leftPoints = [...left.normalize('NFC')];
  const rightPoints = [...right.normalize('NFC')];
  const n = Math.min(leftPoints.length, rightPoints.length);
  for (let i = 0; i < n; i += 1) {
    const a = leftPoints[i]!.codePointAt(0)!;
    const b = rightPoints[i]!.codePointAt(0)!;
    if (a !== b) {
      return a < b ? -1 : 1;
    }
  }
  if (leftPoints.length !== rightPoints.length) {
    return leftPoints.length < rightPoints.length ? -1 : 1;
  }
  return 0;
}

export function swiftStringLessThan(left: string, right: string): boolean {
  return swiftStringCompare(left, right) < 0;
}

export function sortedObjectKeys(fields: Readonly<Record<string, CanonicalJsonValue>>): string[] {
  return Object.keys(fields).sort(swiftStringCompare);
}

export function isCanonicalObject(value: CanonicalJsonValue): value is {
  readonly kind: 'object';
  readonly fields: Readonly<Record<string, CanonicalJsonValue>>;
} {
  return value.kind === 'object';
}
