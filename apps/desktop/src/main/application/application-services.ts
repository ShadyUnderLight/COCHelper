/**
 * Main application services 组装入口（#276）。
 */

import { SystemClock, type Clock } from '@coc-helper/domain';

import {
  AppLifecycleService,
  bootApplicationServices,
  type AppLifecycleBootResult,
} from './app-lifecycle-service';
import { SnapshotImportService } from './snapshot-import-service';
import { VillageService } from './village-service';
import { ProjectionService, type ProjectionCatalogPort } from './projection-service';
import { HistoryService } from './history-service';
import { ManualTrackerService } from './manual-tracker-service';
import type { AppAuthoritativeState } from './app-authoritative-state';
import { getCatalogService } from '../catalog-service';

export type ApplicationServices = {
  readonly lifecycle: AppLifecycleService;
  readonly villages: VillageService;
  readonly imports: SnapshotImportService;
  readonly projections: ProjectionService;
  readonly history: HistoryService | null;
  readonly manual: ManualTrackerService | null;
  readonly state: AppAuthoritativeState;
  readonly boot: AppLifecycleBootResult;
};

export function createApplicationServices(
  options: {
    readonly clock?: Clock;
    readonly boot?: AppLifecycleBootResult;
    readonly catalog?: ProjectionCatalogPort;
  } = {},
): ApplicationServices {
  const clock = options.clock ?? new SystemClock();
  const boot = options.boot ?? bootApplicationServices({ clock });
  const lifecycle = new AppLifecycleService(boot.state, boot.persistence);
  /** 延迟解析 catalog，避免非 Electron 测试在构造时触碰 app.isPackaged。 */
  const catalog: ProjectionCatalogPort = options.catalog ?? {
    getBundle: () => getCatalogService().getBundle(),
  };

  const history =
    boot.persistence?.history !== undefined && boot.persistence?.history !== null
      ? new HistoryService(boot.persistence.history)
      : null;

  const manual =
    boot.persistence !== null
      ? new ManualTrackerService({
          state: boot.state,
          clock,
          manual: boot.persistence.manual,
          history: boot.persistence.history,
          catalog,
          importTransaction: boot.persistence.importTransaction,
        })
      : null;

  return {
    lifecycle,
    villages: new VillageService(boot.state),
    imports: new SnapshotImportService({
      state: boot.state,
      clock,
      importTransaction: boot.persistence?.importTransaction ?? null,
      history: boot.persistence?.history ?? null,
      manual: boot.persistence?.manual ?? null,
      manualTracker: manual,
    }),
    projections: new ProjectionService({
      state: boot.state,
      clock,
      catalog,
      manual: boot.persistence?.manual ?? null,
    }),
    history,
    manual,
    state: boot.state,
    boot,
  };
}

export { AppLifecycleService, bootApplicationServices } from './app-lifecycle-service';
export { VillageService } from './village-service';
export { SnapshotImportService } from './snapshot-import-service';
export { ProjectionService } from './projection-service';
export { HistoryService } from './history-service';
export { ManualTrackerService } from './manual-tracker-service';
export { AppAuthoritativeState, AppServiceError } from './app-authoritative-state';
