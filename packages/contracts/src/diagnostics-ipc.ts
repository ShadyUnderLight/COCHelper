import type { AppAvailability, VillageStoreStatusDto } from './app-ipc';
import type { ManualTrackerStatusDto } from './manual-ipc';
import type { Result } from './result';

export const DIAGNOSTICS_SNAPSHOT_CHANNEL = 'diagnostics.snapshot' as const;

export const TOKEN_STATUS_CHANNEL = 'token.status' as const;
export const TOKEN_SAVE_CHANNEL = 'token.save' as const;
export const TOKEN_CLEAR_CHANNEL = 'token.clear' as const;
export const TOKEN_MAX_LENGTH = 2048;

export const DIAGNOSTICS_IPC_CHANNELS = [DIAGNOSTICS_SNAPSHOT_CHANNEL] as const;
export const TOKEN_IPC_CHANNELS = [
  TOKEN_STATUS_CHANNEL,
  TOKEN_SAVE_CHANNEL,
  TOKEN_CLEAR_CHANNEL,
] as const;

export const DIAGNOSTICS_IPC_BRIDGE_KEYS = ['diagnosticsSnapshot'] as const;
export const TOKEN_IPC_BRIDGE_KEYS = ['tokenStatus', 'tokenSave', 'tokenClear'] as const;

export type TokenStorageStatus = 'available' | 'unavailable' | 'decryptFailed';

export type TokenStatusPayload = {
  readonly configured: boolean;
  readonly storage: TokenStorageStatus;
  /** 只允许安全、简短的用户可见文案；不得包含 token 或底层异常。 */
  readonly message: string | null;
};

export type TokenStatusRequest = Record<string, never>;
export type TokenStatusResponse = Result<TokenStatusPayload>;

export type TokenSaveRequest = {
  /** 一次性输入；Main 不回显，也不得写入普通日志或诊断 DTO。 */
  readonly token: string;
};
export type TokenSaveResponse = Result<TokenStatusPayload>;

export type TokenClearRequest = Record<string, never>;
export type TokenClearResponse = Result<TokenStatusPayload>;

export type DiagnosticsSnapshotRequest = Record<string, never>;

export type DiagnosticsAppDto = {
  readonly name: string;
  readonly version: string;
};

export type DiagnosticsRuntimeDto = {
  readonly electron: string;
  readonly node: string;
  readonly chrome: string;
  readonly platform: string;
  readonly arch: string;
};

export type DiagnosticsApplicationDto = {
  readonly availability: AppAvailability;
  readonly villageStatus: VillageStoreStatusDto;
  readonly generation: number;
  readonly selectedVillageId: string | null;
  readonly selectedVillageName: string | null;
  readonly canWrite: boolean;
  readonly hasPendingJournal: boolean;
};

export type DiagnosticsCatalogDto = {
  readonly status: 'available' | 'unavailable';
  readonly version: string | null;
};

/**
 * 只描述 Official API 的安全边界，不暴露 URL、header、原始响应或错误堆栈。
 * 当前所有请求均由 Main 发出，Renderer 只拿到已映射的 DTO。
 */
export type DiagnosticsOfficialDto = {
  readonly endpointAccess: 'mainOnly';
  readonly authorization: 'mainOnly';
  readonly credentialStorage: TokenStorageStatus;
  readonly rawResponseExposure: 'notExposed';
};

export type DiagnosticsManualDto = {
  readonly status: ManualTrackerStatusDto;
};

export type DiagnosticsSnapshotPayload = {
  readonly sessionId: string;
  readonly app: DiagnosticsAppDto;
  readonly runtime: DiagnosticsRuntimeDto;
  readonly application: DiagnosticsApplicationDto;
  readonly catalog: DiagnosticsCatalogDto;
  readonly official: DiagnosticsOfficialDto;
  readonly manual: DiagnosticsManualDto;
  readonly token: TokenStatusPayload;
};

export type DiagnosticsSnapshotResponse = Result<DiagnosticsSnapshotPayload>;

export type DiagnosticsIpcBridge = {
  readonly diagnosticsSnapshot: (
    request: DiagnosticsSnapshotRequest,
  ) => Promise<DiagnosticsSnapshotResponse>;
};

export type TokenIpcBridge = {
  readonly tokenStatus: (request: TokenStatusRequest) => Promise<TokenStatusResponse>;
  readonly tokenSave: (request: TokenSaveRequest) => Promise<TokenSaveResponse>;
  readonly tokenClear: (request: TokenClearRequest) => Promise<TokenClearResponse>;
};
