/** @vitest-environment jsdom */

import { act, renderHook, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
  ApiRefreshPayload,
  OperationProgressListener,
  Result,
  WarLogLoadMorePayload,
  WarLogStatePayload,
} from '@coc-helper/contracts';

import { resetClockStoreForTests } from './clock-store';
import { useOfficialWarLog, type BridgeWarLogClient } from './use-official-war-log';

function snapshot() {
  return {
    sessionId: 'session-a',
    generation: 1,
    availability: 'available' as const,
    villageStatus: 'available' as const,
    villageError: null,
    canWrite: true,
    hasPendingJournal: false,
    recoveryNotice: null,
    selectedVillageId: 'v1',
    villages: [{ id: 'v1', name: '主村', tag: '#AAA', hasImportedData: true }],
    pendingImport: null,
  };
}

function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

function err(message: string): Result<never> {
  return {
    ok: false,
    error: {
      kind: 'internal',
      code: 'load-more-failed',
      messageKey: 'loadMore.failed',
      message,
    },
  };
}

function warLogPayload(overrides: Partial<WarLogStatePayload> = {}): WarLogStatePayload {
  return {
    generation: 1,
    clanTag: '#CLAN01',
    state: {
      status: 'success',
      parserVersion: 'war-log-0.1',
      fetchedAt: 1_700_000_000_000,
      unrecognizedKeys: [],
      hasMore: true,
      lastGood: {
        page: {
          items: Array.from({ length: 12 }, (_, index) => ({
            endTime: `2024-01-${String(index + 1).padStart(2, '0')}`,
            result: 'win',
          })),
        },
        unrecognizedKeys: [],
      },
    },
    ...overrides,
  };
}

function createBridge() {
  const resolvers: Array<(value: Result<WarLogStatePayload>) => void> = [];
  const refreshResolvers: Array<(value: Result<ApiRefreshPayload>) => void> = [];
  const loadMoreResolvers: Array<(value: Result<WarLogLoadMorePayload>) => void> = [];
  const progressListeners = new Set<OperationProgressListener>();
  const bridge: BridgeWarLogClient = {
    warLogState: vi.fn(
      async () =>
        await new Promise<Result<WarLogStatePayload>>((resolve) => {
          resolvers.push(resolve);
        }),
    ),
    apiRefresh: vi.fn(
      async () =>
        await new Promise<Result<ApiRefreshPayload>>((resolve) => {
          refreshResolvers.push(resolve);
        }),
    ),
    warLogLoadMore: vi.fn(
      async () =>
        await new Promise<Result<WarLogLoadMorePayload>>((resolve) => {
          loadMoreResolvers.push(resolve);
        }),
    ),
    onOperationProgress: (listener) => {
      progressListeners.add(listener);
      return () => {
        progressListeners.delete(listener);
      };
    },
    cancel: vi.fn(),
  };
  return {
    bridge,
    resolve(value: Result<WarLogStatePayload>) {
      resolvers.shift()?.(value);
    },
    resolveRefresh(value: Result<ApiRefreshPayload>) {
      refreshResolvers.shift()?.(value);
    },
    resolveLoadMore(value: Result<WarLogLoadMorePayload>) {
      loadMoreResolvers.shift()?.(value);
    },
    emitProgress(payload: {
      operationId: string;
      phase: 'failed' | 'cancelled' | 'completed';
      generation: number;
      message?: string;
    }) {
      for (const listener of progressListeners) {
        listener(payload);
      }
    },
  };
}

async function expandWarLogToServerMore(result: { current: ReturnType<typeof useOfficialWarLog> }) {
  await waitFor(() => {
    expect(result.current.view.moreState).toBe('localHidden');
  });
  await act(async () => {
    await result.current.loadMore();
  });
  await waitFor(() => {
    expect(result.current.view.moreState).toBe('serverMore');
  });
}

afterEach(() => {
  resetClockStoreForTests();
});

