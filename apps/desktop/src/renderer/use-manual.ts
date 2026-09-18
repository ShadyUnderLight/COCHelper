import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import type {
  AppSnapshotPayload,
  DesktopBridge,
  ManualStatePayload,
  Result,
  TrackerBaseDto,
  VillageItemStateDto,
} from '@coc-helper/contracts';

import { formatIpcError, isCurrentEpoch, type SessionCursor } from './app-session';
import { advanceSessionCursor } from './manual-command-cursor';
import { IDLE_MANUAL_VIEW, type ManualView } from './manual-session';

const MANUAL_COMMAND_UNCERTAIN_MESSAGE = '命令结果未知，正在同步状态…';
import { resourceData, resourceLastError, type ResourceState } from './resource-state';
import { useResourceQuery } from './use-resource-query';

export type BridgeManualClient = Pick<
  DesktopBridge,
  'manualState' | 'manualStart' | 'manualCancel' | 'manualAdjust' | 'manualSettle'
>;

export type ManualApi = {
  readonly view: ManualView;
  readonly refresh: () => Promise<void>;
  readonly commandError: string | null;
  readonly busy: boolean;
  readonly startRow: (input: {
    readonly villageId: string;
    readonly item: VillageItemStateDto;
    readonly base: TrackerBaseDto;
  }) => Promise<boolean>;
  readonly cancel: (input: {
    readonly villageId: string;
    readonly recordId: string;
  }) => Promise<boolean>;
  readonly adjust: (input: {
    readonly villageId: string;
    readonly recordId: string;
    readonly startedAtMs: number;
  }) => Promise<boolean>;
  readonly settle: (input: { readonly villageId?: string }) => Promise<boolean>;
};

function toManualView(
  resource: ResourceState<ManualStatePayload>,
  queryStale: boolean,
  staleMessage: string | null,
): ManualView {
  const payload = resourceData(resource);
  const lastError = resourceLastError(resource);
  if (payload === null) {
    if (lastError !== null) {
      return { status: 'error', payload: null, lastError, queryStale: false };
    }
    return IDLE_MANUAL_VIEW;
  }
  const effectiveStale = queryStale || lastError !== null;
  return {
    status: 'ready',
    payload,
    lastError: lastError ?? (queryStale ? staleMessage : null),
    queryStale: effectiveStale,
  };
}

