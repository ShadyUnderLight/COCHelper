import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  bootstrapPersistence,
  createCountingFault,
  PERSISTENCE_FILE_NAMES,
  SnapshotImportTransactionCoordinator,
  VillageFileStore,
  type ElectronPersistencePaths,
} from '@coc-helper/domain';
import { afterEach, describe, expect, it } from 'vitest';

import { AppAuthoritativeState, AppServiceError } from './app-authoritative-state';
import { PersistentVillageStore } from './persistent-village-store';
import { SnapshotImportService } from './snapshot-import-service';

class FakeClock {
  nowMs(): number {
    return 1_700_000_000_000;
  }
}

const tempRoots: string[] = [];

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

afterEach(() => {
  while (tempRoots.length > 0) {
    const root = tempRoots.pop();
    if (root !== undefined) {
      rmSync(root, { recursive: true, force: true });
    }
  }
});

describe('SnapshotImportService transaction', () => {
  it('villages afterCommit fault 时事务回滚，pending 保留且内存未 adopt', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-e302-tx-'));
    tempRoots.push(root);
    const paths = pathsFor(root);
    const persistence = bootstrapPersistence({ paths });
    const beforeBytes = persistence.villages.readData();

    const villageStore = new PersistentVillageStore({
      villages: persistence.villages,
      selection: persistence.selection,
      initialVillages: persistence.villagesInMemory,
      initialSelectedVillageId: persistence.selectedVillageId,
    });
    const state = new AppAuthoritativeState({
      persistence,
      villageStore,
    });

    const faultedCurrent = new VillageFileStore(paths.villages, {
      fault: createCountingFault('afterCommit', 1, (path) => path === paths.villages),
    });
    const faultedTx = new SnapshotImportTransactionCoordinator({
      current: faultedCurrent,
      history: persistence.history,
      journalURL: paths.snapshotImportJournal,
      manual: persistence.manual,
    });
    const service = new SnapshotImportService({
      state,
      clock: new FakeClock(),
      importTransaction: faultedTx,
      history: persistence.history,
      manual: persistence.manual,
    });

    const prepared = service.prepare({ text: '{"tag":"#TXFAIL","buildings":[]}' });
    expect(() => service.commit(prepared.generation)).toThrow(AppServiceError);

    expect(persistence.villages.readData()).toEqual(beforeBytes);
    expect(existsSync(paths.snapshotImportJournal)).toBe(false);
    expect(state.getPending()?.snapshot.tag).toBe('#TXFAIL');
    expect(villageStore.listVillages().some((village) => village.tag === '#TXFAIL')).toBe(false);
  });

  it('成功 commit 后内存与磁盘一致且 pending 清除', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-e302-ok-'));
    tempRoots.push(root);
    const persistence = bootstrapPersistence({ paths: pathsFor(root) });
    const villageStore = new PersistentVillageStore({
      villages: persistence.villages,
      selection: persistence.selection,
      initialVillages: persistence.villagesInMemory,
      initialSelectedVillageId: persistence.selectedVillageId,
    });
    const state = new AppAuthoritativeState({ persistence, villageStore });
    const service = new SnapshotImportService({
      state,
      clock: new FakeClock(),
      importTransaction: persistence.importTransaction,
      history: persistence.history,
      manual: persistence.manual,
    });

    const prepared = service.prepare({ text: '{"tag":"#TXOK","buildings":[]}' });
    service.commit(prepared.generation);
    expect(state.getPending()).toBeNull();
    expect(villageStore.listVillages().some((village) => village.tag === '#TXOK')).toBe(true);
    const loaded = persistence.villages.load();
    expect(loaded.kind).toBe('loaded');
    if (loaded.kind === 'loaded') {
      expect(loaded.villages.some((village) => village.tag === '#TXOK')).toBe(true);
    }
  });
});
