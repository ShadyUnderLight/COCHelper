import {
  API_REFRESH_CHANNEL,
  APP_HEALTH_CHANNEL,
  APP_SNAPSHOT_CHANNEL,
  CAPITAL_RAID_LOAD_MORE_CHANNEL,
  CAPITAL_RAID_STATE_CHANNEL,
  CLAN_STATE_CHANNEL,
  CLAN_WAR_STATE_CHANNEL,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  MANUAL_ADJUST_CHANNEL,
  MANUAL_CANCEL_CHANNEL,
  MANUAL_RECONCILE_CHANNEL,
  MANUAL_SETTLE_CHANNEL,
  MANUAL_START_CHANNEL,
  MANUAL_STATE_CHANNEL,
  OPERATION_PROGRESS_CHANNEL,
  PLAYER_STATE_CHANNEL,
  RECOVERY_EXPORT_CHANNEL,
  RECOVERY_RECOVER_JOURNAL_CHANNEL,
  RECOVERY_RESET_CHANNEL,
  RECOVERY_RESTORE_CHANNEL,
  RECOVERY_RESTORE_SAVED_CHANNEL,
  RECOVERY_STATUS_CHANNEL,
  REQUEST_CANCEL_CHANNEL,
  STATE_CHANGED_CHANNEL,
  UPGRADE_OVERVIEW_CHANNEL,
  VILLAGE_DETAIL_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  WAR_LOG_LOAD_MORE_CHANNEL,
  WAR_LOG_STATE_CHANNEL,
  isApiRefreshPayload,
  isAppSnapshotPayload,
  isCancelRequest,
  isCapitalRaidLoadMorePayload,
  isCapitalRaidStatePayload,
  isClanStatePayload,
  isClanWarStatePayload,
  isImportCommitPayload,
  isImportDiscardPayload,
  isImportPreparePayload,
  isIpcError,
  isManualAdjustPayload,
  isManualCancelPayload,
  isManualReconcilePayload,
  isManualSettlePayload,
  isManualStartPayload,
  isManualStatePayload,
  isOperationProgressPayload,
  isPlayerStatePayload,
  isRecoveryExportPayload,
  isRecoveryRecoverJournalPayload,
  isRecoveryResetPayload,
  isRecoveryRestorePayload,
  isRecoveryStatusPayload,
  isResult,
  isUpgradeOverviewPayload,
  isVillageDetailPayload,
  isVillageSelectPayload,
  isWarLogLoadMorePayload,
  isWarLogStatePayload,
  type ApiRefreshResponse,
  type AppHealthResponse,
  type AppSnapshotResponse,
  type CancelRequest,
  type CapitalRaidLoadMoreResponse,
  type CapitalRaidStateResponse,
  type ClanStateResponse,
  type ClanWarStateResponse,
  type DesktopBridge,
  type ImportCommitResponse,
  type ImportDiscardResponse,
  type ImportPrepareResponse,
  type ManualAdjustResponse,
  type ManualCancelResponse,
  type ManualReconcileResponse,
  type ManualSettleResponse,
  type ManualStartResponse,
  type ManualStateResponse,
  type OperationProgressListener,
  type PlayerStateResponse,
  type RecoveryExportResponse,
  type RecoveryRecoverJournalResponse,
  type RecoveryResetResponse,
  type RecoveryRestoreResponse,
  type RecoveryRestoreSavedResponse,
  type RecoveryStatusResponse,
  type StateChangedListener,
  type StateChangedPayload,
  type UpgradeOverviewResponse,
  type VillageDetailResponse,
  type VillageSelectResponse,
  type WarLogLoadMoreResponse,
  type WarLogStateResponse,
} from '@coc-helper/contracts';

export function isAppHealthResponse(value: unknown): value is AppHealthResponse {
  return isResult(
    value,
    (payload): payload is { app: 'coc-helper' } =>
      isPlainObject(payload) && Object.keys(payload).length === 1 && payload.app === 'coc-helper',
    isIpcError,
  );
}

export function isAppSnapshotResponse(value: unknown): value is AppSnapshotResponse {
  return isResult(value, isAppSnapshotPayload, isIpcError);
}

