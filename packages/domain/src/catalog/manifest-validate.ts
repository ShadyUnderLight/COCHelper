import { sha256Fingerprint, type Sha256Fingerprint } from '@coc-helper/wire';

import { catalogDurationState } from './duration-state';
import {
  registeredGeneratedFilePaths,
  validateCatalogItemsAssetRefs,
  validateCatalogItemsRenderableAssetRefs,
} from './asset-ref';
import type {
  CatalogItem,
  CatalogLevel,
  CatalogManifest,
  CatalogGeneratedFile,
  GeneratedFileIntegrityProbe,
} from './types';

const SHA256_PREFIX = 'sha256:';

function isHexDigit(value: string): boolean {
  return /^[0-9a-fA-F]$/.test(value);
}

function validSourceFingerprint(value: string): boolean {
  const hex = value.slice(SHA256_PREFIX.length);
  return value.startsWith(SHA256_PREFIX) && hex.length === 64 && [...hex].every(isHexDigit);
}

function validSha256Declaration(value: string | undefined): value is string {
  if (value === undefined) {
    return false;
  }
  const hex = value.slice(SHA256_PREFIX.length);
  return value.startsWith(SHA256_PREFIX) && hex.length === 64 && [...hex].every(isHexDigit);
}

function validDeclaredSize(size: number | undefined): size is number {
  return typeof size === 'number' && Number.isInteger(size) && size >= 0;
}

function validDeclaredEntries(entries: number | undefined): entries is number {
  return typeof entries === 'number' && Number.isInteger(entries) && entries >= 0;
}

function allLevels(items: readonly CatalogItem[]): readonly CatalogLevel[] {
  return items.flatMap((item) => item.levels);
}

function normalizeDirectoryPath(path: string): string {
  return path.endsWith('/') ? path : `${path}/`;
}

function countGeneratedEntriesUnder(manifest: CatalogManifest, dirPath: string): number {
  const prefix = normalizeDirectoryPath(dirPath);
  return manifest.generatedFiles.filter(
    (entry) => entry.kind !== 'directory' && entry.path.startsWith(prefix),
  ).length;
}

function validateGeneratedFileEntry(
  entry: CatalogGeneratedFile,
  manifest: CatalogManifest,
  catalogData: Uint8Array | string,
  probe: GeneratedFileIntegrityProbe,
): boolean {
  if (entry.kind === 'directory') {
    if (!validDeclaredEntries(entry.entries)) {
      return false;
    }
    if (!probe.directoryExists(entry.path)) {
      return false;
    }
    return entry.entries === countGeneratedEntriesUnder(manifest, entry.path);
  }

  if (!validSha256Declaration(entry.sha256)) {
    return false;
  }
  if (!validDeclaredSize(entry.size)) {
    return false;
  }
  if (!probe.fileExists(entry.path)) {
    return false;
  }

  const actualSize = probe.fileSize(entry.path);
  if (actualSize === null || actualSize !== entry.size) {
    return false;
  }

  let actualHash: string | null;
  if (entry.path === 'catalog.json') {
    actualHash = sha256Fingerprint(catalogData);
  } else {
    actualHash = probe.fileSha256(entry.path);
  }
  if (actualHash === null || actualHash !== entry.sha256) {
    return false;
  }

  return true;
}

export function validateCatalogManifest(
  manifest: CatalogManifest,
  items: readonly CatalogItem[],
  catalogData: Uint8Array | string,
  integrity?: GeneratedFileIntegrityProbe,
): boolean {
  if (manifest.schemaVersion < 1 || manifest.schemaVersion > 2) {
    return false;
  }
  if (!validSourceFingerprint(manifest.sourceFingerprint)) {
    return false;
  }
  if (!validateCatalogItemsAssetRefs(items)) {
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
    [
      'notApplicable',
      (level: CatalogLevel) =>
        catalogDurationState(level.durationSeconds, level.missingReason)?.kind === 'notApplicable',
    ],
    [
      'initialLevel',
      (level: CatalogLevel) =>
        catalogDurationState(level.durationSeconds, level.missingReason)?.kind === 'initialLevel',
    ],
    [
      'sourceMissing',
      (level: CatalogLevel) =>
        catalogDurationState(level.durationSeconds, level.missingReason)?.kind === 'sourceMissing',
    ],
    [
      'parseFailed',
      (level: CatalogLevel) =>
        catalogDurationState(level.durationSeconds, level.missingReason)?.kind === 'parseFailed',
    ],
  ] as const) {
    const expected = manifest.counts[field];
    if (expected !== undefined) {
      const actual = levels.filter((level) => predicate(level)).length;
      if (expected !== actual) {
        return false;
      }
    }
  }

  if (integrity !== undefined) {
    const seenPaths = new Set<string>();
    for (const entry of manifest.generatedFiles) {
      if (seenPaths.has(entry.path)) {
        return false;
      }
      seenPaths.add(entry.path);
      if (!validateGeneratedFileEntry(entry, manifest, catalogData, integrity)) {
        return false;
      }
    }
    const registeredPaths = registeredGeneratedFilePaths(manifest);
    if (
      !validateCatalogItemsRenderableAssetRefs(items, registeredPaths, (path) =>
        integrity.fileExists(path),
      )
    ) {
      return false;
    }
  } else {
    const catalogEntry = manifest.generatedFiles.find((file) => file.path === 'catalog.json');
    if (catalogEntry?.sha256 !== undefined) {
      if (!validSha256Declaration(catalogEntry.sha256)) {
        return false;
      }
      const actual = sha256Fingerprint(catalogData);
      if (actual !== catalogEntry.sha256) {
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
