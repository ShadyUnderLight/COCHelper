import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { createVillageProfile } from '../import/types';
import { bootstrapPersistence } from './bootstrap';
import { encodeVillageStoreBytes } from './village-codec';
import type { ElectronPersistencePaths } from './data-root';
import { PERSISTENCE_FILE_NAMES } from './data-root';

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

describe('bootstrapPersistence', () => {
  it('missing villages 时合成默认村并落盘，且加载 fail-open 空库', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-boot-missing-'));
    const result = bootstrapPersistence({ paths: pathsFor(root) });
    expect(result.villageStatus).toBe('missing');
    expect(result.villagesInMemory).toHaveLength(1);
    expect(result.villagesInMemory[0]?.name).toBe('我的村庄');
    expect(result.canInitializeDerivedStores).toBe(true);
    expect(existsSync(result.paths.villages)).toBe(true);
    expect(result.selectedVillageId).toBe(result.villagesInMemory[0]?.id ?? null);
    expect(result.loadedClanStates.states).toEqual({});
    expect(result.loadedTrackedClans.profiles).toEqual([]);
    rmSync(root, { recursive: true, force: true });
  });

  it('corrupt villages 跳过 journal 恢复且不覆盖原 bytes', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-boot-corrupt-'));
    const paths = pathsFor(root);
    writeFileSync(paths.villages, '{');
    writeFileSync(
      paths.snapshotImportJournal,
      JSON.stringify({
        phase: 'committed',
        previousCurrentData: null,
        newCurrentData: Buffer.from(
          encodeVillageStoreBytes([createVillageProfile({ id: 'v-recovered', name: '已恢复' })]),
        ).toString('base64'),
        previousHistoryData: null,
        newHistoryData: Buffer.from('{}').toString('base64'),
        previousManualData: null,
        manualIncluded: false,
        newManualData: null,
      }),
    );
    const result = bootstrapPersistence({ paths });
    expect(result.villageStatus).toBe('corrupt');
    expect(result.canInitializeDerivedStores).toBe(false);
    expect(result.villagesInMemory[0]?.name).toBe('需要恢复的村庄');
    expect(existsSync(paths.snapshotImportJournal)).toBe(true);
    rmSync(root, { recursive: true, force: true });
  });

  it('健康 villages 保留 selection', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-boot-selection-'));
    const paths = pathsFor(root);
    const villages = [
      createVillageProfile({ id: 'v-a', name: 'A' }),
      createVillageProfile({ id: 'v-b', name: 'B' }),
    ];
    writeFileSync(paths.villages, encodeVillageStoreBytes(villages));
    writeFileSync(paths.selection, JSON.stringify({ selectedVillageId: 'v-b' }));
    const result = bootstrapPersistence({ paths });
    expect(result.villageStatus).toBe('available');
    expect(result.selectedVillageId).toBe('v-b');
    rmSync(root, { recursive: true, force: true });
  });
});
