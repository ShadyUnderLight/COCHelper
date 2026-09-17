/** @vitest-environment jsdom */

import { act, renderHook, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
  ApiRefreshPayload,
  CapitalRaidLoadMorePayload,
  CapitalRaidStatePayload,
  OperationProgressListener,
  Result,
} from '@coc-helper/contracts';

import { resetClockStoreForTests } from './clock-store';
import { useOfficialCapitalRaid, type BridgeCapitalRaidClient } from './use-official-capital-raid';

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

function capitalRaidPayload(
  overrides: Partial<CapitalRaidStatePayload> = {},
): CapitalRaidStatePayload {
  return {
    generation: 1,
    clanTag: '#CLAN01',
    state: {
      status: 'success',
      parserVersion: 'capital-raid-0.1',
      fetchedAt: 1_700_000_000_000,
      unrecognizedKeys: [],
      hasMore: true,
      lastGood: {
        page: {
          items: [{ state: 'ended', startTime: '2024-01-01' }],
        },
        unrecognizedKeys: [],
      },
    },
    ...overrides,
  };
}

function createBridge() {
  const resolvers: Array<(value: Result<CapitalRaidStatePayload>) => void> = [];
  const refreshResolvers: Array<(value: Result<ApiRefreshPayload>) => void> = [];
  const loadMoreResolvers: Array<(value: Result<CapitalRaidLoadMorePayload>) => void> = [];
  const progressListeners = new Set<OperationProgressListener>();
  const bridge: BridgeCapitalRaidClient = {
    capitalRaidState: vi.fn(
      async () =>
        await new Promise<Result<CapitalRaidStatePayload>>((resolve) => {
          resolvers.push(resolve);
        }),
    ),
    apiRefresh: vi.fn(
      async () =>
        await new Promise<Result<ApiRefreshPayload>>((resolve) => {
          refreshResolvers.push(resolve);
        }),
    ),
    capitalRaidLoadMore: vi.fn(
      async () =>
        await new Promise<Result<CapitalRaidLoadMorePayload>>((resolve) => {
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
    resolve(value: Result<CapitalRaidStatePayload>) {
      resolvers.shift()?.(value);
    },
    resolveRefresh(value: Result<ApiRefreshPayload>) {
      refreshResolvers.shift()?.(value);
    },
    resolveLoadMore(value: Result<CapitalRaidLoadMorePayload>) {
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

afterEach(() => {
  resetClockStoreForTests();
});

describe('useOfficialCapitalRaid（#277-E2）', () => {
  it('loadMore failed progress 先于 invoke settle 时，refresh 不得被迟到结果重写 error', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useOfficialCapitalRaid(harness.bridge, snapshot(), '#CLAN01', 'v1'),
    );
    act(() => {
      harness.resolve(ok(capitalRaidPayload()));
    });
    await waitFor(() => {
      expect(result.current.view.hasMore).toBe(true);
    });

    act(() => {
      void result.current.loadMore();
    });
    await waitFor(() => {
      expect(harness.bridge.capitalRaidLoadMore).toHaveBeenCalledTimes(1);
    });
    const loadMoreRequestId = vi.mocked(harness.bridge.capitalRaidLoadMore).mock.calls[0]?.[0]
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
      expect(harness.bridge.capitalRaidState).toHaveBeenCalledTimes(2);
    });
    await act(async () => {
      harness.resolve(ok(capitalRaidPayload({ generation: 2 })));
    });
    await waitFor(() => {
      expect(result.current.remoteBusy).toBe(false);
      expect(result.current.view.commandError).toBeNull();
    });
  });

  it('loadMore 失败后 refresh 成功会清除旧 commandError', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useOfficialCapitalRaid(harness.bridge, snapshot(), '#CLAN01', 'v1'),
    );
    act(() => {
      harness.resolve(ok(capitalRaidPayload()));
    });
    await waitFor(() => {
      expect(result.current.view.hasMore).toBe(true);
    });

    act(() => {
      void result.current.loadMore();
    });
    await waitFor(() => {
      expect(harness.bridge.capitalRaidLoadMore).toHaveBeenCalledTimes(1);
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
      expect(harness.bridge.capitalRaidState).toHaveBeenCalledTimes(2);
    });
    await act(async () => {
      harness.resolve(ok(capitalRaidPayload({ generation: 2 })));
    });
    await waitFor(() => {
      expect(result.current.remoteBusy).toBe(false);
      expect(result.current.view.commandError).toBeNull();
    });
  });
});
