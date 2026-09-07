/**
 * E3-02（#276）首批业务 typed IPC：app.snapshot / village.select / import.* / state.changed。
 * 仅 JSON-serializable DTO；command 目标必须显式传入，不得依赖隐式 selected。
 */

import type { PendingImportPreviewWire } from './account-wire';
import type { Result } from './result';

export const APP_SNAPSHOT_CHANNEL = 'app.snapshot' as const;
export const VILLAGE_SELECT_CHANNEL = 'village.select' as const;
export const IMPORT_PREPARE_CHANNEL = 'import.prepare' as const;
export const IMPORT_COMMIT_CHANNEL = 'import.commit' as const;
export const IMPORT_DISCARD_CHANNEL = 'import.discard' as const;
export const STATE_CHANGED_CHANNEL = 'state.changed' as const;

export const APP_IPC_CHANNELS = [
  APP_SNAPSHOT_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  STATE_CHANGED_CHANNEL,
] as const;

export type AppAvailability = 'loading' | 'available' | 'recovery' | 'unavailable';

export type VillageStoreStatusDto =
  | 'missing'
  | 'available'
  | 'empty'
  | 'readOnly'
  | 'corrupt'
  | 'unsupported'
  | 'writeFailed';

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
  readonly generation: number;
  readonly availability: AppAvailability;
  readonly villageStatus: VillageStoreStatusDto;
  readonly villageError: string | null;
  readonly canWrite: boolean;
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

export type ImportCommitRequest = Record<string, never>;
export type ImportCommitPayload = {
  readonly generation: number;
  readonly selectedVillageId: string | null;
};
export type ImportCommitResponse = Result<ImportCommitPayload>;

export type ImportDiscardRequest = Record<string, never>;
export type ImportDiscardPayload = {
  readonly generation: number;
};
export type ImportDiscardResponse = Result<ImportDiscardPayload>;

export type StateChangedPayload = AppSnapshotPayload;

export type StateChangedListener = (payload: StateChangedPayload) => void;

export type AppIpcBridge = {
  snapshot: (request?: AppSnapshotRequest) => Promise<AppSnapshotResponse>;
  selectVillage: (request: VillageSelectRequest) => Promise<VillageSelectResponse>;
  prepareImport: (request: ImportPrepareRequest) => Promise<ImportPrepareResponse>;
  commitImport: (request?: ImportCommitRequest) => Promise<ImportCommitResponse>;
  discardImport: (request?: ImportDiscardRequest) => Promise<ImportDiscardResponse>;
  onStateChanged: (listener: StateChangedListener) => () => void;
};

export const APP_IPC_BRIDGE_KEYS = [
  'snapshot',
  'selectVillage',
  'prepareImport',
  'commitImport',
  'discardImport',
  'onStateChanged',
] as const satisfies ReadonlyArray<keyof AppIpcBridge>;
