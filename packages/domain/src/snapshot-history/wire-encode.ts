import type { CanonicalJsonValue } from '@coc-helper/wire';

import { encodeSwiftSortedJson } from '../account/wire-encode';
import type {
  CanonicalSnapshotObservation,
  SnapshotCoverageField,
  SnapshotCoverageProof,
  SnapshotCoverageSourceSectionRelevance,
  SnapshotCoverageSourceUniverse,
  SnapshotDisplayBinding,
  SnapshotHistoryEntry,
  SnapshotItemIdentity,
  SnapshotNestedPathComponent,
  SnapshotObservationCoverage,
  SnapshotObservationItem,
  SnapshotSectionCoverage,
  SnapshotTimerFieldSpec,
  SnapshotTimerSchema,
} from './types';

export function encodeHistoryEntryWire(entry: SnapshotHistoryEntry): string {
  return encodeSwiftSortedJson(encodeHistoryEntryShape(entry));
}

export function historyEntryWireHex(entry: SnapshotHistoryEntry): string {
  const bytes = new TextEncoder().encode(encodeHistoryEntryWire(entry));
  return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function encodeIntegrityMaterialWire(
  entry: Omit<SnapshotHistoryEntry, 'integrityFingerprint'>,
): string {
  return encodeSwiftSortedJson({
    appliedAt: entry.appliedAtRefSeconds,
    baselineReason: entry.baselineReason ?? undefined,
    canonicalFingerprint: entry.canonicalFingerprint,
    coverage: encodeCoverageWire(entry.coverage),
    fingerprintVersion: entry.fingerprintVersion,
    integrityVersion: entry.integrityVersion,
    isBaseline: entry.isBaseline,
    lineageID: entry.lineageID,
    normalizedPlayerTag: entry.normalizedPlayerTag ?? undefined,
    observation: encodeObservationWire(entry.observation),
    observationVersion: entry.observationVersion,
    parserVersion: entry.parserVersion,
    rawJSON: entry.rawJSON,
    schemaVersion: entry.schemaVersion,
    snapshotID: entry.snapshotID,
    sourceTimestamp: entry.sourceTimestampRefSeconds ?? undefined,
    timerSchema: entry.timerSchema === null ? undefined : encodeTimerSchemaWire(entry.timerSchema),
    villageID: entry.villageID,
  });
}

function encodeHistoryEntryShape(entry: SnapshotHistoryEntry): unknown {
  return {
    appliedAt: entry.appliedAtRefSeconds,
    baselineReason: entry.baselineReason ?? undefined,
    canonicalFingerprint: entry.canonicalFingerprint,
    coverage: encodeCoverageWire(entry.coverage),
    fingerprintVersion: entry.fingerprintVersion,
    integrityFingerprint: entry.integrityFingerprint,
    integrityVersion: entry.integrityVersion,
    isBaseline: entry.isBaseline,
    lineageID: entry.lineageID,
    normalizedPlayerTag: entry.normalizedPlayerTag ?? undefined,
    observation: encodeObservationWire(entry.observation),
    observationVersion: entry.observationVersion,
    parserVersion: entry.parserVersion,
    rawJSON: entry.rawJSON,
    schemaVersion: entry.schemaVersion,
    snapshotID: entry.snapshotID,
    sourceTimestamp: entry.sourceTimestampRefSeconds ?? undefined,
    timerSchema: entry.timerSchema === null ? undefined : encodeTimerSchemaWire(entry.timerSchema),
    villageID: entry.villageID,
  };
}

function encodeObservationWire(observation: CanonicalSnapshotObservation): unknown {
  return {
    items: observation.items.map(encodeObservationItemWire),
    rawTopLevelFields: encodeCanonicalJsonObjectWire(observation.rawTopLevelFields),
    schemaVersion: observation.schemaVersion,
    unknownTopLevelFields: encodeCanonicalJsonObjectWire(observation.unknownTopLevelFields),
  };
}

function encodeCoverageWire(coverage: SnapshotObservationCoverage): unknown {
  return {
    diagnostics: [...coverage.diagnostics],
    fields: coverage.fields.map(encodeCoverageFieldWire),
    schemaVersion: coverage.schemaVersion,
    sections: coverage.sections.map(encodeSectionCoverageWire),
    sourceUniverse:
      coverage.sourceUniverse === null
        ? undefined
        : encodeSourceUniverseWire(coverage.sourceUniverse),
  };
}

function encodeObservationItemWire(item: SnapshotObservationItem): unknown {
  const encoded: Record<string, unknown> = {
    display: encodeDisplayBindingWire(item.display),
    identity: encodeIdentityWire(item.identity),
    rawTimerEvidence: encodeCanonicalJsonObjectWire(item.rawTimerEvidence),
    unknownFields: encodeCanonicalJsonObjectWire(item.unknownFields),
  };
  if (item.count !== null) {
    encoded.count = item.count;
  }
  if (item.gearUp !== null) {
    encoded.gearUp = item.gearUp;
  }
  if (item.helperRecurrent !== null) {
    encoded.helperRecurrent = item.helperRecurrent;
  }
  if (item.level !== null) {
    encoded.level = item.level;
  }
  if (item.weapon !== null) {
    encoded.weapon = item.weapon;
  }
  return encoded;
}

function encodeIdentityWire(identity: SnapshotItemIdentity): unknown {
  const encoded: Record<string, unknown> = {
    base: identity.base,
    dataID: bigintToWireNumber(identity.dataID),
    nestedKind: identity.nestedKind,
    nestedParentPath: identity.nestedParentPath.map(encodeNestedPathWire),
    rawSection: identity.rawSection,
  };
  if (identity.nestedRootDataID !== null) {
    encoded.nestedRootDataID = bigintToWireNumber(identity.nestedRootDataID);
  }
  if (identity.nestedRootIdentity !== null) {
    encoded.nestedRootIdentity = identity.nestedRootIdentity;
  }
  return encoded;
}

function encodeNestedPathWire(path: SnapshotNestedPathComponent): unknown {
  return {
    dataID: bigintToWireNumber(path.dataID),
    kind: path.kind,
  };
}

function encodeDisplayBindingWire(display: SnapshotDisplayBinding): unknown {
  const encoded: Record<string, unknown> = {};
  if (display.catalogFingerprint !== undefined) {
    encoded.catalogFingerprint = display.catalogFingerprint;
  }
  if (display.catalogVersion !== undefined) {
    encoded.catalogVersion = display.catalogVersion;
  }
  if (display.category !== undefined) {
    encoded.category = display.category;
  }
  if (display.displayCategory !== undefined) {
    encoded.displayCategory = display.displayCategory;
  }
  if (display.displayName !== undefined) {
    encoded.displayName = display.displayName;
  }
  return encoded;
}

function encodeCoverageFieldWire(field: SnapshotCoverageField): unknown {
  return {
    base: field.base,
    field: field.field,
    rawSection: field.rawSection,
    state: field.state,
  };
}

function encodeSectionCoverageWire(section: SnapshotSectionCoverage): unknown {
  return {
    base: section.base,
    completeness: section.completeness,
    observedCount: section.observedCount,
    presence: section.presence,
    proof: encodeCoverageProofWire(section.proof),
    rawSection: section.rawSection,
  };
}

function encodeCoverageProofWire(proof: SnapshotCoverageProof): unknown {
  switch (proof.kind) {
    case 'declared':
      return {
        expectedCount: proof.expectedCount ?? undefined,
        kind: 'declared',
        source: proof.source,
        version: proof.version,
      };
    case 'legacyAuthoritative':
      return {
        expectedCount: proof.expectedCount ?? undefined,
        kind: 'authoritative',
        source: proof.source,
        version: proof.version,
      };
    case 'verified':
      return {
        adapterID: proof.adapterID,
        expectedCount: proof.expectedCount ?? undefined,
        inputBinding: proof.inputBinding ?? undefined,
        kind: 'verified',
        protocolVersion: proof.protocolVersion,
        source: proof.source,
        verificationReason: proof.verificationReason ?? undefined,
        verificationRuleVersion: proof.verificationRuleVersion ?? undefined,
      };
    case 'unavailable':
      return {
        kind: 'unavailable',
        reason: proof.reason,
      };
  }
}

function encodeSourceUniverseWire(universe: SnapshotCoverageSourceUniverse): unknown {
  return {
    adapterID: universe.adapterID,
    protocolVersion: universe.protocolVersion,
    sections: universe.sections.map(encodeSourceSectionRelevanceWire),
  };
}

function encodeSourceSectionRelevanceWire(
  section: SnapshotCoverageSourceSectionRelevance,
): unknown {
  return {
    base: section.base,
    rawSection: section.rawSection,
    relevance: section.relevance,
  };
}

function encodeTimerSchemaWire(schema: SnapshotTimerSchema): unknown {
  const fields: Record<string, unknown> = {};
  for (const key of Object.keys(schema.fields).sort()) {
    fields[key] = encodeTimerFieldSpecWire(schema.fields[key]!);
  }
  return {
    fields,
    version: schema.version,
  };
}

function encodeTimerFieldSpecWire(spec: SnapshotTimerFieldSpec): unknown {
  const encoded: Record<string, unknown> = {
    semantics: spec.semantics,
    unit: spec.unit,
  };
  if (spec.maxValue !== undefined) {
    encoded.maxValue = spec.maxValue;
  }
  if (spec.minValue !== undefined) {
    encoded.minValue = spec.minValue;
  }
  return encoded;
}

function encodeCanonicalJsonObjectWire(
  fields: Readonly<Record<string, CanonicalJsonValue>>,
): Record<string, unknown> {
  const encoded: Record<string, unknown> = {};
  for (const key of Object.keys(fields).sort()) {
    encoded[key] = encodeCanonicalJsonValueWire(fields[key]!);
  }
  return encoded;
}

function encodeCanonicalJsonValueWire(value: CanonicalJsonValue): unknown {
  switch (value.kind) {
    case 'null':
      return { kind: 'null' };
    case 'bool':
      return { kind: 'bool', value: value.value };
    case 'number':
      return { kind: 'number', value: value.value };
    case 'string':
      return { kind: 'string', value: value.value };
    case 'array':
      return { kind: 'array', items: value.items.map(encodeCanonicalJsonValueWire) };
    case 'object': {
      const fields: Record<string, unknown> = {};
      for (const key of Object.keys(value.fields).sort()) {
        fields[key] = encodeCanonicalJsonValueWire(value.fields[key]!);
      }
      return { kind: 'object', fields };
    }
  }
}

function bigintToWireNumber(value: bigint): number {
  const asNumber = Number(value);
  if (!Number.isSafeInteger(asNumber) || BigInt(asNumber) !== value) {
    throw new RangeError(`wire 编码超出 JS safe integer：${value.toString()}`);
  }
  return asNumber;
}
