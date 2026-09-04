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
  calculateSnapshotHistoryStatistics,
  confirmedWallLevelGrowth,
  snapshotStatisticValueAvailable,
  snapshotStatisticValueInsufficientData,
} from './diff-statistics';
export type {
  SnapshotHistoryStatistics,
  SnapshotHistoryStatisticsWindow,
  SnapshotStatisticValue,
  SnapshotStatisticValueState,
} from './diff-statistics';
export {
  SnapshotHistoryCanonicalizationException,
  canonicalizeSnapshotHistory,
  canonicalizeSnapshotHistoryWithLineage,
  observationIdentityKey,
} from './canonicalizer';
export type { CanonicalizeSnapshotHistoryOptions } from './canonicalizer';
export { coverageProofsForSnapshot } from './coverage-adapter';
export {
  encodeHistoryEntryWire,
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
export { appendSnapshotHistoryEntry, upsertSnapshotHistoryLineage } from './envelope-mutation';
export {
  createSnapshotHistoryMigrationMarker,
  decodeSnapshotHistoryEnvelopeWire,
  encodeSnapshotHistoryEnvelopeWire,
} from './envelope-wire';
export {
  createInMemorySnapshotHistoryStore,
  defaultSnapshotHistoryFileURL,
  FileSnapshotHistoryStore,
  nowAppliedAtRefSeconds,
} from './file-store';
export {
  createSnapshotHistoryService,
  envelopeHasPersistedHistory,
  migrateSnapshotHistoryFromVillages,
  upgradeExistingSnapshotHistoryEnvelope,
} from './history-service';
export type {
  LoadOrMigrateSnapshotHistoryInput,
  PlanSnapshotHistoryImportForServiceInput,
  SnapshotHistoryService,
} from './history-service';
export { planSnapshotHistoryImport } from './import-service';
export type {
  PlanSnapshotHistoryImportInput,
  SnapshotHistoryImportDecision,
} from './import-service';
export type { SnapshotHistoryStore } from './store-port';
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
  issuePerfFixtureSourceUniverse,
  issueTestFixtureSourceUniverse,
  revalidateCoverageProof,
  revalidateSourceUniverse,
} from './trust-hydration';
export {
  observationDigestForIdentityKey,
  perfFixtureIdentityRecords,
  recognizesPerfFixture,
  requiredSectionsForFixture,
} from './fixture-identities';
