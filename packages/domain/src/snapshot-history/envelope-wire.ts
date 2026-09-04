import { encodeSwiftSortedJson } from '../account/wire-encode';
import type { CanonicalJsonValue, UuidString } from '@coc-helper/wire';
import { parseUuid } from '@coc-helper/wire';

import { encodeHistoryEntryWire } from './wire-encode';
import { SNAPSHOT_HISTORY_SCHEMA } from './schema';
import type {
  SnapshotHistoryDiagnostic,
  SnapshotHistoryDuplicateMetadata,
  SnapshotHistoryEnvelope,
  SnapshotHistoryLineageMetadata,
  SnapshotHistoryMigrationMarker,
} from './store-types';
import type {
  CanonicalSnapshotObservation,
  SnapshotCoverageField,
  SnapshotCoverageProof,
  SnapshotCoverageSourceSectionRelevance,
  SnapshotCoverageSourceUniverse,
  SnapshotCoverageState,
  SnapshotDisplayBinding,
  SnapshotHistoryBase,
  SnapshotHistoryEntry,
  SnapshotLineageReason,
  SnapshotNestedKind,
  SnapshotNestedPathComponent,
  SnapshotObservationCoverage,
  SnapshotObservationItem,
  SnapshotSectionCoverage,
  SnapshotSectionPresence,
  SnapshotTimerFieldSpec,
  SnapshotTimerSchema,
} from './types';

export function encodeSnapshotHistoryEnvelopeWire(envelope: SnapshotHistoryEnvelope): string {
  return encodeSwiftSortedJson(encodeEnvelopeShape(envelope));
}

export function decodeSnapshotHistoryEnvelopeWire(source: string): SnapshotHistoryEnvelope {
  const parsed: unknown = JSON.parse(source);
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('历史 envelope 顶层必须是对象。');
  }
  return decodeEnvelopeShape(parsed as Record<string, unknown>);
}

function encodeEnvelopeShape(envelope: SnapshotHistoryEnvelope): unknown {
  const duplicateMetadata: Record<string, unknown> = {};
  for (const key of Object.keys(envelope.duplicateMetadata).sort()) {
    const metadata = envelope.duplicateMetadata[key]!;
    duplicateMetadata[key] = {
      duplicateImportCount: metadata.duplicateImportCount,
      lastSeenAt: metadata.lastSeenAtRefSeconds,
      lastSourceTimestamp: metadata.lastSourceTimestampRefSeconds ?? undefined,
    };
  }

  return {
    duplicateMetadata,
    entries: envelope.entries.map((entry) => JSON.parse(encodeHistoryEntryWire(entry))),
    lastDiagnostic:
      envelope.lastDiagnostic === null
        ? undefined
        : {
            kind: envelope.lastDiagnostic.kind,
            message: envelope.lastDiagnostic.message,
            recordedAt: envelope.lastDiagnostic.recordedAtRefSeconds,
          },
    lineages: envelope.lineages.map((lineage) => ({
      hasConflict: lineage.hasConflict,
      isActive: lineage.isActive,
      lastAppliedAt: lineage.lastAppliedAtRefSeconds,
      lastEntryID: lineage.lastEntryID,
      lineageID: lineage.lineageID,
      normalizedPlayerTag: lineage.normalizedPlayerTag ?? undefined,
      villageID: lineage.villageID,
    })),
    migrationMarker:
      envelope.migrationMarker === null
        ? undefined
        : {
            completedAt: envelope.migrationMarker.completedAtRefSeconds,
            version: envelope.migrationMarker.version,
          },
    schemaVersion: envelope.schemaVersion,
  };
}

