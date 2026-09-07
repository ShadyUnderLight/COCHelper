/**
 * SnapshotImportService：显式目标的 prepare/commit（#276）。
 * prepare 绝不读取权威 selectedVillageId；仅使用请求中的 villageId。
 * commit/discard 必须携带 expectedGeneration（CAS）。
 * commit 经 SnapshotImportTransactionCoordinator 原子提交 villages+history。
 *
 * 本切片不改写 manual envelope（manualEnvelope=null）：完整 observation 对账留给后续切片，
 * 避免 empty-observation placeholder 错误 rebase 既有 manual provenance。
 */

import {
  pendingImportPreviewWireSchema,
  pendingImportSummaryDtoSchema,
  type ImportCommitPayload,
  type ImportDiscardPayload,
  type ImportPreparePayload,
  type ImportPrepareRequest,
} from '@coc-helper/contracts';
import {
  applySnapshotToVillage,
  createSnapshotHistoryService,
  createVillageProfile,
  encodeVillageStoreBytes,
  parsePendingImport,
  type Clock,
  type PendingImportPreview,
  type SnapshotHistoryStore,
  type SnapshotImportTransactionCoordinator,
  type VillageProfile,
} from '@coc-helper/domain';
import {
  generateUuid,
  parseUuid,
  unixSecondsToRefSeconds,
  type UuidString,
} from '@coc-helper/wire';

import { AppServiceError, type AppAuthoritativeState } from './app-authoritative-state';
import { toPendingImportPreviewWire, toPendingImportSummaryDto } from './dto-mappers';
import type { VillageStorePort } from './import-coordinator';

export type SnapshotImportServiceOptions = {
  readonly state: AppAuthoritativeState;
  readonly clock: Clock;
  readonly importTransaction: SnapshotImportTransactionCoordinator | null;
  readonly history: SnapshotHistoryStore | null;
};

export class SnapshotImportService {
  private readonly state: AppAuthoritativeState;
  private readonly clock: Clock;
  private readonly importTransaction: SnapshotImportTransactionCoordinator | null;
  private readonly history: SnapshotHistoryStore | null;

  constructor(options: SnapshotImportServiceOptions) {
    this.state = options.state;
    this.clock = options.clock;
    this.importTransaction = options.importTransaction;
    this.history = options.history;
  }

  prepare(request: ImportPrepareRequest): ImportPreparePayload {
    if (!this.state.canWrite()) {
      throw new AppServiceError('unavailable', '当前处于恢复或只读状态，无法导入。');
    }
    const villages = this.state.listVillages();
    /** 显式目标：只用请求 villageId，不读 store selected。 */
    const explicitVillageId = request.villageId ?? null;
    if (explicitVillageId !== null) {
      const exists = villages.some((village) => village.id === explicitVillageId);
      if (!exists) {
        throw new AppServiceError('notFound', '目标村庄不存在，无法导入。');
      }
    }

    const result = parsePendingImport({
      text: request.text,
      villages,
      selectedVillageId: explicitVillageId,
      importIntoCurrentVillage: explicitVillageId !== null,
      clock: this.clock,
    });
    if (!result.ok) {
      if ('kind' in result.error && result.error.kind === 'ambiguous') {
        throw new AppServiceError('conflict', result.error.message);
      }
      throw new AppServiceError('validation', formatImportError(result.error));
    }

    const pending = result.value;
    /** mapper + 共享 zod 全部成功后，才 setPending / bump generation。 */
    const dto = mapAndValidatePendingDtos(pending, villages);
    this.state.setPending(pending);
    return {
      generation: this.state.getGeneration(),
      pending: dto.pending,
      preview: dto.preview,
    };
  }

  commit(expectedGeneration: number): ImportCommitPayload {
    if (!this.state.canWrite()) {
      throw new AppServiceError('unavailable', '当前处于恢复或只读状态，无法导入。');
    }
    assertExpectedGeneration(this.state.getGeneration(), expectedGeneration);
    const pending = this.state.getPending();
    if (pending === null) {
      throw new AppServiceError('validation', '没有待确认的导入。');
    }
    if (this.importTransaction === null || this.history === null) {
      throw new AppServiceError('unavailable', '导入事务尚未就绪。');
    }

    const store = this.state.getVillageStore();
    /** 导入前权威 villages：history migration 只能基于它，绝不能用已应用 pending 的 nextVillages。 */
    const villages = [...store.listVillages()];
    const { nextVillages, targetVillage, selectedVillageId } = buildCandidateVillages(
      pending,
      villages,
    );

    const appliedAtMs = this.clock.nowMs();
    const historyService = createSnapshotHistoryService(this.history);
    const historyEnvelope = historyService.loadOrMigrate({
      villages,
      nowRefSeconds: unixSecondsToRefSeconds(appliedAtMs / 1000),
    });
    const villageID = requireUuid(targetVillage.id, '目标村庄 ID');
    const historyDecision = historyService.planImport({
      snapshot: pending.snapshot,
      villageID,
      currentTag: targetVillage.tag,
      hasCurrentSnapshot:
        targetVillage.accountSnapshot !== null && pending.target.kind !== 'create',
      envelope: historyEnvelope,
      appliedAtRefSeconds: unixSecondsToRefSeconds(appliedAtMs / 1000),
    });

    try {
      this.importTransaction.commit({
        currentData: encodeVillageStoreBytes(nextVillages),
        envelope: historyDecision.envelope,
        /** 本切片不纳入 manual：完整 observation 对账前不得 empty-observation rebase。 */
        manualEnvelope: null,
      });
    } catch (error) {
      throw new AppServiceError('unavailable', formatTransactionError(error));
    }

    if (hasAdoptCommittedVillages(store)) {
      store.adoptCommittedVillages(nextVillages, selectedVillageId);
    } else {
      store.saveVillages(nextVillages);
      store.setSelectedVillageId(selectedVillageId);
    }

    this.state.setPending(null, { bump: false });
    this.state.notifyMutation();
    return {
      generation: this.state.getGeneration(),
      selectedVillageId: store.getSelectedVillageId(),
    };
  }

