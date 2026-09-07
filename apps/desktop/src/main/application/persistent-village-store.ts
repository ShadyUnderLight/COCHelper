/**
 * VillageStorePort 的文件实现：villages-v1 + selection-v1。
 * 快照导入的 villages/history/manual 原子提交由 SnapshotImportService
 * 经 SnapshotImportTransactionCoordinator 编排；本 store 在事务成功后
 * 只同步内存权威态与 selection（soft fail-open）。
 */

import {
  SelectionFileStore,
  resolveSelectedVillageId,
  VillageFileStore,
  type VillageProfile,
} from '@coc-helper/domain';

import type { VillageStorePort } from './import-coordinator';

export type PersistentVillageStoreOptions = {
  readonly villages: VillageFileStore;
  readonly selection: SelectionFileStore;
  /** 启动 recover 后的内存权威态；缺省则尝试从文件 load。 */
  readonly initialVillages?: readonly VillageProfile[];
  readonly initialSelectedVillageId?: string | null;
};

export class PersistentVillageStore implements VillageStorePort {
  private villagesCache: VillageProfile[];
  private selectedVillageId: string | null;
  private readonly villagesStore: VillageFileStore;
  private readonly selectionStore: SelectionFileStore;

  constructor(options: PersistentVillageStoreOptions) {
    this.villagesStore = options.villages;
    this.selectionStore = options.selection;
    if (options.initialVillages !== undefined) {
      this.villagesCache = [...options.initialVillages];
    } else {
      const loaded = this.villagesStore.load();
      this.villagesCache = loaded.kind === 'loaded' ? [...loaded.villages] : [];
    }
    this.selectedVillageId = resolveSelectedVillageId(
      this.villagesCache.map((village) => village.id),
      options.initialSelectedVillageId !== undefined
        ? options.initialSelectedVillageId
        : this.selectionStore.load(),
    );
  }

  listVillages(): readonly VillageProfile[] {
    return this.villagesCache;
  }

  saveVillages(villages: readonly VillageProfile[]): void {
    this.villagesStore.save(villages);
    this.villagesCache = [...villages];
    const nextSelected = resolveSelectedVillageId(
      this.villagesCache.map((village) => village.id),
      this.selectedVillageId,
    );
    this.selectedVillageId = nextSelected;
    try {
      this.selectionStore.save(nextSelected);
    } catch {
      // selection 是 soft fail-open：村庄已提交成功；重启后按 resolveSelectedVillageId 回落。
    }
  }

  getSelectedVillageId(): string | null {
    return this.selectedVillageId;
  }

  setSelectedVillageId(id: string | null): void {
    const resolved = resolveSelectedVillageId(
      this.villagesCache.map((village) => village.id),
      id,
    );
    this.selectedVillageId = resolved;
    try {
      this.selectionStore.save(resolved);
    } catch {
      // selection 是 soft fail-open：内存权威已更新；重启后按 resolveSelectedVillageId 回落。
    }
  }

  /**
   * 外部事务（SnapshotImportTransactionCoordinator）已写盘后调用：
   * 只同步内存 villages/selection，不再二次写 villages 文件。
   */
  adoptCommittedVillages(
    villages: readonly VillageProfile[],
    selectedVillageId: string | null,
  ): void {
    this.villagesCache = [...villages];
    this.setSelectedVillageId(selectedVillageId);
  }
}
