import type { UuidString } from '@coc-helper/wire';

import { SNAPSHOT_HISTORY_SCHEMA } from './schema';
import type { SnapshotHistoryEntry } from './types';

export type SnapshotHistoryDiagnosticKind =
  'corrupt' | 'unsupportedSchema' | 'unavailable' | 'writeFailed';

export type SnapshotHistoryDiagnostic = {
  readonly kind: SnapshotHistoryDiagnosticKind;
  readonly message: string;
  readonly recordedAtRefSeconds: number;
};

export type SnapshotHistoryMigrationMarker = {
  readonly version: number;
  readonly completedAtRefSeconds: number;
};

export type SnapshotHistoryDuplicateMetadata = {
  readonly lastSeenAtRefSeconds: number;
  readonly lastSourceTimestampRefSeconds: number | null;
  readonly duplicateImportCount: number;
};

export type SnapshotHistoryLineageMetadata = {
  readonly villageID: UuidString;
  readonly lineageID: UuidString;
  readonly normalizedPlayerTag: string | null;
  readonly lastEntryID: UuidString;
  readonly lastAppliedAtRefSeconds: number;
  readonly hasConflict: boolean;
  readonly isActive: boolean;
};

export type SnapshotHistoryEnvelope = {
  readonly schemaVersion: number;
  readonly entries: readonly SnapshotHistoryEntry[];
  readonly lineages: readonly SnapshotHistoryLineageMetadata[];
  readonly duplicateMetadata: Readonly<Record<string, SnapshotHistoryDuplicateMetadata>>;
  readonly migrationMarker: SnapshotHistoryMigrationMarker | null;
  readonly lastDiagnostic: SnapshotHistoryDiagnostic | null;
};

export function createSnapshotHistoryEnvelope(input: {
  readonly schemaVersion?: number;
  readonly entries?: readonly SnapshotHistoryEntry[];
  readonly lineages?: readonly SnapshotHistoryLineageMetadata[];
  readonly duplicateMetadata?: Readonly<Record<string, SnapshotHistoryDuplicateMetadata>>;
  readonly migrationMarker?: SnapshotHistoryMigrationMarker | null;
  readonly lastDiagnostic?: SnapshotHistoryDiagnostic | null;
}): SnapshotHistoryEnvelope {
  return {
    schemaVersion: input.schemaVersion ?? SNAPSHOT_HISTORY_SCHEMA.envelope,
    entries: input.entries ?? [],
    lineages: input.lineages ?? [],
    duplicateMetadata: input.duplicateMetadata ?? {},
    migrationMarker: input.migrationMarker ?? null,
    lastDiagnostic: input.lastDiagnostic ?? null,
  };
}

export function envelopeIsMigrated(envelope: SnapshotHistoryEnvelope): boolean {
  return envelope.migrationMarker?.version === SNAPSHOT_HISTORY_SCHEMA.envelope;
}

export function envelopeEntry(
  envelope: SnapshotHistoryEnvelope,
  snapshotID: UuidString,
): SnapshotHistoryEntry | undefined {
  return envelope.entries.find((entry) => entry.snapshotID === snapshotID);
}

export function envelopeActiveLineage(
  envelope: SnapshotHistoryEnvelope,
  villageID: UuidString,
): SnapshotHistoryLineageMetadata | undefined {
  return envelope.lineages.find((lineage) => lineage.villageID === villageID && lineage.isActive);
}

export type SectionCoverageRuntimeTrust =
  | { readonly kind: 'notApplicable' }
  | { readonly kind: 'pending' }
  | { readonly kind: 'trusted' }
  | { readonly kind: 'rejected'; readonly reason: string };

export type SourceUniverseRuntimeTrust = SectionCoverageRuntimeTrust;

export type SnapshotCoverageRevalidationPolicy = 'production' | 'testsAllowTestFixture';

export function sectionTrustOpensGates(trust: SectionCoverageRuntimeTrust): boolean {
  return trust.kind === 'trusted';
}
