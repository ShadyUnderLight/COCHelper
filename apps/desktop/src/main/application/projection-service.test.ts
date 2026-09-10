import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  bootstrapPersistence,
  createVillageProfile,
  loadCatalogBundle,
  PERSISTENCE_FILE_NAMES,
  resolveCatalogBundleRoot,
  type CatalogBundle,
  type ElectronPersistencePaths,
} from '@coc-helper/domain';
import { afterEach, describe, expect, it } from 'vitest';

import { AppServiceError } from './app-authoritative-state';
import { createApplicationServices } from './application-services';
import { bootApplicationServices } from './app-lifecycle-service';
import { ProjectionService, type ProjectionCatalogPort } from './projection-service';

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

async function loadRealBundle(): Promise<CatalogBundle> {
  const root = resolveCatalogBundleRoot(process.cwd());
  if (root === null) {
    throw new Error('测试找不到 GameCatalog');
  }
  return loadCatalogBundle({ root });
}

function catalogPort(): ProjectionCatalogPort {
  let cached: CatalogBundle | null = null;
  return {
    async getBundle() {
      if (cached === null) {
        cached = await loadRealBundle();
      }
      return cached;
    },
  };
}

function deferredCatalogPort(bundle: CatalogBundle): ProjectionCatalogPort & {
  readonly resolve: () => void;
} {
  let settle: ((value: CatalogBundle) => void) | null = null;
  const pending = new Promise<CatalogBundle>((resolve) => {
    settle = resolve;
  });
  return {
    getBundle: () => pending,
    resolve: () => {
      if (settle === null) {
        throw new Error('catalog Promise 尚未挂起');
      }
      settle(bundle);
    },
  };
}

