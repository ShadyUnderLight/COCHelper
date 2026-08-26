import { createHash } from 'node:crypto';

export type Sha256Fingerprint = string & { readonly __brand: 'Sha256Fingerprint' };

const SHA256_PREFIX = 'sha256:';
const HEX64 = /^[0-9a-f]{64}$/;

/** `"sha256:" + 64 小写 hex`，总长 71（WA-3）。 */
export function sha256Fingerprint(data: Uint8Array | string): Sha256Fingerprint {
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data;
  const hex = createHash('sha256').update(bytes).digest('hex');
  return `${SHA256_PREFIX}${hex}` as Sha256Fingerprint;
}

export function isSha256Fingerprint(value: string): value is Sha256Fingerprint {
  return (
    value.length === 71 &&
    value.startsWith(SHA256_PREFIX) &&
    HEX64.test(value.slice(SHA256_PREFIX.length))
  );
}
