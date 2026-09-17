/** @vitest-environment jsdom */

import { act, renderHook, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
  ApiRefreshPayload,
  ClanWarStatePayload,
  OperationProgressListener,
  Result,
} from '@coc-helper/contracts';

import { resetClockStoreForTests } from './clock-store';
import { useOfficialClanWar, type BridgeClanWarClient } from './use-official-clan-war';

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

function createBridge() {
  const resolvers: Array<(value: Result<ClanWarStatePayload>) => void> = [];
  const refreshResolvers: Array<(value: Result<ApiRefreshPayload>) => void> = [];
  const progressListeners = new Set<OperationProgressListener>();
  const bridge: BridgeClanWarClient = {
    clanWarState: vi.fn(
      async () =>
        await new Promise<Result<ClanWarStatePayload>>((resolve) => {
          resolvers.push(resolve);
        }),
    ),
    apiRefresh: vi.fn(
      async () =>
        await new Promise<Result<ApiRefreshPayload>>((resolve) => {
          refreshResolvers.push(resolve);
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
    resolve(value: Result<ClanWarStatePayload>) {
      resolvers.shift()?.(value);
    },
    resolveRefresh(value: Result<ApiRefreshPayload>) {
      refreshResolvers.shift()?.(value);
    },
  };
}

afterEach(() => {
  resetClockStoreForTests();
});

describe('useOfficialClanWar（#277-E2）', () => {
  it('clanTag 为 null 时不查询且不自动 refresh', async () => {
    const { bridge } = createBridge();
    renderHook(() => useOfficialClanWar(bridge, snapshot(), null, 'v1'));
    await act(async () => {
      await Promise.resolve();
    });
    expect(bridge.clanWarState).not.toHaveBeenCalled();
    expect(bridge.apiRefresh).not.toHaveBeenCalled();
  });

  it('有 clanTag 时查询缓存，用户 refresh 才发 api.refresh', async () => {
    const { bridge, resolve, resolveRefresh } = createBridge();
    const { result } = renderHook(() =>
      useOfficialClanWar(bridge, snapshot(), '#CLAN01', 'v1'),
    );
    resolve(
      ok({
        generation: 1,
        clanTag: '#CLAN01',
        state: {
          status: 'never',
          parserVersion: 'clan-war-0.1',
          unrecognizedKeys: [],
        },
      }),
    );
    await waitFor(() => {
      expect(result.current.view.clanTag).toBe('#CLAN01');
    });
    expect(bridge.apiRefresh).not.toHaveBeenCalled();

    await act(async () => {
      void result.current.refresh();
    });
    expect(bridge.apiRefresh).toHaveBeenCalledWith(
      expect.objectContaining({ endpoints: ['clanWar'], clanTag: '#CLAN01' }),
    );
    await act(async () => {
      resolveRefresh(ok({ generation: 2, results: [] }));
      await Promise.resolve();
    });
    await act(async () => {
      resolve(
        ok({
          generation: 2,
          clanTag: '#CLAN01',
          state: {
            status: 'success',
            parserVersion: 'clan-war-0.1',
            unrecognizedKeys: [],
            lastGood: { state: 'notInWar', unrecognizedKeys: [] },
          },
        }),
      );
      await Promise.resolve();
    });
    await waitFor(() => {
      expect(result.current.view.phase).toBe('notInWar');
      expect(result.current.refreshing).toBe(false);
    });
  });
});
