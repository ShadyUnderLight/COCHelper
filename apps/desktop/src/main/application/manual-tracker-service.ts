/**
 * ManualTrackerService（#276-S3）：Manual 状态读取与本地写命令。
 * - query 不 bump generation；
 * - command 显式 villageId + expectedGeneration CAS；
 * - 单 store 命令走 manual.save（BE-2.6）；
 * - 导入对账由 SnapshotImportService 调用 buildReconciledManualEnvelope，走三方事务。
 */

import type {
  ManualAdjustPayload,
  ManualAdjustRequest,
  ManualCancelPayload,
  ManualCancelRequest,
  ManualSettlePayload,
  ManualSettleRequest,
  ManualStartPayload,
  ManualStartRequest,
  ManualStatePayload,
  ManualStateRequest,
  ManualUpgradeRecordDto,
  TrackerItemKeyDto,
} from '@coc-helper/contracts';
import {
  applyManualLineageComparable,
  buildReconciliationEvidenceFromHistory,
  createManualTrackerVillageState,
  emptyManualTrackerEnvelope,
  encodeVillageStoreBytes,
  inferredLocalQueueKindForItemKeyAndDuration,
  isBaselineReconciled,
  manualBaselineReferenceForHistoryEntry,
  manualTrackerEnvelopeIsMigrated,
  manualTrackerEnvelopeState,
  ManualUpgradeCoreState,
  projectUpgradeActionForItem,
  projectVillageCatalog,
  reconcileManualTracker,
  trackerItemKeyRoot,
  trackerItemKeyStableId,
  upgradeActionCoverageForItem,
  upsertManualTrackerVillageState,
  validateStartAgainstQueueCapacity,
  type CatalogBundle,
  type Clock,
  type ManualReconciliationDecision,
  type ManualTrackerEnvelope,
  type ManualTrackerStore,
  type ManualTrackerVillageState,
  type ManualUpgradeRecord,
  type QueueCapacityGateError,
  type SnapshotHistoryEntry,
  type SnapshotHistoryImportDecision,
  type SnapshotHistoryStore,
  type SnapshotImportTransactionCoordinator,
  type TrackerItemKey,
  type VillageProfile,
} from '@coc-helper/domain';
import { parseUuid, unixSecondsToRefSeconds, type UuidString } from '@coc-helper/wire';

import { AppServiceError, type AppAuthoritativeState } from './app-authoritative-state';
import { HistoryService } from './history-service';

export type ManualCatalogPort = {
  readonly getBundle: () => Promise<CatalogBundle>;
};

export type ManualTrackerServiceOptions = {
  readonly state: AppAuthoritativeState;
  readonly clock: Clock;
  readonly manual: ManualTrackerStore | null;
  readonly history: SnapshotHistoryStore | null;
  readonly catalog: ManualCatalogPort;
  readonly importTransaction?: SnapshotImportTransactionCoordinator | null;
};

export class ManualTrackerService {
  private readonly state: AppAuthoritativeState;
  private readonly clock: Clock;
  private readonly manual: ManualTrackerStore | null;
  private readonly history: SnapshotHistoryStore | null;
  private readonly catalog: ManualCatalogPort;
  private readonly importTransaction: SnapshotImportTransactionCoordinator | null;

  constructor(options: ManualTrackerServiceOptions) {
    this.state = options.state;
    this.clock = options.clock;
    this.manual = options.manual;
    this.history = options.history;
    this.catalog = options.catalog;
    this.importTransaction = options.importTransaction ?? null;
  }

