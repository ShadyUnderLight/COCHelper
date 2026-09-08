/**
 * #276-S5 Recovery typed IPC：status / export / restore / reset / recoverJournal。
 * 写命令必须显式 expectedGeneration（CAS）；仅 recoveryRequired 时可写。
 */

import type { Result } from './result';
import type { VillageStoreStatusDto } from './app-ipc';

export const RECOVERY_STATUS_CHANNEL = 'recovery.status' as const;
export const RECOVERY_EXPORT_CHANNEL = 'recovery.export' as const;
export const RECOVERY_RESTORE_CHANNEL = 'recovery.restore' as const;
export const RECOVERY_RESTORE_SAVED_CHANNEL = 'recovery.restoreSaved' as const;
export const RECOVERY_RESET_CHANNEL = 'recovery.reset' as const;
export const RECOVERY_RECOVER_JOURNAL_CHANNEL = 'recovery.recoverJournal' as const;

export const RECOVERY_IPC_CHANNELS = [
  RECOVERY_STATUS_CHANNEL,
  RECOVERY_EXPORT_CHANNEL,
  RECOVERY_RESTORE_CHANNEL,
  RECOVERY_RESTORE_SAVED_CHANNEL,
  RECOVERY_RESET_CHANNEL,
  RECOVERY_RECOVER_JOURNAL_CHANNEL,
] as const;

export type RecoveryStatusRequest = Record<string, never>;

export type RecoveryStatusPayload = {
  readonly generation: number;
  readonly sessionId: string;
  readonly recoveryRequired: boolean;
  readonly villageStatus: VillageStoreStatusDto;
  readonly villageError: string | null;
  readonly canWrite: boolean;
  readonly hasPendingJournal: boolean;
  readonly canExport: boolean;
  readonly canRestoreSavedCopy: boolean;
  readonly notice: string | null;
};

export type RecoveryStatusResponse = Result<RecoveryStatusPayload>;

export type RecoveryExportRequest = Record<string, never>;

export type RecoveryExportPayload = {
  readonly generation: number;
  readonly sessionId: string;
  /** villages 原始 bytes 的 base64；无可导出数据时为 null。 */
  readonly dataBase64: string | null;
};

export type RecoveryExportResponse = Result<RecoveryExportPayload>;

/** 用合法 villages blob 覆盖当前损坏/只读态；非法输入绝不写入。 */
export type RecoveryRestoreRequest = {
  readonly expectedGeneration: number;
  readonly dataBase64: string;
};

export type RecoveryRestorePayload = {
  readonly generation: number;
  readonly sessionId: string;
  readonly villageStatus: VillageStoreStatusDto;
  readonly canWrite: boolean;
  readonly notice: string;
};

export type RecoveryRestoreResponse = Result<RecoveryRestorePayload>;

export type RecoveryRestoreSavedRequest = {
  readonly expectedGeneration: number;
};

export type RecoveryRestoreSavedResponse = Result<RecoveryRestorePayload>;

export type RecoveryResetRequest = {
  readonly expectedGeneration: number;
};

export type RecoveryResetPayload = {
  readonly generation: number;
  readonly sessionId: string;
  readonly villageStatus: VillageStoreStatusDto;
  readonly canWrite: boolean;
  readonly notice: string;
};

export type RecoveryResetResponse = Result<RecoveryResetPayload>;

export type RecoveryRecoverJournalRequest = {
  readonly expectedGeneration: number;
};

export type RecoveryRecoverJournalPayload = {
  readonly generation: number;
  readonly sessionId: string;
  readonly villageStatus: VillageStoreStatusDto;
  readonly canWrite: boolean;
  readonly notice: string;
};

export type RecoveryRecoverJournalResponse = Result<RecoveryRecoverJournalPayload>;

export type RecoveryIpcBridge = {
  recoveryStatus: (request?: RecoveryStatusRequest) => Promise<RecoveryStatusResponse>;
  recoveryExport: (request?: RecoveryExportRequest) => Promise<RecoveryExportResponse>;
  recoveryRestore: (request: RecoveryRestoreRequest) => Promise<RecoveryRestoreResponse>;
  recoveryRestoreSaved: (
    request: RecoveryRestoreSavedRequest,
  ) => Promise<RecoveryRestoreSavedResponse>;
  recoveryReset: (request: RecoveryResetRequest) => Promise<RecoveryResetResponse>;
  recoveryRecoverJournal: (
    request: RecoveryRecoverJournalRequest,
  ) => Promise<RecoveryRecoverJournalResponse>;
};

export const RECOVERY_IPC_BRIDGE_KEYS = [
  'recoveryStatus',
  'recoveryExport',
  'recoveryRestore',
  'recoveryRestoreSaved',
  'recoveryReset',
  'recoveryRecoverJournal',
] as const satisfies ReadonlyArray<keyof RecoveryIpcBridge>;
