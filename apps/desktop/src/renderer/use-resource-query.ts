import { useCallback, useEffect, useRef, useState } from 'react';

import type { AppSnapshotPayload, Result } from '@coc-helper/contracts';

import { formatIpcError } from './app-session';
import {
  LOADING_RESOURCE,
  fencedResourceState,
  resourceFailure,
  resourceLoading,
  resourceSuccess,
  type ResourceState,
} from './resource-state';
import {
  beginFetch,
  shouldAcceptGeneration,
  shouldApplyResponse,
  subjectChanged,
  type FenceCursor,
} from './request-fence';

export type ResourceQueryOptions<T> = {
  readonly snapshot: AppSnapshotPayload | null;
  /** null 表示当前无有效 subject，不发起请求。 */
  readonly subjectKey: string | null;
  readonly fetch: () => Promise<Result<T>>;
  readonly extractGeneration: (value: T) => number;
  readonly fetchErrorMessage?: string;
  readonly onSessionReset?: () => void;
};

export type ResourceQueryApi<T> = {
  readonly state: ResourceState<T>;
  readonly refresh: () => Promise<void>;
};

/**
 * 通用只读资源查询 hook：统一 session/generation/subject/requestSeq/epoch 围栏。
 * 写操作状态机（如 quick import）不应使用此 hook。
 */
