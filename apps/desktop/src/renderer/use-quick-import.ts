import { useCallback, useEffect, useRef, useState } from 'react';

import type {
  AppSnapshotPayload,
  DesktopBridge,
  QuickImportPreviewWire,
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
  readonly preview: QuickImportPreviewWire | null;
  readonly preparedGeneration: number | null;
  readonly lastError: string | null;
};

const IDLE_QUICK_IMPORT: QuickImportState = {
  status: 'idle',
  targetVillageId: null,
  preview: null,
  preparedGeneration: null,
  lastError: null,
};

const STALE_MESSAGE = '导入状态已变化，请重新粘贴并更新。';

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
      stateRef.current.lastError !== STALE_MESSAGE
    ) {
      setState((prev) => (prev.status === 'ready' ? { ...prev, lastError: STALE_MESSAGE } : prev));
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
      inFlightRef.current = true;
      try {
        const requestEpoch = epochRef.current;
        setState({
          status: 'preparing',
          targetVillageId,
          preview: null,
          preparedGeneration: null,
          lastError: null,
        });
        let prepared: Awaited<ReturnType<BridgeQuickImportClient['quickPrepare']>>;
        try {
          prepared = await bridge.quickPrepare({ targetVillageId });
        } catch (error: unknown) {
          if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
            return;
          }
          setState({
            status: 'idle',
            targetVillageId,
            preview: null,
            preparedGeneration: null,
            lastError: error instanceof Error ? error.message : '快捷导入预览失败',
          });
          return;
        }
        if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
          return;
        }
        if (!prepared.ok) {
          setState({
            status: 'idle',
            targetVillageId,
            preview: null,
            preparedGeneration: null,
            lastError: formatIpcError(prepared.error),
          });
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
      current.preparedGeneration === null
    ) {
      return false;
    }
    const cursor = cursorRef.current;
    if (cursor === null || cursor.generation !== current.preparedGeneration) {
      setState((prev) => (prev.status === 'ready' ? { ...prev, lastError: STALE_MESSAGE } : prev));
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
        setState({
          status: 'idle',
          targetVillageId: current.targetVillageId,
          preview: null,
          preparedGeneration: null,
          lastError: formatIpcError(committed.error),
        });
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
    const requestEpoch = epochRef.current;
    if (current.status === 'ready' && current.preparedGeneration !== null) {
      const expectedGeneration = current.preparedGeneration;
      setState(IDLE_QUICK_IMPORT);
      try {
        await bridge.quickDiscard({ expectedGeneration });
      } catch {
        // 取消是本地清理语义：Main 侧过期由 CAS 兜底，不回写错误。
      }
      if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
        return;
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
    if (inFlightRef.current) {
      return;
    }
    const current = stateRef.current;
    if (current.status === 'committing' || current.status === 'preparing') {
      return;
    }
    if (current.status === 'ready' && current.preparedGeneration !== null) {
      const expectedGeneration = current.preparedGeneration;
      setState(IDLE_QUICK_IMPORT);
      void (async () => {
        try {
          await bridge.quickDiscard({ expectedGeneration });
        } catch {
          // 同 cancel：本地清理优先，CAS 兜底。
        }
      })();
      return;
    }
    if (current.status !== 'idle' || current.lastError !== null) {
      setState(IDLE_QUICK_IMPORT);
    }
  }, [bridge]);

  useEffect(() => {
    return () => {
      epochRef.current += 1;
    };
  }, [bridge]);

  return { state, open, confirm, cancel, retry, close };
}
