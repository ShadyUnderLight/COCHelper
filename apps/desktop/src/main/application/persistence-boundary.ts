/**
 * E3-01-C / E3-02：从 persistence bootstrap 组装可写边界。
 * recovery / readOnly 状态下不暴露可写 VillageStore。
 */

import { SystemClock, type Clock, type PersistenceBootstrapResult } from '@coc-helper/domain';

import { bootApplicationServices } from './app-lifecycle-service';
import { createApplicationServices, type ApplicationServices } from './application-services';
import { ImportCoordinator } from './import-coordinator';
import { PersistentVillageStore } from './persistent-village-store';

/** @deprecated 使用 createApplicationServices；保留给过渡测试。 */
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

export function createApplicationServicesFromPersistence(
  runtime: PersistenceBootstrapResult,
  clock: Clock = new SystemClock(),
): ApplicationServices {
  const boot = bootApplicationServices({ clock, persistence: runtime });
  return createApplicationServices({ clock, boot });
}
