import type { SnapshotCoverageProof, SnapshotHistoryEntry, SnapshotObservationCoverage } from './types';
import type { SnapshotTimerSchema } from './types';

export type SnapshotHistoryProofDuplicateKey =
  | {
      readonly kind: 'declared';
      readonly source: string;
      readonly version: string;
      readonly expectedCount: number | null;
    }
  | {
      readonly kind: 'verified';
      readonly source: string;
      readonly adapterID: string;
      readonly protocolVersion: string;
      readonly expectedCount: number | null;
      readonly verificationReason: string | null;
      readonly verificationRuleVersion: string | null;
      readonly inputBinding: string | null;
    }
  | {
      readonly kind: 'legacyAuthoritative';
      readonly source: string;
      readonly version: string;
      readonly expectedCount: number | null;
    }
  | { readonly kind: 'unavailable'; readonly reason: string };

export function snapshotHistoryProofDuplicateKey(
  proof: SnapshotCoverageProof,
): SnapshotHistoryProofDuplicateKey {
  switch (proof.kind) {
    case 'declared':
      return {
        kind: 'declared',
        source: proof.source,
        version: proof.version,
        expectedCount: proof.expectedCount,
      };
    case 'verified':
      return {
        kind: 'verified',
        source: proof.source,
        adapterID: proof.adapterID,
        protocolVersion: proof.protocolVersion,
        expectedCount: proof.expectedCount,
        verificationReason: proof.verificationReason,
        verificationRuleVersion: proof.verificationRuleVersion,
        inputBinding: proof.inputBinding,
      };
    case 'legacyAuthoritative':
      return {
        kind: 'legacyAuthoritative',
        source: proof.source,
        version: proof.version,
        expectedCount: proof.expectedCount,
      };
    case 'unavailable':
      return { kind: 'unavailable', reason: proof.reason };
  }
}

export type SnapshotHistorySectionDuplicateKey = {
  readonly base: SnapshotHistoryEntry['coverage']['sections'][number]['base'];
  readonly rawSection: string;
  readonly presence: SnapshotHistoryEntry['coverage']['sections'][number]['presence'];
  readonly completeness: SnapshotHistoryEntry['coverage']['sections'][number]['completeness'];
  readonly proof: SnapshotHistoryProofDuplicateKey;
  readonly observedCount: number;
};

export function snapshotHistorySectionDuplicateKey(
  section: SnapshotHistoryEntry['coverage']['sections'][number],
): SnapshotHistorySectionDuplicateKey {
  return {
    base: section.base,
    rawSection: section.rawSection,
    presence: section.presence,
    completeness: section.completeness,
    proof: snapshotHistoryProofDuplicateKey(section.proof),
    observedCount: section.observedCount,
  };
}

export type SnapshotHistoryCoverageDuplicateKey = {
  readonly schemaVersion: number;
  readonly fields: SnapshotObservationCoverage['fields'];
  readonly sections: readonly SnapshotHistorySectionDuplicateKey[];
  readonly diagnostics: readonly string[];
  readonly sourceUniverse: SnapshotObservationCoverage['sourceUniverse'];
};

export function snapshotHistoryCoverageDuplicateKey(
  coverage: SnapshotObservationCoverage,
): SnapshotHistoryCoverageDuplicateKey {
  return {
    schemaVersion: coverage.schemaVersion,
    fields: coverage.fields,
    sections: coverage.sections.map(snapshotHistorySectionDuplicateKey),
    diagnostics: coverage.diagnostics,
    sourceUniverse: coverage.sourceUniverse,
  };
}

export type SnapshotHistoryDuplicateKey = {
  readonly canonicalFingerprint: string;
  readonly coverage: SnapshotHistoryCoverageDuplicateKey;
  readonly timerSchema: SnapshotTimerSchema | null;
};

export function snapshotHistoryDuplicateKey(entry: SnapshotHistoryEntry): SnapshotHistoryDuplicateKey {
  return {
    canonicalFingerprint: entry.canonicalFingerprint,
    coverage: snapshotHistoryCoverageDuplicateKey(entry.coverage),
    timerSchema: entry.timerSchema,
  };
}

export function snapshotHistoryDuplicateKeysMatch(
  left: SnapshotHistoryEntry,
  right: SnapshotHistoryEntry,
): boolean {
  const leftKey = snapshotHistoryDuplicateKey(left);
  const rightKey = snapshotHistoryDuplicateKey(right);
  return (
    leftKey.canonicalFingerprint === rightKey.canonicalFingerprint &&
    coverageDuplicateKeysEqual(leftKey.coverage, rightKey.coverage) &&
    timerSchemasEqual(leftKey.timerSchema, rightKey.timerSchema)
  );
}

export function snapshotHistoryCoverageDuplicateKeysEqual(
  left: SnapshotHistoryCoverageDuplicateKey,
  right: SnapshotHistoryCoverageDuplicateKey,
): boolean {
  return coverageDuplicateKeysEqual(left, right);
}

function coverageDuplicateKeysEqual(
  left: SnapshotHistoryCoverageDuplicateKey,
  right: SnapshotHistoryCoverageDuplicateKey,
): boolean {
  return (
    left.schemaVersion === right.schemaVersion &&
    JSON.stringify(left.fields) === JSON.stringify(right.fields) &&
    JSON.stringify(left.sections) === JSON.stringify(right.sections) &&
    JSON.stringify(left.diagnostics) === JSON.stringify(right.diagnostics) &&
    JSON.stringify(left.sourceUniverse) === JSON.stringify(right.sourceUniverse)
  );
}

function timerSchemasEqual(
  left: SnapshotTimerSchema | null,
  right: SnapshotTimerSchema | null,
): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}