  getState(request: ManualStateRequest): ManualStatePayload {
    const villageId = request.villageId;
    this.requireVillage(villageId);
    const generation = this.state.getGeneration();
    if (this.manual === null) {
      return emptyStatePayload(generation, villageId, 'unavailable', '手动升级存储尚未就绪。');
    }
    let envelope: ManualTrackerEnvelope | null;
    try {
      envelope = this.manual.load();
    } catch (error) {
      return emptyStatePayload(
        generation,
        villageId,
        'unavailable',
        error instanceof Error ? error.message : '手动升级存储不可用。',
      );
    }
    if (envelope === null) {
      return emptyStatePayload(generation, villageId, 'missing', null);
    }
    if (!manualTrackerEnvelopeIsMigrated(envelope)) {
      return emptyStatePayload(
        generation,
        villageId,
        'migrationRequired',
        '手动升级存储尚未完成迁移。',
      );
    }
    const villageID = requireUuid(villageId, '村庄 ID');
    const villageState = manualTrackerEnvelopeState(envelope, villageID);
    if (villageState === undefined) {
      return emptyStatePayload(generation, villageId, 'empty', null);
    }
    return {
      generation,
      villageId,
      status: 'available',
      error: null,
      baselineRevision: villageState.baselineReference?.revision ?? null,
      baselineLineageId: villageState.baselineReference?.lineageID ?? null,
      activeRecordCount: villageState.core.activeRecords.length,
      itemStateCount: villageState.core.itemStates.length,
      lastSettleAtMs: villageState.lastSettleAtMs,
      lastImportAtMs: villageState.lastImportAtMs,
      stateUpdatedAtMs: villageState.stateUpdatedAtMs,
    };
  }

  async start(request: ManualStartRequest): Promise<ManualStartPayload> {
    this.assertWritable();
    assertExpectedGeneration(this.state.getGeneration(), request.expectedGeneration);
    const village = this.requireVillage(request.villageId);
    const villageID = requireUuid(request.villageId, '村庄 ID');
    const nowMs = this.clock.nowMs();
    if (!Number.isFinite(nowMs) || !Number.isFinite(request.startedAtMs)) {
      throw new AppServiceError('validation', '时间无效。');
    }

    const { envelope, villageState } = this.loadEnvelopeState(villageID, nowMs);
    const core = villageState.core as ManualUpgradeCoreState;
    const currentBaseline = this.currentBaseline(villageID);
    if (!isBaselineReconciled({ core, currentBaseline })) {
      throw new AppServiceError('conflict', '当前快照尚未对账，无法启动手动升级。');
    }

    const bundle = await this.loadBundle();
    const itemKey = trackerItemKeyFromDto(request.itemKey);
    const action = this.revalidatedStartAction({
      village,
      core,
      itemKey,
      request,
      bundle,
      nowMs,
      currentBaseline,
    });

    const capacityError = validateStartAgainstQueueCapacity({
      itemKey: action.itemKey,
      durationState: action.durationState,
      core,
      queueCapacityConfigs: villageState.queueCapacityConfigs,
      queueAssignments: villageState.queueAssignments,
      currentBaseline,
      storeAvailable: true,
      nowMs,
    });
    if (capacityError !== null) {
      throw new AppServiceError('conflict', formatCapacityError(capacityError));
    }

    const inferredQueueKind = inferredLocalQueueKindForItemKeyAndDuration(
      action.itemKey,
      action.durationState,
    );
    const previousIds = new Set(core.records.map((record) => record.recordID));

    let nextCore: ManualUpgradeCoreState;
    try {
      nextCore = core.startUpgrade({
        itemKey: action.itemKey,
        fromLevel: action.fromLevel!,
        targetLevel: action.targetLevel!,
        quantity: action.quantity,
        startedAtMs: request.startedAtMs,
        durationState: action.durationState,
        frozenCosts: action.frozenCosts,
        catalogProvenance: action.catalogProvenance!,
        baselineReference: action.baselineReference!,
        queueKind: inferredQueueKind?.rawValue ?? null,
        nowMs,
      });
    } catch (error) {
      throw mapManualCoreError(error);
    }

    const created = nextCore.records.find((record) => !previousIds.has(record.recordID));
    if (created === undefined) {
      throw new AppServiceError('validation', '启动命令未产生记录。');
    }
    this.persistVillageCore(envelope, villageState, nextCore, nowMs, {
      lastSettleAtMs: villageState.lastSettleAtMs,
    });
    this.state.notifyMutation();
    return {
      generation: this.state.getGeneration(),
      record: toRecordDto(created),
    };
  }

