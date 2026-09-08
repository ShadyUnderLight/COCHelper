/**
 * Main 权威应用态（#276）。generation 单调递增；query 只读快照，不写盘。
 */

import type {
  AppAvailability,
  AppSnapshotPayload,
  PendingImportSummaryDto,
  StateChangedListener,
  VillageStoreStatusDto,
} from '@coc-helper/contracts';
import {
  villageStoreStatusRequiresRecovery,
  type PendingImportPreview,
  type PersistenceBootstrapResult,
  type VillageProfile,
} from '@coc-helper/domain';

import { toPendingImportSummaryDto, toVillageSummaryDto } from './dto-mappers';
import type { VillageStorePort } from './import-coordinator';

export type AppAuthoritativeStateOptions = {
  readonly persistence: PersistenceBootstrapResult | null;
  readonly villageStore: VillageStorePort | null;
  readonly bootError?: string | null;
};

export class AppAuthoritativeState {
  private generation = 0;
  private pending: PendingImportPreview | null = null;
  private readonly listeners = new Set<StateChangedListener>();
  private readonly persistence: PersistenceBootstrapResult | null;
  private readonly villageStore: VillageStorePort | null;
  private readonly bootError: string | null;

  constructor(options: AppAuthoritativeStateOptions) {
    this.persistence = options.persistence;
    this.villageStore = options.villageStore;
    this.bootError = options.bootError ?? null;
  }

  getGeneration(): number {
    return this.generation;
  }

  getPending(): PendingImportPreview | null {
    return this.pending;
  }

  setPending(
    pending: PendingImportPreview | null,
    options: { emit?: boolean; bump?: boolean } = {},
  ): void {
    this.pending = pending;
    if (options.bump === false) {
      return;
    }
    this.bump(options.emit !== false);
  }

  /** 写盘 command 成功后调用：bump generation 并广播。 */
  notifyMutation(): void {
    this.bump(true);
  }

  subscribe(listener: StateChangedListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  /** query：只读，不 bump、不写盘。 */
  snapshot(): AppSnapshotPayload {
    return this.buildSnapshot();
  }

  listVillages(): readonly VillageProfile[] {
    if (this.villageStore === null) {
      return this.persistence?.villagesInMemory ?? [];
    }
    return this.villageStore.listVillages();
  }

  getSelectedVillageId(): string | null {
    if (this.villageStore !== null) {
      return this.villageStore.getSelectedVillageId();
    }
    return this.persistence?.selectedVillageId ?? null;
  }

  getVillageStore(): VillageStorePort {
    if (this.villageStore === null) {
      throw new AppServiceError('unavailable', '持久化未就绪，无法写入村庄。');
    }
    return this.villageStore;
  }

  canWrite(): boolean {
    return this.villageStore !== null && (this.persistence?.canInitializeDerivedStores ?? false);
  }

  private bump(emit: boolean): void {
    this.generation += 1;
    if (emit) {
      const payload = this.buildSnapshot();
      for (const listener of this.listeners) {
        listener(payload);
      }
    }
  }

  private buildSnapshot(): AppSnapshotPayload {
    const villages = this.listVillages();
    const villageStatus = this.resolveVillageStatus();
    const availability = this.resolveAvailability(villageStatus);
    const pendingImport: PendingImportSummaryDto | null =
      this.pending === null ? null : toPendingImportSummaryDto(this.pending, villages);

    return {
      generation: this.generation,
      availability,
      villageStatus,
      villageError: this.bootError ?? this.persistence?.villageError ?? null,
      canWrite: this.canWrite(),
      selectedVillageId: this.getSelectedVillageId(),
      villages: villages.map(toVillageSummaryDto),
      pendingImport,
    };
  }

  private resolveVillageStatus(): VillageStoreStatusDto {
    if (this.persistence === null) {
      return 'missing';
    }
    return this.persistence.villageStatus;
  }

  private resolveAvailability(status: VillageStoreStatusDto): AppAvailability {
    if (this.persistence === null) {
      return this.bootError !== null ? 'unavailable' : 'loading';
    }
    if (villageStoreStatusRequiresRecovery(status)) {
      return 'recovery';
    }
    return 'available';
  }
}

export class AppServiceError extends Error {
  override readonly name = 'AppServiceError';
  constructor(
    readonly code: 'notFound' | 'unavailable' | 'validation' | 'conflict',
    message: string,
  ) {
    super(message);
  }
}
