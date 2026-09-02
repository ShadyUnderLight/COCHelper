export * from './types';
export * from './schema';
export * from './known-sections';
export * from './store-types';
export * from './duplicate-key';
export * from './diff-types';
export * from './diff-ordering';
export * from './coverage-access';
export { SnapshotDiffEngine, createSnapshotObservationItem } from './diff-engine';
export {
  SnapshotHistoryCanonicalizationException,
  canonicalizeSnapshotHistory,
  canonicalizeSnapshotHistoryWithLineage,
  fingerprintForObservation,
  integrityFingerprint,
} from './canonicalizer';
export type { CanonicalizeSnapshotHistoryOptions } from './canonicalizer';
export { coverageProofsForSnapshot } from './coverage-adapter';
export {
  encodeHistoryEntryWire,
  encodeIntegrityMaterialWire,
  encodeSnapshotDiffWire,
  historyEntryWireHex,
  snapshotDiffWireHex,
} from './wire-encode';
export {
  lineageIndexesEqual,
  lineageMetadataEqual,
  recomputeLineageIndexFromEntries,
} from './lineage-index';
export {
  sequentialValidateSnapshotHistoryEntries,
  sequentialValidateSnapshotHistoryEntriesAsync,
} from './sequential-validate';
export type {
  SequentialValidateSnapshotHistoryOptions,
  SequentialValidateSnapshotHistoryResult,
} from './sequential-validate';
export { diagnoseEnvelopeComplexity, diagnoseSnapshotHistoryComplexity } from './complexity';
export type { SnapshotHistoryComplexityDiagnostic } from './complexity';
export {
  snapshotHistoryCoverageDuplicateKey,
  snapshotHistoryDuplicateKey,
  snapshotHistoryDuplicateKeysMatch,
} from './duplicate-key';
export type {
  SnapshotHistoryCoverageDuplicateKey,
  SnapshotHistoryDuplicateKey,
  SnapshotHistoryProofDuplicateKey,
  SnapshotHistorySectionDuplicateKey,
} from './duplicate-key';
export { snapshotHistoryServiceErrorMessage, snapshotHistoryStoreErrorMessage } from './errors';
export type { SnapshotHistoryServiceError, SnapshotHistoryStoreError } from './errors';
export {
  hydrateSnapshotHistoryEnvelope,
  validateSnapshotHistoryEnvelope,
  validateSnapshotHistoryEntry,
  validateSnapshotHistoryEntryIntegrity,
} from './envelope-validate';
export type { ValidateSnapshotHistoryEnvelopeOptions } from './envelope-validate';
export { planSnapshotHistoryImport } from './import-service';
export type {
  PlanSnapshotHistoryImportInput,
  SnapshotHistoryImportDecision,
} from './import-service';
export { resolveSnapshotLineage } from './lineage-resolver';
export {
  createSnapshotHistoryEnvelope,
  envelopeActiveLineage,
  envelopeEntry,
  envelopeIsMigrated,
  sectionTrustOpensGates,
} from './store-types';
export type {
  SnapshotHistoryDiagnostic,
  SnapshotHistoryDiagnosticKind,
  SnapshotHistoryDuplicateMetadata,
  SnapshotHistoryEnvelope,
  SnapshotHistoryLineageMetadata,
  SnapshotHistoryMigrationMarker,
  SectionCoverageRuntimeTrust,
  SnapshotCoverageRevalidationPolicy,
  SourceUniverseRuntimeTrust,
} from './store-types';
export type {
  HydratedSnapshotHistoryEntry,
  HydratedSnapshotObservationCoverage,
  HydratedSnapshotSectionCoverage,
} from './trust-hydration';
export {
  SNAPSHOT_COVERAGE_CURRENT_VERIFICATION_RULE_VERSION,
  SNAPSHOT_COVERAGE_PERF_FIXTURE_ADAPTER_ID,
  SNAPSHOT_COVERAGE_TEST_FIXTURE_ADAPTER_ID,
  coverageHasLegacySectionEvidence,
  hydrateVerifiedCoverageOnEntry,
  hydrateVerifiedCoverageOnEnvelope,
  issueTestFixtureSourceUniverse,
  revalidateCoverageProof,
  revalidateSourceUniverse,
  sectionInputBinding,
} from './trust-hydration';
