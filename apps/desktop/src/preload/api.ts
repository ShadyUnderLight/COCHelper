import {
  APP_HEALTH_CHANNEL,
  APP_SNAPSHOT_CHANNEL,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  REQUEST_CANCEL_CHANNEL,
  STATE_CHANGED_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  isAppSnapshotPayload,
  isCancelRequest,
  isImportCommitPayload,
  isImportDiscardPayload,
  isImportPreparePayload,
  isIpcError,
  isResult,
  isVillageSelectPayload,
  type AppHealthResponse,
  type AppSnapshotResponse,
  type CancelRequest,
  type DesktopBridge,
  type ImportCommitResponse,
  type ImportDiscardResponse,
  type ImportPrepareResponse,
  type StateChangedListener,
  type StateChangedPayload,
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