function decodeEnvelopeShape(wire: Record<string, unknown>): SnapshotHistoryEnvelope {
  const schemaVersion = requireNumber(wire.schemaVersion, 'schemaVersion');
  const entriesWire = requireArray(wire.entries, 'entries');
  const lineagesWire = requireArray(wire.lineages, 'lineages');
  const duplicateWire =
    wire.duplicateMetadata === undefined
      ? {}
      : requireObject(wire.duplicateMetadata, 'duplicateMetadata');

  const duplicateMetadata: Record<string, SnapshotHistoryDuplicateMetadata> = {};
  for (const key of Object.keys(duplicateWire)) {
    const metadata = requireObject(duplicateWire[key], `duplicateMetadata.${key}`);
    duplicateMetadata[key] = {
      duplicateImportCount: requireNumber(metadata.duplicateImportCount, 'duplicateImportCount'),
      lastSeenAtRefSeconds: requireNumber(metadata.lastSeenAt, 'lastSeenAt'),
      lastSourceTimestampRefSeconds:
        metadata.lastSourceTimestamp === undefined
          ? null
          : requireNumber(metadata.lastSourceTimestamp, 'lastSourceTimestamp'),
    };
  }

  return {
    schemaVersion,
    entries: entriesWire.map((entry, index) =>
      decodeHistoryEntryWire(requireObject(entry, `entries[${String(index)}]`)),
    ),
    lineages: lineagesWire.map((lineage, index) =>
      decodeLineageWire(requireObject(lineage, `lineages[${String(index)}]`)),
    ),
    duplicateMetadata,
    migrationMarker:
      wire.migrationMarker === undefined
        ? null
        : decodeMigrationMarkerWire(requireObject(wire.migrationMarker, 'migrationMarker')),
    lastDiagnostic:
      wire.lastDiagnostic === undefined
        ? null
        : decodeDiagnosticWire(requireObject(wire.lastDiagnostic, 'lastDiagnostic')),
  };
}

function decodeHistoryEntryWire(wire: Record<string, unknown>): SnapshotHistoryEntry {
  return {
    schemaVersion: requireNumber(wire.schemaVersion, 'schemaVersion'),
    observationVersion: requireNumber(wire.observationVersion, 'observationVersion'),
    snapshotID: requireUuid(wire.snapshotID, 'snapshotID'),
    villageID: requireUuid(wire.villageID, 'villageID'),
    lineageID: requireUuid(wire.lineageID, 'lineageID'),
    normalizedPlayerTag:
      wire.normalizedPlayerTag === undefined ? null : requireString(wire.normalizedPlayerTag),
    appliedAtRefSeconds: requireNumber(wire.appliedAt, 'appliedAt'),
    sourceTimestampRefSeconds:
      wire.sourceTimestamp === undefined
        ? null
        : requireNumber(wire.sourceTimestamp, 'sourceTimestamp'),
    parserVersion: requireString(wire.parserVersion),
    rawJSON: requireString(wire.rawJSON),
    observation: decodeObservationWire(requireObject(wire.observation, 'observation')),
    coverage: decodeCoverageWire(requireObject(wire.coverage, 'coverage')),
    isBaseline: requireBoolean(wire.isBaseline, 'isBaseline'),
    baselineReason:
      wire.baselineReason === undefined ? null : requireLineageReason(wire.baselineReason),
    timerSchema:
      wire.timerSchema === undefined
        ? null
        : decodeTimerSchemaWire(requireObject(wire.timerSchema, 'timerSchema')),
  };
}

function decodeLineageWire(wire: Record<string, unknown>): SnapshotHistoryLineageMetadata {
  return {
    villageID: requireUuid(wire.villageID, 'villageID'),
    lineageID: requireUuid(wire.lineageID, 'lineageID'),
    normalizedPlayerTag:
      wire.normalizedPlayerTag === undefined ? null : requireString(wire.normalizedPlayerTag),
    lastEntryID: requireUuid(wire.lastEntryID, 'lastEntryID'),
    lastAppliedAtRefSeconds: requireNumber(wire.lastAppliedAt, 'lastAppliedAt'),
    hasConflict: requireBoolean(wire.hasConflict, 'hasConflict'),
    isActive: requireBoolean(wire.isActive, 'isActive'),
  };
}

function decodeMigrationMarkerWire(wire: Record<string, unknown>): SnapshotHistoryMigrationMarker {
  return {
    version: requireNumber(wire.version, 'version'),
    completedAtRefSeconds: requireNumber(wire.completedAt, 'completedAt'),
  };
}

function decodeDiagnosticWire(wire: Record<string, unknown>): SnapshotHistoryDiagnostic {
  const kind = requireString(wire.kind);
  if (
    kind !== 'corrupt' &&
    kind !== 'unsupportedSchema' &&
    kind !== 'unavailable' &&
    kind !== 'writeFailed'
  ) {
    throw new Error(`无效的 diagnostic kind：${kind}`);
  }
  return {
    kind,
    message: requireString(wire.message),
    recordedAtRefSeconds: requireNumber(wire.recordedAt, 'recordedAt'),
  };
}

