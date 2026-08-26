import {
  type CanonicalJsonValue,
  emptyJsonObjectFields,
  jsonArray,
  jsonObject,
  sortedObjectKeys,
} from './json-value';

/** 对象键排序 + 数组按 canonical bytes 排序后的值。 */
export function canonicalize(value: CanonicalJsonValue): CanonicalJsonValue {
  switch (value.kind) {
    case 'null':
    case 'bool':
    case 'number':
    case 'string':
      return value;
    case 'array':
      return jsonArray(sortedByCanonicalBytes(value.items.map(canonicalize)));
    case 'object': {
      const fields = emptyJsonObjectFields();
      for (const key of sortedObjectKeys(value.fields)) {
        fields[key] = canonicalize(value.fields[key]!);
      }
      return jsonObject(fields);
    }
  }
}

/**
 * 逐字节对齐 Swift `CanonicalJSONValue.canonicalData`（WA-2）。
 * 数组在写出时按元素 canonical bytes 字典序排序，重复元素保留。
 */
export function canonicalBytes(value: CanonicalJsonValue): Uint8Array {
  switch (value.kind) {
    case 'null':
      return encodeUtf8('null');
    case 'bool':
      return encodeUtf8(value.value ? 'true' : 'false');
    case 'number':
      return encodeUtf8(value.value);
    case 'string':
      return jsonStringBytes(value.value);
    case 'array': {
      const encoded = value.items.map(canonicalBytes).sort(compareBytes);
      return joinBytes(encoded, 0x5b, 0x5d);
    }
    case 'object': {
      const pieces: Uint8Array[] = [];
      for (const key of sortedObjectKeys(value.fields)) {
        pieces.push(
          concatBytes(jsonStringBytes(key), uint8(0x3a), canonicalBytes(value.fields[key]!)),
        );
      }
      return joinBytes(pieces, 0x7b, 0x7d);
    }
  }
}

export function sortedByCanonicalBytes<T>(
  items: readonly T[],
  representing: (item: T) => CanonicalJsonValue = (item) => item as CanonicalJsonValue,
): T[] {
  return items
    .map((item) => ({ item, key: canonicalBytes(representing(item)) }))
    .sort((a, b) => compareBytes(a.key, b.key))
    .map((entry) => entry.item);
}

export function bytesToHex(data: Uint8Array): string {
  return Array.from(data, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

function jsonStringBytes(value: string): Uint8Array {
  const bytes = encodeUtf8(value);
  const out: number[] = [0x22];
  for (const byte of bytes) {
    switch (byte) {
      case 0x22:
        out.push(0x5c, 0x22);
        break;
      case 0x2f:
        out.push(0x5c, 0x2f);
        break;
      case 0x5c:
        out.push(0x5c, 0x5c);
        break;
      case 0x08:
        out.push(0x5c, 0x62);
        break;
      case 0x09:
        out.push(0x5c, 0x74);
        break;
      case 0x0a:
        out.push(0x5c, 0x6e);
        break;
      case 0x0c:
        out.push(0x5c, 0x66);
        break;
      case 0x0d:
        out.push(0x5c, 0x72);
        break;
      default:
        if (byte < 0x20) {
          out.push(0x5c, 0x75, 0x30, 0x30, hexNibble(byte >> 4), hexNibble(byte & 0x0f));
        } else {
          out.push(byte);
        }
    }
  }
  out.push(0x22);
  return Uint8Array.from(out);
}

function hexNibble(value: number): number {
  return value < 10 ? 0x30 + value : 0x61 + (value - 10);
}

function compareBytes(left: Uint8Array, right: Uint8Array): number {
  const n = Math.min(left.length, right.length);
  for (let i = 0; i < n; i += 1) {
    if (left[i] !== right[i]) {
      return left[i]! - right[i]!;
    }
  }
  return left.length - right.length;
}

function joinBytes(values: readonly Uint8Array[], open: number, close: number): Uint8Array {
  const parts: Uint8Array[] = [uint8(open)];
  for (const [index, value] of values.entries()) {
    if (index > 0) {
      parts.push(uint8(0x2c));
    }
    parts.push(value);
  }
  parts.push(uint8(close));
  return concatBytes(...parts);
}

function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const length = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function uint8(value: number): Uint8Array {
  return Uint8Array.of(value);
}

function encodeUtf8(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}
