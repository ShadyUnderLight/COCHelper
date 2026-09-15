/** @vitest-environment jsdom */

import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
  AppSnapshotPayload,
  Result,
  TrackerBaseDto,
  VillageDetailPayload,
} from '@coc-helper/contracts';

import type {
  BridgeVillageClient,
  VillageDetailApi,
  VillageDetailTarget,
} from './use-village-detail';
import { useVillageDetail } from './use-village-detail';

type HookProps = {
  readonly snap: AppSnapshotPayload;
  readonly detailTarget: VillageDetailTarget | null;
};
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

function target(villageId: string, base: TrackerBaseDto = 'home') {
  return { villageId, base };
}

function createBridge() {
  const resolvers: Array<(value: Result<VillageDetailPayload>) => void> = [];
  const bridge: BridgeVillageClient = {
    villageDetail: vi.fn(
      async () =>
        await new Promise<Result<VillageDetailPayload>>((resolve) => {
          resolvers.push(resolve);
        }),
    ),
  };
  return {
    bridge,
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
  it('target 为 null 时 idle；route target 驱动查询，不依赖 snapshot.selectedVillageId', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook<VillageDetailApi, HookProps>(
      ({ snap, detailTarget }) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: {
          snap: snapshot({ selectedVillageId: null }),
          detailTarget: null,
        },
      },
    );
    await act(async () => {});
    expect(result.current.state.status).toBe('idle');
    expect(harness.bridge.villageDetail).not.toHaveBeenCalled();
    rerender({
      snap: snapshot({ selectedVillageId: 'v1' }),
      detailTarget: target('v2', 'builder'),
    });
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(1);
    });
    expect(harness.bridge.villageDetail).toHaveBeenCalledWith({
      villageId: 'v2',
      base: 'builder',
    });
    act(() => {
      harness.resolve(ok(detail({ generation: 1, villageId: 'v2', base: 'builder' })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    expect(result.current.state.payload?.villageId).toBe('v2');
  });

  it('A pending → null → 旧 A 响应丢弃 → 再进 A 会发新请求', async () => {
    const harness = createBridge();
    const subjectA = target('v1', 'home');
    const snap = snapshot({ generation: 5 });
    const { result, rerender } = renderHook<VillageDetailApi, HookProps>(
      ({ snap, detailTarget }) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: { snap, detailTarget: subjectA },
      },
    );
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(1);
    });
    expect(harness.pendingCount()).toBe(1);
    rerender({ snap, detailTarget: null });
    act(() => {
      harness.resolve(ok(detail({ generation: 5, villageId: 'v1', villageName: '主村' })));
    });
    await act(async () => {});
    expect(result.current.state.status).toBe('idle');
    rerender({ snap, detailTarget: subjectA });
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(2);
    });
    act(() => {
      harness.resolve(ok(detail({ generation: 5, villageId: 'v1', villageName: '主村' })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    expect(result.current.state.payload?.villageName).toBe('主村');
  });

  it('A success → null → B pending 不得泄漏 A 的 last-good', async () => {
    const harness = createBridge();
    const snap = snapshot({ generation: 5 });
    const subjectA = target('vA', 'home');
    const subjectB = target('vB', 'home');
    const { result, rerender } = renderHook<VillageDetailApi, HookProps>(
      ({ snap, detailTarget }) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: { snap, detailTarget: subjectA },
      },
    );
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolve(ok(detail({ generation: 5, villageId: 'vA', villageName: 'A 村' })));
    });
    await waitFor(() => {
      expect(result.current.state.payload?.villageName).toBe('A 村');
    });
    rerender({ snap, detailTarget: null });
    rerender({ snap, detailTarget: subjectB });
    expect(result.current.state.payload).toBeNull();
    expect(result.current.state.status).toBe('loading');
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(2);
    });
  });

  it('A success → null → B 失败不得保留 A payload', async () => {
    const harness = createBridge();
    const snap = snapshot({ generation: 5 });
    const subjectA = target('vA', 'home');
    const subjectB = target('vB', 'home');
    const { result, rerender } = renderHook<VillageDetailApi, HookProps>(
      ({ snap, detailTarget }) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: { snap, detailTarget: subjectA },
      },
    );
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolve(ok(detail({ generation: 5, villageId: 'vA', villageName: 'A 村' })));
    });
    await waitFor(() => {
      expect(result.current.state.payload?.villageName).toBe('A 村');
    });
    rerender({ snap, detailTarget: null });
    rerender({ snap, detailTarget: subjectB });
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(2);
    });
    act(() => {
      harness.resolve(err('B 失败'));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('error');
    });
    expect(result.current.state.payload).toBeNull();
    expect(result.current.state.lastError).toMatch(/B 失败/);
  });

  it('出现 target 后拉取', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook<VillageDetailApi, HookProps>(
      ({ snap, detailTarget }) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: {
          snap: snapshot({ selectedVillageId: null }),
          detailTarget: null,
        },
      },
    );
    await act(async () => {});
    expect(result.current.state.status).toBe('idle');
    expect(harness.bridge.villageDetail).not.toHaveBeenCalled();
    rerender({ snap: snapshot(), detailTarget: target('v1') });
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
      ({ snap, detailTarget }: HookProps) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: {
          snap: snapshot(),
          detailTarget: target('v1', 'home'),
        },
      },
    );
    act(() => {
      harness.resolve(ok(detail({ generation: 1, base: 'home' })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    rerender({ snap: snapshot(), detailTarget: target('v1', 'builder') });
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
      ({ snap, detailTarget }: HookProps) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: {
          snap: snapshot(),
          detailTarget: target('v1'),
        },
      },
    );
    act(() => {
      harness.resolve(ok(detail({ generation: 1, villageId: 'v1' })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    rerender({ snap: snapshot(), detailTarget: target('v2') });
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
      ({ snap, detailTarget }: HookProps) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: {
          snap: snapshot({ sessionId: 'sA', generation: 50 }),
          detailTarget: target('v1'),
        },
      },
    );
    await waitFor(() => {
      expect(harness.bridge.villageDetail).toHaveBeenCalledTimes(1);
    });
    expect(harness.pendingCount()).toBe(1);
    rerender({
      snap: snapshot({ sessionId: 'sB', generation: 1 }),
      detailTarget: target('v1'),
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
      ({ snap, detailTarget }: HookProps) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: {
          snap: snapshot({ generation: 5 }),
          detailTarget: target('v1'),
        },
      },
    );
    rerender({ snap: snapshot({ generation: 6 }), detailTarget: target('v1') });
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
      ({ snap, detailTarget }: HookProps) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: {
          snap: snapshot({ generation: 1 }),
          detailTarget: target('v1'),
        },
      },
    );
    act(() => {
      harness.resolve(ok(detail({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });
    rerender({ snap: snapshot({ generation: 2 }), detailTarget: target('v1') });
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
      ({ snap, detailTarget }: HookProps) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: {
          snap: snapshot({ generation: 1 }),
          detailTarget: target('v1'),
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
      ({ snap, detailTarget }: HookProps) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: {
          snap: snapshot({ generation: 1 }),
          detailTarget: target('v1'),
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
      ({ snap, detailTarget }: HookProps) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: {
          snap: snapshot({ generation: 5 }),
          detailTarget: target('vA'),
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
      snap: snapshot({ generation: 6 }),
      detailTarget: target('vB'),
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
      ({ snap, detailTarget }: HookProps) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: {
          snap: snapshot({ generation: 5 }),
          detailTarget: target('vA'),
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
      snap: snapshot({ generation: 6 }),
      detailTarget: target('vB'),
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
      ({ snap, detailTarget }: HookProps) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: {
          snap: snapshot({ generation: 5 }),
          detailTarget: target('v1', 'home'),
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
      snap: snapshot({ generation: 5 }),
      detailTarget: target('v1', 'builder'),
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
      snap: snapshot({ generation: 6 }),
      detailTarget: target('v1', 'builder'),
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
      ({ snap, detailTarget }: HookProps) => useVillageDetail(harness.bridge, snap, detailTarget),
      {
        initialProps: {
          snap: snapshot({ generation: 5 }),
          detailTarget: target('vA'),
        },
      },
    );
    rerender({
      snap: snapshot({ generation: 6 }),
      detailTarget: target('vB'),
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
