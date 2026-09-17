/** @vitest-environment jsdom */

import { act, renderHook, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { AppSnapshotPayload, Result } from '@coc-helper/contracts';

import { useResourceQuery } from './use-resource-query';

type Payload = {
  readonly generation: number;
  readonly value: string;
};

function snapshot(): AppSnapshotPayload {
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
    villages: [{ id: 'v1', name: '主村', tag: '#AAA', hasImportedData: true }],
    pendingImport: null,
  };
}

function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

function createFetchHarness() {
  const resolvers: Array<(value: Result<Payload>) => void> = [];
  const fetch = vi.fn(
    async () =>
      await new Promise<Result<Payload>>((resolve) => {
        resolvers.push(resolve);
      }),
  );
  return {
    fetch,
    resolve(value: Result<Payload>) {
      resolvers.shift()?.(value);
    },
    pending() {
      return resolvers.length;
    },
  };
}

afterEach(() => {
  vi.useRealTimers();
});

describe('useResourceQuery', () => {
  it('refresh pending 时 subject→null 会 resolve waiter', async () => {
    const harness = createFetchHarness();
    const { result, rerender } = renderHook(
      ({ subjectKey }: { readonly subjectKey: string | null }) =>
        useResourceQuery<Payload>({
          snapshot: snapshot(),
          subjectKey,
          fetch: harness.fetch,
          extractGeneration: (payload) => payload.generation,
        }),
      { initialProps: { subjectKey: 'subject-a' as string | null } },
    );

    await waitFor(() => {
      expect(harness.fetch).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolve(ok({ generation: 1, value: 'a' }));
    });
    await waitFor(() => {
      expect(result.current.state.kind).toBe('ready');
    });

    let pending: Promise<void> = Promise.resolve();
    act(() => {
      pending = result.current.refresh();
    });
    await waitFor(() => {
      expect(harness.pending()).toBe(1);
    });

    rerender({ subjectKey: null });
    await act(async () => {
      await pending;
    });
    expect(result.current.state.kind).toBe('idle');
  });

  it('pending refresh 后 unmount 不产生 unhandled rejection', async () => {
    const rejections: unknown[] = [];
    const onUnhandled = (event: PromiseRejectionEvent) => {
      rejections.push(event.reason);
      event.preventDefault();
    };
    window.addEventListener('unhandledrejection', onUnhandled);

    const harness = createFetchHarness();
    const { result, unmount } = renderHook(() =>
      useResourceQuery<Payload>({
        snapshot: snapshot(),
        subjectKey: 'subject-a',
        fetch: harness.fetch,
        extractGeneration: (payload) => payload.generation,
      }),
    );

    await waitFor(() => {
      expect(harness.fetch).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolve(ok({ generation: 1, value: 'a' }));
    });
    await waitFor(() => {
      expect(result.current.state.kind).toBe('ready');
    });

    let pending: Promise<void> = Promise.resolve();
    act(() => {
      pending = result.current.refresh();
    });
    await waitFor(() => {
      expect(harness.pending()).toBe(1);
    });

    unmount();
    await act(async () => {
      await pending;
    });

    window.removeEventListener('unhandledrejection', onUnhandled);
    expect(rejections).toEqual([]);
  });
});
