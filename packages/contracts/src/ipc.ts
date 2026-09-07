import type { Result } from './result';
import type { AppIpcBridge } from './app-ipc';

/** IPC 通道名。preload 只允许调用这里列出的通道。 */
export const APP_HEALTH_CHANNEL = 'app.health' as const;
export const REQUEST_CANCEL_CHANNEL = 'request.cancel' as const;

export const REQUEST_ID_MAX_LENGTH = 128;

export type RequestId = string & { readonly __brand: 'RequestId' };

export type AppHealthRequest = Record<string, never>;

export type AppHealthPayload = {
  readonly app: 'coc-helper';
};

export type AppHealthResponse = Result<AppHealthPayload>;

export type CancelRequest = {
  readonly requestId: RequestId;
};

export function isRequestId(value: unknown): value is RequestId {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    value.length <= REQUEST_ID_MAX_LENGTH &&
    /^[\x21-\x7e]+$/.test(value)
  );
}

export function isCancelRequest(value: unknown): value is CancelRequest {
  if (
    typeof value !== 'object' ||
    value === null ||
    Object.getPrototypeOf(value) !== Object.prototype
  ) {
    return false;
  }
  const record = value as Record<string, unknown>;
  return Object.keys(record).length === 1 && isRequestId(record.requestId);
}

/** renderer 经 contextBridge 可见的 API。不得包含 ipcRenderer。 */
export type DesktopBridge = {
  health: (request?: AppHealthRequest) => Promise<AppHealthResponse>;
  cancel: (request: CancelRequest) => void;
} & AppIpcBridge;

export const DESKTOP_BRIDGE_KEYS = [
  'health',
  'cancel',
  'snapshot',
  'selectVillage',
  'prepareImport',
  'commitImport',
  'discardImport',
  'onStateChanged',
] as const satisfies ReadonlyArray<keyof DesktopBridge>;

export {
  APP_SNAPSHOT_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  STATE_CHANGED_CHANNEL,
  APP_IPC_CHANNELS,
  APP_IPC_BRIDGE_KEYS,
  type AppAvailability,
  type VillageStoreStatusDto,
  type VillageSummaryDto,
  type PendingImportSummaryDto,
  type AppSnapshotPayload,
  type AppSnapshotRequest,
  type AppSnapshotResponse,
  type VillageSelectRequest,
  type VillageSelectPayload,
  type VillageSelectResponse,
  type ImportPrepareRequest,
  type ImportPreparePayload,
  type ImportPrepareResponse,
  type ImportCommitRequest,
  type ImportCommitPayload,
  type ImportCommitResponse,
  type ImportDiscardRequest,
  type ImportDiscardPayload,
  type ImportDiscardResponse,
  type StateChangedPayload,
  type StateChangedListener,
  type AppIpcBridge,
} from './app-ipc';
