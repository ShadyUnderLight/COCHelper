/** @vitest-environment jsdom */

import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
  AppSnapshotPayload,
  Result,
  StateChangedListener,
  UpgradeOverviewPayload,
} from '@coc-helper/contracts';

import type { BridgeOverviewClient } from './use-upgrade-overview';
import { useUpgradeOverview } from './use-upgrade-overview';

function snapshot(overrides: Partial<AppSnapshotPayload> = {}): AppSnapshotPayload {
  return {
    sessionId: 'session-a',
    generation: 1,
    availability: 'available',
    villageStatus: 'available',
    villageError: null,
    canWrite: true,
    hasPendingJournal: false,
    recoveryNotice: null,
    selectedVillageId: null,
    villages: [],
    pendingImport: null,
    ...overrides,
  };
}

function overview(overrides: Partial<UpgradeOverviewPayload> = {}): UpgradeOverviewPayload {
  return {
    generation: 1,
    nowMs: 1_700_000_000_000,
    catalogVersion: '18.400.13',
    catalogIsUsable: true,
    active: [],
    pending: [],
    state: {
      manualActiveCount: 0,
      importedActiveCount: 0,
      deduplicatedDisplayCount: 0,
      manualCompletedCount: 0,
      completedRecently: [],
      activeRecords: [],
      attentionRecords: [],
      needsReimportRecords: [],
    },
    ...overrides,
  };
}

function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

