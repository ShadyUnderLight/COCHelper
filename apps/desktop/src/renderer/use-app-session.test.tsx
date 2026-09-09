/** @vitest-environment jsdom */

import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
  AppSnapshotPayload,
  ImportPreparePayload,
  Result,
  StateChangedListener,
} from '@coc-helper/contracts';

import type { BridgeSnapshotClient } from './app-session';
import { useAppSession } from './use-app-session';

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

function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

function createBridge(initial: AppSnapshotPayload) {
  let current = initial;
  const listeners = new Set<StateChangedListener>();
  let prepareDeferred:
    | {
        resolve: (value: Result<ImportPreparePayload>) => void;
      }
    | undefined;
  let postPrepareSnapshot: Result<AppSnapshotPayload> | null = null;
  let snapshotCalls = 0;

  const bridge: BridgeSnapshotClient = {
    snapshot: vi.fn(async () => {
      snapshotCalls += 1;
      // 首次 boot + prepare 后的 follow-up
      if (snapshotCalls > 1 && postPrepareSnapshot !== null) {
        const value = postPrepareSnapshot;
        postPrepareSnapshot = null;
        return value;
      }
      return ok(current);
    }),
    selectVillage: vi.fn(async () =>
      ok({ generation: current.generation, selectedVillageId: 'v1' }),
    ),
    prepareImport: vi.fn(
      async () =>
        await new Promise<Result<ImportPreparePayload>>((resolve) => {
          prepareDeferred = { resolve };
        }),
    ),
    commitImport: vi.fn(async () =>
      ok({ generation: current.generation + 1, selectedVillageId: null }),
    ),
    discardImport: vi.fn(async () => ok({ generation: current.generation + 1 })),
    recoveryStatus: vi.fn(async () =>
      ok({
        generation: current.generation,
        sessionId: current.sessionId,
        recoveryRequired: false,
        villageStatus: current.villageStatus,
        villageError: null,
        canWrite: current.canWrite,
        hasPendingJournal: false,
        canExport: false,
        canRestoreSavedCopy: false,
        notice: null,
      }),
    ),
    recoveryReset: vi.fn(async () =>
      ok({
        generation: current.generation,
        sessionId: current.sessionId,
        villageStatus: current.villageStatus,
        canWrite: true,
        notice: 'ok',
      }),
    ),
    recoveryRestoreSaved: vi.fn(async () =>
      ok({
        generation: current.generation,
        sessionId: current.sessionId,
        villageStatus: current.villageStatus,
        canWrite: true,
        notice: 'ok',
      }),
    ),
    recoveryRecoverJournal: vi.fn(async () =>
      ok({
        generation: current.generation,
        sessionId: current.sessionId,
        villageStatus: current.villageStatus,
        canWrite: true,
        notice: 'ok',
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
      current = next;
      for (const listener of listeners) {
        listener(next);
      }
    },
    setCurrent(next: AppSnapshotPayload) {
      current = next;
    },
    resolvePrepare(payload: ImportPreparePayload) {
      prepareDeferred?.resolve(ok(payload));
    },
    setPostPrepareSnapshot(result: Result<AppSnapshotPayload>) {
      postPrepareSnapshot = result;
    },
  };
}

afterEach(() => {
  cleanup();
});

describe('useAppSession prepare/commit race', () => {
  it('prepare 后权威态已推进且 follow-up snapshot 被拒时清空 preview，且 commit 不发送', async () => {
    const harness = createBridge(snapshot({ generation: 10 }));
    const { result } = renderHook(() => useAppSession(harness.bridge));

    await waitFor(() => {
      expect(result.current.state.status).toBe('ready');
    });

    act(() => {
      result.current.setPasteText('{"tag":"#ABC"}');
    });

    let preparePromise: Promise<void>;
    act(() => {
      preparePromise = result.current.prepareImport();
    });

    // 模拟 prepare 完成前/后 state.changed 已到 gen 12
    act(() => {
      harness.push(
        snapshot({
          generation: 12,
          pendingImport: { targetKind: 'create', snapshotTag: '#OTHER' },
        }),
      );
    });

    harness.setPostPrepareSnapshot(
      ok(
        snapshot({
          generation: 11,
          pendingImport: { targetKind: 'create', snapshotTag: '#ABC' },
        }),
      ),
    );

    act(() => {
      harness.resolvePrepare({
        generation: 11,
        pending: { targetKind: 'create', snapshotTag: '#ABC' },
        preview: {
          snapshot: {
            importedAt: 1,
            originalText: '{}',
            objectSections: {},
            numericSections: {},
            boosts: {},
            unknownTopLevelKeys: [],
            diagnostics: [],
          },
          targetKind: 'create',
        },
      });
    });

    await act(async () => {
      await preparePromise!;
    });

    expect(result.current.state.preview).toBeNull();
    expect(result.current.state.lastError).toMatch(/状态已变化|预览已过期|刷新快照失败/);

    await act(async () => {
      await result.current.commitImport();
    });
    expect(harness.bridge.commitImport).not.toHaveBeenCalled();
  });
});
