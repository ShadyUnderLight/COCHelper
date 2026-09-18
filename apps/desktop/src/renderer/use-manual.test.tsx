/** @vitest-environment jsdom */

import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { AppSnapshotPayload, ManualStatePayload, Result } from '@coc-helper/contracts';

import { advanceSessionCursor } from './manual-command-cursor';
import { recordFixture } from './overview-session';
import { useManual, type BridgeManualClient } from './use-manual';

function snapshot(overrides: Partial<AppSnapshotPayload> = {}): AppSnapshotPayload {
  return {
    sessionId: 'session-a',
    generation: 5,
    availability: 'available',
    villageStatus: 'available',
    villageError: null,
    canWrite: true,
    hasPendingJournal: false,
    recoveryNotice: null,
    selectedVillageId: 'v1',
    villages: [{ id: 'v1', name: '主村', tag: '#AAA', hasImportedData: true }],
    pendingImport: null,
    ...overrides,
  };
}

function manualStatePayload(overrides: Partial<ManualStatePayload> = {}): ManualStatePayload {
  return {
    generation: 5,
    villageId: 'v1',
    status: 'available',
    error: null,
    baselineRevision: 'rev',
    baselineLineageId: 'line',
    activeRecordCount: 0,
    itemStateCount: 1,
    activeRecords: [],
    lastSettleAtMs: null,
    lastImportAtMs: 1_000,
    stateUpdatedAtMs: 1_000,
    ...overrides,
  };
}

function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

function err(message: string, code = 'unavailable'): Result<never> {
  return {
    ok: false,
    error: { kind: 'validation', code, messageKey: 'app.validation', message },
  };
}

function createBridge() {
  const stateResolvers: Array<(value: Result<ManualStatePayload>) => void> = [];
  let nextStart: Result<{ generation: number; record: ManualStatePayload['activeRecords'][0] }> =
    ok({
      generation: 6,
      record: {
        recordId: '00000000-0000-4000-8000-000000000001',
        status: 'active',
        fromLevel: 5,
        targetLevel: 6,
        quantity: 1,
        startedAtMs: 1_000,
        expectedEndAtMs: 2_000,
      },
    });
  let nextCancel: Result<{ generation: number; record: ManualStatePayload['activeRecords'][0] }> =
    ok({
      generation: 7,
      record: {
        recordId: '00000000-0000-4000-8000-000000000001',
        status: 'cancelled',
        fromLevel: 5,
        targetLevel: 6,
        quantity: 1,
        startedAtMs: 1_000,
        expectedEndAtMs: 2_000,
      },
    });
  const bridge: BridgeManualClient = {
    manualState: vi.fn(
      async () =>
        await new Promise<Result<ManualStatePayload>>((resolve) => {
          stateResolvers.push(resolve);
        }),
    ),
    manualStart: vi.fn(async () => nextStart),
    manualCancel: vi.fn(async () => nextCancel),
    manualAdjust: vi.fn(async () =>
      ok({
        generation: 8,
        record: {
          recordId: '00000000-0000-4000-8000-000000000001',
          status: 'active',
          fromLevel: 5,
          targetLevel: 6,
          quantity: 1,
          startedAtMs: 1_000,
          expectedEndAtMs: 2_000,
        },
      }),
    ),
    manualSettle: vi.fn(async () => ok({ generation: 9, settledCount: 0 })),
  };
  return {
    bridge,
    resolveState(value: Result<ManualStatePayload>) {
      stateResolvers.shift()?.(value);
    },
    setNextCancel(
      value: Result<{ generation: number; record: ManualStatePayload['activeRecords'][0] }>,
    ) {
      nextCancel = value;
    },
  };
}

const startableItem = {
  ...recordFixture().item,
  manualRowStart: {
    fromLevel: 5,
    targetLevel: 6,
    quantity: 1,
    sourceKind: 'row' as const,
  },
};

