import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  createVillageProfile,
  SelectionFileStore,
  SystemClock,
  VillageFileStore,
} from '@coc-helper/domain';
import { describe, expect, it } from 'vitest';

import { ImportCoordinator } from './import-coordinator';
import { PersistentVillageStore } from './persistent-village-store';

describe('PersistentVillageStore', () => {
  it('save/select 会落盘，跨实例可恢复，ImportCoordinator 可注入', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-persistent-village-'));
    const villagesPath = join(root, 'villages-v1.json');
    const selectionPath = join(root, 'selection-v1.json');
    const store = new PersistentVillageStore({
      villages: new VillageFileStore(villagesPath),
      selection: new SelectionFileStore(selectionPath),
      initialVillages: [createVillageProfile({ id: 'v-1', name: '主村' })],
      initialSelectedVillageId: 'v-1',
    });
    const coordinator = new ImportCoordinator(store, new SystemClock());
    expect(coordinator.getState().lastError).toBeNull();

    store.saveVillages([
      createVillageProfile({ id: 'v-1', name: '主村' }),
      createVillageProfile({ id: 'v-2', name: '二村' }),
    ]);
    store.setSelectedVillageId('v-2');

    const reloaded = new PersistentVillageStore({
      villages: new VillageFileStore(villagesPath),
      selection: new SelectionFileStore(selectionPath),
    });
    expect(reloaded.listVillages()).toHaveLength(2);
    expect(reloaded.getSelectedVillageId()).toBe('v-2');
    rmSync(root, { recursive: true, force: true });
  });
});
