import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  bootstrapPersistence,
  bytesToBase64,
  createVillageProfile,
  emptyManualTrackerEnvelope,
  encodeManualTrackerEnvelopeWire,
  encodeVillageStoreBytes,
  loadVillageStoreBytes,
  PERSISTENCE_FILE_NAMES,
  PERSISTENCE_MAX_FILE_BYTES,
  type ElectronPersistencePaths,
} from '@coc-helper/domain';
import { parseUuid } from '@coc-helper/wire';
import { afterEach, describe, expect, it } from 'vitest';

import { AppServiceError } from './app-authoritative-state';
import { createApplicationServicesFromPersistence } from './persistence-boundary';

class FakeClock {
  constructor(private readonly fixedMs: number) {}
  nowMs(): number {
    return this.fixedMs;
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

function bootCorruptServices(root = mkdtempSync(join(tmpdir(), 'coc-recovery-'))) {
  tempRoots.push(root);
  const paths = pathsFor(root);
  writeFileSync(paths.villages, '{');
  const persistence = bootstrapPersistence({ paths });
  return {
    services: createApplicationServicesFromPersistence(
      persistence,
      new FakeClock(1_700_000_000_000),
    ),
    paths,
    root,
  };
}

function bootHealthyServices() {
  const root = mkdtempSync(join(tmpdir(), 'coc-recovery-ok-'));
  tempRoots.push(root);
  const persistence = bootstrapPersistence({ paths: pathsFor(root) });
  return createApplicationServicesFromPersistence(persistence, new FakeClock(1_700_000_000_000));
}

function writeManualJournal(
  paths: ElectronPersistencePaths,
  phase: 'prepared' | 'committed',
  previousVillages: Uint8Array,
  nextVillages: Uint8Array,
): void {
  const villageID = parseUuid('00000000-0000-0000-0000-000000000061');
  if (villageID === undefined) {
    throw new Error('fixture village id');
  }
  const manualBytes = new TextEncoder().encode(
    encodeManualTrackerEnvelopeWire(emptyManualTrackerEnvelope([villageID], 1_000)),
  );
  writeFileSync(
    paths.manualTracker,
    encodeManualTrackerEnvelopeWire(emptyManualTrackerEnvelope([villageID], 1_000)),
  );
  writeFileSync(
    paths.manualTrackerJournal,
    JSON.stringify({
      phase,
      previousCurrentData: bytesToBase64(previousVillages),
      newCurrentData: bytesToBase64(nextVillages),
      previousManualData: bytesToBase64(manualBytes),
      newManualData: bytesToBase64(manualBytes),
    }),
  );
}

afterEach(() => {
  while (tempRoots.length > 0) {
    const root = tempRoots.pop();
    if (root !== undefined) {
      rmSync(root, { recursive: true, force: true });
    }
  }
});

describe('RecoveryService（#276-S5）', () => {
  it('corrupt 启动进入 recovery，且 sessionId 稳定、generation 从 0 开始', () => {
    const { services } = bootCorruptServices();
    const snapshot = services.lifecycle.snapshot();
    expect(snapshot.availability).toBe('recovery');
    expect(snapshot.villageStatus).toBe('corrupt');
    expect(snapshot.canWrite).toBe(false);
    expect(snapshot.sessionId.length).toBeGreaterThan(0);
    expect(snapshot.generation).toBe(0);
    expect(snapshot.hasPendingJournal).toBe(false);
    expect(services.recovery.status().recoveryRequired).toBe(true);
    expect(services.recovery.status().canExport).toBe(true);
  });

  it('reset 后回到 available/canWrite，并 bump generation；sessionId 不变', () => {
    const { services } = bootCorruptServices();
    const sessionId = services.state.getSessionId();
    const before = services.state.getGeneration();
    const reset = services.recovery.reset(before);
    expect(reset.canWrite).toBe(true);
    expect(reset.villageStatus).toBe('available');
    expect(reset.sessionId).toBe(sessionId);
    expect(reset.generation).toBe(before + 1);

    const snapshot = services.lifecycle.snapshot();
    expect(snapshot.availability).toBe('available');
    expect(snapshot.canWrite).toBe(true);
    expect(snapshot.sessionId).toBe(sessionId);
    expect(snapshot.hasPendingJournal).toBe(false);
    expect(snapshot.villages).toHaveLength(1);
    expect(snapshot.recoveryNotice).toContain('重置');
  });

  it('restore 合法 bytes 成功；非法 bytes 不覆盖；stale generation 拒绝', () => {
    const { services } = bootCorruptServices();
    const good = encodeVillageStoreBytes([
      createVillageProfile({ id: '00000000-0000-0000-0000-0000000000aa', name: '已恢复村' }),
    ]);
    const generation = services.state.getGeneration();

    expect(() =>
      services.recovery.restore(generation, bytesToBase64(new TextEncoder().encode('{'))),
    ).toThrow(AppServiceError);
    expect(services.lifecycle.snapshot().availability).toBe('recovery');
    expect(services.state.getGeneration()).toBe(generation);

    expect(() => services.recovery.restore(generation - 1, bytesToBase64(good))).toThrow(
      AppServiceError,
    );

    const restored = services.recovery.restore(generation, bytesToBase64(good));
    expect(restored.canWrite).toBe(true);
    expect(restored.villageStatus).toBe('available');
    expect(services.lifecycle.snapshot().hasPendingJournal).toBe(false);
    expect(services.lifecycle.snapshot().villages[0]?.name).toBe('已恢复村');
  });

  it('available 状态下拒绝 reset/restore', () => {
    const services = bootHealthyServices();
    const generation = services.state.getGeneration();
    expect(() => services.recovery.reset(generation)).toThrow(AppServiceError);
    expect(() =>
      services.recovery.restore(
        generation,
        bytesToBase64(encodeVillageStoreBytes([createVillageProfile({ id: 'v', name: 'X' })])),
      ),
    ).toThrow(AppServiceError);
  });

  it('两次 boot 产生不同 sessionId（模拟 Main 重启）', () => {
    const first = bootHealthyServices();
    const second = bootHealthyServices();
    expect(first.state.getSessionId()).not.toBe(second.state.getSessionId());
    expect(first.lifecycle.snapshot().availability).toBe('available');
    expect(second.lifecycle.snapshot().availability).toBe('available');
  });

  it('prepared journal + reset 后重启不会把 previousCurrentData 写回', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-recovery-prepared-'));
    const paths = pathsFor(root);
    const previousVillages = encodeVillageStoreBytes([
      createVillageProfile({ id: '00000000-0000-0000-0000-000000000061', name: '旧村' }),
    ]);
    const journalVillages = encodeVillageStoreBytes([
      createVillageProfile({ id: '00000000-0000-0000-0000-000000000061', name: 'Journal村' }),
    ]);
    writeFileSync(paths.villages, '{');
    writeManualJournal(paths, 'prepared', previousVillages, journalVillages);

    const { services } = bootCorruptServices(root);
    expect(services.lifecycle.snapshot().hasPendingJournal).toBe(true);
    const reset = services.recovery.reset(services.state.getGeneration());
    expect(reset.canWrite).toBe(true);
    expect(services.lifecycle.snapshot().hasPendingJournal).toBe(false);
    expect(existsSync(`${paths.manualTrackerJournal}.quarantined`)).toBe(false);
    expect(existsSync(paths.manualTrackerJournal)).toBe(false);

    const resetName = services.lifecycle.snapshot().villages[0]?.name;
    expect(resetName).toBe('我的村庄');

    const reloaded = bootstrapPersistence({ paths });
    expect(reloaded.villageStatus).toBe('available');
    expect(reloaded.canInitializeDerivedStores).toBe(true);
    expect(reloaded.villagesInMemory[0]?.name).toBe('我的村庄');
    expect(existsSync(paths.manualTrackerJournal)).toBe(false);
    expect(existsSync(`${paths.manualTrackerJournal}.quarantined`)).toBe(false);
  });

  it('committed journal + restore 后重启不会把 newCurrentData 写回', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-recovery-committed-'));
    const paths = pathsFor(root);
    const previousVillages = encodeVillageStoreBytes([
      createVillageProfile({ id: '00000000-0000-0000-0000-000000000061', name: '旧村' }),
    ]);
    const journalVillages = encodeVillageStoreBytes([
      createVillageProfile({ id: '00000000-0000-0000-0000-000000000061', name: 'Journal村' }),
    ]);
    const restoredVillages = encodeVillageStoreBytes([
      createVillageProfile({ id: '00000000-0000-0000-0000-0000000000aa', name: '已恢复村' }),
    ]);
    writeFileSync(paths.villages, '{');
    writeManualJournal(paths, 'committed', previousVillages, journalVillages);

    const { services } = bootCorruptServices(root);
    services.recovery.restore(services.state.getGeneration(), bytesToBase64(restoredVillages));
    expect(services.lifecycle.snapshot().villages[0]?.name).toBe('已恢复村');
    expect(services.lifecycle.snapshot().hasPendingJournal).toBe(false);
    expect(existsSync(`${paths.manualTrackerJournal}.quarantined`)).toBe(false);

    const reloaded = bootstrapPersistence({ paths });
    expect(reloaded.villageStatus).toBe('available');
    expect(reloaded.villagesInMemory[0]?.name).toBe('已恢复村');
    expect(existsSync(paths.manualTrackerJournal)).toBe(false);
  });

  it('recovery 副本写入失败时 restore 中止且不覆盖 villages / 不 bump generation', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-recovery-backup-fail-'));
    tempRoots.push(root);
    const paths = pathsFor(root);
    writeFileSync(paths.villages, '{');
    mkdirSync(paths.villagesRecovery);
    const persistence = bootstrapPersistence({ paths });
    const services = createApplicationServicesFromPersistence(
      persistence,
      new FakeClock(1_700_000_000_000),
    );
    const generation = services.state.getGeneration();
    const beforeVillages = readFileSync(paths.villages);

    const good = encodeVillageStoreBytes([
      createVillageProfile({ id: '00000000-0000-0000-0000-0000000000bb', name: '不应写入' }),
    ]);
    expect(() => services.recovery.restore(generation, bytesToBase64(good))).toThrow(
      AppServiceError,
    );

    expect(readFileSync(paths.villages)).toEqual(beforeVillages);
    expect(services.state.getGeneration()).toBe(generation);
    expect(services.lifecycle.snapshot().availability).toBe('recovery');
    expect(services.lifecycle.snapshot().canWrite).toBe(false);
  });

  it('超过 PERSISTENCE_MAX_FILE_BYTES 的 restore candidate 被拒绝且不写盘', () => {
    const { services, paths } = bootCorruptServices();
    const generation = services.state.getGeneration();
    const beforeVillages = readFileSync(paths.villages);
    const oversized = Buffer.alloc(PERSISTENCE_MAX_FILE_BYTES + 1, 0x41);
    expect(() => services.recovery.restore(generation, bytesToBase64(oversized))).toThrow(
      AppServiceError,
    );
    expect(readFileSync(paths.villages)).toEqual(beforeVillages);
    expect(services.state.getGeneration()).toBe(generation);
    expect(loadVillageStoreBytes(readFileSync(paths.villages)).kind).toBe('corrupt');
  });
});
