import { bytesToHex, canonicalBytes, canonicalize, parseJson } from '@coc-helper/wire';

export function manualParityCanonicalHex(value: unknown): string {
  return bytesToHex(canonicalBytes(canonicalize(parseJson(JSON.stringify(value)))));
}

export function manualParityOutcomeHex(outcome: unknown): string {
  const normalized = JSON.parse(JSON.stringify(outcome)) as unknown;
  return manualParityCanonicalHex(normalized);
}
