import { useCallback, useEffect, useRef, useState } from 'react';

import type {
  AppSnapshotPayload,
  DesktopBridge,
  IpcError,
  QuickPreparePreviewWire,
} from '@coc-helper/contracts';

import { formatIpcError, isCurrentEpoch, type SessionCursor } from './app-session';

export type BridgeQuickImportClient = Pick<
  DesktopBridge,
  'quickPrepare' | 'quickCommit' | 'quickDiscard' | 'snapshot' | 'onStateChanged'
>;

export type QuickImportStatus = 'idle' | 'preparing' | 'ready' | 'committing';

export type QuickImportState = {
  readonly status: QuickImportStatus;
  /** 打开 Sheet 时固定的目标村庄；不跟随全局 selected 漂移。 */
  readonly targetVillageId: string | null;
  readonly preview: QuickPreparePreviewWire | null;
  readonly preparedGeneration: number | null;
  /** 世代错位（preview 已过期）：确认被禁用，只能重新预览或取消。 */
  readonly stale: boolean;
  readonly lastError: string | null;
};

const IDLE_QUICK_IMPORT: QuickImportState = {
  status: 'idle',
  targetVillageId: null,
  preview: null,
  preparedGeneration: null,
  stale: false,
  lastError: null,
};

const STALE_MESSAGE = '导入状态已变化，请重新粘贴并更新。';

/**
 * Ownership 不变量：只要 Main 仍持有 live pending，本地必须保留对应 token
 *（preview + preparedGeneration），或者在放弃前显式使 Main pending 失效。
 * - Main 明确说死（conflict/validation）→ token 无用，切 idle 保留 target 供重试。
 * - 其他失败（unavailable/notFound/桥异常）→ Main 仍可能持有 pending，恢复 ready
 *   并保留原 token，绝不静默丢弃。
 */
function isDeadPending(code: IpcError['code']): boolean {
  return code === 'conflict' || code === 'validation';
}

export type QuickImportApi = {
  readonly state: QuickImportState;
  readonly open: (targetVillageId: string) => Promise<void>;
  readonly confirm: () => Promise<boolean>;
  readonly cancel: () => Promise<void>;
  readonly retry: () => Promise<void>;
  readonly close: () => void;
};

