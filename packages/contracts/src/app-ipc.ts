/**
 * E3-02（#276）首批业务 typed IPC：app.snapshot / village.select / import.* / state.changed。
 * 仅 JSON-serializable DTO；command 目标必须显式传入，不得依赖隐式 selected。
 * commit/discard 必须携带 expectedGeneration（CAS），防止 stale UI 提交/丢弃新的 pending。
 */

import type { PendingImportPreviewWire, QuickPreparePreviewWire } from './account-wire';
import type { Result } from './result';

export const APP_SNAPSHOT_CHANNEL = 'app.snapshot' as const;
export const VILLAGE_SELECT_CHANNEL = 'village.select' as const;
export const IMPORT_PREPARE_CHANNEL = 'import.prepare' as const;
export const IMPORT_COMMIT_CHANNEL = 'import.commit' as const;
export const IMPORT_DISCARD_CHANNEL = 'import.discard' as const;
export const IMPORT_QUICK_PREPARE_CHANNEL = 'import.quickPrepare' as const;
export const IMPORT_QUICK_COMMIT_CHANNEL = 'import.quickCommit' as const;
export const IMPORT_QUICK_DISCARD_CHANNEL = 'import.quickDiscard' as const;
export const STATE_CHANGED_CHANNEL = 'state.changed' as const;

export const APP_IPC_CHANNELS = [
  APP_SNAPSHOT_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  IMPORT_QUICK_PREPARE_CHANNEL,
  IMPORT_QUICK_COMMIT_CHANNEL,
  IMPORT_QUICK_DISCARD_CHANNEL,
  STATE_CHANGED_CHANNEL,
] as const;

export type AppAvailability = 'loading' | 'available' | 'recovery' | 'unavailable';

export type VillageStoreStatusDto =
  'missing' | 'available' | 'empty' | 'readOnly' | 'corrupt' | 'unsupported' | 'writeFailed';

export type VillageSummaryDto = {
  readonly id: string;
  readonly name: string;
  readonly tag: string | null;
  readonly hasImportedData: boolean;
};

export type PendingImportSummaryDto = {
  readonly targetKind: 'existing' | 'create';
  readonly targetVillageId?: string;
  readonly targetVillageName?: string;
  readonly snapshotTag: string | null;
};

export type AppSnapshotPayload = {
  /** Main 进程会话身份；进程重启后变化，renderer 应用它丢弃旧 in-flight 响应。 */
  readonly sessionId: string;
  readonly generation: number;
  readonly availability: AppAvailability;
  readonly villageStatus: VillageStoreStatusDto;
  readonly villageError: string | null;
  readonly canWrite: boolean;
  /** 存在活跃或已隔离的事务 journal，可供显式 recoverJournal。 */
  readonly hasPendingJournal: boolean;
  /** 最近一次恢复动作的提示；无动作时为 null。 */
  readonly recoveryNotice: string | null;
  readonly selectedVillageId: string | null;
  readonly villages: readonly VillageSummaryDto[];
  readonly pendingImport: PendingImportSummaryDto | null;
};

export type AppSnapshotRequest = Record<string, never>;
export type AppSnapshotResponse = Result<AppSnapshotPayload>;

export type VillageSelectRequest = {
  readonly villageId: string;
};
export type VillageSelectPayload = {
  readonly generation: number;
  readonly selectedVillageId: string;
};
export type VillageSelectResponse = Result<VillageSelectPayload>;

/**
 * import.prepare：目标必须显式。
 * - villageId 为 string：强制以该村为「当前村」候选（仍允许 tag 唯一匹配优先）；
 * - villageId 为 null/省略：绝不读取权威 selected，只按 tag 匹配或创建。
 */
export type ImportPrepareRequest = {
  readonly text: string;
  readonly villageId?: string | null;
};
export type ImportPreparePayload = {
  readonly generation: number;
  readonly pending: PendingImportSummaryDto;
  /** 完整 preview wire，供确认 UI；权威态 summary 另见 app.snapshot。 */
  readonly preview: PendingImportPreviewWire;
};
export type ImportPrepareResponse = Result<ImportPreparePayload>;

/** 必须等于 prepare 返回的 generation；不匹配则 conflict，不改 pending。 */
export type ImportCommitRequest = {
  readonly expectedGeneration: number;
  /** 导入时 Manual observation 对账决策；省略则 applyNonConflicting。 */
  readonly reconciliationDecision?: 'applyNonConflicting' | 'keepLocal' | 'acceptObserved';
};
export type ImportCommitPayload = {
  readonly generation: number;
  readonly selectedVillageId: string | null;
};
export type ImportCommitResponse = Result<ImportCommitPayload>;

export type ImportDiscardRequest = {
  readonly expectedGeneration: number;
};
export type ImportDiscardPayload = {
  readonly generation: number;
};
export type ImportDiscardResponse = Result<ImportDiscardPayload>;

/**
 * import.quickPrepare：目标固定为详情页当前村庄，文本由 Main 从剪贴板读取。
 * Renderer 只传显式 targetVillageId，不得传文本/完整 preview，避免伪造与日志泄漏。
 * Main 持有待确认 preview，quickCommit 只带 expectedGeneration（CAS）。
 */
export type QuickPrepareRequest = {
  readonly targetVillageId: string;
};
export type QuickPreparePayload = {
  readonly generation: number;
  readonly preview: QuickPreparePreviewWire;
};
export type QuickPrepareResponse = Result<QuickPreparePayload>;

/** 必须等于 quickPrepare 返回的 generation；不匹配则 conflict，不改 quick pending。 */
export type QuickCommitRequest = {
  readonly expectedGeneration: number;
  /** 导入时 Manual observation 对账决策；省略则 applyNonConflicting。 */
  readonly reconciliationDecision?: 'applyNonConflicting' | 'keepLocal' | 'acceptObserved';
};
export type QuickCommitPayload = {
  readonly generation: number;
  readonly selectedVillageId: string | null;
};
export type QuickCommitResponse = Result<QuickCommitPayload>;

export type QuickDiscardRequest = {
  readonly expectedGeneration: number;
};
export type QuickDiscardPayload = {
  readonly generation: number;
};
export type QuickDiscardResponse = Result<QuickDiscardPayload>;

export type StateChangedPayload = AppSnapshotPayload;

export type StateChangedListener = (payload: StateChangedPayload) => void;

export type AppIpcBridge = {
  snapshot: (request?: AppSnapshotRequest) => Promise<AppSnapshotResponse>;
  selectVillage: (request: VillageSelectRequest) => Promise<VillageSelectResponse>;
  prepareImport: (request: ImportPrepareRequest) => Promise<ImportPrepareResponse>;
  commitImport: (request: ImportCommitRequest) => Promise<ImportCommitResponse>;
  discardImport: (request: ImportDiscardRequest) => Promise<ImportDiscardResponse>;
  quickPrepare: (request: QuickPrepareRequest) => Promise<QuickPrepareResponse>;
  quickCommit: (request: QuickCommitRequest) => Promise<QuickCommitResponse>;
  quickDiscard: (request: QuickDiscardRequest) => Promise<QuickDiscardResponse>;
  onStateChanged: (listener: StateChangedListener) => () => void;
};

export const APP_IPC_BRIDGE_KEYS = [
  'snapshot',
  'selectVillage',
  'prepareImport',
  'commitImport',
  'discardImport',
  'quickPrepare',
  'quickCommit',
  'quickDiscard',
  'onStateChanged',
] as const satisfies ReadonlyArray<keyof AppIpcBridge>;
