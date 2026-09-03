/**
 * E3-01-C 交给 #276 的可写导入边界。
 * recovery / readOnly 状态下不暴露可写 ImportCoordinator，避免覆盖需保留的原始 bytes。
 */

import { SystemClock, type Clock, type PersistenceBootstrapResult } from '@coc-helper/domain';

import { ImportCoordinator } from './import-coordinator';
import { PersistentVillageStore } from './persistent-village-store';

export function createImportCoordinatorFromPersistence(
  runtime: PersistenceBootstrapResult,
  clock: Clock = new SystemClock(),
): ImportCoordinator | null {
  if (!runtime.canInitializeDerivedStores) {
    return null;
  }
  const villageStore = new PersistentVillageStore({
    villages: runtime.villages,
    selection: runtime.selection,
    initialVillages: runtime.villagesInMemory,
    initialSelectedVillageId: runtime.selectedVillageId,
  });
  return new ImportCoordinator(villageStore, clock);
}
