import { parseAccountSnapshot } from '@coc-helper/domain';
import { describe, expect, it } from 'vitest';

import { ImportCoordinator, InMemoryVillageStore } from './import-coordinator';

class FakeClock {
  constructor(private readonly fixedMs: number) {}

  nowMs(): number {
    return this.fixedMs;
  }
}

function parsedSnapshot(text: string) {
  const parsed = parseAccountSnapshot(text, { clock: new FakeClock(0) });
  if (!parsed.ok) {
    throw new Error('unexpected parse failure');
  }
  return parsed.value;
}

describe('ImportCoordinator', () => {
  it('parse 无副作用，confirm 才写入 store', () => {
    const store = new InMemoryVillageStore();
    store.seed(
      [
        {
          id: '00000000-0000-0000-0000-000000000001',
          name: 'A',
          tag: null,
          accountSnapshot: null,
          officialAPIState: null,
          hasImportedData: false,
        },
      ],
      '00000000-0000-0000-0000-000000000001',
    );
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

  it('confirmPending 创建新村庄时 officialAPIState 为 null', () => {
    const store = new InMemoryVillageStore();
    store.seed([], null);
    const coordinator = new ImportCoordinator(store, new FakeClock(0));
    coordinator.setImportText('{"tag":"#NEWVIL","buildings":[]}');
    coordinator.parse();
    expect(coordinator.confirmPending()).toBe(true);
    const village = store.listVillages()[0];
    expect(village?.tag).toBe('#NEWVIL');
    expect(village?.officialAPIState).toBeNull();
    expect(village?.accountSnapshot?.tag).toBe('#NEWVIL');
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

  it('applyQuickImport 同 tag 保留 officialAPIState', () => {
    const store = new InMemoryVillageStore();
    const snapshot = parsedSnapshot('{"tag":"#SAME","buildings":[]}');
    const village = {
      id: '00000000-0000-0000-0000-000000000001',
      name: 'A',
      tag: snapshot.tag,
      accountSnapshot: snapshot,
      officialAPIState: { status: 'success' },
      hasImportedData: true,
    };
    store.seed([village], village.id);
    const coordinator = new ImportCoordinator(store, new FakeClock(0));
    const prepared = coordinator.prepareQuickImport('{"tag":"#SAME","buildings":[]}', village.id);
    expect(prepared.ok).toBe(true);
    if (prepared.ok) {
      expect(coordinator.applyQuickImport(prepared.value)).toBe(true);
    }
    expect(store.listVillages()[0]?.officialAPIState).toEqual({ status: 'success' });
  });

  it('applyQuickImport tag 变化时清空 officialAPIState', () => {
    const store = new InMemoryVillageStore();
    const snapshot = parsedSnapshot('{"tag":"#OLD","buildings":[]}');
    const village = {
      id: '00000000-0000-0000-0000-000000000001',
      name: 'A',
      tag: snapshot.tag,
      accountSnapshot: snapshot,
      officialAPIState: { status: 'success' },
      hasImportedData: true,
    };
    store.seed([village], village.id);
    const coordinator = new ImportCoordinator(store, new FakeClock(0));
    const prepared = coordinator.prepareQuickImport('{"tag":"#NEW","buildings":[]}', village.id);
    expect(prepared.ok).toBe(true);
    if (prepared.ok) {
      expect(coordinator.applyQuickImport(prepared.value)).toBe(true);
    }
    expect(store.listVillages()[0]?.officialAPIState).toBeNull();
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

  it('confirmPending 在村庄列表 reorder 后仍写入原 targetVillageId', () => {
    const store = new InMemoryVillageStore();
    const a = {
      id: '00000000-0000-0000-0000-000000000001',
      name: 'A',
      tag: null,
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
    const c = {
      id: '00000000-0000-0000-0000-000000000003',
      name: 'C',
      tag: null,
      accountSnapshot: null,
      officialAPIState: null,
      hasImportedData: false,
    };
    store.seed([a, b, c], b.id);
    const coordinator = new ImportCoordinator(store, new FakeClock(0));
    coordinator.setImportText('{"tag":"#FORB","buildings":[]}');
    coordinator.setImportIntoCurrentVillage(true);
    coordinator.parse();
    expect(coordinator.getState().pending?.target).toEqual({
      kind: 'existing',
      villageId: b.id,
    });

    store.saveVillages([
      {
        id: '00000000-0000-0000-0000-000000000099',
        name: 'D',
        tag: null,
        accountSnapshot: null,
        officialAPIState: null,
        hasImportedData: false,
      },
      c,
      a,
      b,
    ]);

    expect(coordinator.confirmPending()).toBe(true);
    const villages = store.listVillages();
    expect(villages.find((village) => village.id === b.id)?.accountSnapshot?.tag).toBe('#FORB');
    expect(villages.find((village) => village.id === c.id)?.accountSnapshot).toBeNull();
    expect(villages.find((village) => village.id === a.id)?.accountSnapshot).toBeNull();
  });

  it('confirmPending 在 target 村庄删除后 fail closed，不写其他村庄', () => {
    const store = new InMemoryVillageStore();
    const a = {
      id: '00000000-0000-0000-0000-000000000001',
      name: 'A',
      tag: null,
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
    const c = {
      id: '00000000-0000-0000-0000-000000000003',
      name: 'C',
      tag: null,
      accountSnapshot: null,
      officialAPIState: null,
      hasImportedData: false,
    };
    store.seed([a, b, c], b.id);
    const coordinator = new ImportCoordinator(store, new FakeClock(0));
    coordinator.setImportText('{"tag":"#FORB","buildings":[]}');
    coordinator.setImportIntoCurrentVillage(true);
    coordinator.parse();

    store.saveVillages([a, c]);

    expect(coordinator.confirmPending()).toBe(false);
    expect(store.listVillages().every((village) => village.accountSnapshot === null)).toBe(true);
    expect(coordinator.getState().lastError).toContain('目标村庄不存在');
  });
});