async function waitReady(harness: ReturnType<typeof createBridge>, generation = 5): Promise<void> {
  await waitFor(() => {
    expect(harness.bridge.manualState).toHaveBeenCalled();
  });
  act(() => {
    harness.resolveState(ok(manualStatePayload({ generation })));
  });
}

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe('manual-command-cursor', () => {
  it('snapshot 滞后时不回退 mutation 后的 generation', () => {
    const cursorRef = { current: { sessionId: 'session-a', generation: 6 } };
    advanceSessionCursor(cursorRef, 'session-a', 5);
    expect(cursorRef.current.generation).toBe(6);
  });
});

describe('useManual（#277-F）', () => {
  it('bridge reject 时设置 commandError 且不抛出', async () => {
    const harness = createBridge();
    harness.bridge.manualStart = vi.fn(async () => {
      throw new Error('IPC 通道异常');
    });
    const { result } = renderHook(() => useManual(harness.bridge, snapshot(), 'v1'));
    await waitReady(harness);
    await waitFor(() => expect(result.current.view.status).toBe('ready'));

    let settled = false;
    await act(async () => {
      settled = await result.current.startRow({
        villageId: 'v1',
        item: startableItem,
        base: 'home',
      });
    });
    expect(settled).toBe(false);
    expect(result.current.commandError).toBe('IPC 通道异常');
  });

  it('mutation 成功后连续命令使用新 generation', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useManual(harness.bridge, snapshot({ generation: 5 }), 'v1'),
    );
    await waitReady(harness, 5);
    await waitFor(() => expect(result.current.view.status).toBe('ready'));

    await act(async () => {
      await result.current.startRow({ villageId: 'v1', item: startableItem, base: 'home' });
    });
    expect(harness.bridge.manualStart).toHaveBeenCalledWith(
      expect.objectContaining({ expectedGeneration: 5 }),
    );

    await act(async () => {
      await result.current.cancel({
        villageId: 'v1',
        recordId: '00000000-0000-4000-8000-000000000001',
      });
    });
    expect(harness.bridge.manualCancel).toHaveBeenCalledWith(
      expect.objectContaining({ expectedGeneration: 6 }),
    );
  });

  it('切换村庄后连续命令使用新村庄 cursor', async () => {
    const harness = createBridge();
    harness.setNextCancel(
      ok({
        generation: 10,
        record: {
          recordId: '00000000-0000-4000-8000-000000000002',
          status: 'cancelled',
          fromLevel: 1,
          targetLevel: 2,
          quantity: 1,
          startedAtMs: 1,
          expectedEndAtMs: 2,
        },
      }),
    );
    const { result, rerender } = renderHook(
      ({ snap, villageId }) => useManual(harness.bridge, snap, villageId),
      { initialProps: { snap: snapshot({ generation: 8 }), villageId: 'v1' as string | null } },
    );
    await waitReady(harness, 8);
    await waitFor(() => expect(result.current.view.status).toBe('ready'));

    rerender({ snap: snapshot({ generation: 9 }), villageId: 'v2' });
    await waitFor(() => expect(harness.bridge.manualState).toHaveBeenCalledTimes(2));
    act(() => {
      harness.resolveState(ok(manualStatePayload({ villageId: 'v2', generation: 9 })));
    });
    await waitFor(() => expect(result.current.view.payload?.villageId).toBe('v2'));

    await act(async () => {
      await result.current.cancel({
        villageId: 'v2',
        recordId: '00000000-0000-4000-8000-000000000002',
      });
    });
    expect(harness.bridge.manualCancel).toHaveBeenCalledWith(
      expect.objectContaining({ expectedGeneration: 9, villageId: 'v2' }),
    );
  });

  it('查询失败保留 last-good 且 view.lastError 可见', async () => {
    const harness = createBridge();
    const { result } = renderHook(() => useManual(harness.bridge, snapshot(), 'v1'));
    await waitReady(harness);
    await waitFor(() => expect(result.current.view.payload).not.toBeNull());

    act(() => {
      void result.current.refresh();
    });
    await waitFor(() => expect(harness.bridge.manualState).toHaveBeenCalledTimes(2));
    act(() => {
      harness.resolveState(err('手动升级状态查询失败'));
    });
    await waitFor(() => expect(result.current.view.lastError).toContain('手动升级状态查询失败'));
    expect(result.current.view.payload).not.toBeNull();
  });
});
