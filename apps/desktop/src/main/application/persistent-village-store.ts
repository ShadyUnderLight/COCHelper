/**
 * VillageStorePort 的文件实现：villages-v1 + selection-v1。
 * 完整 history/manual 事务导入留给未来 SnapshotImportService（#276）。
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
    if (nextSelected !== this.selectedVillageId) {
      this.setSelectedVillageId(nextSelected);
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
    this.selectionStore.save(resolved);
  }
}
