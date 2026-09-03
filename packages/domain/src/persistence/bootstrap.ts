/**
 * E3-01-C：Main 持久化启动边界（§BE-2.5）。
 * 提供可注入的 store 实例与恢复后的权威态；不做 typed IPC / AppModel 拆分（#276）。
 */

import { mkdirSync } from 'node:fs';

import { generateUuid } from '@coc-helper/wire';

import { createVillageProfile, type VillageProfile } from '../import/types';
import { FileManualTrackerStore } from '../manual/file-store';
import { FileSnapshotHistoryStore } from '../snapshot-history/file-store';
import type { OfficialStateStore } from '../official/official-state-store';
import type {
  ClanAPIState,
  ClanCapitalAPIState,
  ClanWarAPIState,
  ClanWarLogAPIState,
} from '../official/endpoint-state';
import type { OfficialAPIState } from '../official/player-state';
import type { TrackedClanStore } from '../official/tracked-clan';
import { cleanupOrphanAtomicTempFiles } from './limits';
import { resolveElectronPersistencePaths, type ElectronPersistencePaths } from './data-root';
import { reviveQuarantinedJournalIfNeeded } from './journal-quarantine';
import { ManualTrackerTransactionCoordinator } from './manual-tracker-transaction';
import {
  createClanCapitalStateFileStore,
  createClanStateFileStore,
  createClanWarLogStateFileStore,
  createClanWarStateFileStore,
  createPlayerStateFileStore,
  OfficialStateFileStore,
} from './official-state-file-store';
import { SelectionFileStore, resolveSelectedVillageId } from './selection-file-store';
import { SnapshotImportTransactionCoordinator } from './snapshot-import-transaction';
import { TrackedClanFileStore } from './tracked-clan-file-store';
import {
  encodeVillageStoreBytes,
  isVillageStoreError,
  type VillageStoreLoadResult,
  type VillageStoreStatus,
  villageStoreStatusRequiresRecovery,
} from './village-codec';
import { VillageFileStore } from './village-file-store';

export type PersistenceBootstrapOptions = {
  readonly homeDirectory?: string;
  readonly paths?: ElectronPersistencePaths;
};

export type PersistenceBootstrapResult = {
  readonly paths: ElectronPersistencePaths;
  readonly villages: VillageFileStore;
  readonly history: FileSnapshotHistoryStore;
  readonly manual: FileManualTrackerStore;
  readonly selection: SelectionFileStore;
  readonly importTransaction: SnapshotImportTransactionCoordinator;
  readonly manualTransaction: ManualTrackerTransactionCoordinator;
  readonly clanStates: OfficialStateFileStore<ClanAPIState>;
  readonly clanWarStates: OfficialStateFileStore<ClanWarAPIState>;
  readonly clanWarLogStates: OfficialStateFileStore<ClanWarLogAPIState>;
  readonly clanCapitalStates: OfficialStateFileStore<ClanCapitalAPIState>;
  readonly playerStates: OfficialStateFileStore<OfficialAPIState>;
  readonly trackedClans: TrackedClanFileStore;
  readonly villageLoad: VillageStoreLoadResult;
  readonly villageStatus: VillageStoreStatus;
  readonly villageError: string | null;
  readonly villageRecoveryData: Uint8Array | null;
  readonly villagesInMemory: readonly VillageProfile[];
  readonly selectedVillageId: string | null;
  readonly canInitializeDerivedStores: boolean;
  readonly snapshotHistoryError: string | null;
  readonly manualTrackerError: string | null;
  readonly loadedClanStates: OfficialStateStore<ClanAPIState>;
  readonly loadedClanWarStates: OfficialStateStore<ClanWarAPIState>;
  readonly loadedClanWarLogStates: OfficialStateStore<ClanWarLogAPIState>;
  readonly loadedClanCapitalStates: OfficialStateStore<ClanCapitalAPIState>;
  readonly loadedPlayerStates: OfficialStateStore<OfficialAPIState>;
  readonly loadedTrackedClans: TrackedClanStore;
};