  discard(expectedGeneration: number): ImportDiscardPayload {
    assertExpectedGeneration(this.state.getGeneration(), expectedGeneration);
    if (this.state.getPending() === null) {
      return { generation: this.state.getGeneration() };
    }
    this.state.setPending(null);
    return { generation: this.state.getGeneration() };
  }
}

type VillageStoreWithAdopt = VillageStorePort & {
  adoptCommittedVillages(
    villages: readonly VillageProfile[],
    selectedVillageId: string | null,
  ): void;
};

function hasAdoptCommittedVillages(store: VillageStorePort): store is VillageStoreWithAdopt {
  return typeof (store as VillageStoreWithAdopt).adoptCommittedVillages === 'function';
}

function assertExpectedGeneration(current: number, expected: number): void {
  if (current !== expected) {
    throw new AppServiceError('conflict', '导入状态已过期，请刷新后重试。');
  }
}

function mapAndValidatePendingDtos(
  pending: PendingImportPreview,
  villages: readonly VillageProfile[],
): Pick<ImportPreparePayload, 'pending' | 'preview'> {
  let mapped: Pick<ImportPreparePayload, 'pending' | 'preview'>;
  try {
    mapped = {
      pending: toPendingImportSummaryDto(pending, villages),
      preview: toPendingImportPreviewWire(pending),
    };
  } catch (error) {
    if (error instanceof RangeError) {
      throw new AppServiceError('validation', '导入预览包含无法经 IPC 传递的数值。');
    }
    throw error;
  }
  const summary = pendingImportSummaryDtoSchema.safeParse(mapped.pending);
  if (!summary.success) {
    throw new AppServiceError('validation', '导入预览摘要无法经 IPC schema 校验。');
  }
  const preview = pendingImportPreviewWireSchema.safeParse(mapped.preview);
  if (!preview.success) {
    throw new AppServiceError('validation', '导入预览详情无法经 IPC schema 校验。');
  }
  return { pending: summary.data, preview: preview.data };
}

function buildCandidateVillages(
  pending: PendingImportPreview,
  villages: VillageProfile[],
): {
  readonly nextVillages: VillageProfile[];
  readonly targetVillage: VillageProfile;
  readonly selectedVillageId: string;
} {
  const target = pending.target;
  switch (target.kind) {
    case 'create': {
      const snapshot = pending.snapshot;
      const village = createVillageProfile({
        id: generateUuid(),
        name: snapshot.tag?.trim() || `村庄 ${villages.length + 1}`,
        accountSnapshot: snapshot,
      });
      return {
        nextVillages: [...villages, village],
        targetVillage: village,
        selectedVillageId: village.id,
      };
    }
    case 'existing': {
      const index = villages.findIndex((village) => village.id === target.villageId);
      if (index < 0) {
        throw new AppServiceError('notFound', '目标村庄不存在，无法导入。');
      }
      const previous = villages[index]!;
      const updated = applySnapshotToVillage(previous, pending.snapshot);
      const nextVillages = [...villages];
      nextVillages[index] = updated;
      return {
        nextVillages,
        targetVillage: previous,
        selectedVillageId: target.villageId,
      };
    }
    case 'ambiguous':
      throw new AppServiceError('conflict', '导入目标不明确。');
  }
}

function requireUuid(value: string, label: string): UuidString {
  const parsed = parseUuid(value);
  if (parsed === undefined) {
    throw new AppServiceError('validation', `${label} 不是合法 UUID。`);
  }
  return parsed;
}

function formatImportError(error: import('@coc-helper/domain').AccountSnapshotImportError): string {
  switch (error.kind) {
    case 'emptyInput':
      return '没有可解析的文本。请先从游戏复制并粘贴 JSON。';
    case 'topLevelMustBeObject':
      return 'JSON 顶层必须是对象，以 { 开头。';
    case 'invalidJSON':
      return `JSON 解析失败：${error.message}`;
  }
}

function formatTransactionError(error: unknown): string {
  if (
    typeof error === 'object' &&
    error !== null &&
    'message' in error &&
    typeof (error as { message: unknown }).message === 'string'
  ) {
    const message = (error as { message: string }).message;
    return message.length > 0 && message.length <= 200 ? message : '导入事务提交失败。';
  }
  return '导入事务提交失败。';
}