export function useManual(
  bridge: BridgeManualClient,
  snapshot: AppSnapshotPayload | null,
  villageId: string | null,
  options: { readonly onMutated?: () => void } = {},
): ManualApi {
  const [commandError, setCommandError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [queryStale, setQueryStale] = useState(false);
  const [staleMessage, setStaleMessage] = useState<string | null>(null);
  const inFlightRef = useRef(false);
  const cursorRef = useRef<SessionCursor | null>(null);
  const epochRef = useRef(0);
  const onMutatedRef = useRef(options.onMutated);
  onMutatedRef.current = options.onMutated;
  const prevSubjectKeyRef = useRef<string | null>(null);

  const subjectKey =
    snapshot === null || villageId === null ? null : `${snapshot.sessionId}:manual:${villageId}`;

  // snapshot 单调推进 cursor；成功 mutation 后 cursor 可能领先 prop，不得回退。
  useEffect(() => {
    if (snapshot === null) {
      return;
    }
    const cursor = cursorRef.current;
    if (cursor !== null && snapshot.sessionId !== cursor.sessionId) {
      epochRef.current += 1;
      setCommandError(null);
    }
    advanceSessionCursor(cursorRef, snapshot.sessionId, snapshot.generation);
  }, [snapshot]);

  useEffect(() => {
    const prevSubjectKey = prevSubjectKeyRef.current;
    prevSubjectKeyRef.current = subjectKey;
    if (prevSubjectKey !== null && prevSubjectKey !== subjectKey) {
      epochRef.current += 1;
      setCommandError(null);
    }
  }, [subjectKey]);

  const query = useResourceQuery({
    snapshot,
    subjectKey,
    fetch: () => bridge.manualState({ villageId: villageId as string }),
    extractGeneration: (payload) => payload.generation,
    fetchErrorMessage: '手动升级状态查询失败',
  });

  useEffect(() => {
    switch (query.state.kind) {
      case 'failedWithLastGood':
        setQueryStale(true);
        setStaleMessage(query.state.error.message);
        break;
      case 'ready':
        setQueryStale(false);
        setStaleMessage(null);
        break;
      case 'failed':
        setQueryStale(false);
        setStaleMessage(null);
        break;
      case 'refreshing':
      case 'loading':
      case 'idle':
        break;
      default: {
        const exhaustive: never = query.state;
        throw new Error(`未知资源态：${String(exhaustive)}`);
      }
    }
  }, [query.state]);

  const view = useMemo(
    () => toManualView(query.state, queryStale, staleMessage),
    [query.state, queryStale, staleMessage],
  );

  const applyCommandResult = useCallback(
    (result: Result<{ readonly generation: number }>): Result<{ readonly generation: number }> => {
      if (!result.ok) {
        setCommandError(formatIpcError(result.error));
        if (result.error.code === 'conflict') {
          onMutatedRef.current?.();
        }
        return result;
      }
      if (cursorRef.current !== null) {
        advanceSessionCursor(cursorRef, cursorRef.current.sessionId, result.value.generation);
      }
      setCommandError(null);
      return result;
    },
    [],
  );

  const runCommand = useCallback(
    async (
      action: (expectedGeneration: number) => Promise<Result<{ readonly generation: number }>>,
    ): Promise<boolean> => {
      if (inFlightRef.current) {
        return false;
      }
      const cursor = cursorRef.current;
      if (cursor === null) {
        setCommandError('应用尚未就绪。');
        return false;
      }
      const requestEpoch = epochRef.current;
      inFlightRef.current = true;
      setBusy(true);
      setCommandError(null);
      try {
        let result: Result<{ readonly generation: number }>;
        try {
          result = await action(cursor.generation);
        } catch (error: unknown) {
          if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
            return false;
          }
          setCommandError(error instanceof Error ? error.message : '手动升级命令失败');
          setQueryStale(true);
          setStaleMessage(MANUAL_COMMAND_UNCERTAIN_MESSAGE);
          onMutatedRef.current?.();
          void query.refresh();
          return false;
        }
        if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
          return false;
        }
        result = applyCommandResult(result);
        if (!result.ok) {
          return false;
        }
        onMutatedRef.current?.();
        void query.refresh();
        return true;
      } finally {
        inFlightRef.current = false;
        setBusy(false);
      }
    },
    [applyCommandResult, query.refresh],
  );

  const startRow = useCallback(
    async (input: {
      readonly villageId: string;
      readonly item: VillageItemStateDto;
      readonly base: TrackerBaseDto;
    }): Promise<boolean> => {
      const preview = input.item.manualRowStart;
      if (preview === null) {
        setCommandError('当前项目不可启动本地升级。');
        return false;
      }
      return await runCommand(async (expectedGeneration) =>
        bridge.manualStart({
          expectedGeneration,
          villageId: input.villageId,
          itemKey: input.item.trackerItemKey,
          fromLevel: preview.fromLevel,
          targetLevel: preview.targetLevel,
          quantity: preview.quantity,
          startedAtMs: Date.now(),
          sourceKind: preview.sourceKind,
          base: input.base,
        }),
      );
    },
    [bridge, runCommand],
  );

  const cancel = useCallback(
    async (input: { readonly villageId: string; readonly recordId: string }): Promise<boolean> =>
      await runCommand(async (expectedGeneration) =>
        bridge.manualCancel({
          expectedGeneration,
          villageId: input.villageId,
          recordId: input.recordId,
        }),
      ),
    [bridge, runCommand],
  );

  const adjust = useCallback(
    async (input: {
      readonly villageId: string;
      readonly recordId: string;
      readonly startedAtMs: number;
    }): Promise<boolean> =>
      await runCommand(async (expectedGeneration) =>
        bridge.manualAdjust({
          expectedGeneration,
          villageId: input.villageId,
          recordId: input.recordId,
          startedAtMs: input.startedAtMs,
        }),
      ),
    [bridge, runCommand],
  );

  const settle = useCallback(
    async (input: { readonly villageId?: string }): Promise<boolean> =>
      await runCommand(async (expectedGeneration) =>
        bridge.manualSettle({
          expectedGeneration,
          villageId: input.villageId ?? null,
        }),
      ),
    [bridge, runCommand],
  );

  return {
    view,
    refresh: query.refresh,
    commandError,
    busy,
    startRow,
    cancel,
    adjust,
    settle,
  };
}
