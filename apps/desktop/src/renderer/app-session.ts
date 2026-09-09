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

/**
 * 是否接受权威快照。
 * - 尚无 cursor：接受（启动首帧）
 * - 同 session：仅接受 generation >= 当前
 * - 不同 sessionId：拒绝（无法排序；旧 session 的延迟响应不得覆盖新 session）
 *
 * 跨 session 切换只应由可信入口（例如 renderer 重挂载后的首帧）在 cursor === null 时建立。
 */
export function shouldAcceptSnapshot(
  current: SessionCursor | null,
  incoming: AppSnapshotPayload,
): boolean {
  if (current === null) {
    return true;
  }
  if (incoming.sessionId !== current.sessionId) {
    return false;
  }
  return incoming.generation >= current.generation;
}

/** 丢弃与当前 epoch 不匹配的 in-flight 拉取响应。 */
export function isCurrentEpoch(requestEpoch: number, currentEpoch: number): boolean {
  return requestEpoch === currentEpoch;
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

export type PrepareFollowUp =
  | {
      readonly kind: 'applied';
      readonly snapshot: AppSnapshotPayload;
      readonly preview: ImportPreviewState;
    }
  | { readonly kind: 'stale'; readonly reason: string };

/**
 * prepare 之后的快照 follow-up：只有 preview.preparedGeneration === 权威 generation
 * 时才保留 preview；snapshot 失败或被 stale guard 拒绝时清空 preview，绝不挂到更新的 UI state。
 */
export function mergePrepareFollowUp(
  current: SessionCursor | null,
  nextPreview: ImportPreviewState,
  snap: Result<AppSnapshotPayload>,
): PrepareFollowUp {
  if (!snap.ok) {
    return { kind: 'stale', reason: '刷新快照失败，请重新解析预览。' };
  }
  if (!shouldAcceptSnapshot(current, snap.value)) {
    return { kind: 'stale', reason: '状态已变化，请重新解析预览。' };
  }
  if (
    snap.value.pendingImport === null ||
    nextPreview.preparedGeneration !== snap.value.generation
  ) {
    return { kind: 'stale', reason: '预览已过期，请重新解析预览。' };
  }
  return {
    kind: 'applied',
    snapshot: snap.value,
    preview: nextPreview,
  };
}

export type CommitGenerationResolution =
  | { readonly ok: true; readonly expectedGeneration: number }
  | { readonly ok: false; readonly reason: string };

/** commit/discard 必须使用与屏幕 preview 绑定的 preparedGeneration。 */
export function resolveCommitGeneration(
  preview: ImportPreviewState | null,
  cursor: SessionCursor | null,
): CommitGenerationResolution {
  if (preview === null || cursor === null) {
    return { ok: false, reason: '没有可确认的导入预览。' };
  }
  if (preview.preparedGeneration !== cursor.generation) {
    return { ok: false, reason: '状态已变化，请重新解析预览。' };
  }
  return { ok: true, expectedGeneration: preview.preparedGeneration };
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
