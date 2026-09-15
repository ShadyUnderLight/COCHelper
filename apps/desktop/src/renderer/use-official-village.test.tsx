/** @vitest-environment jsdom */

import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
  AppSnapshotPayload,
  ClanStatePayload,
  OperationProgressListener,
  Result,
} from '@coc-helper/contracts';

import { resetClockStoreForTests } from './clock-store';
import { clanFixture, playerFixture } from './official-session';
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

function createBridge() {
  const playerResolvers: Array<(value: Result<ReturnType<typeof playerFixture>>) => void> = [];
  const clanResolvers: Array<(value: Result<ClanStatePayload>) => void> = [];
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
    apiRefresh: vi.fn(async () => ok({ generation: 2, results: [] })),
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
    playerPending() {
      return playerResolvers.length;
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

  it('切村后丢弃旧玩家 last-good，部落归属回到 unknown', async () => {
    const harness = createBridge();
    const { result, rerender } = renderHook<
      OfficialVillageApi,
      { snap: AppSnapshotPayload; villageId: string }
    >(({ snap, villageId }) => useOfficialVillage(harness.bridge, snap, villageId), {
      initialProps: { snap: snapshot(), villageId: 'v1' },
    });
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolvePlayer(ok(playerFixture({ villageId: 'v1', generation: 1 })));
    });
    await waitFor(() => {
      expect(result.current.player.currentClanTag).toBe('#CLAN01');
    });
    rerender({ snap: snapshot({ generation: 2 }), villageId: 'v2' });
    await waitFor(() => {
      expect(result.current.player.summary).toBeNull();
    });
    expect(result.current.clan.affiliation).toBe('unknown');
  });
});
