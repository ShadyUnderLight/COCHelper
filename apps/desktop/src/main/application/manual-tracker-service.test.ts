import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  bootstrapPersistence,
  PERSISTENCE_FILE_NAMES,
  type ElectronPersistencePaths,
} from '@coc-helper/domain';
import { afterEach, describe, expect, it } from 'vitest';

import { createApplicationServicesFromPersistence } from './persistence-boundary';
import { AppServiceError } from './app-authoritative-state';

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
  const root = mkdtempSync(join(tmpdir(), 'coc-e302-s3-'));
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

describe('ManualTrackerService（#276-S3）', () => {
  it('manual.state 只读且不 bump generation', () => {
    const services = bootServices();
    expect(services.manual).not.toBeNull();
    const villageId = services.state.listVillages()[0]!.id;
    const before = services.state.getGeneration();
    const state = services.manual!.getState({ villageId });
    expect(state.generation).toBe(before);
    expect(services.state.getGeneration()).toBe(before);
    expect(state.status === 'missing' || state.status === 'empty').toBe(true);
  });

  it('settle 无记录时不 bump generation', () => {
    const services = bootServices();
    const before = services.state.getGeneration();
    const settled = services.manual!.settle({ expectedGeneration: before });
    expect(settled.settledCount).toBe(0);
    expect(services.state.getGeneration()).toBe(before);
  });

  it('import.commit 写入 manual 后 getState 可见', () => {
    const services = bootServices();
    const prepared = services.imports.prepare({
      text: '{"tag":"#S3OK","buildings":[{"data":1000001,"lvl":1,"cnt":1}]}',
    });
    services.imports.commit(prepared.generation);
    const villageId = services.state
      .listVillages()
      .find((village) => village.tag === '#S3OK')!.id;
    const state = services.manual!.getState({ villageId });
    expect(state.status).toBe('available');
    expect(state.baselineRevision).not.toBeNull();
    expect(state.itemStateCount).toBeGreaterThanOrEqual(0);
  });

  it('stale expectedGeneration 拒绝 settle', () => {
    const services = bootServices();
    expect(() => services.manual!.settle({ expectedGeneration: 999 })).toThrow(AppServiceError);
  });
});
