import type { Result } from './result';
import type { AppIpcBridge } from './app-ipc';
import type { ProjectionIpcBridge } from './projection-ipc';
import type { ManualIpcBridge } from './manual-ipc';
import type { OfficialIpcBridge } from './official-ipc';
import type { RecoveryIpcBridge } from './recovery-ipc';

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
  ManualIpcBridge &
  OfficialIpcBridge &
  RecoveryIpcBridge;

export const DESKTOP_BRIDGE_KEYS = [
  'health',
  'cancel',
  'snapshot',
  'selectVillage',
  'prepareImport',
  'commitImport',
  'discardImport',
  'quickPrepare',
  'quickCommit',
  'quickDiscard',
  'upgradeOverview',
  'villageDetail',
  'manualState',
  'manualStart',
  'manualCancel',
  'manualAdjust',
  'manualSettle',
  'manualReconcile',
  'playerState',
  'clanState',
  'clanWarState',
  'warLogState',
  'capitalRaidState',
  'apiRefresh',
  'warLogLoadMore',
  'capitalRaidLoadMore',
  'recoveryStatus',
  'recoveryExport',
  'recoveryRestore',
  'recoveryRestoreSaved',
  'recoveryReset',
  'recoveryRecoverJournal',
  'onOperationProgress',
  'onStateChanged',
] as const satisfies ReadonlyArray<keyof DesktopBridge>;

export {
  APP_SNAPSHOT_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  IMPORT_QUICK_PREPARE_CHANNEL,
  IMPORT_QUICK_COMMIT_CHANNEL,
  IMPORT_QUICK_DISCARD_CHANNEL,
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
  type QuickPrepareRequest,
  type QuickPreparePayload,
  type QuickPrepareResponse,
  type QuickCommitRequest,
  type QuickCommitPayload,
  type QuickCommitResponse,
  type QuickDiscardRequest,
  type QuickDiscardPayload,
  type QuickDiscardResponse,
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

export {
  PLAYER_STATE_CHANNEL,
  CLAN_STATE_CHANNEL,
  CLAN_WAR_STATE_CHANNEL,
  WAR_LOG_STATE_CHANNEL,
  CAPITAL_RAID_STATE_CHANNEL,
  API_REFRESH_CHANNEL,
  WAR_LOG_LOAD_MORE_CHANNEL,
  CAPITAL_RAID_LOAD_MORE_CHANNEL,
  OPERATION_PROGRESS_CHANNEL,
  OFFICIAL_IPC_CHANNELS,
  OFFICIAL_IPC_BRIDGE_KEYS,
  OFFICIAL_ENDPOINT_KINDS,
  type OfficialEndpointKind,
  type OfficialPlayerSnapshotWire,
  type OfficialEndpointStateDto,
  type PlayerStateRequest,
  type PlayerStatePayload,
  type PlayerStateResponse,
  type ClanStateRequest,
  type ClanStatePayload,
  type ClanStateResponse,
  type ClanWarStateRequest,
  type ClanWarStatePayload,
  type ClanWarStateResponse,
  type WarLogStateRequest,
  type WarLogStatePayload,
  type WarLogStateResponse,
  type CapitalRaidStateRequest,
  type CapitalRaidStatePayload,
  type CapitalRaidStateResponse,
  type ApiRefreshRequest,
  type ApiRefreshEndpointResultDto,
  type ApiRefreshPayload,
  type ApiRefreshResponse,
  type WarLogLoadMoreRequest,
  type WarLogLoadMorePayload,
  type WarLogLoadMoreResponse,
  type CapitalRaidLoadMoreRequest,
  type CapitalRaidLoadMorePayload,
  type CapitalRaidLoadMoreResponse,
  type OperationProgressPhase,
  type OperationProgressPayload,
  type OperationProgressListener,
  type OfficialIpcBridge,
} from './official-ipc';

export {
  RECOVERY_STATUS_CHANNEL,
  RECOVERY_EXPORT_CHANNEL,
  RECOVERY_RESTORE_CHANNEL,
  RECOVERY_RESTORE_SAVED_CHANNEL,
  RECOVERY_RESET_CHANNEL,
  RECOVERY_RECOVER_JOURNAL_CHANNEL,
  RECOVERY_IPC_CHANNELS,
  RECOVERY_IPC_BRIDGE_KEYS,
  type RecoveryStatusRequest,
  type RecoveryStatusPayload,
  type RecoveryStatusResponse,
  type RecoveryExportRequest,
  type RecoveryExportPayload,
  type RecoveryExportResponse,
  type RecoveryRestoreRequest,
  type RecoveryRestorePayload,
  type RecoveryRestoreResponse,
  type RecoveryRestoreSavedRequest,
  type RecoveryRestoreSavedResponse,
  type RecoveryResetRequest,
  type RecoveryResetPayload,
  type RecoveryResetResponse,
  type RecoveryRecoverJournalRequest,
  type RecoveryRecoverJournalPayload,
  type RecoveryRecoverJournalResponse,
  type RecoveryIpcBridge,
} from './recovery-ipc';