export function isVillageSelectResponse(value: unknown): value is VillageSelectResponse {
  return isResult(value, isVillageSelectPayload, isIpcError);
}

export function isImportPrepareResponse(value: unknown): value is ImportPrepareResponse {
  return isResult(value, isImportPreparePayload, isIpcError);
}

export function isImportCommitResponse(value: unknown): value is ImportCommitResponse {
  return isResult(value, isImportCommitPayload, isIpcError);
}

export function isImportDiscardResponse(value: unknown): value is ImportDiscardResponse {
  return isResult(value, isImportDiscardPayload, isIpcError);
}

export function isUpgradeOverviewResponse(value: unknown): value is UpgradeOverviewResponse {
  return isResult(value, isUpgradeOverviewPayload, isIpcError);
}

export function isVillageDetailResponse(value: unknown): value is VillageDetailResponse {
  return isResult(value, isVillageDetailPayload, isIpcError);
}

export function isManualStateResponse(value: unknown): value is ManualStateResponse {
  return isResult(value, isManualStatePayload, isIpcError);
}

export function isManualStartResponse(value: unknown): value is ManualStartResponse {
  return isResult(value, isManualStartPayload, isIpcError);
}

export function isManualCancelResponse(value: unknown): value is ManualCancelResponse {
  return isResult(value, isManualCancelPayload, isIpcError);
}

export function isManualAdjustResponse(value: unknown): value is ManualAdjustResponse {
  return isResult(value, isManualAdjustPayload, isIpcError);
}

export function isManualSettleResponse(value: unknown): value is ManualSettleResponse {
  return isResult(value, isManualSettlePayload, isIpcError);
}

export function isManualReconcileResponse(value: unknown): value is ManualReconcileResponse {
  return isResult(value, isManualReconcilePayload, isIpcError);
}

export function isPlayerStateResponse(value: unknown): value is PlayerStateResponse {
  return isResult(value, isPlayerStatePayload, isIpcError);
}

export function isClanStateResponse(value: unknown): value is ClanStateResponse {
  return isResult(value, isClanStatePayload, isIpcError);
}

export function isClanWarStateResponse(value: unknown): value is ClanWarStateResponse {
  return isResult(value, isClanWarStatePayload, isIpcError);
}

export function isWarLogStateResponse(value: unknown): value is WarLogStateResponse {
  return isResult(value, isWarLogStatePayload, isIpcError);
}

export function isCapitalRaidStateResponse(value: unknown): value is CapitalRaidStateResponse {
  return isResult(value, isCapitalRaidStatePayload, isIpcError);
}

export function isApiRefreshResponse(value: unknown): value is ApiRefreshResponse {
  return isResult(value, isApiRefreshPayload, isIpcError);
}

export function isWarLogLoadMoreResponse(value: unknown): value is WarLogLoadMoreResponse {
  return isResult(value, isWarLogLoadMorePayload, isIpcError);
}

export function isCapitalRaidLoadMoreResponse(
  value: unknown,
): value is CapitalRaidLoadMoreResponse {
  return isResult(value, isCapitalRaidLoadMorePayload, isIpcError);
}

export function isRecoveryStatusResponse(value: unknown): value is RecoveryStatusResponse {
  return isResult(value, isRecoveryStatusPayload, isIpcError);
}

export function isRecoveryExportResponse(value: unknown): value is RecoveryExportResponse {
  return isResult(value, isRecoveryExportPayload, isIpcError);
}

export function isRecoveryRestoreResponse(value: unknown): value is RecoveryRestoreResponse {
  return isResult(value, isRecoveryRestorePayload, isIpcError);
}

export function isRecoveryRestoreSavedResponse(
  value: unknown,
): value is RecoveryRestoreSavedResponse {
  return isResult(value, isRecoveryRestorePayload, isIpcError);
}

export function isRecoveryResetResponse(value: unknown): value is RecoveryResetResponse {
  return isResult(value, isRecoveryResetPayload, isIpcError);
}

export function isRecoveryRecoverJournalResponse(
  value: unknown,
): value is RecoveryRecoverJournalResponse {
  return isResult(value, isRecoveryRecoverJournalPayload, isIpcError);
}

