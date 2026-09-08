import {
  APP_HEALTH_CHANNEL,
  APP_SNAPSHOT_CHANNEL,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  MANUAL_ADJUST_CHANNEL,
  MANUAL_CANCEL_CHANNEL,
  MANUAL_RECONCILE_CHANNEL,
  MANUAL_SETTLE_CHANNEL,
  MANUAL_START_CHANNEL,
  MANUAL_STATE_CHANNEL,
  REQUEST_CANCEL_CHANNEL,
  STATE_CHANGED_CHANNEL,
  UPGRADE_OVERVIEW_CHANNEL,
  VILLAGE_DETAIL_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  isAppSnapshotPayload,
  isCancelRequest,
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
  isResult,
  isUpgradeOverviewPayload,
  isVillageDetailPayload,
  isVillageSelectPayload,
  type AppHealthResponse,
  type AppSnapshotResponse,
  type CancelRequest,
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
  type StateChangedListener,
  type StateChangedPayload,
  type UpgradeOverviewResponse,
  type VillageDetailResponse,
  type VillageSelectResponse,
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
