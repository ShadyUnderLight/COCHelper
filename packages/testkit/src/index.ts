export { FakeClock } from './fake-clock';
export { compareParity, ParityMismatchError } from './compare';
export type { CompareParityOptions, ParityDiff, ParityDiffKind } from './compare';
export {
  loadGoldenBytes,
  loadGoldenJson,
  loadGoldenText,
  resolveGoldenFixture,
} from './load-fixture';
export { fixtureFingerprint, isFixtureFingerprint } from './fingerprint';
export {
  assertFixtureFingerprints,
  fingerprintGoldenFiles,
  loadGoldenManifest,
  TEST_CATEGORIES,
} from './manifest';
export type {
  FixturePortStatus,
  GoldenFixtureEntry,
  GoldenManifest,
  TestCategory,
} from './manifest';
export { isSwiftOracleEnabled, runSwiftOracle, SWIFT_ORACLE_ENV } from './oracle';
export {
  findRepoRoot,
  goldenFixturesRoot,
  goldenManifestPath,
  goldenRoot,
  testRegistryPath,
} from './paths';
export { runSeededProperty } from './property';
export type { SeededProperty, SeededPropertyOptions } from './property';
export { loadTestRegistry, isVitestExecutedOwner } from './registry';
export type { TestPortStatus, TestRegistry, TestRegistryEntry } from './registry';
export { FAULT_REPLAY_STATUS, runFaultReplay } from './replay';
export { SeededRandom } from './seeded-random';
export {
  assertGoldenPayloadSafe,
  findFixtureSecretHits,
  findSensitiveJsonKeys,
  isSensitiveJsonKey,
} from './secrets';
