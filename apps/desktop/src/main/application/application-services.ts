/**
 * Main application services 组装入口（#276 首片）。
 */

import { SystemClock, type Clock } from '@coc-helper/domain';

import {
  AppLifecycleService,
  bootApplicationServices,
  type AppLifecycleBootResult,
} from './app-lifecycle-service';
import { SnapshotImportService } from './snapshot-import-service';
import { VillageService } from './village-service';
import type { AppAuthoritativeState } from './app-authoritative-state';

export type ApplicationServices = {
  readonly lifecycle: AppLifecycleService;
  readonly villages: VillageService;
  readonly imports: SnapshotImportService;
  readonly state: AppAuthoritativeState;
  readonly boot: AppLifecycleBootResult;
};

export function createApplicationServices(
  options: {
    readonly clock?: Clock;
    readonly boot?: AppLifecycleBootResult;
  } = {},
): ApplicationServices {
  const clock = options.clock ?? new SystemClock();
  const boot = options.boot ?? bootApplicationServices({ clock });
  const lifecycle = new AppLifecycleService(boot.state, boot.persistence);
  return {
    lifecycle,
    villages: new VillageService(boot.state),
    imports: new SnapshotImportService({
      state: boot.state,
      clock,
      importTransaction: boot.persistence?.importTransaction ?? null,
      history: boot.persistence?.history ?? null,
      manual: boot.persistence?.manual ?? null,
    }),
    state: boot.state,
    boot,
  };
}

export { AppLifecycleService, bootApplicationServices } from './app-lifecycle-service';
export { VillageService } from './village-service';
export { SnapshotImportService } from './snapshot-import-service';
export { AppAuthoritativeState, AppServiceError } from './app-authoritative-state';