function decodeObservationWire(wire: Record<string, unknown>): CanonicalSnapshotObservation {
  return {
    schemaVersion: requireNumber(wire.schemaVersion, 'schemaVersion'),
    items: requireArray(wire.items, 'items').map((item, index) =>
      decodeObservationItemWire(requireObject(item, `items[${String(index)}]`)),
    ),
    rawTopLevelFields: decodeCanonicalJsonObjectWire(
      requireObject(wire.rawTopLevelFields, 'rawTopLevelFields'),
    ),
    unknownTopLevelFields: decodeCanonicalJsonObjectWire(
      requireObject(wire.unknownTopLevelFields, 'unknownTopLevelFields'),
    ),
  };
}

function decodeCoverageWire(wire: Record<string, unknown>): SnapshotObservationCoverage {
  return {
    schemaVersion: requireNumber(wire.schemaVersion, 'schemaVersion'),
    diagnostics: requireArray(wire.diagnostics, 'diagnostics').map((value, index) =>
      requireString(value, `diagnostics[${String(index)}]`),
    ),
    fields: requireArray(wire.fields, 'fields').map((field, index) =>
      decodeCoverageFieldWire(requireObject(field, `fields[${String(index)}]`)),
    ),
    sections: requireArray(wire.sections, 'sections').map((section, index) =>
      decodeSectionCoverageWire(requireObject(section, `sections[${String(index)}]`)),
    ),
    sourceUniverse:
      wire.sourceUniverse === undefined
        ? null
        : decodeSourceUniverseWire(requireObject(wire.sourceUniverse, 'sourceUniverse')),
  };
}

function decodeObservationItemWire(wire: Record<string, unknown>): SnapshotObservationItem {
  return {
    identity: decodeIdentityWire(requireObject(wire.identity, 'identity')),
    level: wire.level === undefined ? null : requireNumber(wire.level, 'level'),
    count: wire.count === undefined ? null : requireNumber(wire.count, 'count'),
    rawTimerEvidence: decodeCanonicalJsonObjectWire(
      requireObject(wire.rawTimerEvidence, 'rawTimerEvidence'),
    ),
    helperRecurrent:
      wire.helperRecurrent === undefined
        ? null
        : requireBoolean(wire.helperRecurrent, 'helperRecurrent'),
    gearUp: wire.gearUp === undefined ? null : requireNumber(wire.gearUp, 'gearUp'),
    weapon: wire.weapon === undefined ? null : requireNumber(wire.weapon, 'weapon'),
    unknownFields: decodeCanonicalJsonObjectWire(
      requireObject(wire.unknownFields, 'unknownFields'),
    ),
    display: decodeDisplayBindingWire(requireObject(wire.display, 'display')),
  };
}

function decodeIdentityWire(wire: Record<string, unknown>): SnapshotObservationItem['identity'] {
  return {
    base: requireHistoryBase(wire.base),
    rawSection: requireString(wire.rawSection),
    dataID: wireNumberToBigint(wire.dataID, 'dataID'),
    nestedKind: requireNestedKind(wire.nestedKind),
    nestedRootIdentity:
      wire.nestedRootIdentity === undefined ? null : requireString(wire.nestedRootIdentity),
    nestedRootDataID:
      wire.nestedRootDataID === undefined
        ? null
        : wireNumberToBigint(wire.nestedRootDataID, 'nestedRootDataID'),
    nestedParentPath: requireArray(wire.nestedParentPath, 'nestedParentPath').map((path, index) =>
      decodeNestedPathWire(requireObject(path, `nestedParentPath[${String(index)}]`)),
    ),
  };
}

function decodeNestedPathWire(wire: Record<string, unknown>): SnapshotNestedPathComponent {
  return {
    kind: requireNestedKind(wire.kind),
    dataID: wireNumberToBigint(wire.dataID, 'dataID'),
  };
}

function decodeDisplayBindingWire(wire: Record<string, unknown>): SnapshotDisplayBinding {
  return {
    ...(wire.catalogVersion !== undefined
      ? { catalogVersion: requireString(wire.catalogVersion) }
      : {}),
    ...(wire.category !== undefined ? { category: requireString(wire.category) } : {}),
    ...(wire.displayCategory !== undefined
      ? { displayCategory: requireString(wire.displayCategory) }
      : {}),
    ...(wire.displayName !== undefined ? { displayName: requireString(wire.displayName) } : {}),
  };
}

function decodeCoverageFieldWire(wire: Record<string, unknown>): SnapshotCoverageField {
  return {
    base: requireHistoryBase(wire.base),
    rawSection: requireString(wire.rawSection),
    field: requireString(wire.field),
    state: requireCoverageState(wire.state),
  };
}

