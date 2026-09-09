import { useCallback, useEffect, useRef, useState } from 'react';

import type {
  AppSnapshotPayload,
  DesktopBridge,
  UpgradeOverviewPayload,
} from '@coc-helper/contracts';

import { formatIpcError, isCurrentEpoch } from './app-session';
import {
  INITIAL_OVERVIEW_STATE,
  applyOverviewError,
  applyOverviewSuccess,
  cursorFromOverview,
  shouldAcceptOverview,
  type OverviewCursor,
  type OverviewState,
} from './overview-session';

export type BridgeOverviewClient = Pick<DesktopBridge, 'upgradeOverview' | 'onStateChanged'>;

export type OverviewApi = {
  readonly state: OverviewState;
  readonly selectedId: string | null;
  readonly select: (id: string) => void;
  readonly refresh: () => Promise<void>;
};

export function useUpgradeOverview(
  bridge: BridgeOverviewClient,
  snapshot: AppSnapshotPayload | null,
): OverviewApi {
  const [state, setState] = useState<OverviewState>(INITIAL_OVERVIEW_STATE);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [refreshSeq, setRefreshSeq] = useState(0);
  const epochRef = useRef(0);
  const cursorRef = useRef<OverviewCursor | null>(null);
  /** authoritative session：不绑定 cursor（cursor 只有成功后才建立）。 */
  const sessionCursorRef = useRef<string | null>(null);
  /** monotonic 请求序号：error 提交时确认仍是当前有效请求（error 无 payload generation 可比）。 */
  const requestSeqRef = useRef(0);
  const maxRequestedRef = useRef(-1);
  const lastKeyRef = useRef<string | null>(null);
  const lastSeqRef = useRef(0);
  const sessionRef = useRef<string | null>(null);
  sessionRef.current = snapshot?.sessionId ?? null;

  useEffect(() => {
    if (snapshot === null) {
      return;
    }
    const requestEpoch = epochRef.current;
    const requestSession = snapshot.sessionId;
    if (sessionCursorRef.current !== requestSession) {
      sessionCursorRef.current = requestSession;
      cursorRef.current = null;
      maxRequestedRef.current = -1;
      lastKeyRef.current = null;
      setState(INITIAL_OVERVIEW_STATE);
      setSelectedId(null);
    }
    const forced = refreshSeq !== lastSeqRef.current;
    const key = `${requestSession}:${snapshot.generation}:${refreshSeq}`;
    if (key === lastKeyRef.current) {
      return;
    }
    const completed = cursorRef.current;
    if (!forced && !shouldAcceptOverview(completed, requestSession, snapshot.generation)) {
      lastKeyRef.current = key;
      return;
    }
    if (!forced && snapshot.generation < maxRequestedRef.current) {
      // 父级漏过的迟到旧事件：已有更新的请求在途，不重复拉。
      lastKeyRef.current = key;
      return;
    }
    lastKeyRef.current = key;
    lastSeqRef.current = refreshSeq;
    maxRequestedRef.current = Math.max(maxRequestedRef.current, snapshot.generation);
    requestSeqRef.current += 1;
    const requestSeq = requestSeqRef.current;
    void (async () => {
      let result: Awaited<ReturnType<BridgeOverviewClient['upgradeOverview']>>;
      try {
        result = await bridge.upgradeOverview({});
      } catch (error: unknown) {
        if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
          return;
        }
        if (sessionRef.current !== requestSession) {
          return;
        }
        if (requestSeq !== requestSeqRef.current) {
          // 同 session 内已有更新的请求：迟到失败不得污染新状态。
          return;
        }
        setState((prevState) =>
          applyOverviewError(
            prevState,
            error instanceof Error ? error.message : '升级总览查询失败',
          ),
        );
        return;
      }
      if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
        return;
      }
      if (sessionRef.current !== requestSession) {
        return;
      }
      if (!result.ok) {
        if (requestSeq !== requestSeqRef.current) {
          return;
        }
        setState((prevState) => applyOverviewError(prevState, formatIpcError(result.error)));
        return;
      }
      const payload: UpgradeOverviewPayload = result.value;
      const known = cursorRef.current;
      if (!shouldAcceptOverview(known, requestSession, payload.generation)) {
        return;
      }
      cursorRef.current = cursorFromOverview(requestSession, payload);
      setState(applyOverviewSuccess(payload));
    })();
  }, [bridge, snapshot, refreshSeq]);

  useEffect(() => {
    return () => {
      epochRef.current += 1;
    };
  }, [bridge]);

  const select = useCallback((id: string) => {
    setSelectedId(id);
  }, []);

  const refresh = useCallback(async () => {
    setRefreshSeq((n) => n + 1);
  }, []);

  return { state, selectedId, select, refresh };
}
