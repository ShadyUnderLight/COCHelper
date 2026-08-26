import { createHash } from 'node:crypto';

const SHA256_PREFIX = 'sha256:';
const HEX64 = /^[0-9a-f]{64}$/;

/** 与 wire `sha256Fingerprint` 同形：`sha256:` + 64 小写 hex。testkit 自行实现以免与 wire 形成生产环。 */
export function fixtureFingerprint(data: Uint8Array | string): string {
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data;
  const hex = createHash('sha256').update(bytes).digest('hex');
  return `${SHA256_PREFIX}${hex}`;
}

export function isFixtureFingerprint(value: string): boolean {
  return (
    value.length === 71 &&
    value.startsWith(SHA256_PREFIX) &&
    HEX64.test(value.slice(SHA256_PREFIX.length))
  );
}
