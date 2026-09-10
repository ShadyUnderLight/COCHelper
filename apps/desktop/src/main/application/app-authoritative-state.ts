/**
 * Main 权威应用态（#276）。generation 单调递增；query 只读快照，不写盘。
 * sessionId 在 Main 进程生命周期内稳定，重启后变化，供 renderer 丢弃 stale 响应。
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
import { generateUuid } from '@coc-helper/wire';

import { toPendingImportSummaryDto, toVillageSummaryDto } from './dto-mappers';
import type { VillageStorePort } from './import-coordinator';
import { GenerationBoundSlot, STALE_PENDING_MESSAGE } from './pending-slot';

export type AppAuthoritativeStateOptions = {
  readonly persistence: PersistenceBootstrapResult | null;
  readonly villageStore: VillageStorePort | null;
  readonly bootError?: string | null;
  readonly sessionId?: string;
  readonly hasPendingJournal?: () => boolean;
};

export type InstallAvailableStateOptions = {
  readonly villageStore: VillageStorePort;
  readonly villageStatus: VillageStoreStatusDto;
  readonly villageError?: string | null;
  readonly notice?: string | null;
};

export class AppAuthoritativeState {
  private generation = 0;
  /** 普通导入待确认态：与创建代绑定，与 quick 侧走同一 takeLive 不变量。 */
  private readonly pendingSlot = new GenerationBoundSlot<PendingImportPreview>();
  private readonly listeners = new Set<StateChangedListener>();
  private readonly persistence: PersistenceBootstrapResult | null;
  private villageStore: VillageStorePort | null;
  private readonly bootError: string | null;
  private readonly sessionId: string;
  private readonly hasPendingJournalFn: () => boolean;
  /** 显式恢复成功后覆盖 bootstrap 只读字段。 */
  private villageStatusOverride: VillageStoreStatusDto | null = null;
  private villageErrorOverride: string | null | undefined = undefined;
  private canWriteOverride: boolean | null = null;
  private recoveryNotice: string | null = null;

  constructor(options: AppAuthoritativeStateOptions) {
    this.persistence = options.persistence;
    this.villageStore = options.villageStore;
    this.bootError = options.bootError ?? null;
    this.sessionId = options.sessionId ?? generateUuid();
    this.hasPendingJournalFn = options.hasPendingJournal ?? (() => false);
  }

  getSessionId(): string {
    return this.sessionId;
  }

  getGeneration(): number {
    return this.generation;
  }

  getPending(): PendingImportPreview | null {
    return this.pendingSlot.peek();
  }

  /**
   * 取出与当前 generation 绑定的普通 pending（与 quick 侧同一不变量）。
   * 死 pending 在此清理并按 conflict 拒绝，失败路径不 bump。
   */
  takeLivePending(): PendingImportPreview | null {
    return this.pendingSlot.takeLive(this.generation, () => {
      throw new AppServiceError('conflict', STALE_PENDING_MESSAGE);
    });
  }

  getRecoveryNotice(): string | null {
    return this.recoveryNotice;
  }

  setPending(
    pending: PendingImportPreview | null,
    options: { emit?: boolean; bump?: boolean } = {},
  ): void {
    if (options.bump === false) {
      if (pending === null) {
        this.pendingSlot.clear();
      } else {
        this.pendingSlot.store(pending, this.generation);
      }
      return;
    }
    // 先推进代再绑定：创建代精确等于本次广播/prepare 返回的 generation，
    // 不依赖“bump 步长为 1”的算术巧合。
    this.bump(false);
    if (pending === null) {
      this.pendingSlot.clear();
    } else {
      this.pendingSlot.store(pending, this.generation);
    }
    if (options.emit !== false) {
      this.emit();
    }
  }

  /** 写盘 command 成功后调用：bump generation 并广播。 */
  notifyMutation(): void {
    this.bump(true);
  }

  /**
   * 用户显式恢复成功后安装可写权威态。
   * sessionId 不变；generation +1；pending 清空。
   */
  installAvailableState(options: InstallAvailableStateOptions): void {
    this.villageStore = options.villageStore;
    this.villageStatusOverride = options.villageStatus;
    this.villageErrorOverride = options.villageError ?? null;
    this.canWriteOverride = true;
    this.recoveryNotice = options.notice ?? null;
    this.pendingSlot.clear();
    this.bump(true);
  }

  /** 恢复动作失败但仍留在 recovery：更新 notice，可选覆盖错误文案。 */
  noteRecoveryFailure(notice: string, villageError?: string | null): void {
    this.recoveryNotice = notice;
    if (villageError !== undefined) {
      this.villageErrorOverride = villageError;
    }
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
    if (this.canWriteOverride !== null) {
      return this.canWriteOverride;
    }
    return this.villageStore !== null && (this.persistence?.canInitializeDerivedStores ?? false);
  }

  hasPendingJournal(): boolean {
    return this.hasPendingJournalFn();
  }

  private bump(emit: boolean): void {
    this.generation += 1;
    if (emit) {
      this.emit();
    }
  }

  private emit(): void {
    const payload = this.buildSnapshot();
    for (const listener of this.listeners) {
      listener(payload);
    }
  }

  private buildSnapshot(): AppSnapshotPayload {
    const villages = this.listVillages();
    const villageStatus = this.resolveVillageStatus();
    const availability = this.resolveAvailability(villageStatus);
    const pending = this.pendingSlot.peek();
    const pendingImport: PendingImportSummaryDto | null =
      pending === null ? null : toPendingImportSummaryDto(pending, villages);

    return {
      sessionId: this.sessionId,
      generation: this.generation,
      availability,
      villageStatus,
      villageError: this.resolveVillageError(),
      canWrite: this.canWrite(),
      hasPendingJournal: this.hasPendingJournal(),
      recoveryNotice: this.recoveryNotice,
      selectedVillageId: this.getSelectedVillageId(),
      villages: villages.map(toVillageSummaryDto),
      pendingImport,
    };
  }

  private resolveVillageStatus(): VillageStoreStatusDto {
    if (this.villageStatusOverride !== null) {
      return this.villageStatusOverride;
    }
    if (this.persistence === null) {
      return 'missing';
    }
    return this.persistence.villageStatus;
  }

  private resolveVillageError(): string | null {
    if (this.villageErrorOverride !== undefined) {
      return this.villageErrorOverride;
    }
    return this.bootError ?? this.persistence?.villageError ?? null;
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
