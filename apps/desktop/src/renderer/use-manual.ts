import { useCallback, useRef, useState } from 'react';

import type {
  AppSnapshotPayload,
  DesktopBridge,
  ManualStatePayload,
  TrackerBaseDto,
  VillageItemStateDto,
} from '@coc-helper/contracts';

import { cursorFromSnapshot, formatIpcError, isCurrentEpoch, type SessionCursor } from './app-session';
import { IDLE_MANUAL_VIEW, type ManualView } from './manual-session';
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

function toManualView(resource: ResourceState<ManualStatePayload>): ManualView {
  const payload = resourceData(resource);
  const lastError = resourceLastError(resource);
  if (payload === null) {
    if (lastError !== null) {
      return { status: 'error', payload: null, lastError };
    }
    return IDLE_MANUAL_VIEW;
  }
  return { status: 'ready', payload, lastError };
}

export function useManual(
  bridge: BridgeManualClient,
  snapshot: AppSnapshotPayload | null,
  villageId: string | null,
  options: { readonly onMutated?: () => void } = {},
): ManualApi {
  const [commandError, setCommandError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const inFlightRef = useRef(false);
  const cursorRef = useRef<SessionCursor | null>(null);
  const epochRef = useRef(0);
  const onMutatedRef = useRef(options.onMutated);
  onMutatedRef.current = options.onMutated;

  if (snapshot !== null) {
    cursorRef.current = cursorFromSnapshot(snapshot);
  }

  const subjectKey =
    snapshot === null || villageId === null ? null : `${snapshot.sessionId}:manual:${villageId}`;

  const query = useResourceQuery({
    snapshot,
    subjectKey,
    fetch: () => bridge.manualState({ villageId: villageId as string }),
    extractGeneration: (payload) => payload.generation,
    fetchErrorMessage: '手动升级状态查询失败',
  });

  const runCommand = useCallback(
    async (action: (expectedGeneration: number) => Promise<{ readonly ok: boolean }>): Promise<boolean> => {
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
        const result = await action(cursor.generation);
        if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
          return false;
        }
        if (!result.ok) {
          return false;
        }
        onMutatedRef.current?.();
        await query.refresh();
        return true;
      } finally {
        inFlightRef.current = false;
        setBusy(false);
      }
    },
    [query.refresh],
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
      return await runCommand(async (expectedGeneration) => {
        const result = await bridge.manualStart({
          expectedGeneration,
          villageId: input.villageId,
          itemKey: input.item.trackerItemKey,
          fromLevel: preview.fromLevel,
          targetLevel: preview.targetLevel,
          quantity: preview.quantity,
          startedAtMs: Date.now(),
          sourceKind: preview.sourceKind,
          base: input.base,
        });
        if (!result.ok) {
          setCommandError(formatIpcError(result.error));
          if (result.error.code === 'conflict') {
            onMutatedRef.current?.();
          }
          return result;
        }
        cursorRef.current =
          cursorRef.current === null
            ? cursorRef.current
            : { sessionId: cursorRef.current.sessionId, generation: result.value.generation };
        setCommandError(null);
        return result;
      });
    },
    [bridge, runCommand],
  );

  const cancel = useCallback(
    async (input: { readonly villageId: string; readonly recordId: string }): Promise<boolean> =>
      await runCommand(async (expectedGeneration) => {
        const result = await bridge.manualCancel({
          expectedGeneration,
          villageId: input.villageId,
          recordId: input.recordId,
        });
        if (!result.ok) {
          setCommandError(formatIpcError(result.error));
          if (result.error.code === 'conflict') {
            onMutatedRef.current?.();
          }
          return result;
        }
        cursorRef.current =
          cursorRef.current === null
            ? cursorRef.current
            : { sessionId: cursorRef.current.sessionId, generation: result.value.generation };
        setCommandError(null);
        return result;
      }),
    [bridge, runCommand],
  );

  const adjust = useCallback(
    async (input: {
      readonly villageId: string;
      readonly recordId: string;
      readonly startedAtMs: number;
    }): Promise<boolean> =>
      await runCommand(async (expectedGeneration) => {
        const result = await bridge.manualAdjust({
          expectedGeneration,
          villageId: input.villageId,
          recordId: input.recordId,
          startedAtMs: input.startedAtMs,
        });
        if (!result.ok) {
          setCommandError(formatIpcError(result.error));
          if (result.error.code === 'conflict') {
            onMutatedRef.current?.();
          }
          return result;
        }
        cursorRef.current =
          cursorRef.current === null
            ? cursorRef.current
            : { sessionId: cursorRef.current.sessionId, generation: result.value.generation };
        setCommandError(null);
        return result;
      }),
    [bridge, runCommand],
  );

  const settle = useCallback(
    async (input: { readonly villageId?: string }): Promise<boolean> =>
      await runCommand(async (expectedGeneration) => {
        const result = await bridge.manualSettle({
          expectedGeneration,
          villageId: input.villageId ?? null,
        });
        if (!result.ok) {
          setCommandError(formatIpcError(result.error));
          if (result.error.code === 'conflict') {
            onMutatedRef.current?.();
          }
          return result;
        }
        cursorRef.current =
          cursorRef.current === null
            ? cursorRef.current
            : { sessionId: cursorRef.current.sessionId, generation: result.value.generation };
        setCommandError(null);
        return result;
      }),
    [bridge, runCommand],
  );

  return {
    view: toManualView(query.state),
    refresh: query.refresh,
    commandError,
    busy,
    startRow,
    cancel,
    adjust,
    settle,
  };
}
