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
    const requestVillage = snapshot.selectedVillageId;
    if (sessionCursorRef.current !== requestSession) {
      sessionCursorRef.current = requestSession;
      cursorRef.current = null;
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
      const known = cursorRef.current;
      if (!shouldAcceptOverview(known, requestSession, payload.generation)) {
        return;
      }
      cursorRef.current = cursorFromOverview(requestSession, payload);
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
