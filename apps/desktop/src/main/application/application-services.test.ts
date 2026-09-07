import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  bootstrapPersistence,
  createVillageProfile,
  PERSISTENCE_FILE_NAMES,
  type ElectronPersistencePaths,
} from '@coc-helper/domain';
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

function bootServices() {
  const root = mkdtempSync(join(tmpdir(), 'coc-e302-'));
  tempRoots.push(root);
  const persistence = bootstrapPersistence({ paths: pathsFor(root) });
  return createApplicationServicesFromPersistence(persistence, new FakeClock(1_700_000_000_000));
}

afterEach(() => {
  while (tempRoots.length > 0) {
    const root = tempRoots.pop();
    if (root !== undefined) {
      rmSync(root, { recursive: true, force: true });
    }
  }
});

describe('ApplicationServices（#276 首片）', () => {
  it('app.snapshot 只读且不 bump generation', () => {
    const services = bootServices();
    const first = services.lifecycle.snapshot();
    const second = services.lifecycle.snapshot();
    expect(first.generation).toBe(0);
    expect(second.generation).toBe(0);
    expect(first.availability).toBe('available');
    expect(first.canWrite).toBe(true);
    expect(first.villageStatus).toBe('missing');
    expect(first.villages).toHaveLength(1);
  });

  it('village.select 需要显式 villageId，且 bump generation', () => {
    const services = bootServices();
    const store = services.state.getVillageStore();
    const village = createVillageProfile({
      id: '00000000-0000-0000-0000-000000000001',
      name: 'A',
    });
    store.saveVillages([village]);
    store.setSelectedVillageId(null);

    const selected = services.villages.selectVillage(village.id);
    expect(selected.selectedVillageId).toBe(village.id);
    expect(selected.generation).toBe(1);
    expect(services.lifecycle.snapshot().selectedVillageId).toBe(village.id);

    expect(() => services.villages.selectVillage('missing')).toThrow(AppServiceError);
  });

  it('import.prepare 不读取权威 selected；省略 villageId 时创建新村', () => {
    const services = bootServices();
    const store = services.state.getVillageStore();
    const existing = createVillageProfile({
      id: '00000000-0000-0000-0000-000000000001',
      name: 'Selected',
    });
    store.saveVillages([existing]);
    store.setSelectedVillageId(existing.id);

    const prepared = services.imports.prepare({
      text: '{"tag":"#NEWTAG","buildings":[]}',
    });
    expect(prepared.pending.targetKind).toBe('create');
    expect(prepared.pending.snapshotTag).toBe('#NEWTAG');
    expect(prepared.generation).toBe(1);

    const committed = services.imports.commit(prepared.generation);
    expect(committed.generation).toBe(2);
    expect(store.listVillages()).toHaveLength(2);
    expect(store.listVillages().some((village) => village.tag === '#NEWTAG')).toBe(true);
  });

  it('import.prepare 显式 villageId 写入该村，即使 selected 是另一个', () => {
    const services = bootServices();
    const store = services.state.getVillageStore();
    const a = createVillageProfile({
      id: '00000000-0000-0000-0000-000000000001',
      name: 'A',
    });
    const b = createVillageProfile({
      id: '00000000-0000-0000-0000-000000000002',
      name: 'B',
    });
    store.saveVillages([a, b]);
    store.setSelectedVillageId(a.id);

    const prepared = services.imports.prepare({
      text: '{"buildings":[]}',
      villageId: b.id,
    });
    services.imports.commit(prepared.generation);

    expect(store.listVillages().find((village) => village.id === b.id)?.hasImportedData).toBe(true);
    expect(store.listVillages().find((village) => village.id === a.id)?.hasImportedData).toBe(
      false,
    );
    expect(store.getSelectedVillageId()).toBe(b.id);
  });

  it('stale commit/discard 不匹配 expectedGeneration 时 conflict，且不改新 pending', () => {
    const services = bootServices();
    const first = services.imports.prepare({ text: '{"tag":"#AAA","buildings":[]}' });
    const second = services.imports.prepare({ text: '{"tag":"#BBB","buildings":[]}' });
    expect(second.generation).toBeGreaterThan(first.generation);
    expect(services.state.getPending()?.snapshot.tag).toBe('#BBB');

    expect(() => services.imports.commit(first.generation)).toThrow(AppServiceError);
    expect(services.state.getPending()?.snapshot.tag).toBe('#BBB');
    expect(services.state.getGeneration()).toBe(second.generation);

    expect(() => services.imports.discard(first.generation)).toThrow(AppServiceError);
    expect(services.state.getPending()?.snapshot.tag).toBe('#BBB');

    services.imports.commit(second.generation);
    expect(services.state.getPending()).toBeNull();
  });

  it('state.changed 在 mutation 后通知订阅者', () => {
    const services = bootServices();
    const events: number[] = [];
    services.state.subscribe((payload) => {
      events.push(payload.generation);
    });
    const store = services.state.getVillageStore();
    const villageId = store.listVillages()[0]!.id;
    services.villages.selectVillage(villageId);
    expect(events).toEqual([1]);
  });
});
