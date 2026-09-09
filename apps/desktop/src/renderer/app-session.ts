/**
 * Renderer 会话态：只消费 AppSnapshot DTO，处理 sessionId / generation 防 stale。
 * 不复制领域判断；写命令必须携带 expectedGeneration。
 */

import type {
  AppSnapshotPayload,
  DesktopBridge,
  IpcError,
  PendingImportPreviewWire,
  Result,
} from '@coc-helper/contracts';

export type SessionCursor = {
  readonly sessionId: string;
  readonly generation: number;
};

export type ImportPreviewState = {
  readonly preview: PendingImportPreviewWire;
  readonly preparedGeneration: number;
};

export type AppSessionState = {
  readonly status: 'booting' | 'ready' | 'fatal';
  readonly snapshot: AppSnapshotPayload | null;
  readonly preview: ImportPreviewState | null;
  readonly pasteText: string;
  readonly busy: boolean;
  readonly lastError: string | null;
};

export const INITIAL_APP_SESSION: AppSessionState = {
  status: 'booting',
  snapshot: null,
  preview: null,
  pasteText: '',
  busy: false,
  lastError: null,
};

/** 是否接受新的权威快照（state.changed 或 snapshot 响应）。 */
export function shouldAcceptSnapshot(
  current: SessionCursor | null,
  incoming: AppSnapshotPayload,
): boolean {
  if (current === null) {
    return true;
  }
  if (incoming.sessionId !== current.sessionId) {
    return true;
  }
  return incoming.generation >= current.generation;
}

export function cursorFromSnapshot(snapshot: AppSnapshotPayload): SessionCursor {
  return { sessionId: snapshot.sessionId, generation: snapshot.generation };
}

/**
 * 应用已接受的权威快照。
 * pendingImport 清空或 generation 与本地 prepare 不一致时丢弃完整 preview wire。
 */
export function applyAcceptedSnapshot(
  state: AppSessionState,
  snapshot: AppSnapshotPayload,
): AppSessionState {
  return {
    ...state,
    status: 'ready',
    snapshot,
    preview: resolvePreviewAfterSnapshot(state.preview, snapshot),
    lastError: null,
  };
}

function resolvePreviewAfterSnapshot(
  preview: ImportPreviewState | null,
  snapshot: AppSnapshotPayload,
): ImportPreviewState | null {
  if (snapshot.pendingImport === null || preview === null) {
    return null;
  }
  if (preview.preparedGeneration !== snapshot.generation) {
    return null;
  }
  return preview;
}

export function applyFatalError(state: AppSessionState, message: string): AppSessionState {
  return {
    ...state,
    status: 'fatal',
    busy: false,
    lastError: message,
  };
}

export function applyActionError(state: AppSessionState, message: string): AppSessionState {
  return {
    ...state,
    busy: false,
    lastError: message,
  };
}

export function formatIpcError(error: IpcError): string {
  if (error.code === 'conflict') {
    return `状态已过期（conflict）：${error.message}`;
  }
  return error.message;
}

export function isEmptyVillages(snapshot: AppSnapshotPayload): boolean {
  return snapshot.villages.length === 0 || snapshot.villageStatus === 'empty';
}

export function isReadOnly(snapshot: AppSnapshotPayload): boolean {
  return !snapshot.canWrite || snapshot.villageStatus === 'readOnly';
}

export type BridgeSnapshotClient = Pick<
  DesktopBridge,
  | 'snapshot'
  | 'selectVillage'
  | 'prepareImport'
  | 'commitImport'
  | 'discardImport'
  | 'recoveryStatus'
  | 'recoveryReset'
  | 'recoveryRestoreSaved'
  | 'recoveryRecoverJournal'
  | 'onStateChanged'
>;

export async function loadInitialSnapshot(
  bridge: BridgeSnapshotClient,
): Promise<Result<AppSnapshotPayload>> {
  return bridge.snapshot({});
}
