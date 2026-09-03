export {
  assertFileSizeWithinLimit,
  cleanupOrphanAtomicTempFiles,
  isPersistenceTooLargeError,
  PERSISTENCE_MAX_FILE_BYTES,
} from './limits';
export type { PersistenceReadError } from './limits';
export { atomicWriteFile, atomicWriteFileSimple } from './atomic-write';
export type { AtomicWriteOptions } from './atomic-write';
export { base64ToBytes, bytesEqual, bytesToBase64 } from './bytes';
export {
  ELECTRON_DATA_ROOT_NAME,
  PERSISTENCE_FILE_NAMES,
  resolveElectronDataRoot,
  resolveElectronPersistencePaths,
} from './data-root';
export type { ElectronPersistencePaths } from './data-root';
export { createCountingFault, createThrowingFault, FaultInjectionError } from './fault';
export type { WriteFaultInjector } from './fault';
export {
  quarantinePendingJournal,
  quarantinePendingJournals,
  quarantinedJournalPath,
  removeQuarantinedJournal,
  reviveQuarantinedJournalIfNeeded,
  writeQuarantineFixture,
} from './journal-quarantine';
export { ManualTrackerTransactionCoordinator } from './manual-tracker-transaction';
export type {
  ManualTrackerJournalPhase,
  ManualTrackerTransactionCoordinatorOptions,
  ManualTrackerTransactionError,
  TrackerJournalV1,
} from './manual-tracker-transaction';
export { SnapshotImportTransactionCoordinator } from './snapshot-import-transaction';
export type {
  SnapshotImportJournalPhase,
  SnapshotImportJournalV1,
  SnapshotImportTransactionCoordinatorOptions,
  SnapshotImportTransactionError,
} from './snapshot-import-transaction';
export {
  encodeVillageStoreBytes,
  loadVillageStoreBytes,
  validateVillageStoreBytes,
  villageStoreStatusRequiresRecovery,
  VILLAGE_STORE_SCHEMA,
} from './village-codec';
export type {
  VillageStoreError,
  VillageStoreLoadResult,
  VillageStoreStatus,
} from './village-codec';
export { defaultVillagesFileURL, VillageFileStore } from './village-file-store';
export type { CurrentVillagePersistence, VillageFileStoreOptions } from './village-file-store';
export { readFailOpenJsonFile, writeFailOpenJsonFile } from './fail-open-file';
export type { FailOpenFileStoreOptions } from './fail-open-file';
export {
  OfficialStateFileStore,
  createClanStateFileStore,
  createClanWarStateFileStore,
  createClanWarLogStateFileStore,
  createClanCapitalStateFileStore,
  createPlayerStateFileStore,
} from './official-state-file-store';
export type { OfficialStateFileStoreOptions } from './official-state-file-store';
export { TrackedClanFileStore } from './tracked-clan-file-store';
export type { TrackedClanFileStoreOptions } from './tracked-clan-file-store';
export { SelectionFileStore, resolveSelectedVillageId } from './selection-file-store';
export type { SelectionFileStoreOptions, SelectionFileV1 } from './selection-file-store';
export { bootstrapPersistence } from './bootstrap';
export type { PersistenceBootstrapOptions, PersistenceBootstrapResult } from './bootstrap';