function decodeSectionCoverageWire(wire: Record<string, unknown>): SnapshotSectionCoverage {
  return {
    base: requireHistoryBase(wire.base),
    rawSection: requireString(wire.rawSection),
    presence: requireSectionPresence(wire.presence),
    completeness: requireCoverageState(wire.completeness),
    proof: decodeCoverageProofWire(requireObject(wire.proof, 'proof')),
    observedCount: requireNumber(wire.observedCount, 'observedCount'),
  };
}

function decodeCoverageProofWire(wire: Record<string, unknown>): SnapshotCoverageProof {
  const kind = requireString(wire.kind);
  switch (kind) {
    case 'declared':
      return {
        kind: 'declared',
        source: requireString(wire.source),
        version: requireString(wire.version),
        expectedCount:
          wire.expectedCount === undefined
            ? null
            : requireNumber(wire.expectedCount, 'expectedCount'),
      };
    case 'verified':
      return {
        kind: 'verified',
        source: requireString(wire.source),
        adapterID: requireString(wire.adapterID),
        protocolVersion: requireString(wire.protocolVersion),
        expectedCount:
          wire.expectedCount === undefined
            ? null
            : requireNumber(wire.expectedCount, 'expectedCount'),
        verificationReason:
          wire.verificationReason === undefined ? null : requireString(wire.verificationReason),
        verificationRuleVersion:
          wire.verificationRuleVersion === undefined
            ? null
            : requireString(wire.verificationRuleVersion),
        fixtureID: wire.fixtureID === undefined ? null : requireString(wire.fixtureID),
      };
    case 'authoritative':
      return {
        kind: 'legacyAuthoritative',
        source: requireString(wire.source),
        version: requireString(wire.version),
        expectedCount:
          wire.expectedCount === undefined
            ? null
            : requireNumber(wire.expectedCount, 'expectedCount'),
      };
    case 'unavailable':
      return {
        kind: 'unavailable',
        reason: requireString(wire.reason),
      };
    default:
      throw new Error(`无效的 coverage proof kind：${kind}`);
  }
}

function decodeSourceUniverseWire(wire: Record<string, unknown>): SnapshotCoverageSourceUniverse {
  return {
    adapterID: requireString(wire.adapterID),
    protocolVersion: requireString(wire.protocolVersion),
    sections: requireArray(wire.sections, 'sections').map((section, index) =>
      decodeSourceSectionRelevanceWire(requireObject(section, `sections[${String(index)}]`)),
    ),
  };
}

function decodeSourceSectionRelevanceWire(
  wire: Record<string, unknown>,
): SnapshotCoverageSourceSectionRelevance {
  return {
    base: requireHistoryBase(wire.base),
    rawSection: requireString(wire.rawSection),
    relevance: requireSectionRelevance(wire.relevance),
  };
}

function decodeTimerSchemaWire(wire: Record<string, unknown>): SnapshotTimerSchema {
  const fieldsWire = requireObject(wire.fields, 'fields');
  const fields: Record<string, SnapshotTimerFieldSpec> = {};
  for (const key of Object.keys(fieldsWire)) {
    fields[key] = decodeTimerFieldSpecWire(requireObject(fieldsWire[key], `fields.${key}`));
  }
  return {
    version: requireString(wire.version),
    fields,
  };
}

function decodeTimerFieldSpecWire(wire: Record<string, unknown>): SnapshotTimerFieldSpec {
  return {
    unit: requireTimerUnit(wire.unit),
    semantics: requireTimerSemantics(wire.semantics),
    ...(wire.minValue !== undefined ? { minValue: requireNumber(wire.minValue, 'minValue') } : {}),
    ...(wire.maxValue !== undefined ? { maxValue: requireNumber(wire.maxValue, 'maxValue') } : {}),
  };
}

function decodeCanonicalJsonObjectWire(
  wire: Record<string, unknown>,
): Readonly<Record<string, CanonicalJsonValue>> {
  const fields: Record<string, CanonicalJsonValue> = {};
  for (const key of Object.keys(wire)) {
    fields[key] = decodeCanonicalJsonValueWire(wire[key]);
  }
  return fields;
}