export function useQuickImport(
  bridge: BridgeQuickImportClient,
  snapshot: AppSnapshotPayload | null,
  options: { readonly onCommitted?: () => void } = {},
): QuickImportApi {
  const [state, setState] = useState<QuickImportState>(IDLE_QUICK_IMPORT);
  const cursorRef = useRef<SessionCursor | null>(null);
  const epochRef = useRef(0);
  /** 同步在途标志：setState 到重渲染之间有空隙，防重提交不能只看 state。 */
  const inFlightRef = useRef(false);
  const stateRef = useRef(state);
  stateRef.current = state;
  const snapshotRef = useRef(snapshot);
  snapshotRef.current = snapshot;
  const onCommittedRef = useRef(options.onCommitted);
  onCommittedRef.current = options.onCommitted;

  // snapshot 推进：同 session 取最大 generation；跨 session 全重置。
  // stale 判定只看 cursor（已见最大 generation），不直接看 snapshot prop——
  // prepare 返回与 state.changed 广播到达之间 prop 天然滞后，直接比对会误判。
  useEffect(() => {
    if (snapshot === null) {
      return;
    }
    const cursor = cursorRef.current;
    if (cursor !== null && snapshot.sessionId !== cursor.sessionId) {
      cursorRef.current = null;
      if (stateRef.current.status !== 'idle' || stateRef.current.lastError !== null) {
        setState(IDLE_QUICK_IMPORT);
      }
      return;
    }
    if (cursor === null || snapshot.generation > cursor.generation) {
      cursorRef.current = { sessionId: snapshot.sessionId, generation: snapshot.generation };
    }
    const known = cursorRef.current;
    if (
      known !== null &&
      stateRef.current.status === 'ready' &&
      stateRef.current.preparedGeneration !== null &&
      known.generation !== stateRef.current.preparedGeneration &&
      !stateRef.current.stale
    ) {
      setState((prev) =>
        prev.status === 'ready' ? { ...prev, stale: true, lastError: STALE_MESSAGE } : prev,
      );
    }
  }, [snapshot]);

  const open = useCallback(
    async (targetVillageId: string) => {
      if (inFlightRef.current) {
        return;
      }
      const current = stateRef.current;
      if (current.status === 'preparing' || current.status === 'committing') {
        return;
      }
      // ready 时重开：先留住旧 ownership，失败则恢复（Main 旧 pending 仍 live）。
      const previous =
        current.status === 'ready' && current.preparedGeneration !== null ? current : null;
      inFlightRef.current = true;
      try {
        const requestEpoch = epochRef.current;
        const sessionAtOpen = snapshotRef.current?.sessionId;
        setState({
          status: 'preparing',
          targetVillageId,
          preview: null,
          preparedGeneration: null,
          stale: false,
          lastError: null,
        });
        let prepared: Awaited<ReturnType<BridgeQuickImportClient['quickPrepare']>>;
        try {
          prepared = await bridge.quickPrepare({ targetVillageId });
        } catch (error: unknown) {
          if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
            return;
          }
          if (snapshotRef.current?.sessionId !== sessionAtOpen) {
            return;
          }
          restoreAfterOpenFailure(
            setState,
            previous,
            targetVillageId,
            error instanceof Error ? error.message : '快捷导入预览失败',
          );
          return;
        }
        if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
          return;
        }
        if (!prepared.ok) {
          if (snapshotRef.current?.sessionId !== sessionAtOpen) {
            return;
          }
          restoreAfterOpenFailure(
            setState,
            previous,
            targetVillageId,
            formatIpcError(prepared.error),
          );
          return;
        }
        const generation = prepared.value.generation;
        const cursor = cursorRef.current;
        const sessionId = snapshotRef.current?.sessionId;
        if (sessionId !== undefined && (cursor === null || generation >= cursor.generation)) {
          cursorRef.current = { sessionId, generation };
        }
        // 与权威快照对齐：prepare 已 bump generation，广播可能仍在路上，显式拉一次。
        try {
          const snap = await bridge.snapshot({});
          if (isCurrentEpoch(requestEpoch, epochRef.current) && snap.ok) {
            const incoming = snap.value;
            const known = cursorRef.current;
            if (known === null || incoming.sessionId !== known.sessionId) {
              cursorRef.current = {
                sessionId: incoming.sessionId,
                generation: incoming.generation,
              };
            } else if (incoming.generation > known.generation) {
              cursorRef.current = {
                sessionId: incoming.sessionId,
                generation: incoming.generation,
              };
            }
          }
        } catch {
          // 快照拉取失败不阻塞预览：Main 已持有待确认态，CAS 会兜底。
        }
        if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
          return;
        }
        setState({
          status: 'ready',
          targetVillageId,
          preview: prepared.value.preview,
          preparedGeneration: generation,
          stale: false,
          lastError: null,
        });
      } finally {
        inFlightRef.current = false;
      }
    },
    [bridge],
  );

  const confirm = useCallback(async (): Promise<boolean> => {
    if (inFlightRef.current) {
      return false;
    }
    const current = stateRef.current;
    if (current.status === 'committing') {
      return false;
    }
    if (
      current.status !== 'ready' ||
      current.preview === null ||
      current.preparedGeneration === null ||
      current.stale
    ) {
      return false;
    }
    const cursor = cursorRef.current;
    if (cursor === null || cursor.generation !== current.preparedGeneration) {
      setState((prev) =>
        prev.status === 'ready' ? { ...prev, stale: true, lastError: STALE_MESSAGE } : prev,
      );
      return false;
    }
    const expectedGeneration = current.preparedGeneration;
    const requestEpoch = epochRef.current;
    inFlightRef.current = true;
    try {
      setState((prev) => (prev.status === 'ready' ? { ...prev, status: 'committing' } : prev));
      let committed: Awaited<ReturnType<BridgeQuickImportClient['quickCommit']>>;
      try {
        committed = await bridge.quickCommit({ expectedGeneration });
      } catch (error: unknown) {
        if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
          return false;
        }
        // 桥异常：Main pending 状态未知，保守保留 ownership。
        setState((prev) =>
          prev.status === 'committing'
            ? {
                ...prev,
                status: 'ready',
                lastError: error instanceof Error ? error.message : '快捷导入确认失败',
              }
            : prev,
        );
        return false;
      }
      if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
        return false;
      }
      if (!committed.ok) {
        if (isDeadPending(committed.error.code)) {
          // Main 已无该 pending：token 作废，切 idle 保留 target 供重试。
          setState({
            status: 'idle',
            targetVillageId: current.targetVillageId,
            preview: null,
            preparedGeneration: null,
            stale: false,
            lastError: formatIpcError(committed.error),
          });
        } else {
          // Main 仍持有 pending（事务失败/目标缺失等）：恢复 ready 保住 token。
          setState({
            status: 'ready',
            targetVillageId: current.targetVillageId,
            preview: current.preview,
            preparedGeneration: current.preparedGeneration,
            stale: false,
            lastError: formatIpcError(committed.error),
          });
        }
        return false;
      }
      cursorRef.current =
        cursorRef.current === null
          ? cursorRef.current
          : { sessionId: cursorRef.current.sessionId, generation: committed.value.generation };
      setState(IDLE_QUICK_IMPORT);
      onCommittedRef.current?.();
      return true;
    } finally {
      inFlightRef.current = false;
    }
  }, [bridge]);

  const cancel = useCallback(async (): Promise<void> => {
    if (inFlightRef.current) {
      return;
    }
    const current = stateRef.current;
    if (current.status === 'committing' || current.status === 'preparing') {
      return;
    }
    if (current.status === 'ready' && current.preparedGeneration !== null) {
      const expectedGeneration = current.preparedGeneration;
      const requestEpoch = epochRef.current;
      inFlightRef.current = true;
      try {
        let discarded: Awaited<ReturnType<BridgeQuickImportClient['quickDiscard']>>;
        try {
          discarded = await bridge.quickDiscard({ expectedGeneration });
        } catch {
          if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
            return;
          }
          // 丢弃请求没送达：Main 仍可能持有 live pending，保住 ownership。
          setState((prev) =>
            prev.status === 'ready' && prev.preparedGeneration === expectedGeneration
              ? { ...prev, lastError: '取消失败，请重试。' }
              : prev,
          );
          return;
        }
        if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
          return;
        }
        if (!discarded.ok && !isDeadPending(discarded.error.code)) {
          // Main 仍持有 pending：保住 token，让用户重试取消。
          setState((prev) =>
            prev.status === 'ready' && prev.preparedGeneration === expectedGeneration
              ? { ...prev, lastError: formatIpcError(discarded.error) }
              : prev,
          );
          return;
        }
        setState(IDLE_QUICK_IMPORT);
      } finally {
        inFlightRef.current = false;
      }
      return;
    }
    if (current.lastError !== null || current.targetVillageId !== null) {
      setState(IDLE_QUICK_IMPORT);
    }
  }, [bridge]);

  const retry = useCallback(async (): Promise<void> => {
    if (inFlightRef.current) {
      return;
    }
    const target = stateRef.current.targetVillageId;
    if (target === null) {
      return;
    }
    await open(target);
  }, [open]);

  const close = useCallback((): void => {
    void cancel();
  }, [cancel]);

  useEffect(() => {
    return () => {
      epochRef.current += 1;
    };
  }, [bridge]);

  return { state, open, confirm, cancel, retry, close };
}

/** open 失败：有旧 live token 则恢复 ready（保住 ownership），否则 idle 报错。 */
function restoreAfterOpenFailure(
  setState: (updater: QuickImportState) => void,
  previous: QuickImportState | null,
  targetVillageId: string,
  message: string,
): void {
  if (previous !== null) {
    setState({ ...previous, lastError: message });
    return;
  }
  setState({
    status: 'idle',
    targetVillageId,
    preview: null,
    preparedGeneration: null,
    stale: false,
    lastError: message,
  });
}
