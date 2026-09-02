import { isSha256Fingerprint, parseUuid, type UuidString } from '@coc-helper/wire';

import { parseAccountSnapshot } from '../account/parser';
import {
  canonicalizeSnapshotHistory,
  fingerprintForObservation,
  integrityFingerprint,
} from './canonicalizer';
import { lineageIndexesEqual, recomputeLineageIndexFromEntries } from './lineage-index';
import { SNAPSHOT_HISTORY_SCHEMA } from './schema';
import type { SnapshotHistoryStoreError } from './errors';
import {
  coverageHasLegacySectionEvidence,
  hydrateVerifiedCoverageOnEnvelope,
} from './trust-hydration';
import type { SnapshotCoverageRevalidationPolicy, SnapshotHistoryEnvelope } from './store-types';
import type { SnapshotHistoryEntry } from './types';

export type ValidateSnapshotHistoryEnvelopeOptions = {
  readonly validateIntegrity?: (entry: SnapshotHistoryEntry) => void;
};

const defaultValidateIntegrity = (entry: SnapshotHistoryEntry): void => {
  validateSnapshotHistoryEntryIntegrity(entry);
};

export function validateSnapshotHistoryEnvelope(
  envelope: SnapshotHistoryEnvelope,
  options: ValidateSnapshotHistoryEnvelopeOptions = {},
): SnapshotHistoryEnvelope {
  const validateIntegrity = options.validateIntegrity ?? defaultValidateIntegrity;
  if (envelope.schemaVersion !== SNAPSHOT_HISTORY_SCHEMA.envelope) {
    throw storeError({
      kind: 'unsupportedSchema',
      version: envelope.schemaVersion,
    });
  }

  const entryIDs = new Set<UuidString>();
  for (const entry of envelope.entries) {
    if (entryIDs.has(entry.snapshotID)) {
      throw storeError({ kind: 'invalidEntry', message: '存在重复的 snapshotID。' });
    }
    entryIDs.add(entry.snapshotID);
    validateSnapshotHistoryEntry(entry, { validateIntegrity });
  }

  const lineageIDs = new Set<UuidString>();
  const activeVillages = new Set<UuidString>();
  for (const lineage of envelope.lineages) {
    if (lineageIDs.has(lineage.lineageID)) {
      throw storeError({ kind: 'invalidEntry', message: '存在重复的 lineageID。' });
    }
    lineageIDs.add(lineage.lineageID);
    if (lineage.isActive && activeVillages.has(lineage.villageID)) {
      throw storeError({ kind: 'invalidEntry', message: '同一村庄存在多个 active lineage。' });
    }
    if (lineage.isActive) {
      activeVillages.add(lineage.villageID);
    }
    const lastEntry = envelope.entries.find((entry) => entry.snapshotID === lineage.lastEntryID);
    if (
      lastEntry === undefined ||
      lastEntry.villageID !== lineage.villageID ||
      lastEntry.lineageID !== lineage.lineageID ||
      lastEntry.canonicalFingerprint !== lineage.lastFingerprint ||
      lastEntry.normalizedPlayerTag !== lineage.normalizedPlayerTag ||
      lastEntry.appliedAtRefSeconds !== lineage.lastAppliedAtRefSeconds
    ) {
      throw storeError({
        kind: 'invalidEntry',
        message: 'lineage index 指向不存在或不匹配的 entry。',
      });
    }
  }

  if (!lineageIndexesEqual(envelope.lineages, recomputeLineageIndexFromEntries(envelope.entries))) {
    throw storeError({
      kind: 'invalidEntry',
      message: 'lineage index 与 entries 派生结果不一致。',
    });
  }

  for (const [rawID, metadata] of Object.entries(envelope.duplicateMetadata)) {
    const snapshotID = parseUuid(rawID);
    if (snapshotID === undefined || !entryIDs.has(snapshotID)) {
      throw storeError({
        kind: 'invalidEntry',
        message: 'duplicate metadata 指向不存在的 entry。',
      });
    }
    if (metadata.duplicateImportCount <= 0) {
      throw storeError({
        kind: 'invalidEntry',
        message: 'duplicateImportCount 必须为正数。',
      });
    }
  }

  if (
    envelope.migrationMarker !== null &&
    envelope.migrationMarker.version !== SNAPSHOT_HISTORY_SCHEMA.envelope
  ) {
    throw storeError({
      kind: 'unsupportedSchema',
      version: envelope.migrationMarker.version,
    });
  }
  if (
    envelope.migrationMarker === null &&
    (envelope.entries.length > 0 ||
      envelope.lineages.length > 0 ||
      Object.keys(envelope.duplicateMetadata).length > 0)
  ) {
    throw storeError({
      kind: 'invalidEntry',
      message: '未完成迁移的历史 envelope 不得包含 entries。',
    });
  }

  return envelope;
}

