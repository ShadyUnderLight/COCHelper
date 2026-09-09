import { useCallback, useEffect, useRef, useState } from 'react';

import type {
  AppSnapshotPayload,
  DesktopBridge,
  TrackerBaseDto,
  VillageDetailPayload,
} from '@coc-helper/contracts';

import { formatIpcError, isCurrentEpoch } from './app-session';
import { shouldAcceptOverview, cursorFromOverview, type OverviewCursor } from './overview-session';
import {
  INITIAL_VILLAGE_DETAIL_STATE,
  applyVillageDetailError,
  applyVillageDetailSuccess,
  idleVillageDetailState,
  type VillageDetailState,
} from './village-detail-session';

export type BridgeVillageClient = Pick<DesktopBridge, 'villageDetail' | 'onStateChanged'>;

export type VillageDetailApi = {
  readonly state: VillageDetailState;
  readonly refresh: () => Promise<void>;
};

export function useVillageDetail(
  bridge: BridgeVillageClient,
  snapshot: AppSnapshotPayload | null,
  base: TrackerBaseDto,
): VillageDetailApi {
  const [state, setState] = useState<VillageDetailState>(INITIAL_VILLAGE_DETAIL_STATE);
  const [refreshSeq, setRefreshSeq] = useState(0);
  const epochRef = useRef(0);
  const cursorRef = useRef<OverviewCursor | null>(null);
  const sessionCursorRef = useRef<string | null>(null);
  const requestSeqRef = useRef(0);
  /** 当前 payload 所属 subject（session:village:base）；subject 切换即丢 last-good，防跨村泄漏。 */
  const payloadKeyRef = useRef<string | null>(null);
  const maxRequestedRef = useRef(-1);
  const lastKeyRef = useRef<string | null>(null);
  const lastSeqRef = useRef(0);
  const sessionRef = useRef<string | null>(null);
  sessionRef.current = snapshot?.sessionId ?? null;
  const subjectRef = useRef<string | null>(null);
  const requestVillagePreview = snapshot?.selectedVillageId ?? null;
  subjectRef.current =
    snapshot === null || requestVillagePreview === null
      ? null
      : `${snapshot.sessionId}:${requestVillagePreview}:${base}`;

  useEffect(() => {
    if (snapshot === null) {
      return;
    }
    const requestEpoch = epochRef.current;
    const requestSession = snapshot.sessionId;
    const requestVillage = snapshot.selectedVillageId;
    if (sessionCursorRef.current !== requestSession) {
      sessionCursorRef.current = requestSession;
      cursorRef.current = null;
      payloadKeyRef.current = null;
      maxRequestedRef.current = -1;
      lastKeyRef.current = null;
      setState(requestVillage === null ? idleVillageDetailState() : INITIAL_VILLAGE_DETAIL_STATE);
    }
    if (requestVillage === null) {
      setState((prev) => (prev.status === 'idle' ? prev : idleVillageDetailState()));
      return;
    }
    const forced = refreshSeq !== lastSeqRef.current;
    const key = `${requestSession}:${snapshot.generation}:${requestVillage}:${base}:${refreshSeq}`;
    if (key === lastKeyRef.current) {
      return;
    }
    const completed = cursorRef.current;
    if (!forced && !shouldAcceptOverview(completed, requestSession, snapshot.generation)) {
      lastKeyRef.current = key;
      return;
    }
    if (!forced && snapshot.generation < maxRequestedRef.current) {
      lastKeyRef.current = key;
      return;
    }
    lastKeyRef.current = key;
    lastSeqRef.current = refreshSeq;
    maxRequestedRef.current = Math.max(maxRequestedRef.current, snapshot.generation);
    requestSeqRef.current += 1;
    const requestSeq = requestSeqRef.current;
    const subjectKey = `${requestSession}:${requestVillage}:${base}`;
    if (payloadKeyRef.current !== null && payloadKeyRef.current !== subjectKey) {
      // subject 已切换（村庄/base）：旧 last-good 不得再展示，回到 loading 等新数据。
      payloadKeyRef.current = null;
      setState(INITIAL_VILLAGE_DETAIL_STATE);
    }
    void (async () => {
      let result: Awaited<ReturnType<BridgeVillageClient['villageDetail']>>;
      try {
        result = await bridge.villageDetail({ villageId: requestVillage, base });
      } catch (error: unknown) {
        if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
          return;
        }
        if (sessionRef.current !== requestSession) {
          return;
        }
        if (requestSeq !== requestSeqRef.current) {
          return;
        }
        setState((prevState) =>
          applyVillageDetailError(
            prevState,
            error instanceof Error ? error.message : '村庄详情查询失败',
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
        setState((prevState) => applyVillageDetailError(prevState, formatIpcError(result.error)));
        return;
      }
      const payload: VillageDetailPayload = result.value;
      if (subjectKey !== subjectRef.current) {
        // subject 已切换：迟到成功不得把旧村数据写进新上下文。
        return;
      }
      const known = cursorRef.current;
      if (!shouldAcceptOverview(known, requestSession, payload.generation)) {
        return;
      }
      cursorRef.current = cursorFromOverview(requestSession, payload);
      payloadKeyRef.current = subjectKey;
      setState(applyVillageDetailSuccess(payload));
    })();
  }, [bridge, snapshot, base, refreshSeq]);

  useEffect(() => {
    return () => {
      epochRef.current += 1;
    };
  }, [bridge]);

  const refresh = useCallback(async () => {
    setRefreshSeq((n) => n + 1);
  }, []);

  return { state, refresh };
}
