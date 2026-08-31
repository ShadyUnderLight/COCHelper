import { describe, expect, it } from 'vitest';

import {
  ImportCoordinator,
  InMemoryVillageStore,
} from './import-coordinator';

class FakeClock {
  constructor(private readonly fixedMs: number) {}

  nowMs(): number {
    return this.fixedMs;
  }
}

describe('ImportCoordinator', () => {
  it('parse 无副作用，confirm 才写入 store', () => {
    const store = new InMemoryVillageStore();
    store.seed([
      {
        id: '00000000-0000-0000-0000-000000000001',
        name: 'A',
        tag: null,
        accountSnapshot: null,
        officialAPIState: null,
        hasImportedData: false,
      },
    ], '00000000-0000-0000-0000-000000000001');
    const coordinator = new ImportCoordinator(store, new FakeClock(0));

    coordinator.setImportText('{"tag":"#ABC","buildings":[]}');
    coordinator.setImportIntoCurrentVillage(true);
    coordinator.parse();

    expect(store.listVillages()[0]?.accountSnapshot).toBeNull();
    expect(coordinator.getState().pending?.snapshot.tag).toBe('#ABC');

    expect(coordinator.confirmPending()).toBe(true);
    expect(store.listVillages()[0]?.accountSnapshot?.tag).toBe('#ABC');
    expect(coordinator.getState().pending).toBeNull();
  });

  it('selection 变化后 applyQuickImport 仍更新固定 target', () => {
    const store = new InMemoryVillageStore();
    const a = {
      id: '00000000-0000-0000-0000-000000000001',
      name: 'A',
      tag: '#ABC' as string | null,
      accountSnapshot: null,
      officialAPIState: null,
      hasImportedData: false,
    };
    const b = {
      id: '00000000-0000-0000-0000-000000000002',
      name: 'B',
      tag: null,
      accountSnapshot: null,
      officialAPIState: null,
      hasImportedData: false,
    };
    store.seed([a, b], b.id);
    const coordinator = new ImportCoordinator(store, new FakeClock(0));

    const prepared = coordinator.prepareQuickImport('{"tag":"#ABC","buildings":[]}', a.id);
    expect(prepared.ok).toBe(true);
    store.setSelectedVillageId(b.id);

    if (prepared.ok) {
      expect(coordinator.applyQuickImport(prepared.value)).toBe(true);
    }
    expect(store.listVillages()[0]?.accountSnapshot?.tag).toBe('#ABC');
    expect(store.getSelectedVillageId()).toBe(a.id);
  });

  it('目标村庄删除后 applyQuickImport no-op', () => {
    const store = new InMemoryVillageStore();
    const village = {
      id: '00000000-0000-0000-0000-000000000001',
      name: 'A',
      tag: null,
      accountSnapshot: null,
      officialAPIState: null,
      hasImportedData: false,
    };
    store.seed([village], village.id);
    const coordinator = new ImportCoordinator(store, new FakeClock(0));
    const prepared = coordinator.prepareQuickImport('{"tag":"#ABC","buildings":[]}', village.id);
    expect(prepared.ok).toBe(true);
    store.seed([], null);
    if (prepared.ok) {
      expect(coordinator.applyQuickImport(prepared.value)).toBe(false);
    }
  });
});