export function validateSnapshotHistoryEntry(
  entry: SnapshotHistoryEntry,
  options: ValidateSnapshotHistoryEnvelopeOptions = {},
): SnapshotHistoryEntry {
  if (entry.schemaVersion !== SNAPSHOT_HISTORY_SCHEMA.entry) {
    throw storeError({ kind: 'unsupportedSchema', version: entry.schemaVersion });
  }
  if (
    entry.observationVersion < SNAPSHOT_HISTORY_SCHEMA.observationWithSectionEvidence ||
    entry.observationVersion > SNAPSHOT_HISTORY_SCHEMA.observation
  ) {
    throw storeError({ kind: 'unsupportedSchema', version: entry.observationVersion });
  }
  if (
    entry.observation.schemaVersion !== entry.observationVersion ||
    entry.coverage.schemaVersion !== entry.observationVersion
  ) {
    throw storeError({
      kind: 'invalidEntry',
      message: '历史 entry 的 observation/coverage 版本不一致。',
    });
  }
  if (
    entry.observationVersion >= SNAPSHOT_HISTORY_SCHEMA.observationWithSectionEvidence &&
    coverageHasLegacySectionEvidence(entry.coverage)
  ) {
    throw storeError({
      kind: 'invalidEntry',
      message: '历史 entry 的 observation v2+ 缺少 section 完整性证据。',
    });
  }
  if (
    entry.observationVersion < SNAPSHOT_HISTORY_SCHEMA.observationWithSourceUniverse &&
    entry.coverage.sourceUniverse !== null
  ) {
    throw storeError({
      kind: 'invalidEntry',
      message: 'observation v5 及更早的 entry 不得携带 source universe。',
    });
  }
  if (entry.fingerprintVersion !== SNAPSHOT_HISTORY_SCHEMA.fingerprint) {
    throw storeError({ kind: 'unsupportedSchema', version: entry.fingerprintVersion });
  }
  if (entry.integrityVersion !== SNAPSHOT_HISTORY_SCHEMA.integrity) {
    throw storeError({ kind: 'unsupportedSchema', version: entry.integrityVersion });
  }
  if (entry.rawJSON.trim().length === 0) {
    throw storeError({ kind: 'invalidEntry', message: '历史 entry 缺少 rawJSON。' });
  }
  if (!isSha256Fingerprint(entry.canonicalFingerprint)) {
    throw storeError({ kind: 'invalidEntry', message: '历史 entry 的 fingerprint 格式无效。' });
  }
  if (!isSha256Fingerprint(entry.integrityFingerprint)) {
    throw storeError({ kind: 'invalidEntry', message: '历史 entry 的完整性摘要格式无效。' });
  }

  if (options.validateIntegrity !== undefined) {
    options.validateIntegrity(entry);
  }

  return entry;
}

export function validateSnapshotHistoryEntryIntegrity(entry: SnapshotHistoryEntry): void {
  const expectedIntegrity = integrityFingerprint(entry);
  if (expectedIntegrity !== entry.integrityFingerprint) {
    throw storeError({
      kind: 'invalidEntry',
      message: '历史 entry 的完整性摘要不一致。',
    });
  }

  const parsed = parseAccountSnapshot(entry.rawJSON, { clock: { nowMs: () => 1000 } });
  if (!parsed.ok) {
    throw storeError({
      kind: 'invalidEntry',
      message: `历史 entry 的 rawJSON 无法重建 observation：${parsed.error.kind}`,
    });
  }

  let rebuilt;
  try {
    rebuilt = canonicalizeSnapshotHistory(parsed.value, {
      villageID: entry.villageID,
      lineageID: entry.lineageID,
      appliedAtRefSeconds: entry.appliedAtRefSeconds,
      snapshotID: entry.snapshotID,
      isBaseline: entry.isBaseline,
      baselineReason: entry.baselineReason,
      observationVersion: entry.observationVersion,
      timerSchema: entry.timerSchema,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw storeError({
      kind: 'invalidEntry',
      message: `历史 entry 的 rawJSON 无法重建 observation：${message}`,
    });
  }

  const storedObservationFingerprint = fingerprintForObservation(entry.observation);
  if (storedObservationFingerprint !== entry.canonicalFingerprint) {
    throw storeError({
      kind: 'invalidEntry',
      message: '历史 entry 的 observation 与 canonicalFingerprint 不一致。',
    });
  }
  if (rebuilt.canonicalFingerprint !== entry.canonicalFingerprint) {
    throw storeError({
      kind: 'invalidEntry',
      message: '历史 entry 的 rawJSON 与 canonicalFingerprint 不一致。',
    });
  }
}

export function hydrateSnapshotHistoryEnvelope(
  envelope: SnapshotHistoryEnvelope,
  policy: SnapshotCoverageRevalidationPolicy = 'production',
): SnapshotHistoryEnvelope {
  return hydrateVerifiedCoverageOnEnvelope({ envelope, policy });
}

function storeError(error: SnapshotHistoryStoreError): SnapshotHistoryStoreError {
  return error;
}
