import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  bootstrapPersistence,
  createVillageProfile,
  loadCatalogBundle,
  PERSISTENCE_FILE_NAMES,
  resolveCatalogBundleRoot,
  type ElectronPersistencePaths,
} from '@coc-helper/domain';
import { afterEach, describe, expect, it } from 'vitest';

import { AppServiceError } from './app-authoritative-state';
import { createApplicationServices } from './application-services';
import { bootApplicationServices } from './app-lifecycle-service';
import type { ProjectionCatalogPort } from './projection-service';

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

function catalogPort(): ProjectionCatalogPort {
  const root = resolveCatalogBundleRoot(process.cwd());
  if (root === null) {
    throw new Error('测试找不到 GameCatalog');
  }
  let cached: Awaited<ReturnType<typeof loadCatalogBundle>> | null = null;
  return {
    async getBundle() {
      if (cached === null) {
        cached = await loadCatalogBundle({ root });
      }
      return cached;
    },
  };
}

function bootServices() {
  const root = mkdtempSync(join(tmpdir(), 'coc-e302-s2-'));
  tempRoots.push(root);
  const persistence = bootstrapPersistence({ paths: pathsFor(root) });
  const clock = new FakeClock(1_700_000_000_000);
  return createApplicationServices({
    clock,
    boot: bootApplicationServices({ clock, persistence }),
    catalog: catalogPort(),
  });
}

afterEach(() => {
  while (tempRoots.length > 0) {
    const root = tempRoots.pop();
    if (root !== undefined) {
      rmSync(root, { recursive: true, force: true });
    }
  }
});

describe('ProjectionService（#276-S2）', () => {
  it('upgrade.overview 只读且不 bump generation', async () => {
    const services = bootServices();
    const before = services.state.getGeneration();
    const overview = await services.projections.upgradeOverview();
    expect(overview.generation).toBe(before);
    expect(services.state.getGeneration()).toBe(before);
    expect(overview.catalogIsUsable).toBe(true);
    expect(overview.catalogVersion).toBeTruthy();
    expect(Array.isArray(overview.active)).toBe(true);
    expect(Array.isArray(overview.pending)).toBe(true);
  });

  it('village.detail 需要显式 villageId+base，且不 bump generation', async () => {
    const services = bootServices();
    const store = services.state.getVillageStore();
    const village = createVillageProfile({
      id: '00000000-0000-0000-0000-0000000000aa',
      name: 'Detail',
    });
    store.saveVillages([village]);
    store.setSelectedVillageId(village.id);
    const before = services.state.getGeneration();

    const detail = await services.projections.villageDetail({
      villageId: village.id,
      base: 'home',
    });
    expect(detail.generation).toBe(before);
    expect(services.state.getGeneration()).toBe(before);
    expect(detail.villageId).toBe(village.id);
    expect(detail.base).toBe('home');
    expect(detail.catalogIsUsable).toBe(true);
    expect(Array.isArray(detail.items)).toBe(true);
    expect(Array.isArray(detail.groups)).toBe(true);
    expect(Array.isArray(detail.flatRows)).toBe(true);
    expect(Array.isArray(detail.buildingGroups)).toBe(true);

    await expect(
      services.projections.villageDetail({
        villageId: '00000000-0000-0000-0000-0000000000ff',
        base: 'home',
      }),
    ).rejects.toBeInstanceOf(AppServiceError);
  });

  it('导入快照后 overview/detail 可投影且仍不写盘', async () => {
    const services = bootServices();
    const prepared = services.imports.prepare({
      text: '{"tag":"#PROJ","buildings":[{"data":1000001,"lvl":1}]}',
    });
    services.imports.commit(prepared.generation);
    const village = services.state.listVillages().find((entry) => entry.tag === '#PROJ');
    expect(village).toBeDefined();
    const generation = services.state.getGeneration();

    const overview = await services.projections.upgradeOverview();
    expect(overview.generation).toBe(generation);
    expect(services.state.getGeneration()).toBe(generation);

    const detail = await services.projections.villageDetail({
      villageId: village!.id,
      base: 'home',
    });
    expect(detail.generation).toBe(generation);
    expect(detail.villageTag).toBe('#PROJ');
    expect(services.state.getGeneration()).toBe(generation);
  });
});
