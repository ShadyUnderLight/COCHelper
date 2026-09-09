import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { createVillageProfile } from '../import/types';
import { emptyManualTrackerEnvelope } from '../manual/tracker-envelope';
import { encodeManualTrackerEnvelopeWire } from '../manual/tracker-wire';
import { bootstrapPersistence } from './bootstrap';
import { bytesToBase64 } from './bytes';
import { PERSISTENCE_FILE_NAMES, type ElectronPersistencePaths } from './data-root';
import { quarantinedJournalPath } from './journal-quarantine';
import { encodeVillageStoreBytes } from './village-codec';

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

  it('文件存在但读取失败时保持 readOnly，不覆盖原文件、不恢复 journal', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-boot-unreadable-'));
    const paths = pathsFor(root);
    const original = Buffer.from('KEEP-ORIGINAL-VILLAGES');
    writeFileSync(paths.villages, original);
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
    chmodSync(paths.villages, 0o000);
    try {
      const result = bootstrapPersistence({ paths });
      expect(result.villageLoad.kind).toBe('unavailable');
      expect(result.villageStatus).toBe('readOnly');
      expect(result.canInitializeDerivedStores).toBe(false);
      chmodSync(paths.villages, 0o600);
      expect(readFileSync(paths.villages)).toEqual(original);
      expect(existsSync(paths.snapshotImportJournal)).toBe(true);
    } finally {
      try {
        chmodSync(paths.villages, 0o600);
      } catch {
        // best-effort
      }
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('健康 villages + quarantined committed journal 不自动 revive/replay（reset/restore crash window）', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-boot-quarantine-crash-'));
    const paths = pathsFor(root);
    const villageID = parseUuid('00000000-0000-0000-0000-000000000061');
    if (villageID === undefined) {
      throw new Error('fixture village id');
    }
    const restored = encodeVillageStoreBytes([
      createVillageProfile({ id: villageID, name: '已恢复村' }),
    ]);
    const journalVillages = encodeVillageStoreBytes([
      createVillageProfile({ id: villageID, name: 'Journal村' }),
    ]);
    const manualBytes = new TextEncoder().encode(
      encodeManualTrackerEnvelopeWire(emptyManualTrackerEnvelope([villageID], 1_000)),
    );
    writeFileSync(paths.villages, restored);
    writeFileSync(
      paths.manualTracker,
      encodeManualTrackerEnvelopeWire(emptyManualTrackerEnvelope([villageID], 1_000)),
    );
    writeFileSync(
      quarantinedJournalPath(paths.manualTrackerJournal),
      JSON.stringify({
        phase: 'committed',
        previousCurrentData: bytesToBase64(restored),
        newCurrentData: bytesToBase64(journalVillages),
        previousManualData: bytesToBase64(manualBytes),
        newManualData: bytesToBase64(manualBytes),
      }),
    );

    const result = bootstrapPersistence({ paths });
    expect(result.villageStatus).toBe('available');
    expect(result.villagesInMemory[0]?.name).toBe('已恢复村');
    expect(existsSync(paths.manualTrackerJournal)).toBe(false);
    expect(existsSync(quarantinedJournalPath(paths.manualTrackerJournal))).toBe(false);
    rmSync(root, { recursive: true, force: true });
  });

  it('清理 stale quarantine 失败时仍可启动，且保持 available', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-boot-quarantine-rm-fail-'));
    const paths = pathsFor(root);
    const villageID = parseUuid('00000000-0000-0000-0000-000000000062');
    if (villageID === undefined) {
      throw new Error('fixture village id');
    }
    writeFileSync(
      paths.villages,
      encodeVillageStoreBytes([createVillageProfile({ id: villageID, name: '健康村' })]),
    );
    // 把 quarantine 路径做成目录，rmSync 无 recursive 会抛 EISDIR。
    const quarantinePath = quarantinedJournalPath(paths.manualTrackerJournal);
    mkdirSync(quarantinePath, { recursive: true });
    writeFileSync(join(quarantinePath, 'blocker'), 'locked');

    const result = bootstrapPersistence({ paths });
    expect(result.villageStatus).toBe('available');
    expect(result.canInitializeDerivedStores).toBe(true);
    expect(result.villagesInMemory[0]?.name).toBe('健康村');
    expect(existsSync(quarantinePath)).toBe(true);
    rmSync(root, { recursive: true, force: true });
  });
});
