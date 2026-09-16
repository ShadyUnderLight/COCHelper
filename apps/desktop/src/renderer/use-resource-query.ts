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
      }
      return;
    }
    const requestEpoch = epochRef.current;
    const requestSession = snapshot.sessionId;

    if (sessionCursorRef.current !== requestSession) {
      sessionCursorRef.current = requestSession;
      completedCursorRef.current = null;
      payloadSubjectRef.current = null;
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
      return;
    }

    if (subjectChanged(payloadSubjectRef.current, subjectKey)) {
      payloadSubjectRef.current = null;
      setState(LOADING_RESOURCE);
    }

    lastKeyRef.current = planned.fetchKey;
    lastSeqRef.current = refreshSeq;
    maxRequestedRef.current = planned.nextMaxRequestedGeneration;
    requestSeqRef.current = planned.requestSeq;
    const requestSeq = planned.requestSeq;

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
          return;
        }
        setState((prev) => resourceFailure(prev, message));
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
        return;
      }

      if (!result.ok) {
        setState((prev) => resourceFailure(prev, formatIpcError(result.error)));
        return;
      }

      const generation = extractGenerationRef.current(result.value);
      completedCursorRef.current = { sessionId: requestSession, generation };
      payloadSubjectRef.current = subjectKey;
      setState(resourceSuccess(result.value));
    })();
  }, [snapshot, subjectKey, refreshSeq]);

  useEffect(() => {
    return () => {
      epochRef.current += 1;
    };
  }, []);

  const refresh = useCallback(async () => {
    setRefreshSeq((n) => n + 1);
  }, []);

  return {
    state: fencedResourceState(state, payloadSubjectRef.current, subjectKey),
    refresh,
  };
}
