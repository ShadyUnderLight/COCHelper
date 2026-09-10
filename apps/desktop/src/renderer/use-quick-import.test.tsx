/** @vitest-environment jsdom */

import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
  AppSnapshotPayload,
  QuickImportPreviewWire,
  Result,
  StateChangedListener,
} from '@coc-helper/contracts';

import { useQuickImport, type BridgeQuickImportClient } from './use-quick-import';

function snapshot(overrides: Partial<AppSnapshotPayload> = {}): AppSnapshotPayload {
  return {
    sessionId: 'session-a',
    generation: 7,
    availability: 'available',
    villageStatus: 'available',
    villageError: null,
    canWrite: true,
    hasPendingJournal: false,
    recoveryNotice: null,
    selectedVillageId: 'v-a',
    villages: [],
    pendingImport: null,
    ...overrides,
  };
}

function preview(overrides: Partial<QuickImportPreviewWire> = {}): QuickImportPreviewWire {
  return {
    snapshot: {
      importedAt: 1,
      originalText: '{"tag":"#QA","buildings":[]}',
      objectSections: {},
      numericSections: {},
      boosts: {},
      unknownTopLevelKeys: [],
      diagnostics: [],
    },
    targetVillageId: 'v-a',
    targetVillageName: 'A',
    targetVillageTag: '#QA',
    targetVillageHasSnapshot: true,
    replacesSameTag: true,
    destinationDescription: '导入目标：按当前详情页更新「A」',
    ...overrides,
  };
}

function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

function err(message: string, code = 'validation'): Result<never> {
  return {
    ok: false,
    error: { kind: 'validation', code, messageKey: 'app.validation', message },
  };
}