/**
 * 按 §BE-2.5 顺序恢复权威存储。不启动 refresh / 投影 / IPC。
 */
export function bootstrapPersistence(
  options: PersistenceBootstrapOptions = {},
): PersistenceBootstrapResult {
  const paths = options.paths ?? resolveElectronPersistencePaths(options.homeDirectory);
  if (paths === null) {
    throw new Error('无法解析 Electron 持久化数据根。');
  }
  mkdirSync(paths.root, { recursive: true });
  cleanupOrphanAtomicTempFiles(paths.root);

  const villages = new VillageFileStore(paths.villages);
  const history = new FileSnapshotHistoryStore(paths.snapshotHistory);
  const manual = new FileManualTrackerStore(paths.manualTracker);
  const selection = new SelectionFileStore(paths.selection);
  const importTransaction = new SnapshotImportTransactionCoordinator({
    current: villages,
    history,
    journalURL: paths.snapshotImportJournal,
    manual,
  });
  const manualTransaction = new ManualTrackerTransactionCoordinator({
    current: villages,
    manual,
    journalURL: paths.manualTrackerJournal,
  });
  const clanStates = createClanStateFileStore(paths.clans);
  const clanWarStates = createClanWarStateFileStore(paths.clanWars);
  const clanWarLogStates = createClanWarLogStateFileStore(paths.clanWarLogs);
  const clanCapitalStates = createClanCapitalStateFileStore(paths.clanCapitals);
  const playerStates = createPlayerStateFileStore(paths.playerStates);
  const trackedClans = new TrackedClanFileStore(paths.trackedClans);

  let villageLoad = loadVillageStore(villages);
  const skipTransactionRecovery =
    villageLoad.kind === 'corrupt' ||
    villageLoad.kind === 'unsupportedSchema' ||
    villageLoad.kind === 'unavailable';

  let snapshotHistoryError: string | null = null;
  let manualTrackerError: string | null = null;

  if (!skipTransactionRecovery) {
    try {
      reviveQuarantinedJournalIfNeeded(paths.snapshotImportJournal);
      importTransaction.recoverIfNeeded();
      villageLoad = loadVillageStore(villages);
    } catch (error) {
      snapshotHistoryError = formatPersistenceError(error);
    }

    if (snapshotHistoryError === null) {
      const skipManual =
        villageLoad.kind === 'corrupt' ||
        villageLoad.kind === 'unsupportedSchema' ||
        villageLoad.kind === 'unavailable';
      if (!skipManual) {
        try {
          reviveQuarantinedJournalIfNeeded(paths.manualTrackerJournal);
          manualTransaction.recoverIfNeeded();
        } catch (error) {
          manualTrackerError = formatPersistenceError(error);
        }
      }
      villageLoad = loadVillageStore(villages);
    }
  }

  let villageStatus: VillageStoreStatus;
  let villageError: string | null = null;
  let villageRecoveryData: Uint8Array | null = null;
  let villagesInMemory: VillageProfile[];
  let shouldPersistInitial = false;
  let canInitializeDerivedStores = false;

  switch (villageLoad.kind) {
    case 'missing':
      villagesInMemory = [createVillageProfile({ id: generateUuid(), name: '我的村庄' })];
      villageStatus = 'missing';
      shouldPersistInitial = true;
      canInitializeDerivedStores = true;
      break;
    case 'loaded':
      if (villageLoad.villages.length === 0) {
        villagesInMemory = [createVillageProfile({ id: generateUuid(), name: '我的村庄' })];
        villageStatus = 'empty';
        shouldPersistInitial = true;
        canInitializeDerivedStores = true;
      } else {
        villagesInMemory = [...villageLoad.villages];
        villageStatus = 'available';
        canInitializeDerivedStores = true;
      }
      break;
    case 'corrupt':
      villagesInMemory = [createVillageProfile({ id: generateUuid(), name: '需要恢复的村庄' })];
      villageStatus = 'corrupt';
      villageError = `村庄数据无法解码，原始 bytes 已保留。\n${villageLoad.message}`;
      villageRecoveryData = villageLoad.rawData;
      break;
    case 'unsupportedSchema':
      villagesInMemory = [createVillageProfile({ id: generateUuid(), name: '需要升级的村庄数据' })];
      villageStatus = 'unsupported';
      villageError = `检测到未来村庄存储版本 ${String(villageLoad.schemaVersion)}，当前版本不会覆盖它。`;
      villageRecoveryData = villageLoad.rawData;
      break;
    case 'unavailable':
      villagesInMemory = [createVillageProfile({ id: generateUuid(), name: '需要完成存储恢复' })];
      villageStatus = 'readOnly';
      villageError = villageLoad.message;
      villageRecoveryData = null;
      break;
  }

  if (snapshotHistoryError !== null) {
    villageStatus = 'readOnly';
    villageError = snapshotHistoryError;
    villageRecoveryData = readVillageBytesBestEffort(villages);
    villagesInMemory = [createVillageProfile({ id: generateUuid(), name: '需要完成存储恢复' })];
    shouldPersistInitial = false;
    canInitializeDerivedStores = false;
  }

  if (shouldPersistInitial && snapshotHistoryError === null) {
    try {
      villages.writeData(encodeVillageStoreBytes(villagesInMemory));
    } catch (error) {
      snapshotHistoryError = formatPersistenceError(error);
      villageStatus = 'writeFailed';
      villageError = snapshotHistoryError;
      canInitializeDerivedStores = false;
    }
  }

  // fail-open 组：与 villages 恢复态无关，始终尝试加载。
  const loadedClanStates = clanStates.load();
  const loadedClanWarStates = clanWarStates.load();
  const loadedClanWarLogStates = clanWarLogStates.load();
  const loadedClanCapitalStates = clanCapitalStates.load();
  const loadedPlayerStates = playerStates.load();
  const loadedTrackedClans = trackedClans.load();

  const persistedSelection = selection.load();
  const selectedVillageId = resolveSelectedVillageId(
    villagesInMemory.map((village) => village.id),
    persistedSelection,
  );
  if (
    selectedVillageId !== persistedSelection &&
    selectedVillageId !== null &&
    !villageStoreStatusRequiresRecovery(villageStatus)
  ) {
    try {
      selection.save(selectedVillageId);
    } catch {
      // selection 写失败不阻断启动
    }
  }

  if (!canInitializeDerivedStores && manualTrackerError === null) {
    manualTrackerError = villageError ?? '村庄基础存储尚未恢复，手动升级状态不会被初始化。';
  }

  return {
    paths,
    villages,
    history,
    manual,
    selection,
    importTransaction,
    manualTransaction,
    clanStates,
    clanWarStates,
    clanWarLogStates,
    clanCapitalStates,
    playerStates,
    trackedClans,
    villageLoad,
    villageStatus,
    villageError,
    villageRecoveryData,
    villagesInMemory,
    selectedVillageId,
    canInitializeDerivedStores,
    snapshotHistoryError,
    manualTrackerError,
    loadedClanStates,
    loadedClanWarStates,
    loadedClanWarLogStates,
    loadedClanCapitalStates,
    loadedPlayerStates,
    loadedTrackedClans,
  };
}

function loadVillageStore(store: VillageFileStore): VillageStoreLoadResult {
  try {
    return store.load();
  } catch (error) {
    if (isVillageStoreError(error) && error.kind === 'unavailable') {
      return { kind: 'unavailable', message: error.message };
    }
    return { kind: 'unavailable', message: formatPersistenceError(error) };
  }
}

/** journal 失败后尽力保留原 bytes；读失败不得伪装成 missing。 */
function readVillageBytesBestEffort(store: VillageFileStore): Uint8Array | null {
  try {
    return store.readData();
  } catch {
    return null;
  }
}

function formatPersistenceError(error: unknown): string {
  if (typeof error === 'object' && error !== null && 'message' in error) {
    const message = (error as { message: unknown }).message;
    if (typeof message === 'string') {
      return message;
    }
  }
  return error instanceof Error ? error.message : String(error);
}