  cancel(request: ManualCancelRequest): ManualCancelPayload {
    this.assertWritable();
    assertExpectedGeneration(this.state.getGeneration(), request.expectedGeneration);
    const villageID = requireUuid(request.villageId, '村庄 ID');
    this.requireVillage(request.villageId);
    const nowMs = this.clock.nowMs();
    const { envelope, villageState } = this.loadEnvelopeState(villageID, nowMs);
    const currentBaseline = this.currentBaseline(villageID);
    if (!isBaselineReconciled({ core: villageState.core, currentBaseline })) {
      throw new AppServiceError('conflict', '当前快照尚未对账，无法取消手动升级。');
    }
    const recordID = requireUuid(request.recordId, '记录 ID');
    let nextCore: ManualUpgradeCoreState;
    try {
      nextCore = (villageState.core as ManualUpgradeCoreState).cancelUpgrade(recordID);
    } catch (error) {
      throw mapManualCoreError(error);
    }
    const cancelled = nextCore.records.find((record) => record.recordID === recordID);
    if (cancelled === undefined) {
      throw new AppServiceError('notFound', '升级记录不存在。');
    }
    this.persistVillageCore(envelope, villageState, nextCore, nowMs, {
      lastSettleAtMs: villageState.lastSettleAtMs,
    });
    this.state.notifyMutation();
    return { generation: this.state.getGeneration(), record: toRecordDto(cancelled) };
  }

  adjust(request: ManualAdjustRequest): ManualAdjustPayload {
    this.assertWritable();
    assertExpectedGeneration(this.state.getGeneration(), request.expectedGeneration);
    const villageID = requireUuid(request.villageId, '村庄 ID');
    this.requireVillage(request.villageId);
    const nowMs = this.clock.nowMs();
    if (!Number.isFinite(nowMs) || !Number.isFinite(request.startedAtMs)) {
      throw new AppServiceError('validation', '时间无效。');
    }
    const { envelope, villageState } = this.loadEnvelopeState(villageID, nowMs);
    const currentBaseline = this.currentBaseline(villageID);
    if (!isBaselineReconciled({ core: villageState.core, currentBaseline })) {
      throw new AppServiceError('conflict', '当前快照尚未对账，无法调整手动升级。');
    }
    const recordID = requireUuid(request.recordId, '记录 ID');
    let nextCore: ManualUpgradeCoreState;
    try {
      nextCore = (villageState.core as ManualUpgradeCoreState).adjustStartTime(
        recordID,
        request.startedAtMs,
        nowMs,
      );
    } catch (error) {
      throw mapManualCoreError(error);
    }
    const adjusted = nextCore.records.find((record) => record.recordID === recordID);
    if (adjusted === undefined) {
      throw new AppServiceError('notFound', '升级记录不存在。');
    }
    this.persistVillageCore(envelope, villageState, nextCore, nowMs, {
      lastSettleAtMs: villageState.lastSettleAtMs,
    });
    this.state.notifyMutation();
    return { generation: this.state.getGeneration(), record: toRecordDto(adjusted) };
  }

