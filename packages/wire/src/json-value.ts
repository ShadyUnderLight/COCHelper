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

/** 对齐 Swift `String <` 的 Unicode 标量字典序（golden 以 ASCII/CJK/emoji 为主）。 */
export function swiftStringLessThan(left: string, right: string): boolean {
  const leftPoints = [...left];
  const rightPoints = [...right];
  const n = Math.min(leftPoints.length, rightPoints.length);
  for (let i = 0; i < n; i += 1) {
    const a = leftPoints[i]!.codePointAt(0)!;
    const b = rightPoints[i]!.codePointAt(0)!;
    if (a !== b) {
      return a < b;
    }
  }
  return leftPoints.length < rightPoints.length;
}

export function sortedObjectKeys(fields: Readonly<Record<string, CanonicalJsonValue>>): string[] {
  return Object.keys(fields).sort((a, b) => {
    if (a === b) {
      return 0;
    }
    return swiftStringLessThan(a, b) ? -1 : 1;
  });
}

export function isCanonicalObject(
  value: CanonicalJsonValue,
): value is {
  readonly kind: 'object';
  readonly fields: Readonly<Record<string, CanonicalJsonValue>>;
} {
  return value.kind === 'object';
}
