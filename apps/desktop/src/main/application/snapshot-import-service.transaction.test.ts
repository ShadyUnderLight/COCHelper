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
import { ManualTrackerService } from './manual-tracker-service';

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

function bootService(root: string) {
  const paths = pathsFor(root);
  const persistence = bootstrapPersistence({ paths });
  const villageStore = new PersistentVillageStore({
    villages: persistence.villages,
    selection: persistence.selection,
    initialVillages: persistence.villagesInMemory,
    initialSelectedVillageId: persistence.selectedVillageId,
  });
  const state = new AppAuthoritativeState({ persistence, villageStore });
  const clock = new FakeClock();
  const manualTracker = new ManualTrackerService({
    state,
    clock,
    manual: persistence.manual,
    history: persistence.history,
    catalog: {
      getBundle: async () => {
        throw new Error('catalog not needed for import transaction tests');
      },
    },
    importTransaction: persistence.importTransaction,
  });
  const service = new SnapshotImportService({
    state,
    clock,
    importTransaction: persistence.importTransaction,
    history: persistence.history,
    manual: persistence.manual,
    manualTracker,
  });
  return { paths, persistence, villageStore, state, service, manualTracker };
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
  it('villages afterCommit fault 时 current/history 都不含失败 snapshot', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-e302-tx-'));
    tempRoots.push(root);
    const { paths, persistence, villageStore, state } = bootService(root);
    const beforeVillages = persistence.villages.readData();
    expect(persistence.history.load()).toBeNull();

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
      manualTracker: new ManualTrackerService({
        state,
        clock: new FakeClock(),
        manual: persistence.manual,
        history: persistence.history,
        catalog: {
          getBundle: async () => {
            throw new Error('unused');
          },
        },
        importTransaction: faultedTx,
      }),
    });

    const prepared = service.prepare({ text: '{"tag":"#TXFAIL","buildings":[]}' });
    expect(() => service.commit(prepared.generation)).toThrow(AppServiceError);

    expect(persistence.villages.readData()).toEqual(beforeVillages);
    expect(existsSync(paths.snapshotImportJournal)).toBe(false);
    expect(state.getPending()?.snapshot.tag).toBe('#TXFAIL');
    expect(villageStore.listVillages().some((village) => village.tag === '#TXFAIL')).toBe(false);

    /**
     * loadOrMigrate 可能在 transaction 前把空 baseline envelope 落盘；
     * 关键的是失败 snapshot 不得进入 history（P1：不得用 nextVillages 迁移）。
     */
    const historyAfter = persistence.history.load();
    if (historyAfter !== null) {
      expect(historyAfter.entries).toHaveLength(0);
      expect(historyAfter.entries.some((entry) => entry.rawJSON.includes('#TXFAIL'))).toBe(false);
      expect(Object.keys(historyAfter.duplicateMetadata)).toHaveLength(0);
    }
  });

  it('首次成功 import：append 新 history entry，且 duplicate === false', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-e302-ok-'));
    tempRoots.push(root);
    const { persistence, villageStore, state, service } = bootService(root);

    expect(persistence.history.load()).toBeNull();

    const prepared = service.prepare({ text: '{"tag":"#TXOK","buildings":[]}' });
    service.commit(prepared.generation);
    expect(state.getPending()).toBeNull();
    expect(villageStore.listVillages().some((village) => village.tag === '#TXOK')).toBe(true);

    const afterEnvelope = persistence.history.load();
    expect(afterEnvelope).not.toBeNull();
    /** fresh install：migration 基于空 villages，planImport 必须真正 append（非 duplicate）。 */
    expect(afterEnvelope!.entries).toHaveLength(1);
    const imported = afterEnvelope!.entries[0]!;
    expect(imported.rawJSON).toContain('#TXOK');
    expect(afterEnvelope!.duplicateMetadata[imported.snapshotID]).toBeUndefined();
    expect(Object.keys(afterEnvelope!.duplicateMetadata)).toHaveLength(0);

    const loaded = persistence.villages.load();
    expect(loaded.kind).toBe('loaded');
    if (loaded.kind === 'loaded') {
      expect(loaded.villages.some((village) => village.tag === '#TXOK')).toBe(true);
    }

    /** S3：import 必须写入对账后的 manual envelope。 */
    const manualAfter = persistence.manual.load();
    expect(manualAfter).not.toBeNull();
    expect(manualAfter!.migrationMarker).not.toBeNull();
    expect(manualAfter!.villages.length).toBeGreaterThanOrEqual(1);
  });
});