function bootServices(catalog: ProjectionCatalogPort = catalogPort()) {
  const root = mkdtempSync(join(tmpdir(), 'coc-e302-s2-'));
  tempRoots.push(root);
  const persistence = bootstrapPersistence({ paths: pathsFor(root) });
  const clock = new FakeClock(1_700_000_000_000);
  return createApplicationServices({
    clock,
    boot: bootApplicationServices({ clock, persistence }),
    catalog,
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

  it('聚合 idle 行的 instanceID 经 instanceItems 可解析（真 ProjectionService）', async () => {
    const services = bootServices();
    const prepared = services.imports.prepare({
      text: '{"tag":"#INST","buildings":[{"data":1000010,"lvl":1},{"data":1000010,"lvl":1},{"data":1000001,"lvl":5},{"data":1000002,"lvl":3,"timer":3600}]}',
    });
    services.imports.commit(prepared.generation);
    const village = services.state.listVillages().find((entry) => entry.tag === '#INST');
    expect(village).toBeDefined();

    const detail = await services.projections.villageDetail({
      villageId: village!.id,
      base: 'home',
    });
    // 聚合确实发生：否则本测试无意义。
    expect(detail.items.some((entry) => entry.id.startsWith('agg:'))).toBe(true);
    expect(detail.instanceItems.length).toBeGreaterThan(0);

    // renderer 解析规则镜像：items 优先 exact，instanceItems 补齐，'#' 后缀兜底。
    const byId = new Map(detail.items.map((entry) => [entry.id, entry] as const));
    for (const raw of detail.instanceItems) {
      if (!byId.has(raw.id)) {
        byId.set(raw.id, raw);
      }
    }
    const resolve = (id: string) => byId.get(id) ?? byId.get(id.split('#')[0] ?? id) ?? null;
    for (const row of detail.flatRows) {
      if (row.kind === 'instance') {
        expect(resolve(row.instanceID)).not.toBeNull();
      } else if (row.kind === 'legacy') {
        expect(resolve(row.itemID)).not.toBeNull();
      }
    }

    // 城墙组：2 个同级 idle 实例聚合，第二个 raw 实例在 items 中无对应项。
    const wallGroups = detail.buildingGroups.filter((group) => group.dataID === 1000010);
    expect(wallGroups.length).toBeGreaterThan(0);
    const wallInstances = wallGroups.flatMap((group) => group.instanceIds);
    expect(wallInstances.length).toBe(2);
    const itemIds = new Set(detail.items.map((entry) => entry.id));
    expect(wallInstances.some((id) => !itemIds.has(id))).toBe(true);
    for (const id of wallInstances) {
      expect(resolve(id)).not.toBeNull();
      expect(resolve(id)!.dataID).toBe(1000010);
    }

    // 升级中实例保留 raw ID，items 内可直接命中。
    const upgrading = detail.flatRows.find(
      (row) => row.kind === 'instance' && itemIds.has(row.instanceID),
    );
    expect(upgrading).toBeDefined();
  });

  it('catalog await 期间发生 import 时，overview 在 catalog 之后同步抓取 villages/generation', async () => {
    const bundle = await loadRealBundle();
    const catalog = deferredCatalogPort(bundle);
    const events: string[] = [];
    const services = bootServices(catalogPort());
    const clock = new FakeClock(1_700_000_000_000);
    const instrumentedState = new Proxy(services.state, {
      get(target, property, receiver) {
        if (property === 'getGeneration' || property === 'listVillages') {
          return (...args: unknown[]) => {
            events.push(String(property));
            const value = Reflect.get(target, property, receiver);
            return Reflect.apply(value as (...inner: unknown[]) => unknown, target, args);
          };
        }
        return Reflect.get(target, property, receiver);
      },
    });
    const projections = new ProjectionService({
      state: instrumentedState,
      clock,
      catalog: {
        getBundle: async () => {
          events.push('catalog-await');
          const value = await catalog.getBundle();
          events.push('catalog-resolved');
          return value;
        },
      },
      manual: services.boot.persistence?.manual ?? null,
    });

    const pending = projections.upgradeOverview();
    await Promise.resolve();
    expect(events).toEqual(['catalog-await']);

    const prepared = services.imports.prepare({
      text: '{"tag":"#RACE","buildings":[{"data":1000001,"lvl":1}]}',
    });
    services.imports.commit(prepared.generation);
    const afterGeneration = services.state.getGeneration();
    expect(afterGeneration).toBeGreaterThan(0);
    expect(services.state.listVillages().some((village) => village.tag === '#RACE')).toBe(true);

    catalog.resolve();
    const overview = await pending;
    expect(overview.generation).toBe(afterGeneration);
    expect(events.indexOf('catalog-resolved')).toBeLessThan(events.indexOf('listVillages'));
    expect(events.indexOf('catalog-resolved')).toBeLessThan(events.indexOf('getGeneration'));
  });

  it('catalog await 期间发生 import 时，detail 使用更新后的 village 与 generation', async () => {
    const bundle = await loadRealBundle();
    const catalog = deferredCatalogPort(bundle);
    const services = bootServices(catalog);
    const store = services.state.getVillageStore();
    const village = createVillageProfile({
      id: '00000000-0000-0000-0000-0000000000bb',
      name: 'Race',
    });
    store.saveVillages([village]);
    store.setSelectedVillageId(village.id);
    expect(village.tag).toBeNull();
    const generationBefore = services.state.getGeneration();

    const pending = services.projections.villageDetail({
      villageId: village.id,
      base: 'home',
    });
    await Promise.resolve();

    const prepared = services.imports.prepare({
      text: '{"tag":"#AFTER","buildings":[{"data":1000001,"lvl":1}]}',
      villageId: village.id,
    });
    services.imports.commit(prepared.generation);
    const generationAfter = services.state.getGeneration();
    expect(generationAfter).toBeGreaterThan(generationBefore);
    expect(store.listVillages().find((entry) => entry.id === village.id)?.tag).toBe('#AFTER');

    catalog.resolve();
    const detail = await pending;
    expect(detail.generation).toBe(generationAfter);
    expect(detail.villageTag).toBe('#AFTER');
  });
});
