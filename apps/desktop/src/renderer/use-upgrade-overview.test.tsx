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
  const resolvers: Array<(value: Result<UpgradeOverviewPayload>) => void> = [];
  const bridge: BridgeOverviewClient = {
    upgradeOverview: vi.fn(
      async () =>
        await new Promise<Result<UpgradeOverviewPayload>>((resolve) => {
          resolvers.push(resolve);
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
      resolvers.shift()?.(value);
    },
    /** 按请求下标 resolve 并从队列移除（overlap 回归用例）。 */
    resolveAt(index: number, value: Result<UpgradeOverviewPayload>) {
      resolvers.splice(index, 1)[0]?.(value);
    },
    pendingCount() {
      return resolvers.length;
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

  it('P1a：旧 session 请求 pending 时切换新 session（低 generation）必须发新请求', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap }) => useUpgradeOverview(harness.bridge, snap),
      { initialProps: { snap: snapshot({ sessionId: 'sA', generation: 50 }) } },
    );
    await waitFor(() => {
      expect(harness.bridge.upgradeOverview).toHaveBeenCalledTimes(1);
    });
    expect(harness.pendingCount()).toBe(1);
    act(() => {
      result.current.select('rec-x');
    });
    rerender({ snap: snapshot({ sessionId: 'sB', generation: 1 }) });
    // 切 session 即清空（含选择态），且 B 世代再低也必须发请求。
    expect(result.current.state.status).toBe('loading');
    expect(result.current.state.payload).toBeNull();
    expect(result.current.selectedId).toBeNull();
    await waitFor(() => {
      expect(harness.bridge.upgradeOverview).toHaveBeenCalledTimes(2);
    });
    // A 的迟到成功不得影响 B。
    act(() => {
      harness.resolveAt(0, ok(overview({ generation: 50 })));
    });
    await act(async () => {});
    expect(result.current.state.status).toBe('loading');
    act(() => {
      harness.resolveAt(0, ok(overview({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    expect(result.current.state.payload?.generation).toBe(1);
  });

  it('P1b：旧 session 首次请求失败后切换 session，清旧错并发新请求', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap }) => useUpgradeOverview(harness.bridge, snap),
      { initialProps: { snap: snapshot({ sessionId: 'sA', generation: 50 }) } },
    );
    act(() => {
      harness.resolve({
        ok: false,
        error: {
          kind: 'serverError',
          code: 'catalog-unavailable',
          messageKey: 'catalog.unavailable',
          message: 'A 失败',
        },
      });
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('error');
    });
    rerender({ snap: snapshot({ sessionId: 'sB', generation: 1 }) });
    expect(result.current.state.status).toBe('loading');
    expect(result.current.state.payload).toBeNull();
    expect(result.current.state.lastError).toBeNull();
    await waitFor(() => {
      expect(harness.bridge.upgradeOverview).toHaveBeenCalledTimes(2);
    });
    act(() => {
      harness.resolve(ok(overview({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
  });

  it('P2：旧请求的迟到失败不得污染新 overview', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap }) => useUpgradeOverview(harness.bridge, snap),
      { initialProps: { snap: snapshot({ generation: 5 }) } },
    );
    rerender({ snap: snapshot({ generation: 6 }) });
    await waitFor(() => {
      expect(harness.bridge.upgradeOverview).toHaveBeenCalledTimes(2);
    });
    expect(harness.pendingCount()).toBe(2);
    // B（新请求）先成功。
    act(() => {
      harness.resolveAt(1, ok(overview({ generation: 6 })));
    });
    await waitFor(() => {
      expect(result.current.state.payload?.generation).toBe(6);
    });
    expect(result.current.state.lastError).toBeNull();
    // A（旧请求）后失败：必须丢弃。
    act(() => {
      harness.resolveAt(0, {
        ok: false,
        error: {
          kind: 'serverError',
          code: 'stale-fail',
          messageKey: 'stale.fail',
          message: 'A 迟到失败',
        },
      });
    });
    await act(async () => {});
    expect(result.current.state.payload?.generation).toBe(6);
    expect(result.current.state.lastError).toBeNull();
  });
});
