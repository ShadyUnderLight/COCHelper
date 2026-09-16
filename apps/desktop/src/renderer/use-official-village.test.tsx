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
    villages: [{ id: 'v1', name: '主村', tag: '#AAA', hasImportedData: true }],
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
  vi.useRealTimers();
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

  it('有 villageId 时也不订阅秒级 clock', () => {
    vi.useFakeTimers();
    resetClockStoreForTests(1000);
    const harness = createBridge();
    const renders = { n: 0 };
    renderHook(() => {
      renders.n += 1;
      return useOfficialVillage(harness.bridge, snapshot(), 'v1');
    });
    const afterMount = renders.n;
    vi.advanceTimersByTime(3000);
    expect(clockStore.getSnapshot()).toBe(1000);
    expect(renders.n).toBe(afterMount);
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

  it('A 无 last-good 查询失败后切 B，任何一帧都不得出现 A 的查询错误', async () => {
    const harness = createBridge();
    const snap = snapshot();
    const v2Frames: Array<{
      readonly lastQueryError: string | null;
      readonly queryStatus: string;
    }> = [];
    const latest: { current: OfficialVillageApi | null } = { current: null };
    function Probe(props: { readonly villageId: string }) {
      const api = useOfficialVillage(harness.bridge, snap, props.villageId);
      latest.current = api;
      if (props.villageId === 'v2') {
        v2Frames.push({
          lastQueryError: api.player.lastQueryError,
          queryStatus: api.player.queryStatus,
        });
      }
      return null;
    }
    const view = render(<Probe villageId="v1" />);
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolvePlayer(err('A 查询失败'));
    });
    await waitFor(() => {
      expect(latest.current?.player.lastQueryError).toMatch(/A 查询失败/);
    });
    view.rerender(<Probe villageId="v2" />);
    expect(v2Frames.length).toBeGreaterThan(0);
    expect(
      v2Frames.every(
        (frame) => frame.lastQueryError === null || !frame.lastQueryError.includes('A 查询失败'),
      ),
    ).toBe(true);
  });

  it('切走 subject 后真正清空 commandError，切回 A 不得复活', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook<OfficialVillageApi, { villageId: string }>(
      ({ villageId }) => useOfficialVillage(harness.bridge, snapshot(), villageId),
      { initialProps: { villageId: 'v1' } },
    );
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolvePlayer(ok(playerFixture({ villageId: 'v1', generation: 1 })));
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
    rerender({ villageId: 'v2' });
    expect(result.current.player.commandError).toBeNull();
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(2);
    });
    act(() => {
      harness.resolvePlayer(
        ok(playerFixture({ villageId: 'v2', generation: 1, playerTag: '#BBB' })),
      );
    });
    rerender({ villageId: 'v1' });
    expect(result.current.player.commandError).toBeNull();
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

  it('同 village 换 player tag 的第一帧就丢掉 A 的玩家/部落，并 cancel 旧操作', async () => {
    const harness = createBridge();
    const bFrames: Array<{
      readonly playerName: string | null;
      readonly playerTag: string | null;
      readonly clanTag: string | null;
      readonly clanName: string | null;
      readonly playerRefreshing: boolean;
      readonly clanRefreshing: boolean;
      readonly commandError: string | null;
    }> = [];
    const latest: { current: OfficialVillageApi | null } = { current: null };
    function Probe(props: { readonly snap: AppSnapshotPayload }) {
      const api = useOfficialVillage(harness.bridge, props.snap, 'v1');
      latest.current = api;
      if (props.snap.villages[0]?.tag === '#BBB') {
        bFrames.push({
          playerName: api.player.summary?.name ?? null,
          playerTag: api.player.playerTag,
          clanTag: api.player.currentClanTag,
          clanName: api.clan.summary?.name ?? null,
          playerRefreshing: api.playerRefreshing,
          clanRefreshing: api.clanRefreshing,
          commandError: api.player.commandError,
        });
      }
      return null;
    }
    const view = render(<Probe snap={snapshot({ generation: 1 })} />);
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolvePlayer(ok(playerFixture({ villageId: 'v1', generation: 1 })));
    });
    await waitFor(() => {
      expect(harness.bridge.clanState).toHaveBeenCalledWith({ clanTag: '#CLAN01' });
    });
    act(() => {
      harness.resolveClan(ok(clanFixture({ generation: 1 })));
    });
    await waitFor(() => {
      expect(latest.current?.clan.summary?.name).toBe('测试部落');
    });
    await act(async () => {
      const pending = latest.current?.refreshPlayer();
      harness.resolveRefresh(err('A 的刷新失败'));
      await pending;
    });
    expect(latest.current?.player.commandError).toMatch(/A 的刷新失败/);
    act(() => {
      void latest.current?.refreshClan();
    });
    await waitFor(() => {
      expect(harness.refreshPending()).toBe(1);
    });
    const clanRefreshRequest = vi.mocked(harness.bridge.apiRefresh).mock.calls.at(-1)?.[0];
    expect(clanRefreshRequest?.clanTag).toBe('#CLAN01');
    const refreshCallsBeforeSwitch = vi.mocked(harness.bridge.apiRefresh).mock.calls.length;
    view.rerender(
      <Probe
        snap={snapshot({
          generation: 2,
          villages: [{ id: 'v1', name: '主村', tag: '#BBB', hasImportedData: true }],
        })}
      />,
    );
    expect(bFrames.length).toBeGreaterThan(0);
    expect(
      bFrames.every(
        (frame) =>
          frame.playerName === null &&
          frame.playerTag === null &&
          frame.clanTag === null &&
          frame.clanName === null &&
          frame.playerRefreshing === false &&
          frame.clanRefreshing === false &&
          frame.commandError === null,
      ),
    ).toBe(true);
    expect(harness.bridge.cancel).toHaveBeenCalledWith({
      requestId: clanRefreshRequest?.requestId,
    });
    await act(async () => {
      await latest.current?.refreshClan();
    });
    expect(vi.mocked(harness.bridge.apiRefresh).mock.calls.length).toBe(refreshCallsBeforeSwitch);
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(2);
    });
    act(() => {
      harness.resolvePlayer(
        ok(
          playerFixture({
            villageId: 'v1',
            generation: 2,
            playerTag: '#BBB',
            currentClanTag: '#CLAN02',
            summary: {
              ...playerFixture().summary!,
              name: 'Bravo',
              tag: '#BBB',
              clanName: 'B部落',
              clanTag: '#CLAN02',
            },
          }),
        ),
      );
    });
    await waitFor(() => {
      expect(latest.current?.player.summary?.name).toBe('Bravo');
    });
    expect(latest.current?.player.playerTag).toBe('#BBB');
    expect(latest.current?.player.currentClanTag).toBe('#CLAN02');
    expect(latest.current?.clan.summary).toBeNull();
    expect(bFrames.every((frame) => frame.playerName !== 'Hero')).toBe(true);
  });

  it('snapshot 原始 tag 带空白时仍显示 Main 的 canonical player payload', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useOfficialVillage(
        harness.bridge,
        snapshot({
          villages: [{ id: 'v1', name: '主村', tag: ' #AAA ', hasImportedData: true }],
        }),
        'v1',
      ),
    );
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolvePlayer(ok(playerFixture({ villageId: 'v1', playerTag: '#AAA' })));
    });
    await waitFor(() => {
      expect(result.current.player.queryStatus).toBe('ready');
    });
    expect(result.current.player.summary?.name).toBe('Hero');
    expect(result.current.player.playerTag).toBe('#AAA');
    expect(result.current.player.canRefresh).toBe(true);
  });

  it('Main 判定无效的非空 village tag 进入缺少标签，而不是永久 loading', async () => {
    const harness = createBridge();
    const { result } = renderHook(() =>
      useOfficialVillage(
        harness.bridge,
        snapshot({
          villages: [{ id: 'v1', name: '主村', tag: '#aaa', hasImportedData: true }],
        }),
        'v1',
      ),
    );
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolvePlayer(
        ok(
          playerFixture({
            villageId: 'v1',
            playerTag: null,
            currentClanTag: null,
            summary: null,
            state: null,
          }),
        ),
      );
    });
    await waitFor(() => {
      expect(result.current.player.queryStatus).toBe('ready');
    });
    expect(result.current.player.playerTag).toBeNull();
    expect(result.current.player.summary).toBeNull();
    expect(result.current.player.canRefresh).toBe(false);
    expect(result.current.player.refreshStatus).toBeNull();
  });

  it('同 village tag A→B 会 cancel 在途 player refresh，迟到结果不得作用于 B', async () => {
    const harness = createBridge();
    const bFrames: Array<{
      readonly playerRefreshing: boolean;
      readonly commandError: string | null;
      readonly playerName: string | null;
    }> = [];
    const latest: { current: OfficialVillageApi | null } = { current: null };
    function Probe(props: { readonly snap: AppSnapshotPayload }) {
      const api = useOfficialVillage(harness.bridge, props.snap, 'v1');
      latest.current = api;
      if (props.snap.villages[0]?.tag === '#BBB') {
        bFrames.push({
          playerRefreshing: api.playerRefreshing,
          commandError: api.player.commandError,
          playerName: api.player.summary?.name ?? null,
        });
      }
      return null;
    }
    const view = render(<Probe snap={snapshot({ generation: 1 })} />);
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
    const playerRefreshRequest = vi.mocked(harness.bridge.apiRefresh).mock.calls[0]?.[0];
    expect(playerRefreshRequest?.endpoints).toEqual(['player']);
    view.rerender(
      <Probe
        snap={snapshot({
          generation: 2,
          villages: [{ id: 'v1', name: '主村', tag: '#BBB', hasImportedData: true }],
        })}
      />,
    );
    expect(bFrames.length).toBeGreaterThan(0);
    expect(bFrames.every((frame) => frame.playerRefreshing === false)).toBe(true);
    expect(bFrames.every((frame) => frame.commandError === null)).toBe(true);
    expect(bFrames.every((frame) => frame.playerName === null)).toBe(true);
    expect(harness.bridge.cancel).toHaveBeenCalledWith({
      requestId: playerRefreshRequest?.requestId,
    });
    await act(async () => {
      harness.resolveRefresh(ok({ generation: 3, results: [] }));
      harness.emitProgress({
        operationId: playerRefreshRequest?.requestId as string,
        phase: 'failed',
        generation: 3,
        message: '迟到的 A 失败',
      });
    });
    expect(latest.current?.player.commandError).toBeNull();
    expect(latest.current?.playerRefreshing).toBe(false);
    expect(latest.current?.player.summary).toBeNull();
  });

  it('apiRefresh ok 后强制重查并展示新 summary', async () => {
    const harness = createBridge();
    const { result } = renderHook(() => useOfficialVillage(harness.bridge, snapshot(), 'v1'));
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolvePlayer(ok(playerFixture({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.player.summary?.name).toBe('Hero');
    });
    await act(async () => {
      const pending = result.current.refreshPlayer();
      harness.resolveRefresh(ok({ generation: 2, results: [] }));
      await pending;
    });
    expect(result.current.playerRefreshing).toBe(false);
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(2);
    });
    act(() => {
      harness.resolvePlayer(
        ok(
          playerFixture({
            generation: 2,
            summary: { ...playerFixture().summary!, name: 'NewHero' },
          }),
        ),
      );
    });
    await waitFor(() => {
      expect(result.current.player.summary?.name).toBe('NewHero');
    });
    expect(result.current.playerRefreshing).toBe(false);
  });

  it('refreshClan ok 且不发 progress 也会结束 refreshing', async () => {
    const harness = createBridge();
    const { result } = renderHook(() => useOfficialVillage(harness.bridge, snapshot(), 'v1'));
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolvePlayer(ok(playerFixture({ generation: 1 })));
    });
    await waitFor(() => {
      expect(harness.bridge.clanState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolveClan(ok(clanFixture({ generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.clan.summary?.name).toBe('测试部落');
    });
    await act(async () => {
      const pending = result.current.refreshClan();
      harness.resolveRefresh(ok({ generation: 2, results: [] }));
      await pending;
    });
    expect(result.current.clanRefreshing).toBe(false);
    await waitFor(() => {
      expect(harness.bridge.clanState).toHaveBeenCalledTimes(2);
    });
    act(() => {
      harness.resolveClan(
        ok(
          clanFixture({
            generation: 2,
            summary: { ...clanFixture().summary!, name: '新部落' },
          }),
        ),
      );
    });
    await waitFor(() => {
      expect(result.current.clan.summary?.name).toBe('新部落');
    });
    expect(result.current.clanRefreshing).toBe(false);
  });

  it('completed progress 先到、Promise 后到时 refreshing 仍正确结束', async () => {
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
    expect(result.current.playerRefreshing).toBe(true);
    const requestId = vi.mocked(harness.bridge.apiRefresh).mock.calls[0]?.[0]?.requestId;
    act(() => {
      harness.emitProgress({
        operationId: requestId as string,
        phase: 'completed',
        generation: 2,
      });
    });
    expect(result.current.playerRefreshing).toBe(false);
    await act(async () => {
      harness.resolveRefresh(ok({ generation: 2, results: [] }));
    });
    expect(result.current.playerRefreshing).toBe(false);
  });

  it('旧 refresh Promise 在新 refresh 开始后返回，不得 settle 新 op', async () => {
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
    let firstRefresh: Promise<void> = Promise.resolve();
    act(() => {
      firstRefresh = result.current.refreshPlayer();
    });
    await waitFor(() => {
      expect(harness.refreshPending()).toBe(1);
    });
    const firstRequestId = vi.mocked(harness.bridge.apiRefresh).mock.calls[0]?.[0]?.requestId;
    let secondRefresh: Promise<void> = Promise.resolve();
    act(() => {
      secondRefresh = result.current.refreshPlayer();
    });
    await waitFor(() => {
      expect(harness.refreshPending()).toBe(2);
    });
    expect(harness.bridge.cancel).toHaveBeenCalledWith({ requestId: firstRequestId });
    expect(result.current.playerRefreshing).toBe(true);
    await act(async () => {
      harness.resolveRefresh(ok({ generation: 2, results: [] }));
      await firstRefresh;
    });
    expect(result.current.playerRefreshing).toBe(true);
    await act(async () => {
      harness.resolveRefresh(ok({ generation: 3, results: [] }));
      await secondRefresh;
    });
    expect(result.current.playerRefreshing).toBe(false);
  });
});
