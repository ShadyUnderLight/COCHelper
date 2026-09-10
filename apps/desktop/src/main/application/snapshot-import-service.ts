/**
 * SnapshotImportService：显式目标的 prepare/commit（#276）。
 * prepare 绝不读取权威 selectedVillageId；仅使用请求中的 villageId。
 * commit/discard 必须携带 expectedGeneration（CAS）。
 * commit 经 SnapshotImportTransactionCoordinator 原子提交 villages+history+manual。
 */

import {
  MAX_IMPORT_TEXT_LENGTH,
  pendingImportPreviewWireSchema,
  pendingImportSummaryDtoSchema,
  quickPreparePreviewWireSchema,
  type ImportCommitPayload,
  type ImportDiscardPayload,
  type ImportPreparePayload,
  type ImportPrepareRequest,
  type QuickCommitPayload,
  type QuickDiscardPayload,
  type QuickPreparePayload,
} from '@coc-helper/contracts';
import {
  applySnapshotToVillage,
  createVillageProfile,
  encodeVillageStoreBytes,
  parsePendingImport,
  prepareQuickImport,
  type AccountSnapshot,
  type Clock,
  type ManualReconciliationDecision,
  type ManualTrackerStore,
  type PendingImportPreview,
  type QuickImportPreview,
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
import {
  toPendingImportPreviewWire,
  toPendingImportSummaryDto,
  toQuickPreparePreviewWire,
} from './dto-mappers';
import { GenerationBoundSlot, STALE_PENDING_MESSAGE } from './pending-slot';
import { HistoryService } from './history-service';
import type { VillageStorePort } from './import-coordinator';
import type { ManualTrackerService } from './manual-tracker-service';

export type SnapshotImportServiceOptions = {
  readonly state: AppAuthoritativeState;
  readonly clock: Clock;
  readonly importTransaction: SnapshotImportTransactionCoordinator | null;
  readonly history: SnapshotHistoryStore | null;
  readonly manual: ManualTrackerStore | null;
  readonly manualTracker: ManualTrackerService | null;
};

export class SnapshotImportService {
  private readonly state: AppAuthoritativeState;
  private readonly clock: Clock;
  private readonly importTransaction: SnapshotImportTransactionCoordinator | null;
  private readonly history: SnapshotHistoryStore | null;
  private readonly manual: ManualTrackerStore | null;
  private readonly manualTracker: ManualTrackerService | null;
  /**
   * 快捷导入待确认态：只保存在 Main 内存，Renderer 不得回传 preview。
   * 与普通 pending 走同一个 GenerationBoundSlot 不变量：
   * 调用者 token == 当前 generation == 创建代。
   */
  private readonly quickPending = new GenerationBoundSlot<QuickImportPreview>();

  constructor(options: SnapshotImportServiceOptions) {
    this.state = options.state;
    this.clock = options.clock;
    this.importTransaction = options.importTransaction;
    this.history = options.history;
    this.manual = options.manual;
    this.manualTracker = options.manualTracker;
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

  commit(
    expectedGeneration: number,
    reconciliationDecision: ManualReconciliationDecision = 'applyNonConflicting',
  ): ImportCommitPayload {
    if (!this.state.canWrite()) {
      throw new AppServiceError('unavailable', '当前处于恢复或只读状态，无法导入。');
    }
    const pending = this.state.takeLivePending();
    assertExpectedGeneration(this.state.getGeneration(), expectedGeneration);
    if (pending === null) {
      throw new AppServiceError('validation', '没有待确认的导入。');
    }
    if (pending.target.kind === 'existing') {
      const selectedVillageId = this.commitSnapshotToTarget({
        snapshot: pending.snapshot,
        targetVillageId: pending.target.villageId,
        reconciliationDecision,
      });
      this.state.setPending(null, { bump: false });
      this.state.notifyMutation();
      return {
        generation: this.state.getGeneration(),
        selectedVillageId,
      };
    }
    if (
      this.importTransaction === null ||
      this.history === null ||
      this.manual === null ||
      this.manualTracker === null
    ) {
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
    const historyService = new HistoryService(this.history);
    const historyEnvelope = historyService.loadOrMigrate({
      villages,
      nowRefSeconds: unixSecondsToRefSeconds(appliedAtMs / 1000),
    });
    const villageID = requireUuid(targetVillage.id, '目标村庄 ID');
    const previousEntry = historyService.activeEntry(historyEnvelope, villageID);
    const historyDecision = historyService.planImport({
      snapshot: pending.snapshot,
      villageID,
      currentTag: targetVillage.tag,
      hasCurrentSnapshot:
        targetVillage.accountSnapshot !== null && pending.target.kind !== 'create',
      envelope: historyEnvelope,
      appliedAtRefSeconds: unixSecondsToRefSeconds(appliedAtMs / 1000),
    });

    const reconciled = this.manualTracker.buildReconciledManualEnvelope({
      villageID,
      previousEntry,
      decision: historyDecision,
      appliedAtMs,
      reconciliationDecision,
    });

    try {
      this.importTransaction.commit({
        currentData: encodeVillageStoreBytes(nextVillages),
        envelope: historyDecision.envelope,
        manualEnvelope: reconciled.envelope,
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
    const pending = this.state.takeLivePending();
    assertExpectedGeneration(this.state.getGeneration(), expectedGeneration);
    if (pending === null) {
      return { generation: this.state.getGeneration() };
    }
    this.state.setPending(null);
    return { generation: this.state.getGeneration() };
  }

  /**
   * 快捷导入 prepare（#277-D）：目标固定为详情页当前村庄，文本由 Main 从剪贴板读取后传入。
   * 成功时把 preview 保存在 Main 内存并 bump generation；失败不留待确认态。
   */
  quickPrepare(input: { targetVillageId: string; text: string }): QuickPreparePayload {
    if (!this.state.canWrite()) {
      throw new AppServiceError('unavailable', '当前处于恢复或只读状态，无法导入。');
    }
    // 资源边界（与 import.prepare 同值）：剪贴板不走 IPC schema，必须在进入
    // domain parser 之前显式设限。拒绝时不 bump、不动现有 pending。
    if (input.text.length > MAX_IMPORT_TEXT_LENGTH) {
      throw new AppServiceError('validation', '剪贴板文本过长，无法导入。');
    }
    const result = prepareQuickImport({
      text: input.text,
      targetVillageId: input.targetVillageId,
      villages: this.state.listVillages(),
      clock: this.clock,
    });
    if (!result.ok) {
      throw mapQuickImportError(result.error);
    }
    const preview = result.value;
    let wire: QuickPreparePayload['preview'];
    try {
      wire = toQuickPreparePreviewWire(preview);
    } catch (error) {
      if (error instanceof RangeError) {
        throw new AppServiceError('validation', '导入预览包含无法经 IPC 传递的数值。');
      }
      throw error;
    }
    const parsed = quickPreparePreviewWireSchema.safeParse(wire);
    if (!parsed.success) {
      throw new AppServiceError('validation', '导入预览详情无法经 IPC schema 校验。');
    }
    /** mapper + 共享 zod 全部成功后，才保存 quickPending / bump generation。 */
    this.state.notifyMutation();
    const generation = this.state.getGeneration();
    this.quickPending.store(preview, generation);
    return { generation, preview: parsed.data };
  }

  /**
   * 快捷导入 commit：只用 Main 保存的 preview 与双重绑定的 generation（CAS），
   * 复用与普通导入一致的 villages+history+manual 原子提交边界。
   */
  quickCommit(
    expectedGeneration: number,
    reconciliationDecision: ManualReconciliationDecision = 'applyNonConflicting',
  ): QuickCommitPayload {
    if (!this.state.canWrite()) {
      throw new AppServiceError('unavailable', '当前处于恢复或只读状态，无法导入。');
    }
    const pending = this.takeLiveQuickPending();
    assertExpectedGeneration(this.state.getGeneration(), expectedGeneration);
    if (pending === null) {
      throw new AppServiceError('validation', '没有待确认的快捷导入。');
    }
    const selectedVillageId = this.commitSnapshotToTarget({
      snapshot: pending.snapshot,
      targetVillageId: pending.targetVillageId,
      reconciliationDecision,
    });
    this.quickPending.clear();
    this.state.notifyMutation();
    return {
      generation: this.state.getGeneration(),
      selectedVillageId,
    };
  }

  quickDiscard(expectedGeneration: number): QuickDiscardPayload {
    const pending = this.takeLiveQuickPending();
    assertExpectedGeneration(this.state.getGeneration(), expectedGeneration);
    if (pending === null) {
      return { generation: this.state.getGeneration() };
    }
    this.quickPending.clear();
    this.state.notifyMutation();
    return { generation: this.state.getGeneration() };
  }

  /** 与普通 takeLivePending 同一不变量，共享 GenerationBoundSlot。 */
  private takeLiveQuickPending(): QuickImportPreview | null {
    return this.quickPending.takeLive(this.state.getGeneration(), () => {
      throw new AppServiceError('conflict', STALE_PENDING_MESSAGE);
    });
  }

  /**
   * 快照写入既有村庄的共享内核：普通 commit（existing 目标）与 quickCommit 共用，
   * 保证崩溃/重启/事务失败语义一致。调用方负责 generation CAS 与 pending 生命周期。
   */
  private commitSnapshotToTarget(input: {
    snapshot: AccountSnapshot;
    targetVillageId: string;
    reconciliationDecision: ManualReconciliationDecision;
  }): string {
    if (
      this.importTransaction === null ||
      this.history === null ||
      this.manual === null ||
      this.manualTracker === null
    ) {
      throw new AppServiceError('unavailable', '导入事务尚未就绪。');
    }

    const store = this.state.getVillageStore();
    /** 导入前权威 villages：history migration 只能基于它，绝不能用已应用 pending 的 nextVillages。 */
    const villages = [...store.listVillages()];
    const index = villages.findIndex((village) => village.id === input.targetVillageId);
    if (index < 0) {
      throw new AppServiceError('notFound', '目标村庄不存在，无法导入。');
    }
    const previous = villages[index]!;
    const updated = applySnapshotToVillage(previous, input.snapshot);
    const nextVillages = [...villages];
    nextVillages[index] = updated;

    const appliedAtMs = this.clock.nowMs();
    const historyService = new HistoryService(this.history);
    const historyEnvelope = historyService.loadOrMigrate({
      villages,
      nowRefSeconds: unixSecondsToRefSeconds(appliedAtMs / 1000),
    });
    const villageID = requireUuid(previous.id, '目标村庄 ID');
    const previousEntry = historyService.activeEntry(historyEnvelope, villageID);
    const historyDecision = historyService.planImport({
      snapshot: input.snapshot,
      villageID,
      currentTag: previous.tag,
      hasCurrentSnapshot: previous.accountSnapshot !== null,
      envelope: historyEnvelope,
      appliedAtRefSeconds: unixSecondsToRefSeconds(appliedAtMs / 1000),
    });

    const reconciled = this.manualTracker.buildReconciledManualEnvelope({
      villageID,
      previousEntry,
      decision: historyDecision,
      appliedAtMs,
      reconciliationDecision: input.reconciliationDecision,
    });

    try {
      this.importTransaction.commit({
        currentData: encodeVillageStoreBytes(nextVillages),
        envelope: historyDecision.envelope,
        manualEnvelope: reconciled.envelope,
      });
    } catch (error) {
      throw new AppServiceError('unavailable', formatTransactionError(error));
    }

    if (hasAdoptCommittedVillages(store)) {
      store.adoptCommittedVillages(nextVillages, input.targetVillageId);
    } else {
      store.saveVillages(nextVillages);
      store.setSelectedVillageId(input.targetVillageId);
    }
    return input.targetVillageId;
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

function mapQuickImportError(
  error: import('@coc-helper/domain').QuickImportError,
): AppServiceError {
  switch (error.kind) {
    case 'emptyClipboard':
      return new AppServiceError('validation', '系统剪贴板中没有可用的文本。');
    case 'parseFailed':
      return new AppServiceError('validation', formatImportError(error.error));
    case 'targetVillageMissing':
      return new AppServiceError('notFound', '目标村庄不存在，无法导入。');
    case 'tagBelongsToAnotherVillage':
      return new AppServiceError(
        'conflict',
        `账号 Tag（${error.tag}）属于「${error.villageName}」，不能导入到当前村庄。`,
      );
  }
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