function decodeCanonicalJsonValueWire(value: unknown): CanonicalJsonValue {
  const wire = requireObject(value, 'canonicalJsonValue');
  const kind = requireString(wire.kind);
  switch (kind) {
    case 'null':
      return { kind: 'null' };
    case 'bool':
      return { kind: 'bool', value: requireBoolean(wire.value, 'value') };
    case 'number':
      return { kind: 'number', value: requireString(wire.value) };
    case 'string':
      return { kind: 'string', value: requireString(wire.value) };
    case 'array':
      return {
        kind: 'array',
        items: requireArray(wire.items, 'items').map((item) => decodeCanonicalJsonValueWire(item)),
      };
    case 'object': {
      const fieldsWire = requireObject(wire.fields, 'fields');
      const fields: Record<string, CanonicalJsonValue> = {};
      for (const key of Object.keys(fieldsWire)) {
        fields[key] = decodeCanonicalJsonValueWire(fieldsWire[key]);
      }
      return { kind: 'object', fields };
    }
    default:
      throw new Error(`无效的 canonical json kind：${kind}`);
  }
}

function requireObject(value: unknown, label = 'value'): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} 必须是对象。`);
  }
  return value as Record<string, unknown>;
}

function requireArray(value: unknown, label: string): unknown[] {
  if (!Array.isArray(value)) {
    throw new Error(`${label} 必须是数组。`);
  }
  return value;
}

function requireString(value: unknown, label = 'value'): string {
  if (typeof value !== 'string') {
    throw new Error(`${label} 必须是字符串。`);
  }
  return value;
}

function requireNumber(value: unknown, label: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error(`${label} 必须是有限数字。`);
  }
  return value;
}

function requireBoolean(value: unknown, label: string): boolean {
  if (typeof value !== 'boolean') {
    throw new Error(`${label} 必须是布尔值。`);
  }
  return value;
}

function requireUuid(value: unknown, label: string): UuidString {
  const parsed = parseUuid(requireString(value, label));
  if (parsed === undefined) {
    throw new Error(`${label} 不是有效 UUID。`);
  }
  return parsed;
}

function wireNumberToBigint(value: unknown, label: string): bigint {
  const number = requireNumber(value, label);
  if (!Number.isSafeInteger(number)) {
    throw new Error(`${label} 超出安全整数范围。`);
  }
  return BigInt(number);
}

function requireHistoryBase(value: unknown): SnapshotHistoryBase {
  const base = requireString(value);
  if (base !== 'home' && base !== 'builder' && base !== 'unknown') {
    throw new Error(`无效的 base：${base}`);
  }
  return base;
}

function requireNestedKind(value: unknown): SnapshotNestedKind {
  const kind = requireString(value);
  if (kind !== 'root' && kind !== 'type' && kind !== 'module' && kind !== 'unknown') {
    throw new Error(`无效的 nestedKind：${kind}`);
  }
  return kind;
}

function requireCoverageState(value: unknown): SnapshotCoverageState {
  const state = requireString(value);
  if (state !== 'complete' && state !== 'partial' && state !== 'unavailable') {
    throw new Error(`无效的 coverage state：${state}`);
  }
  return state;
}

function requireSectionPresence(value: unknown): SnapshotSectionPresence {
  const presence = requireString(value);
  if (
    presence !== 'missing' &&
    presence !== 'presentEmpty' &&
    presence !== 'presentNonEmpty' &&
    presence !== 'invalid'
  ) {
    throw new Error(`无效的 section presence：${presence}`);
  }
  return presence;
}

function requireSectionRelevance(value: unknown) {
  const relevance = requireString(value);
  if (relevance !== 'required' && relevance !== 'notApplicable' && relevance !== 'unknown') {
    throw new Error(`无效的 section relevance：${relevance}`);
  }
  return relevance;
}

function requireTimerUnit(value: unknown) {
  const unit = requireString(value);
  if (unit !== 'seconds' && unit !== 'milliseconds') {
    throw new Error(`无效的 timer unit：${unit}`);
  }
  return unit;
}

function requireTimerSemantics(value: unknown) {
  const semantics = requireString(value);
  if (semantics !== 'remaining' && semantics !== 'absolute') {
    throw new Error(`无效的 timer semantics：${semantics}`);
  }
  return semantics;
}

function requireLineageReason(value: unknown): SnapshotLineageReason {
  const reason = requireString(value);
  if (
    reason !== 'initial' &&
    reason !== 'sameVillageAndTag' &&
    reason !== 'tagChanged' &&
    reason !== 'missingTag' &&
    reason !== 'invalidTag' &&
    reason !== 'villageChanged' &&
    reason !== 'previousConflict'
  ) {
    throw new Error(`无效的 baselineReason：${reason}`);
  }
  return reason;
}

export function createSnapshotHistoryMigrationMarker(
  completedAtRefSeconds: number,
): SnapshotHistoryMigrationMarker {
  return {
    version: SNAPSHOT_HISTORY_SCHEMA.envelope,
    completedAtRefSeconds,
  };
}