describe('useOfficialWarLog（#277-E2）', () => {
  it('warLog 不公开时不查询', async () => {
    const { bridge } = createBridge();
    renderHook(() => useOfficialWarLog(bridge, snapshot(), 'tagged', '#CLAN01', 'v1', 'private'));
    await act(async () => {
      await Promise.resolve();
    });
    expect(bridge.warLogState).not.toHaveBeenCalled();
  });

  it('refresh 完成前保持 remoteBusy，state 重查后才结束', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useOfficialWarLog(harness.bridge, snapshot(), 'tagged', '#CLAN01', 'v1', 'public'),
    );
    act(() => {
      harness.resolve(ok(warLogPayload()));
    });
    await waitFor(() => {
      expect(result.current.view.entries).toHaveLength(12);
    });

    act(() => {
      void result.current.refresh();
    });
    await waitFor(() => {
      expect(result.current.remoteBusy).toBe(true);
    });

    const requestId = vi.mocked(harness.bridge.apiRefresh).mock.calls[0]?.[0]?.requestId;
    act(() => {
      harness.emitProgress({ operationId: requestId as string, phase: 'completed', generation: 2 });
    });
    expect(result.current.remoteBusy).toBe(true);

    await act(async () => {
      harness.resolveRefresh(ok({ generation: 2, results: [] }));
    });
    await act(async () => {
      harness.resolve(ok(warLogPayload({ generation: 2 })));
      await Promise.resolve();
    });
    await waitFor(() => {
      expect(result.current.remoteBusy).toBe(false);
    });
  });

  it('refresh 进行中禁止 loadMore', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useOfficialWarLog(harness.bridge, snapshot(), 'tagged', '#CLAN01', 'v1', 'public'),
    );
    act(() => {
      harness.resolve(ok(warLogPayload()));
    });
    await waitFor(() => {
      expect(result.current.view.moreState).toBe('localHidden');
    });

    act(() => {
      void result.current.refresh();
    });
    await waitFor(() => {
      expect(result.current.remoteBusy).toBe(true);
    });

    await act(async () => {
      await result.current.loadMore();
    });
    expect(harness.bridge.warLogLoadMore).not.toHaveBeenCalled();
  });

  it('refresh cross-cancel 后旧 loadMore 不得回写 commandError', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useOfficialWarLog(harness.bridge, snapshot(), 'tagged', '#CLAN01', 'v1', 'public'),
    );
    act(() => {
      harness.resolve(ok(warLogPayload()));
    });
    await waitFor(() => {
      expect(result.current.view.moreState).toBe('localHidden');
    });

    await act(async () => {
      await result.current.loadMore();
    });
    await waitFor(() => {
      expect(result.current.view.moreState).toBe('serverMore');
    });

    act(() => {
      void result.current.loadMore();
      // 同一同步块内交叉调用：remoteBusy 尚未 re-render，refresh 会 cross-cancel loadMore。
      void result.current.refresh();
    });
    await waitFor(() => {
      expect(harness.bridge.warLogLoadMore).toHaveBeenCalledTimes(1);
      expect(harness.bridge.cancel).toHaveBeenCalled();
    });

    await act(async () => {
      harness.resolveLoadMore(err('迟到的 loadMore 失败'));
    });
    expect(result.current.view.commandError).toBeNull();

    await act(async () => {
      harness.resolveRefresh(ok({ generation: 2, results: [] }));
    });
    await waitFor(() => {
      expect(harness.bridge.warLogState).toHaveBeenCalledTimes(2);
    });
    await act(async () => {
      harness.resolve(ok(warLogPayload({ generation: 2 })));
    });
    await waitFor(() => {
      expect(result.current.remoteBusy).toBe(false);
    });
    expect(result.current.view.commandError).toBeNull();
  });

  it('loadMore failed progress 先于 invoke settle 时，refresh 不得被迟到结果重写 error', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useOfficialWarLog(harness.bridge, snapshot(), 'tagged', '#CLAN01', 'v1', 'public'),
    );
    act(() => {
      harness.resolve(ok(warLogPayload()));
    });
    await expandWarLogToServerMore(result);

    act(() => {
      void result.current.loadMore();
    });
    await waitFor(() => {
      expect(harness.bridge.warLogLoadMore).toHaveBeenCalledTimes(1);
    });
    const loadMoreRequestId = vi.mocked(harness.bridge.warLogLoadMore).mock.calls[0]?.[0]
      ?.requestId as string;

    act(() => {
      harness.emitProgress({
        operationId: loadMoreRequestId,
        phase: 'failed',
        generation: 2,
        message: '加载更多失败',
      });
    });
    await waitFor(() => {
      expect(result.current.view.commandError).toBe('加载更多失败');
      expect(result.current.remoteBusy).toBe(false);
    });

    act(() => {
      void result.current.refresh();
    });
    await waitFor(() => {
      expect(harness.bridge.apiRefresh).toHaveBeenCalledTimes(1);
    });

    await act(async () => {
      harness.resolveLoadMore(err('加载更多失败'));
    });
    expect(result.current.view.commandError).toBeNull();

    await act(async () => {
      harness.resolveRefresh(ok({ generation: 2, results: [] }));
    });
    await waitFor(() => {
      expect(harness.bridge.warLogState).toHaveBeenCalledTimes(2);
    });
    await act(async () => {
      harness.resolve(ok(warLogPayload({ generation: 2 })));
    });
    await waitFor(() => {
      expect(result.current.remoteBusy).toBe(false);
      expect(result.current.view.commandError).toBeNull();
    });
  });

  it('loadMore 失败后 refresh 成功会清除旧 commandError', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useOfficialWarLog(harness.bridge, snapshot(), 'tagged', '#CLAN01', 'v1', 'public'),
    );
    act(() => {
      harness.resolve(ok(warLogPayload()));
    });
    await waitFor(() => {
      expect(result.current.view.moreState).toBe('localHidden');
    });

    await act(async () => {
      await result.current.loadMore();
    });
    await waitFor(() => {
      expect(result.current.view.moreState).toBe('serverMore');
    });

    act(() => {
      void result.current.loadMore();
    });
    await waitFor(() => {
      expect(harness.bridge.warLogLoadMore).toHaveBeenCalledTimes(1);
    });
    await act(async () => {
      harness.resolveLoadMore(err('加载更多失败'));
    });
    await waitFor(() => {
      expect(result.current.view.commandError).toBe('加载更多失败');
    });

    act(() => {
      void result.current.refresh();
    });
    await waitFor(() => {
      expect(harness.bridge.apiRefresh).toHaveBeenCalledTimes(1);
    });
    await act(async () => {
      harness.resolveRefresh(ok({ generation: 2, results: [] }));
    });
    await waitFor(() => {
      expect(harness.bridge.warLogState).toHaveBeenCalledTimes(2);
    });
    await act(async () => {
      harness.resolve(ok(warLogPayload({ generation: 2 })));
    });
    await waitFor(() => {
      expect(result.current.remoteBusy).toBe(false);
      expect(result.current.view.commandError).toBeNull();
    });
  });

  it('refresh 失败后 loadMore 成功会清除旧 commandError', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useOfficialWarLog(harness.bridge, snapshot(), 'tagged', '#CLAN01', 'v1', 'public'),
    );
    act(() => {
      harness.resolve(ok(warLogPayload()));
    });
    await waitFor(() => {
      expect(result.current.view.moreState).toBe('localHidden');
    });

    await act(async () => {
      await result.current.loadMore();
    });
    await waitFor(() => {
      expect(result.current.view.moreState).toBe('serverMore');
    });

    act(() => {
      void result.current.refresh();
    });
    await waitFor(() => {
      expect(harness.bridge.apiRefresh).toHaveBeenCalledTimes(1);
    });
    await act(async () => {
      harness.resolveRefresh(err('刷新失败'));
    });
    await waitFor(() => {
      expect(result.current.view.commandError).toBe('刷新失败');
    });

    act(() => {
      void result.current.loadMore();
    });
    await waitFor(() => {
      expect(harness.bridge.warLogLoadMore).toHaveBeenCalledTimes(1);
    });
    await act(async () => {
      harness.resolveLoadMore(
        ok({
          generation: 2,
          clanTag: '#CLAN01',
          state: {
            status: 'success',
            parserVersion: 'war-log-0.1',
            fetchedAt: 1_700_000_000_000,
            unrecognizedKeys: [],
            hasMore: true,
            lastGood: warLogPayload().state?.lastGood,
          },
        }),
      );
    });
    await waitFor(() => {
      expect(harness.bridge.warLogState).toHaveBeenCalledTimes(2);
    });
    await act(async () => {
      harness.resolve(ok(warLogPayload({ generation: 2 })));
    });
    await waitFor(() => {
      expect(result.current.remoteBusy).toBe(false);
      expect(result.current.view.commandError).toBeNull();
    });
  });

  it('loadMore 失败后可正常重试', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useOfficialWarLog(harness.bridge, snapshot(), 'tagged', '#CLAN01', 'v1', 'public'),
    );
    act(() => {
      harness.resolve(ok(warLogPayload()));
    });
    await waitFor(() => {
      expect(result.current.view.moreState).toBe('localHidden');
    });

    await act(async () => {
      await result.current.loadMore();
    });
    await waitFor(() => {
      expect(result.current.view.moreState).toBe('serverMore');
    });

    act(() => {
      void result.current.loadMore();
    });
    await waitFor(() => {
      expect(harness.bridge.warLogLoadMore).toHaveBeenCalledTimes(1);
    });

    await act(async () => {
      harness.resolveLoadMore(err('加载更多失败'));
    });
    await waitFor(() => {
      expect(result.current.loadingMore).toBe(false);
      expect(result.current.view.commandError).toBe('加载更多失败');
    });

    act(() => {
      void result.current.loadMore();
    });
    await waitFor(() => {
      expect(harness.bridge.warLogLoadMore).toHaveBeenCalledTimes(2);
    });

    await act(async () => {
      harness.resolveLoadMore(
        ok({
          generation: 2,
          clanTag: '#CLAN01',
          state: {
            status: 'success',
            parserVersion: 'war-log-0.1',
            fetchedAt: 1_700_000_000_000,
            unrecognizedKeys: [],
            hasMore: true,
            lastGood: warLogPayload().state?.lastGood,
          },
        }),
      );
    });
    await waitFor(() => {
      expect(harness.bridge.warLogState).toHaveBeenCalledTimes(2);
    });
    await act(async () => {
      harness.resolve(ok(warLogPayload({ generation: 2 })));
    });
    await waitFor(() => {
      expect(result.current.remoteBusy).toBe(false);
      expect(result.current.view.commandError).toBeNull();
    });
  });
});
