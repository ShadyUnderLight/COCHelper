/** @vitest-environment jsdom */

import { act, cleanup, render, renderHook, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
  AppSnapshotPayload,
  ApiRefreshPayload,
  ClanStatePayload,
  OperationProgressListener,
  OperationProgressPayload,
  Result,
} from '@coc-helper/contracts';

import { clockStore, resetClockStoreForTests } from './clock-store';
import { clanFixture, playerFixture } from './official-session.fixtures';
import {
  useOfficialVillage,
  type BridgeOfficialClient,
  type OfficialVillageApi,
} from './use-official-village';

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

function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

function err(message: string): Result<never> {
  return {
    ok: false,
    error: {
      kind: 'internal',
      code: 'refresh-failed',
      messageKey: 'refresh.failed',
      message,
    },
  };
}

function createBridge() {
  const playerResolvers: Array<(value: Result<ReturnType<typeof playerFixture>>) => void> = [];
  const clanResolvers: Array<(value: Result<ClanStatePayload>) => void> = [];
  const refreshResolvers: Array<(value: Result<ApiRefreshPayload>) => void> = [];
  const progressListeners = new Set<OperationProgressListener>();
  const bridge: BridgeOfficialClient = {
    playerState: vi.fn(
      async () =>
        await new Promise<Result<ReturnType<typeof playerFixture>>>((resolve) => {
          playerResolvers.push(resolve);
        }),
    ),
    clanState: vi.fn(
      async () =>
        await new Promise<Result<ClanStatePayload>>((resolve) => {
          clanResolvers.push(resolve);
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
    resolvePlayer(value: Result<ReturnType<typeof playerFixture>>) {
      playerResolvers.shift()?.(value);
    },
    resolveClan(value: Result<ClanStatePayload>) {
      clanResolvers.shift()?.(value);
    },
    resolveRefresh(value: Result<ApiRefreshPayload>) {
      refreshResolvers.shift()?.(value);
    },
    emitProgress(payload: OperationProgressPayload) {
      for (const listener of progressListeners) {
        listener(payload);
      }
    },
    playerPending() {
      return playerResolvers.length;
    },
    refreshPending() {
      return refreshResolvers.length;
    },
  };
}

afterEach(() => {
  cleanup();
  resetClockStoreForTests();
});

describe('useOfficialVillage（#277-E1）', () => {
  it('villageId 为 null 不请求，且不自动 refresh', async () => {
    const harness = createBridge();
    const { result } = renderHook<OfficialVillageApi, { villageId: string | null }>(
      ({ villageId }) => useOfficialVillage(harness.bridge, snapshot(), villageId),
      { initialProps: { villageId: null } },
    );
    await act(async () => {});
    expect(result.current.player.queryStatus).toBe('idle');
    expect(harness.bridge.playerState).not.toHaveBeenCalled();
    expect(harness.bridge.apiRefresh).not.toHaveBeenCalled();
  });

  it('villageId 为 null 不订阅秒级 clock', () => {
    vi.useFakeTimers();
    resetClockStoreForTests(1000);
    const harness = createBridge();
    renderHook(() => useOfficialVillage(harness.bridge, snapshot(), null));
    vi.advanceTimersByTime(3000);
    expect(clockStore.getSnapshot()).toBe(1000);
    vi.useRealTimers();
  });

  it('有 villageId 时查询玩家，不自动 api.refresh；有 currentClanTag 再查部落', async () => {
    const harness = createBridge();
    const { result } = renderHook(() => useOfficialVillage(harness.bridge, snapshot(), 'v1'));
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    expect(harness.bridge.apiRefresh).not.toHaveBeenCalled();
    expect(harness.bridge.clanState).not.toHaveBeenCalled();
    act(() => {
      harness.resolvePlayer(ok(playerFixture({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.player.summary?.name).toBe('Hero');
    });
    await waitFor(() => {
      expect(harness.bridge.clanState).toHaveBeenCalledWith({ clanTag: '#CLAN01' });
    });
    act(() => {
      harness.resolveClan(ok(clanFixture({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.clan.summary?.name).toBe('测试部落');
    });
    expect(result.current.clan.affiliation).toBe('tagged');
  });

  it('切村后的第一次 render 即丢弃旧玩家 last-good，且不沿用旧 clan tag', async () => {
    const harness = createBridge();
    const snap = snapshot();
    const v2Frames: Array<{
      readonly playerName: string | null;
      readonly clanTag: string | null;
      readonly clanName: string | null;
    }> = [];
    function Probe(props: { readonly villageId: string }) {
      const api = useOfficialVillage(harness.bridge, snap, props.villageId);
      if (props.villageId === 'v2') {
        v2Frames.push({
          playerName: api.player.summary?.name ?? null,
          clanTag: api.player.currentClanTag,
          clanName: api.clan.summary?.name ?? null,
        });
      }
      return null;
    }
    const view = render(<Probe villageId="v1" />);
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolvePlayer(ok(playerFixture({ villageId: 'v1', generation: 1 })));
    });
    await waitFor(() => {
      expect(harness.bridge.clanState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolveClan(ok(clanFixture({ generation: 1 })));
    });
    await waitFor(() => {
      expect(harness.bridge.clanState).toHaveBeenCalledTimes(1);
    });
    view.rerender(<Probe villageId="v2" />);
    expect(v2Frames.length).toBeGreaterThan(0);
    expect(v2Frames.every((frame) => frame.playerName === null)).toBe(true);
    expect(v2Frames.every((frame) => frame.clanTag === null)).toBe(true);
    expect(v2Frames.every((frame) => frame.clanName === null)).toBe(true);
  });

  it('apiRefresh ok:false 把错误展示到玩家卡，不清成静默成功', async () => {
    const harness = createBridge();
    const { result } = renderHook(() => useOfficialVillage(harness.bridge, snapshot(), 'v1'));
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolvePlayer(ok(playerFixture({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.player.canRefresh).toBe(true);
    });
    await act(async () => {
      const pending = result.current.refreshPlayer();
      harness.resolveRefresh(err('提交官方缓存失败'));
      await pending;
    });
    expect(result.current.player.commandError).toMatch(/提交官方缓存失败/);
    expect(result.current.playerRefreshing).toBe(false);
  });

  it('切村时取消旧村庄的在途刷新，新村庄不得继承 refreshing', async () => {
    const harness = createBridge();
    const snap = snapshot();
    const v2Frames: Array<{
      readonly playerRefreshing: boolean;
      readonly clanRefreshing: boolean;
    }> = [];
    const latest: { current: OfficialVillageApi | null } = { current: null };
    function Probe(props: { readonly villageId: string }) {
      const api = useOfficialVillage(harness.bridge, snap, props.villageId);
      latest.current = api;
      if (props.villageId === 'v2') {
        v2Frames.push({
          playerRefreshing: api.playerRefreshing,
          clanRefreshing: api.clanRefreshing,
        });
      }
      return null;
    }
    const view = render(<Probe villageId="v1" />);
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolvePlayer(ok(playerFixture({ villageId: 'v1', generation: 1 })));
    });
    await waitFor(() => {
      expect(latest.current?.player.canRefresh).toBe(true);
    });
    act(() => {
      void latest.current?.refreshPlayer();
    });
    await waitFor(() => {
      expect(harness.refreshPending()).toBe(1);
    });
    expect(latest.current?.playerRefreshing).toBe(true);
    const refreshRequest = vi.mocked(harness.bridge.apiRefresh).mock.calls[0]?.[0];
    view.rerender(<Probe villageId="v2" />);
    expect(v2Frames.length).toBeGreaterThan(0);
    expect(v2Frames.every((frame) => frame.playerRefreshing === false)).toBe(true);
    expect(harness.bridge.cancel).toHaveBeenCalledWith({ requestId: refreshRequest?.requestId });
    await act(async () => {
      await latest.current?.refreshClan();
    });
    expect(harness.bridge.apiRefresh).toHaveBeenCalledTimes(1);
  });

  it('operation.progress failed 把 message 展示到卡片', async () => {
    const harness = createBridge();
    const { result } = renderHook(() => useOfficialVillage(harness.bridge, snapshot(), 'v1'));
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolvePlayer(ok(playerFixture({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.player.canRefresh).toBe(true);
    });
    act(() => {
      void result.current.refreshPlayer();
    });
    await waitFor(() => {
      expect(harness.refreshPending()).toBe(1);
    });
    const requestId = vi.mocked(harness.bridge.apiRefresh).mock.calls[0]?.[0]?.requestId;
    expect(requestId).toBeDefined();
    act(() => {
      harness.emitProgress({
        operationId: requestId as string,
        phase: 'failed',
        generation: 1,
        message: '写盘失败',
      });
    });
    expect(result.current.player.commandError).toBe('写盘失败');
    expect(result.current.playerRefreshing).toBe(false);
  });
});
