import { randomUUID } from 'node:crypto';

export type UuidString = string & { readonly __brand: 'UuidString' };

const CANONICAL_UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
const PARSE_UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

/** 持久化形态：Swift `uuidString` 大写连字符。 */
export function generateUuid(): UuidString {
  return randomUUID().toUpperCase() as UuidString;
}

export function parseUuid(raw: string): UuidString | undefined {
  if (!PARSE_UUID.test(raw)) {
    return undefined;
  }
  return raw.toUpperCase() as UuidString;
}

export function isCanonicalUuidString(raw: string): raw is UuidString {
  return CANONICAL_UUID.test(raw);
}
