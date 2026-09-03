import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  bootstrapPersistence,
  createThrowingFault,
  createVillageProfile,
  PERSISTENCE_FILE_NAMES,
  SelectionFileStore,
  SystemClock,
  VillageFileStore,
  type ElectronPersistencePaths,
} from '@coc-helper/domain';
import { describe, expect, it } from 'vitest';

import { createImportCoordinatorFromPersistence } from './persistence-boundary';
import { PersistentVillageStore } from './persistent-village-store';

function pathsFor(root: string): ElectronPersistencePaths {
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

describe('PersistentVillageStore', () => {
  it('save/select 会落盘，跨实例可恢复', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-persistent-village-'));
    const villagesPath = join(root, 'villages-v1.json');
    const selectionPath = join(root, 'selection-v1.json');
    const store = new PersistentVillageStore({
      villages: new VillageFileStore(villagesPath),
      selection: new SelectionFileStore(selectionPath),
      initialVillages: [createVillageProfile({ id: 'v-1', name: '主村' })],
      initialSelectedVillageId: 'v-1',
    });

    store.saveVillages([
      createVillageProfile({ id: 'v-1', name: '主村' }),
      createVillageProfile({ id: 'v-2', name: '二村' }),
    ]);
    store.setSelectedVillageId('v-2');

    const reloaded = new PersistentVillageStore({
      villages: new VillageFileStore(villagesPath),
      selection: new SelectionFileStore(selectionPath),
    });
    expect(reloaded.listVillages()).toHaveLength(2);
    expect(reloaded.getSelectedVillageId()).toBe('v-2');
    rmSync(root, { recursive: true, force: true });
  });

  it('setSelectedVillageId 写失败时不改内存', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-selection-mem-'));
    const villagesPath = join(root, 'villages-v1.json');
    const selectionPath = join(root, 'selection-v1.json');
    const store = new PersistentVillageStore({
      villages: new VillageFileStore(villagesPath),
      selection: new SelectionFileStore(selectionPath, {
        fault: createThrowingFault('beforeWrite'),
      }),
      initialVillages: [
        createVillageProfile({ id: 'v-1', name: '主村' }),
        createVillageProfile({ id: 'v-2', name: '二村' }),
      ],
      initialSelectedVillageId: 'v-1',
    });
    expect(() => store.setSelectedVillageId('v-2')).toThrow();
    expect(store.getSelectedVillageId()).toBe('v-1');
    rmSync(root, { recursive: true, force: true });
  });

  it('saveVillages 在 selection 写失败时仍提交村庄', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-selection-soft-'));
    const villagesPath = join(root, 'villages-v1.json');
    const villagesStore = new VillageFileStore(villagesPath);
    const store = new PersistentVillageStore({
      villages: villagesStore,
      selection: new SelectionFileStore(join(root, 'selection-v1.json'), {
        fault: createThrowingFault('beforeWrite'),
      }),
      initialVillages: [createVillageProfile({ id: 'v-1', name: '主村' })],
      initialSelectedVillageId: 'v-1',
    });
    store.saveVillages([
      createVillageProfile({ id: 'v-1', name: '主村' }),
      createVillageProfile({ id: 'v-2', name: '二村' }),
    ]);
    expect(villagesStore.load().kind).toBe('loaded');
    expect(store.listVillages()).toHaveLength(2);
    rmSync(root, { recursive: true, force: true });
  });
});

describe('createImportCoordinatorFromPersistence', () => {
  it('recovery 状态下不返回可写 coordinator', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-import-readonly-'));
    const paths = pathsFor(root);
    writeFileSync(paths.villages, '{');
    const runtime = bootstrapPersistence({ paths });
    expect(runtime.canInitializeDerivedStores).toBe(false);
    expect(createImportCoordinatorFromPersistence(runtime, new SystemClock())).toBeNull();
    rmSync(root, { recursive: true, force: true });
  });
});