function createBridge() {
  const listeners = new Set<StateChangedListener>();
  let deferred: { resolve: (value: Result<UpgradeOverviewPayload>) => void } | undefined;
  const bridge: BridgeOverviewClient = {
    upgradeOverview: vi.fn(
      async () =>
        await new Promise<Result<UpgradeOverviewPayload>>((resolve) => {
          deferred = { resolve };
        }),
    ),
    onStateChanged: (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
  return {
    bridge,
    push(next: AppSnapshotPayload) {
      for (const listener of listeners) {
        listener(next);
      }
    },
    resolve(value: Result<UpgradeOverviewPayload>) {
      deferred?.resolve(value);
      deferred = undefined;
    },
  };
}

afterEach(() => {
  cleanup();
});

describe('useUpgradeOverview', () => {
  it('首次 loading → success', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useUpgradeOverview(harness.bridge, snapshot({ generation: 3 })),
    );
    expect(result.current.state.status).toBe('loading');
    act(() => {
      harness.resolve(ok(overview({ generation: 3 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    expect(result.current.state.payload?.generation).toBe(3);
  });

  it('过期 generation 响应丢弃', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap }) => useUpgradeOverview(harness.bridge, snap),
      { initialProps: { snap: snapshot({ generation: 5 }) } },
    );
    act(() => {
      harness.resolve(ok(overview({ generation: 5 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    rerender({ snap: snapshot({ generation: 8 }) });
    await waitFor(() => {
      expect(harness.bridge.upgradeOverview).toHaveBeenCalledTimes(2);
    });
    act(() => {
      harness.resolve(ok(overview({ generation: 4 })));
    });
    await act(async () => {});
    expect(result.current.state.payload?.generation).toBe(5);
  });

  it('sessionId 变化后旧请求丢弃且清空 last-good', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap }) => useUpgradeOverview(harness.bridge, snap),
      { initialProps: { snap: snapshot({ sessionId: 's1', generation: 2 }) } },
    );
    act(() => {
      harness.resolve(ok(overview({ generation: 2 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    rerender({ snap: snapshot({ sessionId: 's2', generation: 2 }) });
    expect(result.current.state.status).toBe('loading');
    expect(result.current.state.payload).toBeNull();
    act(() => {
      harness.resolve(ok(overview({ generation: 2 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
  });

  it('失败且有 last-good 时保持 ready 并挂错误', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap }) => useUpgradeOverview(harness.bridge, snap),
      { initialProps: { snap: snapshot({ generation: 1 }) } },
    );
    act(() => {
      harness.resolve(ok(overview({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    rerender({ snap: snapshot({ generation: 2 }) });
    act(() => {
      harness.resolve({
        ok: false,
        error: {
          kind: 'serverError',
          code: 'catalog-unavailable',
          messageKey: 'catalog.unavailable',
          message: '目录未就绪',
        },
      });
    });
    await waitFor(() => {
      expect(result.current.state.lastError).toMatch(/目录未就绪/);
    });
    expect(result.current.state.status).toBe('ready');
    expect(result.current.state.payload?.generation).toBe(1);
  });

  it('新世代 snapshot 触发重刷；迟到旧世代不重复拉', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap }) => useUpgradeOverview(harness.bridge, snap),
      { initialProps: { snap: snapshot({ generation: 1 }) } },
    );
    act(() => {
      harness.resolve(ok(overview({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    expect(harness.bridge.upgradeOverview).toHaveBeenCalledTimes(1);
    rerender({ snap: snapshot({ generation: 1 }) });
    await act(async () => {});
    expect(harness.bridge.upgradeOverview).toHaveBeenCalledTimes(1);
    rerender({ snap: snapshot({ generation: 2 }) });
    await waitFor(() => {
      expect(harness.bridge.upgradeOverview).toHaveBeenCalledTimes(2);
    });
    rerender({ snap: snapshot({ generation: 1 }) });
    await act(async () => {});
    expect(harness.bridge.upgradeOverview).toHaveBeenCalledTimes(2);
  });

  it('卸载后响应不再更新 UI', async () => {
    const harness = createBridge();
    const { result, unmount } = renderHook(() =>
      useUpgradeOverview(harness.bridge, snapshot({ generation: 1 })),
    );
    unmount();
    act(() => {
      harness.resolve(ok(overview({ generation: 1 })));
    });
    await act(async () => {});
    expect(result.current.state.status).toBe('loading');
  });

  it('refresh 主动重刷', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useUpgradeOverview(harness.bridge, snapshot({ generation: 1 })),
    );
    act(() => {
      harness.resolve(ok(overview({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    act(() => {
      void result.current.refresh();
    });
    await waitFor(() => {
      expect(harness.bridge.upgradeOverview).toHaveBeenCalledTimes(2);
    });
  });

  it('select 记录选择 id', () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useUpgradeOverview(harness.bridge, snapshot({ generation: 1 })),
    );
    expect(result.current.selectedId).toBeNull();
    act(() => {
      result.current.select('rec-9');
    });
    expect(result.current.selectedId).toBe('rec-9');
  });

  it('snapshot 为 null 时保持 loading 且不发请求，来快照后拉取', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap }) => useUpgradeOverview(harness.bridge, snap),
      { initialProps: { snap: null as AppSnapshotPayload | null } },
    );
    await act(async () => {});
    expect(result.current.state.status).toBe('loading');
    expect(harness.bridge.upgradeOverview).not.toHaveBeenCalled();
    rerender({ snap: snapshot({ generation: 1 }) });
    await waitFor(() => {
      expect(harness.bridge.upgradeOverview).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolve(ok(overview({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
  });

  it('请求抛错进入 error 态；非 Error 抛值用兜底文案', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap }) => useUpgradeOverview(harness.bridge, snap),
      { initialProps: { snap: snapshot({ generation: 1 }) } },
    );
    act(() => {
      harness.resolve(ok(overview({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    vi.mocked(harness.bridge.upgradeOverview).mockRejectedValueOnce(new Error('ipc 炸了'));
    act(() => {
      void result.current.refresh();
    });
    await waitFor(() => {
      expect(result.current.state.lastError).toMatch(/ipc 炸了/);
    });
    expect(result.current.state.status).toBe('ready');
    expect(result.current.state.payload?.generation).toBe(1);
    vi.mocked(harness.bridge.upgradeOverview).mockRejectedValueOnce('plain-string');
    rerender({ snap: snapshot({ generation: 2 }) });
    await waitFor(() => {
      expect(result.current.state.lastError).toBe('升级总览查询失败');
    });
  });
});
