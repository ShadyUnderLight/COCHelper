/** @vitest-environment jsdom */

import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
  AppSnapshotPayload,
  Result,
  StateChangedListener,
  TrackerBaseDto,
  VillageDetailPayload,
} from '@coc-helper/contracts';

import type { BridgeVillageClient } from './use-village-detail';
import { useVillageDetail } from './use-village-detail';
import { villageDetailFixture } from './village-detail-session';

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
    selectedVillageId: 'v1',
    villages: [],
    pendingImport: null,
    ...overrides,
  };
}

function detail(overrides: Partial<VillageDetailPayload> = {}): VillageDetailPayload {
  return villageDetailFixture(overrides);
}

function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

function err(message: string): Result<never> {
  return {
    ok: false,
    error: {
      kind: 'serverError',
      code: 'detail-failed',
      messageKey: 'detail.failed',
      message,
    },
  };
}

function createBridge() {
  const listeners = new Set<StateChangedListener>();
  const resolvers: Array<(value: Result<VillageDetailPayload>) => void> = [];
  const bridge: BridgeVillageClient = {
    villageDetail: vi.fn(
      async () =>
        await new Promise<Result<VillageDetailPayload>>((resolve) => {
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
    resolve(value: Result<VillageDetailPayload>) {
      resolvers.shift()?.(value);
    },
    /** 按请求下标 resolve 并从队列移除（overlap 回归用例）。 */
    resolveAt(index: number, value: Result<VillageDetailPayload>) {
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

describe('useVillageDetail', () => {
  it('村庄为 null 时 idle 不请求；出现村庄后拉取', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap, base }) => useVillageDetail(harness.bridge, snap, base),
      {
        initialProps: {
          snap: snapshot({ selectedVillageId: null }),
          base: 'home' as TrackerBaseDto,
        },
      },
    );
    await act(async () => {});
    expect(result.current.state.status).toBe('idle');
    expect(harness.bridge.villageDetail).not.toHaveBeenCalled();
    rerender({ snap: snapshot({ selectedVillageId: 'v1' }), base: 'home' });
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(1);
    });
    expect(harness.bridge.villageDetail).toHaveBeenCalledWith({ villageId: 'v1', base: 'home' });
    act(() => {
      harness.resolve(ok(detail({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
  });

  it('base 切换重拉且参数 base 变化', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap, base }) => useVillageDetail(harness.bridge, snap, base),
      {
        initialProps: {
          snap: snapshot({ selectedVillageId: 'v1' }),
          base: 'home' as TrackerBaseDto,
        },
      },
    );
    act(() => {
      harness.resolve(ok(detail({ generation: 1, base: 'home' })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    rerender({ snap: snapshot({ selectedVillageId: 'v1' }), base: 'builder' });
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(2);
    });
    expect(vi.mocked(harness.bridge.villageDetail).mock.calls[1]?.[0]).toEqual({
      villageId: 'v1',
      base: 'builder',
    });
  });

  it('村庄切换重拉（同 generation 也拉）', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap, base }) => useVillageDetail(harness.bridge, snap, base),
      {
        initialProps: {
          snap: snapshot({ selectedVillageId: 'v1' }),
          base: 'home' as TrackerBaseDto,
        },
      },
    );
    act(() => {
      harness.resolve(ok(detail({ generation: 1, villageId: 'v1' })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    rerender({ snap: snapshot({ selectedVillageId: 'v2' }), base: 'home' });
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(2);
    });
    expect(vi.mocked(harness.bridge.villageDetail).mock.calls[1]?.[0]).toEqual({
      villageId: 'v2',
      base: 'home',
    });
  });

  it('P1：旧 session pending 时切新 session 低 generation 必须发新请求，旧成功丢弃', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap, base }) => useVillageDetail(harness.bridge, snap, base),
      {
        initialProps: {
          snap: snapshot({ sessionId: 'sA', generation: 50, selectedVillageId: 'v1' }),
          base: 'home' as TrackerBaseDto,
        },
      },
    );
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(1);
    });
    expect(harness.pendingCount()).toBe(1);
    rerender({
      snap: snapshot({ sessionId: 'sB', generation: 1, selectedVillageId: 'v1' }),
      base: 'home',
    });
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(2);
    });
    // A 的迟到成功不得影响 B。
    act(() => {
      harness.resolveAt(0, ok(detail({ generation: 50, villageId: 'v1' })));
    });
    await act(async () => {});
    expect(result.current.state.status).toBe('loading');
    act(() => {
      harness.resolveAt(0, ok(detail({ generation: 1, villageId: 'v1' })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    expect(result.current.state.payload?.generation).toBe(1);
  });

  it('P2：gen5→gen6 overlap，新成功后旧失败被丢弃', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap, base }) => useVillageDetail(harness.bridge, snap, base),
      {
        initialProps: {
          snap: snapshot({ generation: 5, selectedVillageId: 'v1' }),
          base: 'home' as TrackerBaseDto,
        },
      },
    );
    rerender({ snap: snapshot({ generation: 6, selectedVillageId: 'v1' }), base: 'home' });
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(2);
    });
    expect(harness.pendingCount()).toBe(2);
    // B（新请求）先成功。
    act(() => {
      harness.resolveAt(1, ok(detail({ generation: 6 })));
    });
    await waitFor(() => {
      expect(result.current.state.payload?.generation).toBe(6);
    });
    expect(result.current.state.lastError).toBeNull();
    // A（旧请求）后失败：必须丢弃。
    act(() => {
      harness.resolveAt(0, err('A 迟到失败'));
    });
    await act(async () => {});
    expect(result.current.state.payload?.generation).toBe(6);
    expect(result.current.state.lastError).toBeNull();
  });

  it('失败且有 last-good 时保持 ready 并挂错误', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap, base }) => useVillageDetail(harness.bridge, snap, base),
      {
        initialProps: {
          snap: snapshot({ generation: 1, selectedVillageId: 'v1' }),
          base: 'home' as TrackerBaseDto,
        },
      },
    );
    act(() => {
      harness.resolve(ok(detail({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    rerender({ snap: snapshot({ generation: 2, selectedVillageId: 'v1' }), base: 'home' });
    act(() => {
      harness.resolve(err('目录未就绪'));
    });
    await waitFor(() => {
      expect(result.current.state.lastError).toMatch(/目录未就绪/);
    });
    expect(result.current.state.status).toBe('ready');
    expect(result.current.state.payload?.generation).toBe(1);
  });

  it('卸载后响应不再更新 UI', async () => {
    const harness = createBridge();
    const { result, unmount } = renderHook(
      ({ snap, base }) => useVillageDetail(harness.bridge, snap, base),
      {
        initialProps: {
          snap: snapshot({ generation: 1, selectedVillageId: 'v1' }),
          base: 'home' as TrackerBaseDto,
        },
      },
    );
    unmount();
    act(() => {
      harness.resolve(ok(detail({ generation: 1 })));
    });
    await act(async () => {});
    expect(result.current.state.status).toBe('loading');
  });

  it('refresh 主动重刷', async () => {
    const harness = createBridge();
    const { result } = renderHook(
      ({ snap, base }) => useVillageDetail(harness.bridge, snap, base),
      {
        initialProps: {
          snap: snapshot({ generation: 1, selectedVillageId: 'v1' }),
          base: 'home' as TrackerBaseDto,
        },
      },
    );
    act(() => {
      harness.resolve(ok(detail({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    act(() => {
      void result.current.refresh();
    });
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(2);
    });
  });

  it('P2a：切村庄即丢旧 last-good，进 loading 不展示旧村数据', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap, base }) => useVillageDetail(harness.bridge, snap, base),
      {
        initialProps: {
          snap: snapshot({ generation: 5, selectedVillageId: 'vA' }),
          base: 'home' as TrackerBaseDto,
        },
      },
    );
    act(() => {
      harness.resolve(ok(detail({ generation: 5, villageId: 'vA', villageName: 'A 村' })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    expect(result.current.state.payload?.villageName).toBe('A 村');
    rerender({
      snap: snapshot({ generation: 6, selectedVillageId: 'vB' }),
      base: 'home' as TrackerBaseDto,
    });
    // subject 切换：旧 payload 立即清除，不等新请求返回。
    expect(result.current.state.status).toBe('loading');
    expect(result.current.state.payload).toBeNull();
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(2);
    });
    act(() => {
      harness.resolveAt(0, ok(detail({ generation: 6, villageId: 'vB', villageName: 'B 村' })));
    });
    await waitFor(() => {
      expect(result.current.state.payload?.villageName).toBe('B 村');
    });
  });

  it('P2b：切村庄后新请求失败，只显示新 error 不泄漏旧村数据', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap, base }) => useVillageDetail(harness.bridge, snap, base),
      {
        initialProps: {
          snap: snapshot({ generation: 5, selectedVillageId: 'vA' }),
          base: 'home' as TrackerBaseDto,
        },
      },
    );
    act(() => {
      harness.resolve(ok(detail({ generation: 5, villageId: 'vA', villageName: 'A 村' })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    rerender({
      snap: snapshot({ generation: 6, selectedVillageId: 'vB' }),
      base: 'home' as TrackerBaseDto,
    });
    act(() => {
      harness.resolve(err('B 加载失败'));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('error');
    });
    expect(result.current.state.payload).toBeNull();
    expect(result.current.state.lastError).toMatch(/B 加载失败/);
  });

  it('P2c：切 base 即丢旧 last-good；同 subject 刷新失败仍保留', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap, base }) => useVillageDetail(harness.bridge, snap, base),
      {
        initialProps: {
          snap: snapshot({ generation: 5, selectedVillageId: 'v1' }),
          base: 'home' as TrackerBaseDto,
        },
      },
    );
    act(() => {
      harness.resolve(ok(detail({ generation: 5 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    rerender({
      snap: snapshot({ generation: 5, selectedVillageId: 'v1' }),
      base: 'builder' as TrackerBaseDto,
    });
    expect(result.current.state.status).toBe('loading');
    expect(result.current.state.payload).toBeNull();
    act(() => {
      harness.resolve(ok(detail({ generation: 5, base: 'builder' })));
    });
    await waitFor(() => {
      expect(result.current.state.payload?.base).toBe('builder');
    });
    // 同 subject 刷新失败：保留 last-good。
    rerender({
      snap: snapshot({ generation: 6, selectedVillageId: 'v1' }),
      base: 'builder' as TrackerBaseDto,
    });
    act(() => {
      harness.resolve(err('刷新失败'));
    });
    await waitFor(() => {
      expect(result.current.state.lastError).toMatch(/刷新失败/);
    });
    expect(result.current.state.status).toBe('ready');
    expect(result.current.state.payload?.base).toBe('builder');
  });

  it('P2d：切村庄后旧请求的迟到成功不得写入新上下文', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap, base }) => useVillageDetail(harness.bridge, snap, base),
      {
        initialProps: {
          snap: snapshot({ generation: 5, selectedVillageId: 'vA' }),
          base: 'home' as TrackerBaseDto,
        },
      },
    );
    rerender({
      snap: snapshot({ generation: 6, selectedVillageId: 'vB' }),
      base: 'home' as TrackerBaseDto,
    });
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(2);
    });
    expect(harness.pendingCount()).toBe(2);
    // A 的迟到成功：subject 已是 vB，丢弃。
    act(() => {
      harness.resolveAt(0, ok(detail({ generation: 5, villageId: 'vA', villageName: 'A 村' })));
    });
    await act(async () => {});
    expect(result.current.state.status).toBe('loading');
    expect(result.current.state.payload).toBeNull();
    act(() => {
      harness.resolveAt(0, ok(detail({ generation: 6, villageId: 'vB', villageName: 'B 村' })));
    });
    await waitFor(() => {
      expect(result.current.state.payload?.villageName).toBe('B 村');
    });
  });
});