export function useResourceQuery<T>(options: ResourceQueryOptions<T>): ResourceQueryApi<T> {
  const { snapshot, subjectKey, fetch, extractGeneration, fetchErrorMessage, onSessionReset } =
    options;
  const [state, setState] = useState<ResourceState<T>>(LOADING_RESOURCE);
  const [refreshSeq, setRefreshSeq] = useState(0);

  const epochRef = useRef(0);
  const requestSeqRef = useRef(0);
  const maxRequestedRef = useRef(-1);
  const lastKeyRef = useRef<string | null>(null);
  const lastSeqRef = useRef(0);
  const sessionCursorRef = useRef<string | null>(null);
  const completedCursorRef = useRef<FenceCursor | null>(null);
  const payloadSubjectRef = useRef<string | null>(null);
  const stateSubjectRef = useRef<string | null>(null);

  const sessionRef = useRef<string | null>(null);
  const subjectRef = useRef<string | null>(null);
  sessionRef.current = snapshot?.sessionId ?? null;
  subjectRef.current = subjectKey;

  const fetchRef = useRef(fetch);
  fetchRef.current = fetch;
  const extractGenerationRef = useRef(extractGeneration);
  extractGenerationRef.current = extractGeneration;
  const onSessionResetRef = useRef(onSessionReset);
  onSessionResetRef.current = onSessionReset;
  const prevSubjectKeyRef = useRef<string | null>(subjectKey);
  const refreshWaitersRef = useRef(new Map<number, { readonly resolve: () => void }>());

  const settleRefreshWaiter = useCallback((seq: number): void => {
    const waiter = refreshWaitersRef.current.get(seq);
    if (waiter === undefined) {
      return;
    }
    refreshWaitersRef.current.delete(seq);
    waiter.resolve();
  }, []);

  const settleAllRefreshWaiters = useCallback((): void => {
    for (const seq of refreshWaitersRef.current.keys()) {
      settleRefreshWaiter(seq);
    }
  }, [settleRefreshWaiter]);

  useEffect(() => {
    const prevSubjectKey = prevSubjectKeyRef.current;
    prevSubjectKeyRef.current = subjectKey;

    if (snapshot === null || subjectKey === null) {
      // subject 离开有效态：作废在途请求，避免同 key 在重新进入时被 beginFetch skip。
      if (prevSubjectKey !== null && subjectKey === null) {
        requestSeqRef.current += 1;
        lastKeyRef.current = null;
        lastSeqRef.current = refreshSeq;
        // 保留 payloadSubjectRef：它标记 last-good 归属，供 A→null→B 时 subjectChanged 清数据；
        // A→null→A 仍可依赖 last-good 与 beginFetch 重新拉取。
        // stateSubjectRef 不在这里改：无 subject 时 fencedResourceState 直接返回 idle。
      }
      // 无法继续 fetch 时，把 pending refresh 当作正常取消 resolve，避免 Promise 泄漏。
      settleAllRefreshWaiters();
      return;
    }
    const requestEpoch = epochRef.current;
    const requestSession = snapshot.sessionId;

    if (sessionCursorRef.current !== requestSession) {
      sessionCursorRef.current = requestSession;
      completedCursorRef.current = null;
      payloadSubjectRef.current = null;
      stateSubjectRef.current = null;
      maxRequestedRef.current = -1;
      lastKeyRef.current = null;
      setState(LOADING_RESOURCE);
      onSessionResetRef.current?.();
    }

    const forced = refreshSeq !== lastSeqRef.current;
    const planned = beginFetch(
      {
        sessionId: requestSession,
        generation: snapshot.generation,
        subjectKey,
        refreshSeq,
        forced,
        completedCursor: completedCursorRef.current,
        maxRequestedGeneration: maxRequestedRef.current,
        lastFetchKey: lastKeyRef.current,
        currentRequestSeq: requestSeqRef.current,
      },
      shouldAcceptGeneration,
    );

    if (planned.kind === 'skip') {
      lastKeyRef.current = planned.fetchKey;
      if (forced) {
        settleRefreshWaiter(refreshSeq);
      }
      return;
    }

    if (subjectChanged(payloadSubjectRef.current, subjectKey)) {
      payloadSubjectRef.current = null;
      stateSubjectRef.current = subjectKey;
      setState(LOADING_RESOURCE);
    }

    lastKeyRef.current = planned.fetchKey;
    lastSeqRef.current = refreshSeq;
    maxRequestedRef.current = planned.nextMaxRequestedGeneration;
    requestSeqRef.current = planned.requestSeq;
    const requestSeq = planned.requestSeq;

    stateSubjectRef.current = subjectKey;
    setState((prev) => resourceLoading(prev));

    void (async () => {
      let result: Result<T>;
      try {
        result = await fetchRef.current();
      } catch (error: unknown) {
        const message =
          error instanceof Error ? error.message : (fetchErrorMessage ?? '资源查询失败');
        if (
          !shouldApplyResponse({
            requestEpoch,
            currentEpoch: epochRef.current,
            requestSessionId: requestSession,
            currentSessionId: sessionRef.current,
            requestSubjectKey: subjectKey,
            currentSubjectKey: subjectRef.current,
            requestSeq,
            currentRequestSeq: requestSeqRef.current,
            completedCursor: completedCursorRef.current,
            shouldAcceptGeneration,
          })
        ) {
          settleRefreshWaiter(refreshSeq);
          return;
        }
        setState((prev) => resourceFailure(prev, message));
        stateSubjectRef.current = subjectKey;
        settleRefreshWaiter(refreshSeq);
        return;
      }

      if (
        !shouldApplyResponse({
          requestEpoch,
          currentEpoch: epochRef.current,
          requestSessionId: requestSession,
          currentSessionId: sessionRef.current,
          requestSubjectKey: subjectKey,
          currentSubjectKey: subjectRef.current,
          requestSeq,
          currentRequestSeq: requestSeqRef.current,
          responseGeneration: result.ok ? extractGenerationRef.current(result.value) : undefined,
          completedCursor: completedCursorRef.current,
          shouldAcceptGeneration,
        })
      ) {
        settleRefreshWaiter(refreshSeq);
        return;
      }

      if (!result.ok) {
        setState((prev) => resourceFailure(prev, formatIpcError(result.error)));
        stateSubjectRef.current = subjectKey;
        settleRefreshWaiter(refreshSeq);
        return;
      }

      const generation = extractGenerationRef.current(result.value);
      completedCursorRef.current = { sessionId: requestSession, generation };
      payloadSubjectRef.current = subjectKey;
      stateSubjectRef.current = subjectKey;
      setState(resourceSuccess(result.value));
      settleRefreshWaiter(refreshSeq);
    })();
  }, [snapshot, subjectKey, refreshSeq, settleAllRefreshWaiters, settleRefreshWaiter]);

  useEffect(() => {
    return () => {
      epochRef.current += 1;
      settleAllRefreshWaiters();
    };
  }, [settleAllRefreshWaiters]);

  const refresh = useCallback((): Promise<void> => {
    return new Promise<void>((resolve) => {
      setRefreshSeq((current) => {
        const next = current + 1;
        refreshWaitersRef.current.set(next, { resolve });
        return next;
      });
    });
  }, []);

  return {
    state: fencedResourceState(state, stateSubjectRef.current, subjectKey),
    refresh,
  };
}
