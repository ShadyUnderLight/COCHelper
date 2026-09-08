import type { Result } from './result';
import type { AppIpcBridge } from './app-ipc';
import type { ProjectionIpcBridge } from './projection-ipc';
import type { ManualIpcBridge } from './manual-ipc';

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
} & AppIpcBridge &
  ProjectionIpcBridge &
  ManualIpcBridge;

export const DESKTOP_BRIDGE_KEYS = [
  'health',
  'cancel',
  'snapshot',
  'selectVillage',
  'prepareImport',
  'commitImport',
  'discardImport',
  'upgradeOverview',
  'villageDetail',
  'manualState',
  'manualStart',
  'manualCancel',
  'manualAdjust',
  'manualSettle',
  'manualReconcile',
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

export {
  UPGRADE_OVERVIEW_CHANNEL,
  VILLAGE_DETAIL_CHANNEL,
  PROJECTION_IPC_CHANNELS,
  PROJECTION_IPC_BRIDGE_KEYS,
  type UpgradeOverviewRequest,
  type UpgradeOverviewPayload,
  type UpgradeOverviewResponse,
  type VillageDetailRequest,
  type VillageDetailPayload,
  type VillageDetailResponse,
  type ProjectionIpcBridge,
} from './projection-ipc';

export {
  MANUAL_STATE_CHANNEL,
  MANUAL_START_CHANNEL,
  MANUAL_CANCEL_CHANNEL,
  MANUAL_ADJUST_CHANNEL,
  MANUAL_SETTLE_CHANNEL,
  MANUAL_RECONCILE_CHANNEL,
  MANUAL_IPC_CHANNELS,
  MANUAL_IPC_BRIDGE_KEYS,
  type ManualTrackerStatusDto,
  type ManualReconciliationDecisionDto,
  type ManualStateRequest,
  type ManualStatePayload,
  type ManualStateResponse,
  type ManualStartRequest,
  type ManualStartPayload,
  type ManualStartResponse,
  type ManualCancelRequest,
  type ManualCancelPayload,
  type ManualCancelResponse,
  type ManualAdjustRequest,
  type ManualAdjustPayload,
  type ManualAdjustResponse,
  type ManualSettleRequest,
  type ManualSettlePayload,
  type ManualSettleResponse,
  type ManualReconcileRequest,
  type ManualReconcilePayload,
  type ManualReconcileResponse,
  type ManualUpgradeRecordDto,
  type ManualIpcBridge,
} from './manual-ipc';