function createBridge() {
  const listeners = new Set<StateChangedListener>();
  const calls: { prepare: unknown[]; commit: unknown[]; discard: unknown[] } = {
    prepare: [],
    commit: [],
    discard: [],
  };
  let nextPrepare: Result<{ generation: number; preview: QuickImportPreviewWire }> = ok({
    generation: 8,
    preview: preview(),
  });
  let nextCommit: Result<{ generation: number; selectedVillageId: string | null }> = ok({
    generation: 9,
    selectedVillageId: 'v-a',
  });
  const nextDiscard: Result<{ generation: number }> = ok({ generation: 9 });
  let nextSnapshot: Result<AppSnapshotPayload> = ok(snapshot({ generation: 8 }));
  const bridge: BridgeQuickImportClient = {
    quickPrepare: vi.fn(async (request: unknown) => {
      calls.prepare.push(request);
      return nextPrepare;
    }),
    quickCommit: vi.fn(
      async (request: unknown) =>
        await new Promise<Result<{ generation: number; selectedVillageId: string | null }>>(
          (resolve) => {
            calls.commit.push(request);
            // 默认立即 resolve；需要测防重提交时由测试改写
            resolve(nextCommit);
          },
        ),
    ),
    quickDiscard: vi.fn(async (request: unknown) => {
      calls.discard.push(request);
      return nextDiscard;
    }),
    snapshot: vi.fn(async () => nextSnapshot),
    onStateChanged: (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
  return {
    bridge,
    calls,
    setNextPrepare(value: typeof nextPrepare) {
      nextPrepare = value;
    },
    setNextCommit(value: typeof nextCommit) {
      nextCommit = value;
    },
    setNextSnapshot(value: typeof nextSnapshot) {
      nextSnapshot = value;
    },
  };
}

afterEach(() => {
  cleanup();
});

describe('useQuickImport', () => {
  it('open 成功后进入 ready，目标固定为打开时村庄', async () => {
    const harness = createBridge();
    const onCommitted = vi.fn();
    const snap = snapshot();
    const { result } = renderHook(() => useQuickImport(harness.bridge, snap, { onCommitted }));
    expect(result.current.state.status).toBe('idle');
    await act(async () => {
      await result.current.open('v-a');
    });
    expect(result.current.state.status).toBe('ready');
    expect(result.current.state.targetVillageId).toBe('v-a');
    expect(result.current.state.preparedGeneration).toBe(8);
    expect(harness.calls.prepare).toEqual([{ targetVillageId: 'v-a' }]);
    expect(onCommitted).not.toHaveBeenCalled();
  });

  it('open 失败（空剪贴板）→ idle + 错误文案，不抛异常', async () => {
    const harness = createBridge();
    harness.setNextPrepare(err('系统剪贴板中没有可用的文本。'));
    const snap = snapshot();
    const { result } = renderHook(() => useQuickImport(harness.bridge, snap, {}));
    await act(async () => {
      await result.current.open('v-a');
    });
    expect(result.current.state.status).toBe('idle');
    expect(result.current.state.lastError).toBe('系统剪贴板中没有可用的文本。');
    expect(result.current.state.preview).toBeNull();
  });

  it('confirm 成功后回到 idle 并通知已提交', async () => {
    const harness = createBridge();
    const onCommitted = vi.fn();
    const snap = snapshot();
    const { result } = renderHook(() => useQuickImport(harness.bridge, snap, { onCommitted }));
    await act(async () => {
      await result.current.open('v-a');
    });
    let committed = false;
    await act(async () => {
      committed = await result.current.confirm();
    });
    expect(committed).toBe(true);
    expect(harness.calls.commit).toEqual([{ expectedGeneration: 8 }]);
    expect(result.current.state.status).toBe('idle');
    expect(result.current.state.preview).toBeNull();
    expect(onCommitted).toHaveBeenCalledTimes(1);
  });

  it('confirm 期间重复调用只提交一次', async () => {
    const harness = createBridge();
    let releaseCommit!: (
      value: Result<{ generation: number; selectedVillageId: string | null }>,
    ) => void;
    harness.bridge.quickCommit = vi.fn(
      async (request: unknown) =>
        await new Promise<Result<{ generation: number; selectedVillageId: string | null }>>(
          (resolve) => {
            harness.calls.commit.push(request);
            releaseCommit = resolve;
          },
        ),
    );
    const snap = snapshot();
    const { result } = renderHook(() => useQuickImport(harness.bridge, snap, {}));
    await act(async () => {
      await result.current.open('v-a');
    });
    let first = false;
    let second = false;
    await act(async () => {
      const pending = result.current.confirm();
      second = await result.current.confirm();
      releaseCommit(ok({ generation: 9, selectedVillageId: 'v-a' }));
      first = await pending;
    });
    expect(first).toBe(true);
    expect(second).toBe(false);
    expect(harness.calls.commit).toHaveLength(1);
  });

  it('generation 变化后 confirm 直接 stale，不发 IPC', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap }) => useQuickImport(harness.bridge, snap, {}),
      { initialProps: { snap: snapshot() } },
    );
    await act(async () => {
      await result.current.open('v-a');
    });
    // 其他动作推进了 generation（例如切村）：preview 已过期
    rerender({ snap: snapshot({ generation: 10 }) });
    let committed = true;
    await act(async () => {
      committed = await result.current.confirm();
    });
    expect(committed).toBe(false);
    expect(harness.calls.commit).toHaveLength(0);
    expect(result.current.state.lastError).toMatch(/过期|变化/);
  });

  it('Main 侧 conflict 也转为 stale 文案并保留重试目标', async () => {
    const harness = createBridge();
    harness.setNextCommit(err('导入状态已过期，请刷新后重试。', 'conflict'));
    const snap = snapshot();
    const { result } = renderHook(() => useQuickImport(harness.bridge, snap, {}));
    await act(async () => {
      await result.current.open('v-a');
    });
    let committed = true;
    await act(async () => {
      committed = await result.current.confirm();
    });
    expect(committed).toBe(false);
    expect(result.current.state.targetVillageId).toBe('v-a');
    expect(result.current.state.lastError).toMatch(/过期/);
    // 重试沿用固定目标
    await act(async () => {
      await result.current.retry();
    });
    expect(harness.calls.prepare).toHaveLength(2);
    expect(harness.calls.prepare[1]).toEqual({ targetVillageId: 'v-a' });
  });

  it('cancel 清理待确认态并回到 idle', async () => {
    const harness = createBridge();
    const snap = snapshot();
    const { result } = renderHook(() => useQuickImport(harness.bridge, snap, {}));
    await act(async () => {
      await result.current.open('v-a');
    });
    await act(async () => {
      await result.current.cancel();
    });
    expect(harness.calls.discard).toEqual([{ expectedGeneration: 8 }]);
    expect(result.current.state.status).toBe('idle');
    expect(result.current.state.preview).toBeNull();
  });

  it('打开后全局 selected 漂移不改变固定目标', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap }) => useQuickImport(harness.bridge, snap, {}),
      { initialProps: { snap: snapshot() } },
    );
    await act(async () => {
      await result.current.open('v-a');
    });
    // 全局切到 v-b，但 generation 未变（测试只验证目标固定；generation 推进走 stale 分支）
    rerender({ snap: snapshot({ selectedVillageId: 'v-b' }) });
    expect(result.current.state.targetVillageId).toBe('v-a');
    let committed = false;
    await act(async () => {
      committed = await result.current.confirm();
    });
    expect(committed).toBe(true);
    expect(harness.calls.commit).toEqual([{ expectedGeneration: 8 }]);
  });

  it('session 切换后重置', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook(
      ({ snap }) => useQuickImport(harness.bridge, snap, {}),
      { initialProps: { snap: snapshot() } },
    );
    await act(async () => {
      await result.current.open('v-a');
    });
    expect(result.current.state.status).toBe('ready');
    rerender({ snap: snapshot({ sessionId: 'session-b', generation: 1 }) });
    expect(result.current.state.status).toBe('idle');
    expect(result.current.state.preview).toBeNull();
  });

  it('上报 Main 桥返回包装异常时转为错误文案', async () => {
    const harness = createBridge();
    harness.bridge.quickPrepare = vi.fn(async () => {
      throw new Error('import.quickPrepare 返回值不合法');
    });
    const snap = snapshot();
    const { result } = renderHook(() => useQuickImport(harness.bridge, snap, {}));
    await act(async () => {
      await result.current.open('v-a');
    });
    expect(result.current.state.status).toBe('idle');
    expect(result.current.state.lastError).toBe('import.quickPrepare 返回值不合法');
  });

  it('close 在 ready 时丢弃并回到 idle', async () => {
    const harness = createBridge();
    const snap = snapshot();
    const { result } = renderHook(() => useQuickImport(harness.bridge, snap, {}));
    await act(async () => {
      await result.current.open('v-a');
    });
    await act(async () => {
      result.current.close();
    });
    await waitFor(() => {
      expect(result.current.state.status).toBe('idle');
    });
    expect(harness.calls.discard).toEqual([{ expectedGeneration: 8 }]);
  });
});
