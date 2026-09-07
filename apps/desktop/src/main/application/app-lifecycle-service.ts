/**
 * AppLifecycleService：启动权威态 + recovery/availability 暴露（#276）。
 */

import type { AppSnapshotPayload } from '@coc-helper/contracts';
import {
  SystemClock,
  bootstrapPersistence,
  type Clock,
  type PersistenceBootstrapResult,
} from '@coc-helper/domain';

import { AppAuthoritativeState } from './app-authoritative-state';
import { PersistentVillageStore } from './persistent-village-store';
import { applyOrphanCachePolicyOnStartup } from './orphan-startup';
import type { VillageStorePort } from './import-coordinator';

export type AppLifecycleBootResult = {
  readonly state: AppAuthoritativeState;
  readonly persistence: PersistenceBootstrapResult | null;
  readonly villageStore: VillageStorePort | null;
  readonly bootError: string | null;
};

export class AppLifecycleService {
  constructor(
    private readonly state: AppAuthoritativeState,
    private readonly persistence: PersistenceBootstrapResult | null,
  ) {}

  snapshot(): AppSnapshotPayload {
    return this.state.snapshot();
  }

  getPersistence(): PersistenceBootstrapResult | null {
    return this.persistence;
  }

  getState(): AppAuthoritativeState {
    return this.state;
  }
}

export function bootApplicationServices(
  options: {
    readonly clock?: Clock;
    readonly persistence?: PersistenceBootstrapResult | null;
    readonly bootError?: string | null;
  } = {},
): AppLifecycleBootResult {
  const clock = options.clock ?? new SystemClock();
  let persistence: PersistenceBootstrapResult | null = options.persistence ?? null;
  let bootError: string | null = options.bootError ?? null;

  if (options.persistence === undefined) {
    try {
      persistence = bootstrapPersistence();
    } catch (error) {
      persistence = null;
      bootError = error instanceof Error ? error.message : String(error);
    }
  }

  if (persistence !== null) {
    applyOrphanCachePolicyOnStartup(persistence, clock.nowMs());
  }

  const villageStore =
    persistence !== null && persistence.canInitializeDerivedStores
      ? new PersistentVillageStore({
          villages: persistence.villages,
          selection: persistence.selection,
          initialVillages: persistence.villagesInMemory,
          initialSelectedVillageId: persistence.selectedVillageId,
        })
      : null;

  const state = new AppAuthoritativeState({
    persistence,
    villageStore,
    bootError,
  });

  return {
    state,
    persistence,
    villageStore,
    bootError,
  };
}