  settle(request: ManualSettleRequest): ManualSettlePayload {
    this.assertWritable();
    assertExpectedGeneration(this.state.getGeneration(), request.expectedGeneration);
    if (this.manual === null) {
      throw new AppServiceError('unavailable', '手动升级存储尚未就绪。');
    }
    const nowMs = this.clock.nowMs();
    const envelope = this.manual.load();
    if (envelope === null || !manualTrackerEnvelopeIsMigrated(envelope)) {
      return { generation: this.state.getGeneration(), settledCount: 0 };
    }

    const targetIds =
      request.villageId !== undefined && request.villageId !== null
        ? [this.requireVillage(request.villageId).id]
        : this.state.listVillages().map((village) => village.id);

    let settledCount = 0;
    let candidate = envelope;
    let changed = false;
    for (const id of targetIds) {
      const villageID = parseUuid(id);
      if (villageID === undefined) {
        continue;
      }
      const previous = manualTrackerEnvelopeState(candidate, villageID);
      if (previous === undefined) {
        continue;
      }
      const currentBaseline = this.currentBaseline(villageID);
      if (!isBaselineReconciled({ core: previous.core, currentBaseline })) {
        continue;
      }
      const settled = (previous.core as ManualUpgradeCoreState).settleDue(nowMs);
      if (settled.settled.length === 0) {
        continue;
      }
      settledCount += settled.settled.length;
      const nextState = createManualTrackerVillageState({
        villageID,
        core: settled.core,
        stateUpdatedAtMs: nowMs,
        lastSettleAtMs: nowMs,
        lastImportAtMs: previous.lastImportAtMs,
        diagnostics: previous.diagnostics,
        reconciliationHistory: previous.reconciliationHistory,
        queueCapacityConfigs: previous.queueCapacityConfigs,
        queueAssignments: previous.queueAssignments,
      });
      candidate = upsertManualTrackerVillageState(candidate, nextState);
      changed = true;
    }

    if (changed) {
      try {
        this.manual.save(candidate);
      } catch (error) {
        throw new AppServiceError(
          'unavailable',
          error instanceof Error ? error.message : '手动升级存储写入失败。',
        );
      }
      this.state.notifyMutation();
    }
    return { generation: this.state.getGeneration(), settledCount };
  }

  /**
   * 对当前村庄快照与 history 再跑对账；history+manual 经三方事务提交（villages 字节不变）。
   */
  reconcile(input: {
    readonly expectedGeneration: number;
    readonly villageId: string;
    readonly decision: ManualReconciliationDecision;
  }): {
    readonly generation: number;
    readonly attentionCount: number;
    readonly duplicate: boolean;
    readonly lineageComparable: boolean;
  } {
    this.assertWritable();
    assertExpectedGeneration(this.state.getGeneration(), input.expectedGeneration);
    if (this.manual === null || this.history === null || this.importTransaction === null) {
      throw new AppServiceError('unavailable', 'History/Manual 事务尚未就绪。');
    }
    const village = this.requireVillage(input.villageId);
    if (village.accountSnapshot === null) {
      throw new AppServiceError('validation', '目标村庄没有可对账的账号快照。');
    }
    const villageID = requireUuid(input.villageId, '村庄 ID');
    const nowMs = this.clock.nowMs();
    const historyService = new HistoryService(this.history);
    const villages = [...this.state.listVillages()];
    const historyEnvelope = historyService.loadOrMigrate({
      villages,
      nowRefSeconds: unixSecondsToRefSeconds(nowMs / 1000),
    });
    const previousEntry = historyService.activeEntry(historyEnvelope, villageID);
    const decision = historyService.planImport({
      snapshot: village.accountSnapshot,
      villageID,
      currentTag: village.tag,
      hasCurrentSnapshot: true,
      envelope: historyEnvelope,
      appliedAtRefSeconds: unixSecondsToRefSeconds(nowMs / 1000),
    });

    const reconciled = this.buildReconciledManualEnvelope({
      villageID,
      previousEntry,
      decision,
      appliedAtMs: nowMs,
      reconciliationDecision: input.decision,
    });

    try {
      this.importTransaction.commit({
        currentData: encodeVillageStoreBytes(villages),
        envelope: decision.envelope,
        manualEnvelope: reconciled.envelope,
      });
    } catch (error) {
      throw new AppServiceError(
        'unavailable',
        error instanceof Error ? error.message : '对账事务提交失败。',
      );
    }
    this.state.notifyMutation();

    return {
      generation: this.state.getGeneration(),
      attentionCount: reconciled.attentionCount,
      duplicate: reconciled.duplicate,
      lineageComparable: reconciled.lineageComparable,
    };
  }

