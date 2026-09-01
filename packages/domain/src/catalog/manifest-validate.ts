import { sha256Fingerprint, type Sha256Fingerprint } from '@coc-helper/wire';

import { catalogDurationState } from './duration-state';
import { collectCatalogIconRefs } from './asset-ref';
import type {
  CatalogItem,
  CatalogLevel,
  CatalogManifest,
  FileCheck,
} from './types';

const SHA256_PREFIX = 'sha256:';

function isHexDigit(value: string): boolean {
  return /^[0-9a-fA-F]$/.test(value);
}

function validSourceFingerprint(value: string): boolean {
  const hex = value.slice(SHA256_PREFIX.length);
  return (
    value.startsWith(SHA256_PREFIX) &&
    hex.length === 64 &&
    [...hex].every(isHexDigit)
  );
}

function allLevels(items: readonly CatalogItem[]): readonly CatalogLevel[] {
  return items.flatMap((item) => item.levels);
}

export function validateCatalogManifest(
  manifest: CatalogManifest,
  items: readonly CatalogItem[],
  catalogData: Uint8Array | string,
  fileCheck?: FileCheck,
): boolean {
  if (manifest.schemaVersion < 1 || manifest.schemaVersion > 2) {
    return false;
  }
  if (!validSourceFingerprint(manifest.sourceFingerprint)) {
    return false;
  }

  const levels = allLevels(items);
  if (manifest.counts.items !== items.length || manifest.counts.levels !== levels.length) {
    return false;
  }

  if (manifest.counts.missingTime !== undefined) {
    const missingTime = levels.filter((level) => level.durationSeconds === null).length;
    if (manifest.counts.missingTime !== missingTime) {
      return false;
    }
  }

  if (manifest.counts.timed !== undefined) {
    const timed = levels.filter((level) => (level.durationSeconds ?? 0n) > 0n).length;
    if (manifest.counts.timed !== timed) {
      return false;
    }
  }

  if (manifest.counts.instant !== undefined) {
    const instant = levels.filter((level) => level.durationSeconds === 0n).length;
    if (manifest.counts.instant !== instant) {
      return false;
    }
  }

  for (const [field, predicate] of [
    ['notApplicable', (level: CatalogLevel) => catalogDurationState(level.durationSeconds, level.missingReason)?.kind === 'notApplicable'],
    ['initialLevel', (level: CatalogLevel) => catalogDurationState(level.durationSeconds, level.missingReason)?.kind === 'initialLevel'],
    ['sourceMissing', (level: CatalogLevel) => catalogDurationState(level.durationSeconds, level.missingReason)?.kind === 'sourceMissing'],
    ['parseFailed', (level: CatalogLevel) => catalogDurationState(level.durationSeconds, level.missingReason)?.kind === 'parseFailed'],
  ] as const) {
    const expected = manifest.counts[field];
    if (expected !== undefined) {
      const actual = levels.filter((level) => predicate(level)).length;
      if (expected !== actual) {
        return false;
      }
    }
  }

  const catalogEntry = manifest.generatedFiles.find((file) => file.path === 'catalog.json');
  if (catalogEntry?.sha256 !== undefined) {
    if (!catalogEntry.sha256.startsWith(SHA256_PREFIX)) {
      return false;
    }
    const actual = sha256Fingerprint(catalogData).slice(SHA256_PREFIX.length);
    const declared = catalogEntry.sha256.slice(SHA256_PREFIX.length);
    if (declared !== actual) {
      return false;
    }
  }

  if (fileCheck !== undefined) {
    for (const file of manifest.generatedFiles) {
      if (file.kind === 'directory') {
        continue;
      }
      if (!fileCheck(file.path, file.size ?? null)) {
        return false;
      }
    }
    for (const renderedPath of collectCatalogIconRefs(items)) {
      if (!fileCheck(renderedPath, null)) {
        return false;
      }
    }
  }

  return true;
}

export function catalogManifestFingerprint(manifest: CatalogManifest): Sha256Fingerprint {
  return sha256Fingerprint(
    `${manifest.gameVersion}|${manifest.sourceFingerprint}|${manifest.generatedFiles.find((file) => file.path === 'catalog.json')?.sha256 ?? ''}`,
  );
}
