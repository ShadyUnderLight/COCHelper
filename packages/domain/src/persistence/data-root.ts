import { join } from 'node:path';

/** 新 Electron 数据根；故意不复用旧 Swift `COCHelper` Application Support。 */
export const ELECTRON_DATA_ROOT_NAME = 'COCHelperElectron';

export const PERSISTENCE_FILE_NAMES = {
  villages: 'villages-v1.json',
  villagesRecovery: 'villages-v1.recovery.json',
  selection: 'selection-v1.json',
  snapshotHistory: 'snapshot-history-v1.json',
  snapshotHistoryJournal: 'snapshot-history-v1.transaction.json',
  manualTracker: 'manual-tracker-v1.json',
  manualTrackerJournal: 'manual-tracker-v1.transaction.json',
  snapshotImportJournal: 'snapshot-import-v1.transaction.json',
  clans: 'clans-v1.json',
  clanWars: 'clan-wars-v1.json',
  clanWarLogs: 'clan-war-logs-v1.json',
  clanCapitals: 'clan-capitals-v1.json',
  playerStates: 'player-states-v1.json',
  trackedClans: 'tracked-clans-v1.json',
  apiTokenEncrypted: 'api-token.enc',
} as const;

export function resolveElectronDataRoot(homeDirectory?: string): string | null {
  const home = homeDirectory ?? process.env.HOME;
  if (home === undefined || home.length === 0) {
    return null;
  }
  if (process.platform === 'darwin') {
    return join(home, 'Library', 'Application Support', ELECTRON_DATA_ROOT_NAME);
  }
  if (process.platform === 'win32') {
    const appData = process.env.APPDATA;
    if (appData === undefined || appData.length === 0) {
      return join(home, 'AppData', 'Roaming', ELECTRON_DATA_ROOT_NAME);
    }
    return join(appData, ELECTRON_DATA_ROOT_NAME);
  }
  const xdg = process.env.XDG_CONFIG_HOME;
  if (xdg !== undefined && xdg.length > 0) {
    return join(xdg, ELECTRON_DATA_ROOT_NAME);
  }
  return join(home, '.config', ELECTRON_DATA_ROOT_NAME);
}

export type ElectronPersistencePaths = {
  readonly root: string;
  readonly villages: string;
  readonly villagesRecovery: string;
  readonly selection: string;
  readonly snapshotHistory: string;
  readonly snapshotHistoryJournal: string;
  readonly manualTracker: string;
  readonly manualTrackerJournal: string;
  readonly snapshotImportJournal: string;
  readonly clans: string;
  readonly clanWars: string;
  readonly clanWarLogs: string;
  readonly clanCapitals: string;
  readonly playerStates: string;
  readonly trackedClans: string;
  readonly apiTokenEncrypted: string;
};

export function resolveElectronPersistencePaths(
  homeDirectory?: string,
): ElectronPersistencePaths | null {
  const root = resolveElectronDataRoot(homeDirectory);
  if (root === null) {
    return null;
  }
  return {
    root,
    villages: join(root, PERSISTENCE_FILE_NAMES.villages),
    villagesRecovery: join(root, PERSISTENCE_FILE_NAMES.villagesRecovery),
    selection: join(root, PERSISTENCE_FILE_NAMES.selection),
    snapshotHistory: join(root, PERSISTENCE_FILE_NAMES.snapshotHistory),
    snapshotHistoryJournal: join(root, PERSISTENCE_FILE_NAMES.snapshotHistoryJournal),
    manualTracker: join(root, PERSISTENCE_FILE_NAMES.manualTracker),
    manualTrackerJournal: join(root, PERSISTENCE_FILE_NAMES.manualTrackerJournal),
    snapshotImportJournal: join(root, PERSISTENCE_FILE_NAMES.snapshotImportJournal),
    clans: join(root, PERSISTENCE_FILE_NAMES.clans),
    clanWars: join(root, PERSISTENCE_FILE_NAMES.clanWars),
    clanWarLogs: join(root, PERSISTENCE_FILE_NAMES.clanWarLogs),
    clanCapitals: join(root, PERSISTENCE_FILE_NAMES.clanCapitals),
    playerStates: join(root, PERSISTENCE_FILE_NAMES.playerStates),
    trackedClans: join(root, PERSISTENCE_FILE_NAMES.trackedClans),
    apiTokenEncrypted: join(root, PERSISTENCE_FILE_NAMES.apiTokenEncrypted),
  };
}