  /** 供 SnapshotImportService：在已有 history decision 上计算对账后的 manual envelope。 */
  buildReconciledManualEnvelope(input: {
    readonly villageID: UuidString;
    readonly previousEntry: SnapshotHistoryEntry | null;
    readonly decision: SnapshotHistoryImportDecision;
    readonly appliedAtMs: number;
    readonly reconciliationDecision?: ManualReconciliationDecision;
    readonly seedEnvelope?: ManualTrackerEnvelope | null;
  }): {
    readonly envelope: ManualTrackerEnvelope;
    readonly attentionCount: number;
    readonly duplicate: boolean;
    readonly lineageComparable: boolean;
  } {
    if (this.manual === null) {
      throw new AppServiceError('unavailable', '手动升级存储尚未就绪。');
    }
    let envelope =
      input.seedEnvelope ?? this.manual.load() ?? emptyManualTrackerEnvelope([], input.appliedAtMs);
    if (!manualTrackerEnvelopeIsMigrated(envelope)) {
      envelope = emptyManualTrackerEnvelope([], input.appliedAtMs);
    }
    const currentState =
      manualTrackerEnvelopeState(envelope, input.villageID) ??
      createManualTrackerVillageState({
        villageID: input.villageID,
        core: ManualUpgradeCoreState.create(),
        stateUpdatedAtMs: input.appliedAtMs,
      });
    const evidence = applyManualLineageComparable(
      buildReconciliationEvidenceFromHistory({
        villageID: input.villageID,
        previousEntry: input.previousEntry,
        decision: input.decision,
      }),
      currentState.baselineReference,
    );
    try {
      const plan = reconcileManualTracker(evidence, currentState, {
        decision: input.reconciliationDecision ?? 'applyNonConflicting',
        appliedAtMs: input.appliedAtMs,
      });
      return {
        envelope: upsertManualTrackerVillageState(envelope, plan.state),
        attentionCount: plan.preview.items.filter((item) =>
          [
            'manualAhead',
            'staleImport',
            'observedTimerEnded',
            'possibleDuplicate',
            'unknown',
            'conflict',
            'lineageMismatch',
          ].includes(item.classification),
        ).length,
        duplicate: plan.preview.duplicate,
        lineageComparable: plan.preview.lineageComparable,
      };
    } catch (error) {
      throw mapReconcileError(error);
    }
  }

  private revalidatedStartAction(input: {
    readonly village: VillageProfile;
    readonly core: ManualUpgradeCoreState;
    readonly itemKey: TrackerItemKey;
    readonly request: ManualStartRequest;
    readonly bundle: CatalogBundle;
    readonly nowMs: number;
    readonly currentBaseline: ReturnType<ManualTrackerService['currentBaseline']>;
  }) {
    const projection = projectVillageCatalog({
      village: input.village,
      catalog: input.bundle.gameCatalog,
      craftTableCatalog: input.bundle.craftTableCatalog,
      seasonalPhases: input.bundle.seasonalPhaseTable,
      base: input.request.base,
      nowMs: input.nowMs,
      manualUpgradeCore: input.core,
    });
    const item = projection.items.find(
      (entry) =>
        trackerItemKeyStableId(trackerItemKeyRoot(entry.base, entry.section, entry.dataID)) ===
        trackerItemKeyStableId(input.itemKey),
    );
    if (item === undefined) {
      throw new AppServiceError('conflict', '升级动作已过期，请刷新后重试。');
    }
    const coverage = upgradeActionCoverageForItem(item, projection.progressCoverage);
    const action = projectUpgradeActionForItem({
      item,
      catalog: input.bundle.gameCatalog,
      catalogIsUsable: projection.catalogIsUsable,
      manualUpgradeCore: input.core,
      coverage,
      nowMs: input.nowMs,
    });
    if (
      action === null ||
      !action.isStartable ||
      action.fromLevel !== input.request.fromLevel ||
      action.targetLevel !== input.request.targetLevel ||
      action.quantity !== BigInt(input.request.quantity) ||
      action.baselineReference === null ||
      action.catalogProvenance === null
    ) {
      throw new AppServiceError('conflict', '升级动作已过期，请刷新后重试。');
    }
    if (
      input.currentBaseline !== null &&
      (action.baselineReference.revision !== input.currentBaseline.revision ||
        action.baselineReference.lineageID !== input.currentBaseline.lineageID)
    ) {
      throw new AppServiceError('conflict', '升级动作已过期，请刷新后重试。');
    }
    return action;
  }

