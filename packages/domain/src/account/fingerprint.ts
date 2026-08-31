import {
  sha256Fingerprint,
  unixSecondsToRefSeconds,
  type Sha256Fingerprint,
} from '@coc-helper/wire';

import type { AccountSnapshot } from './types';
import {
  encodeSwiftSortedJson,
  mapBoostsForWire,
  mapNumericSectionsForWire,
  mapObjectSectionsForWire,
} from './wire-encode';

type FingerprintDiagnostic = {
  readonly severity: string;
  readonly path: string;
  readonly message: string;
};

type FingerprintMaterial = {
  readonly tag: string | null;
  readonly capturedAt: number | null;
  readonly importedAt: number;
  readonly ageSeconds: bigint | null;
  readonly originalText: string;
  readonly objectSections: Readonly<Record<string, readonly unknown[]>>;
  readonly numericSections: Readonly<Record<string, readonly number[]>>;
  readonly boosts: Readonly<Record<string, number>>;
  readonly unknownTopLevelKeys: readonly string[];
  readonly diagnostics: readonly FingerprintDiagnostic[];
};

export function computeContentFingerprint(
  snapshot: Omit<AccountSnapshot, 'contentFingerprint'>,
): Sha256Fingerprint {
  const material: FingerprintMaterial = {
    tag: snapshot.tag,
    capturedAt:
      snapshot.capturedAtMs === null ? null : unixSecondsToRefSeconds(snapshot.capturedAtMs / 1000),
    importedAt: unixSecondsToRefSeconds(snapshot.importedAtMs / 1000),
    ageSeconds: snapshot.ageSeconds,
    originalText: snapshot.originalText,
    objectSections: mapObjectSectionsForWire(snapshot.objectSections),
    numericSections: mapNumericSectionsForWire(snapshot.numericSections),
    boosts: mapBoostsForWire(snapshot.boosts),
    unknownTopLevelKeys: snapshot.unknownTopLevelKeys,
    diagnostics: snapshot.diagnostics.map((item) => ({
      severity: item.severity,
      path: item.path,
      message: item.message,
    })),
  };
  const json = encodeSwiftSortedJson(material);
  return sha256Fingerprint(json);
}

export function maskDiagnosticIdsInWireHex(wireHex: string): string {
  const bytes = hexToBytes(wireHex);
  const json = new TextDecoder().decode(bytes);
  const masked = json.replace(
    /"id":"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"/g,
    '"id":"<RANDOM_DIAGNOSTIC_UUID>"',
  );
  return bytesToHex(new TextEncoder().encode(masked));
}

function hexToBytes(value: string): Uint8Array {
  const bytes = new Uint8Array(value.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

function bytesToHex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}