export function isStateChangedPayload(value: unknown): value is StateChangedPayload {
  return isAppSnapshotPayload(value);
}

type Invoke = (channel: string, request?: unknown) => Promise<unknown>;
type Send = (channel: string, request: unknown) => void;
type On = (channel: string, listener: (payload: unknown) => void) => () => void;

export function createDesktopBridge(invoke: Invoke, send: Send, on: On): DesktopBridge {
  return {
    health: async (request) => {
      const result = await invoke(APP_HEALTH_CHANNEL, request);
      if (!isAppHealthResponse(result)) {
        throw new Error('app.health 返回值不合法');
      }
      return result;
    },
    cancel: (request) => {
      if (!isCancelRequest(request)) {
        throw new Error('request.cancel 参数不合法');
      }
      send(REQUEST_CANCEL_CHANNEL, request);
    },
    snapshot: async (request) => {
      const result = await invoke(APP_SNAPSHOT_CHANNEL, request);
      if (!isAppSnapshotResponse(result)) {
        throw new Error('app.snapshot 返回值不合法');
      }
      return result;
    },
    selectVillage: async (request) => {
      const result = await invoke(VILLAGE_SELECT_CHANNEL, request);
      if (!isVillageSelectResponse(result)) {
        throw new Error('village.select 返回值不合法');
      }
      return result;
    },
    prepareImport: async (request) => {
      const result = await invoke(IMPORT_PREPARE_CHANNEL, request);
      if (!isImportPrepareResponse(result)) {
        throw new Error('import.prepare 返回值不合法');
      }
      return result;
    },
    commitImport: async (request) => {
      const result = await invoke(IMPORT_COMMIT_CHANNEL, request);
      if (!isImportCommitResponse(result)) {
        throw new Error('import.commit 返回值不合法');
      }
      return result;
    },
    discardImport: async (request) => {
      const result = await invoke(IMPORT_DISCARD_CHANNEL, request);
      if (!isImportDiscardResponse(result)) {
        throw new Error('import.discard 返回值不合法');
      }
      return result;
    },
    upgradeOverview: async (request) => {
      const result = await invoke(UPGRADE_OVERVIEW_CHANNEL, request);
      if (!isUpgradeOverviewResponse(result)) {
        throw new Error('upgrade.overview 返回值不合法');
      }
      return result;
    },
    villageDetail: async (request) => {
      const result = await invoke(VILLAGE_DETAIL_CHANNEL, request);
      if (!isVillageDetailResponse(result)) {
        throw new Error('village.detail 返回值不合法');
      }
      return result;
    },
    manualState: async (request) => {
      const result = await invoke(MANUAL_STATE_CHANNEL, request);
      if (!isManualStateResponse(result)) {
        throw new Error('manual.state 返回值不合法');
      }
      return result;
    },
    manualStart: async (request) => {
      const result = await invoke(MANUAL_START_CHANNEL, request);
      if (!isManualStartResponse(result)) {
        throw new Error('manual.start 返回值不合法');
      }
      return result;
    },
    manualCancel: async (request) => {
      const result = await invoke(MANUAL_CANCEL_CHANNEL, request);
      if (!isManualCancelResponse(result)) {
        throw new Error('manual.cancel 返回值不合法');
      }
      return result;
    },
    manualAdjust: async (request) => {
      const result = await invoke(MANUAL_ADJUST_CHANNEL, request);
      if (!isManualAdjustResponse(result)) {
        throw new Error('manual.adjust 返回值不合法');
      }
      return result;
    },
    manualSettle: async (request) => {
      const result = await invoke(MANUAL_SETTLE_CHANNEL, request);
      if (!isManualSettleResponse(result)) {
        throw new Error('manual.settle 返回值不合法');
      }
      return result;
    },
    manualReconcile: async (request) => {
      const result = await invoke(MANUAL_RECONCILE_CHANNEL, request);
      if (!isManualReconcileResponse(result)) {
        throw new Error('manual.reconcile 返回值不合法');
      }
      return result;
    },
    playerState: async (request) => {
      const result = await invoke(PLAYER_STATE_CHANNEL, request);
      if (!isPlayerStateResponse(result)) {
        throw new Error('player.state 返回值不合法');
      }
      return result;
    },
    clanState: async (request) => {
      const result = await invoke(CLAN_STATE_CHANNEL, request);
      if (!isClanStateResponse(result)) {
        throw new Error('clan.state 返回值不合法');
      }
      return result;
    },
    clanWarState: async (request) => {
      const result = await invoke(CLAN_WAR_STATE_CHANNEL, request);
      if (!isClanWarStateResponse(result)) {
        throw new Error('clanWar.state 返回值不合法');
      }
      return result;
    },
    warLogState: async (request) => {
      const result = await invoke(WAR_LOG_STATE_CHANNEL, request);
      if (!isWarLogStateResponse(result)) {
        throw new Error('warLog.state 返回值不合法');
      }
      return result;
    },
    capitalRaidState: async (request) => {
      const result = await invoke(CAPITAL_RAID_STATE_CHANNEL, request);
      if (!isCapitalRaidStateResponse(result)) {
        throw new Error('capitalRaid.state 返回值不合法');
      }
      return result;
    },
    apiRefresh: async (request) => {
      const result = await invoke(API_REFRESH_CHANNEL, request);
      if (!isApiRefreshResponse(result)) {
        throw new Error('api.refresh 返回值不合法');
      }
      return result;
    },
    warLogLoadMore: async (request) => {
      const result = await invoke(WAR_LOG_LOAD_MORE_CHANNEL, request);
      if (!isWarLogLoadMoreResponse(result)) {
        throw new Error('warLog.loadMore 返回值不合法');
      }
      return result;
    },
    capitalRaidLoadMore: async (request) => {
      const result = await invoke(CAPITAL_RAID_LOAD_MORE_CHANNEL, request);
      if (!isCapitalRaidLoadMoreResponse(result)) {
        throw new Error('capitalRaid.loadMore 返回值不合法');
      }
      return result;
    },
    recoveryStatus: async (request) => {
      const result = await invoke(RECOVERY_STATUS_CHANNEL, request);
      if (!isRecoveryStatusResponse(result)) {
        throw new Error('recovery.status 返回值不合法');
      }
      return result;
    },
    recoveryExport: async (request) => {
      const result = await invoke(RECOVERY_EXPORT_CHANNEL, request);
      if (!isRecoveryExportResponse(result)) {
        throw new Error('recovery.export 返回值不合法');
      }
      return result;
    },
    recoveryRestore: async (request) => {
      const result = await invoke(RECOVERY_RESTORE_CHANNEL, request);
      if (!isRecoveryRestoreResponse(result)) {
        throw new Error('recovery.restore 返回值不合法');
      }
      return result;
    },
    recoveryRestoreSaved: async (request) => {
      const result = await invoke(RECOVERY_RESTORE_SAVED_CHANNEL, request);
      if (!isRecoveryRestoreSavedResponse(result)) {
        throw new Error('recovery.restoreSaved 返回值不合法');
      }
      return result;
    },
    recoveryReset: async (request) => {
      const result = await invoke(RECOVERY_RESET_CHANNEL, request);
      if (!isRecoveryResetResponse(result)) {
        throw new Error('recovery.reset 返回值不合法');
      }
      return result;
    },
    recoveryRecoverJournal: async (request) => {
      const result = await invoke(RECOVERY_RECOVER_JOURNAL_CHANNEL, request);
      if (!isRecoveryRecoverJournalResponse(result)) {
        throw new Error('recovery.recoverJournal 返回值不合法');
      }
      return result;
    },
    onOperationProgress: (listener: OperationProgressListener) => {
      return on(OPERATION_PROGRESS_CHANNEL, (payload) => {
        if (!isOperationProgressPayload(payload)) {
          return;
        }
        listener(payload);
      });
    },
    onStateChanged: (listener: StateChangedListener) => {
      return on(STATE_CHANGED_CHANNEL, (payload) => {
        if (!isStateChangedPayload(payload)) {
          return;
        }
        listener(payload);
      });
    },
  };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === 'object' &&
    value !== null &&
    !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype
  );
}

export type { CancelRequest };
export { isAppSnapshotPayload };