  private currentBaseline(villageID: UuidString) {
    if (this.history === null) {
      return null;
    }
    const historyService = new HistoryService(this.history);
    const villages = this.state.listVillages();
    const nowMs = this.clock.nowMs();
    let envelope;
    try {
      envelope = historyService.loadOrMigrate({
        villages: [...villages],
        nowRefSeconds: unixSecondsToRefSeconds(nowMs / 1000),
      });
    } catch {
      return null;
    }
    const entry = historyService.activeEntry(envelope, villageID);
    if (entry === null) {
      return null;
    }
    const village = villages.find((item) => item.id === villageID);
    if (village === undefined || village.accountSnapshot === null) {
      return null;
    }
    return manualBaselineReferenceForHistoryEntry(entry, envelope);
  }

  private loadEnvelopeState(
    villageID: UuidString,
    nowMs: number,
  ): { envelope: ManualTrackerEnvelope; villageState: ManualTrackerVillageState } {
    if (this.manual === null) {
      throw new AppServiceError('unavailable', '手动升级存储尚未就绪。');
    }
    let envelope = this.manual.load();
    if (envelope === null) {
      envelope = emptyManualTrackerEnvelope([], nowMs);
    } else if (!manualTrackerEnvelopeIsMigrated(envelope)) {
      throw new AppServiceError('unavailable', '手动升级存储尚未完成迁移。');
    }
    const villageState =
      manualTrackerEnvelopeState(envelope, villageID) ??
      createManualTrackerVillageState({
        villageID,
        core: ManualUpgradeCoreState.create(),
        stateUpdatedAtMs: nowMs,
      });
    return { envelope, villageState };
  }

  private persistVillageCore(
    envelope: ManualTrackerEnvelope,
    previous: ManualTrackerVillageState,
    core: ManualUpgradeCoreState,
    nowMs: number,
    options: { lastSettleAtMs: number | null },
  ): void {
    if (this.manual === null) {
      throw new AppServiceError('unavailable', '手动升级存储尚未就绪。');
    }
    const nextState = createManualTrackerVillageState({
      villageID: previous.villageID,
      core,
      stateUpdatedAtMs: nowMs,
      lastSettleAtMs: options.lastSettleAtMs,
      lastImportAtMs: previous.lastImportAtMs,
      diagnostics: previous.diagnostics,
      reconciliationHistory: previous.reconciliationHistory,
      queueCapacityConfigs: previous.queueCapacityConfigs,
      queueAssignments: previous.queueAssignments,
    });
    const nextEnvelope = upsertManualTrackerVillageState(envelope, nextState);
    try {
      this.manual.save(nextEnvelope);
    } catch (error) {
      throw new AppServiceError(
        'unavailable',
        error instanceof Error ? error.message : '手动升级存储写入失败。',
      );
    }
  }

  private assertWritable(): void {
    if (!this.state.canWrite()) {
      throw new AppServiceError('unavailable', '当前处于恢复或只读状态，无法写入。');
    }
  }

  private requireVillage(villageId: string): VillageProfile {
    const village = this.state.listVillages().find((entry) => entry.id === villageId);
    if (village === undefined) {
      throw new AppServiceError('notFound', '目标村庄不存在。');
    }
    return village;
  }

  private async loadBundle(): Promise<CatalogBundle> {
    try {
      return await this.catalog.getBundle();
    } catch {
      throw new AppServiceError('unavailable', '游戏目录尚未就绪。');
    }
  }
}

