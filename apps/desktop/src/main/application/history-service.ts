/**
 * HistoryService（#276-S3）：Snapshot History 查询与 planImport 封装。
 * 不写盘（loadOrMigrate 除外，其可能完成一次性 migration save）。
 */

import {
  createSnapshotHistoryService,
  envelopeActiveLineage,
  envelopeEntry,
  type PlanSnapshotHistoryImportForServiceInput,
  type SnapshotHistoryEnvelope,
  type SnapshotHistoryEntry,
  type SnapshotHistoryImportDecision,
  type SnapshotHistoryStore,
  type VillageProfile,
} from '@coc-helper/domain';
import type { UuidString } from '@coc-helper/wire';

export class HistoryService {
  private readonly store: SnapshotHistoryStore;
  private readonly inner: ReturnType<typeof createSnapshotHistoryService>;

  constructor(store: SnapshotHistoryStore) {
    this.store = store;
    this.inner = createSnapshotHistoryService(store);
  }

  loadOrMigrate(input: {
    readonly villages: readonly VillageProfile[];
    readonly nowRefSeconds: number;
  }): SnapshotHistoryEnvelope {
    return this.inner.loadOrMigrate(input);
  }

  planImport(input: PlanSnapshotHistoryImportForServiceInput): SnapshotHistoryImportDecision {
    return this.inner.planImport(input);
  }

  activeEntry(
    envelope: SnapshotHistoryEnvelope,
    villageID: UuidString,
  ): SnapshotHistoryEntry | null {
    const lineage = envelopeActiveLineage(envelope, villageID);
    if (lineage === undefined) {
      return null;
    }
    return envelopeEntry(envelope, lineage.lastEntryID) ?? null;
  }

  loadRaw(): SnapshotHistoryEnvelope | null {
    return this.store.load();
  }
}