function emptyStatePayload(
  generation: number,
  villageId: string,
  status: ManualStatePayload['status'],
  error: string | null,
): ManualStatePayload {
  return {
    generation,
    villageId,
    status,
    error,
    baselineRevision: null,
    baselineLineageId: null,
    activeRecordCount: 0,
    itemStateCount: 0,
    lastSettleAtMs: null,
    lastImportAtMs: null,
    stateUpdatedAtMs: null,
  };
}

function assertExpectedGeneration(current: number, expected: number): void {
  if (current !== expected) {
    throw new AppServiceError('conflict', '状态已过期，请刷新后重试。');
  }
}

function requireUuid(value: string, label: string): UuidString {
  const parsed = parseUuid(value);
  if (parsed === undefined) {
    throw new AppServiceError('validation', `${label} 不是合法 UUID。`);
  }
  return parsed;
}

function trackerItemKeyFromDto(dto: TrackerItemKeyDto): TrackerItemKey {
  return {
    base: dto.base,
    rawSection: dto.rawSection,
    dataID: BigInt(dto.dataID),
    nestedKind: dto.nestedKind as TrackerItemKey['nestedKind'],
    nestedRootIdentity:
      dto.nestedRootIdentity === null
        ? null
        : {
            base: dto.nestedRootIdentity.base,
            rawSection: dto.nestedRootIdentity.rawSection,
            dataID: BigInt(dto.nestedRootIdentity.dataID),
          },
    nestedPath: dto.nestedPath.map((component) => ({
      kind: component.kind as TrackerItemKey['nestedKind'],
      dataID: BigInt(component.dataID),
    })),
  };
}

function toRecordDto(record: ManualUpgradeRecord): ManualUpgradeRecordDto {
  const quantity = Number(record.quantity);
  if (!Number.isSafeInteger(quantity)) {
    throw new AppServiceError('validation', '记录数量无法经 IPC 传递。');
  }
  return {
    recordId: record.recordID,
    status: record.status,
    fromLevel: record.fromLevel,
    targetLevel: record.targetLevel,
    quantity,
    startedAtMs: record.startedAtMs,
    expectedEndAtMs: record.expectedEndAtMs,
  };
}

function mapManualCoreError(error: unknown): AppServiceError {
  if (typeof error === 'object' && error !== null && 'kind' in error) {
    const kind = (error as { kind: string }).kind;
    switch (kind) {
      case 'recordNotFound':
        return new AppServiceError('notFound', '升级记录不存在。');
      case 'recordNotActive':
      case 'cannotCancelCompleted':
        return new AppServiceError('conflict', '升级记录不在进行中。');
      case 'futureStart':
        return new AppServiceError('validation', '开始时间无效。');
      default:
        break;
    }
  }
  return new AppServiceError(
    'validation',
    error instanceof Error ? error.message : '手动升级命令被拒绝。',
  );
}

function mapReconcileError(error: unknown): AppServiceError {
  if (typeof error === 'object' && error !== null && 'kind' in error) {
    const kind = (error as { kind: string }).kind;
    if (kind === 'stalePreview') {
      return new AppServiceError('conflict', '对账预览已过期，请刷新后重试。');
    }
    if (kind === 'villageMismatch') {
      return new AppServiceError('validation', '对账村庄不匹配。');
    }
    if (kind === 'invalidObservation') {
      return new AppServiceError(
        'validation',
        (error as { message?: string }).message ?? '导入观察无效。',
      );
    }
  }
  return new AppServiceError('unavailable', error instanceof Error ? error.message : '对账失败。');
}

function formatCapacityError(error: QueueCapacityGateError): string {
  switch (error.kind) {
    case 'invalidQueueKind':
      return '队列类型无效。';
    case 'occupancyNotAvailable':
      return error.status === 'unreconciled'
        ? '当前快照尚未对账，无法校验队列容量。'
        : '队列占用不可用。';
    case 'queueCapacityFull':
      return `队列已满（${error.activeCount}+${error.confirmedImportedCount}/${error.capacity}）。`;
  }
}
