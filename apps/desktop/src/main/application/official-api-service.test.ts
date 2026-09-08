/**
 * OfficialApiService（#276-S4）回归：villageId 索引、取消不落盘、写盘 CAS、loadMore、single-flight。
 */

import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  CoAPIClient,
  DEFAULT_CO_API_CONFIG,
  PERSISTENCE_FILE_NAMES,
  bootstrapPersistence,
  createOfficialAPIState,
  createOfficialStateStore,
  createVillageProfile,
  type ElectronPersistencePaths,
  type OfficialAPIState,
} from '@coc-helper/domain';
import { generateUuid } from '@coc-helper/wire';
import { afterEach, describe, expect, it } from 'vitest';

import { AppAuthoritativeState } from './app-authoritative-state';
import { OfficialApiService } from './official-api-service';
import { PersistentVillageStore } from './persistent-village-store';

class FakeClock {
  constructor(private readonly fixedMs: number) {}
  nowMs(): number {
    return this.fixedMs;
  }
}

function makePaths(root: string): ElectronPersistencePaths {
  return {
    root,
    villages: join(root, PERSISTENCE_FILE_NAMES.villages),
    villagesRecovery: join(root, PERSISTENCE_FILE_NAMES.villagesRecovery),
    selection: join(root, PERSISTENCE_FILE_NAMES.selection),
    snapshotHistory: join(root, PERSISTENCE_FILE_NAMES.snapshotHistory),
    snapshotHistoryJournal: join(root, PERSISTENCE_FILE_NAMES.snapshotHistoryJournal),
    manualTracker: join(root, PERSISTENCE_FILE_NAMES.manualTracker),
    manualTrackerJournal: join(root, PERSISTENCE_FILE_NAMES.manualTrackerJournal),
    snapshotImportJournal: join(root, PERSISTENCE_FILE_NAMES.snapshotImportJournal),
    clans: join(root, PERSISTENCE_FILE_NAMES.clans),
    clanWars: join(root, PERSISTENCE_FILE_NAMES.clanWars),
    clanWarLogs: join(root, PERSISTENCE_FILE_NAMES.clanWarLogs),
    clanCapitals: join(root, PERSISTENCE_FILE_NAMES.clanCapitals),
    playerStates: join(root, PERSISTENCE_FILE_NAMES.playerStates),
    trackedClans: join(root, PERSISTENCE_FILE_NAMES.trackedClans),
    apiTokenEncrypted: join(root, PERSISTENCE_FILE_NAMES.apiTokenEncrypted),
  };
}

describe('OfficialApiService（#276-S4）', () => {
  const directories: string[] = [];

  afterEach(() => {
    for (const directory of directories.splice(0)) {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  function boot(tag: string | null = '#ABCDE123') {
    const root = mkdtempSync(join(tmpdir(), 'coc-official-api-'));
    directories.push(root);
    const paths = makePaths(root);
    const persistence = bootstrapPersistence({ paths });
    const villageId = generateUuid();
    const village = createVillageProfile({ id: villageId, name: '测试村' });
    village.tag = tag;
    const villages = [village];
    const villageStore = new PersistentVillageStore({
      villages: persistence.villages,
      selection: persistence.selection,
      initialVillages: villages,
      initialSelectedVillageId: villageId,
    });
    villageStore.saveVillages(villages);
    const state = new AppAuthoritativeState({
      persistence,
      villageStore,
    });
    return { persistence, state, villageId, root, paths };
  }

  function makeService(
    bootResult: ReturnType<typeof boot>,
    handler: (request: Request, init?: RequestInit) => Promise<Response> | Response,
  ) {
    const client = new CoAPIClient({
      config: { ...DEFAULT_CO_API_CONFIG, maxRetryCount: 0, requestTimeoutMs: 5_000 },
      tokenProvider: () => 'fake-token',
      fetch: async (input, init) => handler(new Request(input, init), init),
    });
    return new OfficialApiService({
      state: bootResult.state,
      clock: new FakeClock(1_700_000_000_000),
      persistence: bootResult.persistence,
      tokenProvider: () => 'fake-token',
      client,
    });
  }

  it('player.state / refresh 按 villageId 存取，重启后仍可读', async () => {
    const bootResult = boot();
    const service = makeService(bootResult, async (request) => {
      if (request.url.includes('/players/')) {
        return Response.json({ tag: '#ABCDE123', name: 'Hero', townHallLevel: 16 });
      }
      return new Response('{}', { status: 404 });
    });

    await service.refresh({
      requestId: 'req-1' as never,
      villageId: bootResult.villageId,
      endpoints: ['player'],
    });
    expect(service.playerState({ villageId: bootResult.villageId }).state?.status).toBe('success');

    const reloaded = bootstrapPersistence({ paths: bootResult.paths });
    expect(reloaded.loadedPlayerStates.states[bootResult.villageId]?.playerTag).toBe('#ABCDE123');
    expect(reloaded.loadedPlayerStates.states['#ABCDE123']).toBeUndefined();
  });

  it('api.refresh player 失败保留 last-good', async () => {
    const bootResult = boot();
    let calls = 0;
    const service = makeService(bootResult, async (request) => {
      calls += 1;
      if (request.url.includes('/players/')) {
        if (calls === 1) {
          return Response.json({ tag: '#ABCDE123', name: 'Hero', townHallLevel: 16 });
        }
        return new Response('', { status: 500 });
      }
      return new Response('{}', { status: 404 });
    });

    await service.refresh({
      requestId: 'req-1' as never,
      villageId: bootResult.villageId,
      endpoints: ['player'],
    });
    await service.refresh({
      requestId: 'req-2' as never,
      villageId: bootResult.villageId,
      endpoints: ['player'],
    });
    const afterFail = service.playerState({ villageId: bootResult.villageId });
    expect(afterFail.state?.status).toBe('failed');
    expect((afterFail.state?.lastGood as { name?: string } | undefined)?.name).toBe('Hero');
  });

  it('fetch 中途 cancel 不落盘、只发一次 cancelled、不 completed', async () => {
    const bootResult = boot();
    const controller = new AbortController();
    const progress: string[] = [];

    const service = makeService(bootResult, async (_request, init) => {
      const signal = init?.signal;
      await new Promise<never>((_resolve, reject) => {
        const fail = () => {
          const error = new Error('aborted');
          error.name = 'AbortError';
          reject(error);
        };
        if (signal?.aborted) {
          fail();
          return;
        }
        signal?.addEventListener('abort', fail, { once: true });
      });
      return Response.json({ tag: '#ABCDE123', name: 'Late' });
    });
    service.subscribeProgress((payload) => {
      progress.push(payload.phase);
    });

    const refreshPromise = service.refresh(
      {
        requestId: 'req-cancel' as never,
        villageId: bootResult.villageId,
        endpoints: ['player'],
      },
      controller.signal,
    );
    await Promise.resolve();
    await Promise.resolve();
    controller.abort();

    await expect(refreshPromise).rejects.toMatchObject({ name: 'AbortError' });
    expect(service.playerState({ villageId: bootResult.villageId }).state).toBeNull();
    expect(progress.filter((phase) => phase === 'cancelled')).toHaveLength(1);
    expect(progress).not.toContain('completed');
  });

  it('clan save 抛错时内存仍是旧 state', async () => {
    const bootResult = boot();
    const service = makeService(bootResult, async () =>
      Response.json({ tag: '#CLAN01', name: 'Clan' }),
    );

    const originalSave = bootResult.persistence.clanStates.save.bind(
      bootResult.persistence.clanStates,
    );
    bootResult.persistence.clanStates.save = () => {
      throw new Error('disk full');
    };

    await expect(
      service.refresh({
        requestId: 'req-save-fail' as never,
        clanTag: '#CLAN01',
        endpoints: ['clan'],
      }),
    ).rejects.toThrow('disk full');
    expect(service.clanState({ clanTag: '#CLAN01' }).state).toBeNull();
    expect(bootResult.state.getGeneration()).toBe(0);

    bootResult.persistence.clanStates.save = originalSave;
  });

  it('warLog.loadMore 无缓存时 fetch 并 persist；无更多时不 bump', async () => {
    const bootResult = boot();
    let warLogCalls = 0;
    const service = makeService(bootResult, async (request) => {
      if (request.url.includes('/warlog')) {
        warLogCalls += 1;
        return Response.json({
          items: [{ result: 'win', endTime: '20260101T000000.000Z' }],
          after: undefined,
        });
      }
      return new Response('{}', { status: 404 });
    });

    const first = await service.loadMoreWarLog({
      requestId: 'req-more-1' as never,
      clanTag: '#CLAN01',
    });
    expect(first.state.status).toBe('success');
    expect(service.warLogState({ clanTag: '#CLAN01' }).state?.status).toBe('success');
    const generationAfterFirst = bootResult.state.getGeneration();
    expect(generationAfterFirst).toBeGreaterThan(0);
    expect(warLogCalls).toBe(1);

    const second = await service.loadMoreWarLog({
      requestId: 'req-more-2' as never,
      clanTag: '#CLAN01',
    });
    expect(second.state.status).toBe('success');
    expect(bootResult.state.getGeneration()).toBe(generationAfterFirst);
    expect(warLogCalls).toBe(1);
  });

  it('同 clanTag 并发 refresh 只发一次网络请求且 generation 只 +1', async () => {
    const bootResult = boot();
    let clanCalls = 0;
    let release: (() => void) | undefined;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const service = makeService(bootResult, async (request) => {
      if (request.url.includes('/clans/') && !request.url.includes('currentwar')) {
        clanCalls += 1;
        await gate;
        return Response.json({ tag: '#CLAN01', name: 'Clan' });
      }
      return new Response('{}', { status: 404 });
    });

    const a = service.refresh({
      requestId: 'req-a' as never,
      clanTag: '#CLAN01',
      endpoints: ['clan'],
    });
    const b = service.refresh({
      requestId: 'req-b' as never,
      clanTag: '#CLAN01',
      endpoints: ['clan'],
    });
    await Promise.resolve();
    expect(clanCalls).toBe(1);
    release?.();
    await Promise.all([a, b]);
    expect(clanCalls).toBe(1);
    expect(service.clanState({ clanTag: '#CLAN01' }).state?.status).toBe('success');
    expect(bootResult.state.getGeneration()).toBe(1);
  });

  it('clan refresh 与 warLog loadMore 不互相合并 flight', async () => {
    const bootResult = boot();
    let clanCalls = 0;
    let warLogCalls = 0;
    let releaseClan: (() => void) | undefined;
    const clanGate = new Promise<void>((resolve) => {
      releaseClan = resolve;
    });
    const service = makeService(bootResult, async (request) => {
      if (request.url.includes('/warlog')) {
        warLogCalls += 1;
        return Response.json({
          items: [{ result: 'win', endTime: '20260101T000000.000Z' }],
          after: undefined,
        });
      }
      if (request.url.includes('/clans/') && !request.url.includes('currentwar')) {
        clanCalls += 1;
        await clanGate;
        return Response.json({ tag: '#CLAN01', name: 'Clan' });
      }
      return new Response('{}', { status: 404 });
    });

    const clanRefresh = service.refresh({
      requestId: 'req-clan' as never,
      clanTag: '#CLAN01',
      endpoints: ['clan'],
    });
    await Promise.resolve();
    expect(clanCalls).toBe(1);

    const loadMore = await service.loadMoreWarLog({
      requestId: 'req-more' as never,
      clanTag: '#CLAN01',
    });
    expect(loadMore.state.status).toBe('success');
    expect(warLogCalls).toBe(1);
    expect(service.warLogState({ clanTag: '#CLAN01' }).state?.status).toBe('success');

    releaseClan?.();
    await clanRefresh;
    expect(clanCalls).toBe(1);
    expect(service.clanState({ clanTag: '#CLAN01' }).state?.status).toBe('success');
  });

  it('village tag A→B 后失败刷新不泄漏 A 的 lastGood / clan', async () => {
    const bootResult = boot('#AAAAA111');
    const service = makeService(bootResult, async (request) => {
      if (request.url.includes('/players/%23AAAAA111')) {
        return Response.json({
          tag: '#AAAAA111',
          name: 'PlayerA',
          townHallLevel: 16,
          clan: { tag: '#CLANA1', name: 'ClanA', clanLevel: 10, badgeUrls: {} },
        });
      }
      if (request.url.includes('/players/%23BBBBB222')) {
        return new Response('', { status: 500 });
      }
      return new Response('{}', { status: 404 });
    });

    await service.refresh({
      requestId: 'req-a' as never,
      villageId: bootResult.villageId,
      endpoints: ['player'],
    });
    expect(service.playerState({ villageId: bootResult.villageId }).state?.status).toBe('success');

    const villages = bootResult.state.listVillages().map((village) => {
      if (village.id !== bootResult.villageId) {
        return village;
      }
      return { ...village, tag: '#BBBBB222' as string | null };
    });
    bootResult.state.getVillageStore().saveVillages(villages);

    expect(service.playerState({ villageId: bootResult.villageId }).state).toBeNull();

    await service.refresh({
      requestId: 'req-b' as never,
      villageId: bootResult.villageId,
      endpoints: ['player'],
    });
    const afterB = service.playerState({ villageId: bootResult.villageId });
    expect(afterB.state?.status).toBe('failed');
    expect(afterB.state?.lastGood).toBeUndefined();
    expect(afterB.playerTag).toBe('#BBBBB222');

    await expect(
      service.refresh({
        requestId: 'req-clan-via-village' as never,
        villageId: bootResult.villageId,
        endpoints: ['clan'],
      }),
    ).rejects.toThrow(/clanTag|部落/);
  });

  it('独立 request 取消 follower 不影响 leader', async () => {
    const bootResult = boot();
    let clanCalls = 0;
    let release: (() => void) | undefined;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const service = makeService(bootResult, async (request, init) => {
      if (request.url.includes('/clans/') && !request.url.includes('currentwar')) {
        clanCalls += 1;
        const signal = init?.signal;
        await new Promise<void>((resolve, reject) => {
          const onAbort = () => {
            const error = new Error('aborted');
            error.name = 'AbortError';
            reject(error);
          };
          if (signal?.aborted) {
            onAbort();
            return;
          }
          signal?.addEventListener('abort', onAbort, { once: true });
          void gate.then(() => {
            signal?.removeEventListener('abort', onAbort);
            resolve();
          });
        });
        return Response.json({ tag: '#CLAN01', name: 'Clan' });
      }
      return new Response('{}', { status: 404 });
    });

    const leaderSignal = new AbortController();
    const followerSignal = new AbortController();
    const leader = service.refresh(
      {
        requestId: 'req-leader' as never,
        clanTag: '#CLAN01',
        endpoints: ['clan'],
      },
      leaderSignal.signal,
    );
    const follower = service.refresh(
      {
        requestId: 'req-follower' as never,
        clanTag: '#CLAN01',
        endpoints: ['clan'],
      },
      followerSignal.signal,
    );
    await Promise.resolve();
    expect(clanCalls).toBe(1);
    followerSignal.abort();
    await expect(follower).rejects.toMatchObject({ name: 'AbortError' });
    release?.();
    await expect(leader).resolves.toMatchObject({
      results: [{ endpoint: 'clan', status: 'success' }],
    });
    expect(service.clanState({ clanTag: '#CLAN01' }).state?.status).toBe('success');
    expect(bootResult.state.getGeneration()).toBe(1);
  });

  it('leader 取消但 follower 存活时仍 commit 且 generation +1', async () => {
    const bootResult = boot();
    let release: (() => void) | undefined;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const service = makeService(bootResult, async (request, init) => {
      if (request.url.includes('/clans/') && !request.url.includes('currentwar')) {
        const signal = init?.signal;
        await new Promise<void>((resolve, reject) => {
          const onAbort = () => {
            const error = new Error('aborted');
            error.name = 'AbortError';
            reject(error);
          };
          if (signal?.aborted) {
            onAbort();
            return;
          }
          signal?.addEventListener('abort', onAbort, { once: true });
          void gate.then(() => {
            signal?.removeEventListener('abort', onAbort);
            resolve();
          });
        });
        return Response.json({ tag: '#CLAN01', name: 'Clan' });
      }
      return new Response('{}', { status: 404 });
    });

    const leaderSignal = new AbortController();
    const followerSignal = new AbortController();
    const leader = service.refresh(
      {
        requestId: 'req-leader-cancel' as never,
        clanTag: '#CLAN01',
        endpoints: ['clan'],
      },
      leaderSignal.signal,
    );
    const follower = service.refresh(
      {
        requestId: 'req-follower-survive' as never,
        clanTag: '#CLAN01',
        endpoints: ['clan'],
      },
      followerSignal.signal,
    );
    await Promise.resolve();
    leaderSignal.abort();
    await expect(leader).rejects.toMatchObject({ name: 'AbortError' });
    release?.();
    await expect(follower).resolves.toMatchObject({
      results: [{ endpoint: 'clan', status: 'success' }],
    });
    expect(service.clanState({ clanTag: '#CLAN01' }).state?.status).toBe('success');
    expect(bootResult.state.getGeneration()).toBe(1);
  });

  it('warLog loadMore 与 refresh 串行，不让旧 merge 覆盖新 refresh', async () => {
    const bootResult = boot();
    const clanTag = '#CLAN01';
    const events: string[] = [];
    let releaseLoadMore!: () => void;
    const loadMoreGate = new Promise<void>((resolve) => {
      releaseLoadMore = resolve;
    });
    let allowRefreshFetch = false;

    const service = makeService(bootResult, async (request) => {
      const url = request.url;
      if (!url.includes('/warlog')) {
        return new Response('{}', { status: 404 });
      }
      if (url.includes('after=')) {
        events.push('loadMore-fetch-start');
        await loadMoreGate;
        events.push('loadMore-fetch-end');
        return Response.json({
          items: [{ result: 'lose', endTime: '20260102T000000.000Z' }],
          paging: { cursors: {} },
        });
      }
      if (!allowRefreshFetch) {
        return Response.json({
          items: [{ result: 'win', endTime: '20260101T000000.000Z' }],
          paging: { cursors: { after: 'cursor-1' } },
        });
      }
      events.push('refresh-fetch');
      return Response.json({
        items: [
          { result: 'win', endTime: '20260103T000000.000Z' },
          { result: 'win', endTime: '20260104T000000.000Z' },
        ],
        paging: { cursors: { after: 'cursor-fresh' } },
      });
    });

    await service.refresh({
      requestId: 'req-seed-warlog' as never,
      clanTag,
      endpoints: ['warLog'],
    });
    expect(
      (service.warLogState({ clanTag }).state?.lastGood as { page?: { after?: string } })?.page
        ?.after,
    ).toBe('cursor-1');

    allowRefreshFetch = true;
    const loadMorePromise = service.loadMoreWarLog({
      requestId: 'req-stale-more' as never,
      clanTag,
    });
    for (let i = 0; i < 30 && !events.includes('loadMore-fetch-start'); i += 1) {
      await Promise.resolve();
    }
    expect(events).toEqual(['loadMore-fetch-start']);

    const refreshPromise = service.refresh({
      requestId: 'req-warlog-refresh' as never,
      clanTag,
      endpoints: ['warLog'],
    });
    for (let i = 0; i < 10; i += 1) {
      await Promise.resolve();
    }
    expect(events).toEqual(['loadMore-fetch-start']);

    releaseLoadMore();
    await loadMorePromise;
    await refreshPromise;

    expect(events).toEqual(['loadMore-fetch-start', 'loadMore-fetch-end', 'refresh-fetch']);
    const final = service.warLogState({ clanTag }).state;
    const page = final?.lastGood as { page?: { items?: unknown[]; after?: string } } | undefined;
    expect(page?.page?.items).toHaveLength(2);
    expect(page?.page?.after).toBe('cursor-fresh');
  });

  it('player tag 改变后新 refresh 不 join 旧玩家 flight', async () => {
    const bootResult = boot('#AAAAA111');
    let releaseA!: () => void;
    const gateA = new Promise<void>((resolve) => {
      releaseA = resolve;
    });
    const fetchedTags: string[] = [];
    const service = makeService(bootResult, async (request) => {
      if (request.url.includes('/players/%23AAAAA111')) {
        fetchedTags.push('#AAAAA111');
        await gateA;
        return Response.json({ tag: '#AAAAA111', name: 'PlayerA', townHallLevel: 16 });
      }
      if (request.url.includes('/players/%23BBBBB222')) {
        fetchedTags.push('#BBBBB222');
        return Response.json({ tag: '#BBBBB222', name: 'PlayerB', townHallLevel: 15 });
      }
      return new Response('{}', { status: 404 });
    });

    const refreshA = service.refresh({
      requestId: 'req-player-a' as never,
      villageId: bootResult.villageId,
      endpoints: ['player'],
    });
    await Promise.resolve();
    expect(fetchedTags).toEqual(['#AAAAA111']);

    bootResult.state
      .getVillageStore()
      .saveVillages(
        bootResult.state
          .listVillages()
          .map((village) =>
            village.id === bootResult.villageId ? { ...village, tag: '#BBBBB222' } : village,
          ),
      );

    const refreshB = await service.refresh({
      requestId: 'req-player-b' as never,
      villageId: bootResult.villageId,
      endpoints: ['player'],
    });
    expect(refreshB.results[0]?.status).toBe('success');
    expect(fetchedTags).toEqual(['#AAAAA111', '#BBBBB222']);
    expect(
      (
        service.playerState({ villageId: bootResult.villageId }).state?.lastGood as {
          name?: string;
        }
      )?.name,
    ).toBe('PlayerB');

    releaseA();
    await expect(refreshA).resolves.toMatchObject({
      results: [{ endpoint: 'player', status: 'skipped' }],
    });
  });

  it('取消后立即重试 clan refresh 会真正重新请求', async () => {
    const bootResult = boot();
    let clanCalls = 0;
    let releaseFirst!: () => void;
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    const service = makeService(bootResult, async (request, init) => {
      if (request.url.includes('/clans/') && !request.url.includes('currentwar')) {
        clanCalls += 1;
        const signal = init?.signal;
        if (clanCalls === 1) {
          await new Promise<void>((resolve, reject) => {
            const onAbort = () => {
              const error = new Error('aborted');
              error.name = 'AbortError';
              reject(error);
            };
            if (signal?.aborted) {
              onAbort();
              return;
            }
            signal?.addEventListener('abort', onAbort, { once: true });
            void firstGate.then(() => {
              signal?.removeEventListener('abort', onAbort);
              resolve();
            });
          });
        }
        return Response.json({ tag: '#CLAN01', name: 'Clan' });
      }
      return new Response('{}', { status: 404 });
    });

    const controller = new AbortController();
    const first = service.refresh(
      {
        requestId: 'req-cancel-retry-1' as never,
        clanTag: '#CLAN01',
        endpoints: ['clan'],
      },
      controller.signal,
    );
    await Promise.resolve();
    controller.abort();
    await expect(first).rejects.toMatchObject({ name: 'AbortError' });

    const second = service.refresh({
      requestId: 'req-cancel-retry-2' as never,
      clanTag: '#CLAN01',
      endpoints: ['clan'],
    });
    releaseFirst();
    await expect(second).resolves.toMatchObject({
      results: [{ endpoint: 'clan', status: 'success' }],
    });
    expect(clanCalls).toBe(2);
  });

  it('预置 villageId keyed player cache 可被 query 读到', () => {
    const bootResult = boot();
    const cached: OfficialAPIState = createOfficialAPIState({
      status: 'success',
      playerTag: '#ABCDE123',
      fetchedAtMs: 1,
      lastAttemptAtMs: 1,
      lastGood: {
        tag: '#ABCDE123',
        name: 'Cached',
        townHallLevel: 15,
        townHallWeaponLevel: undefined,
        townHallWeaponLevelKeyPresent: false,
        builderHallLevel: undefined,
        expLevel: undefined,
        trophies: undefined,
        bestTrophies: undefined,
        warStars: undefined,
        attackWins: undefined,
        defenseWins: undefined,
        builderBaseTrophies: undefined,
        versusBattleWins: undefined,
        legendStatistics: undefined,
        clan: undefined,
        role: undefined,
        warPreference: undefined,
        donations: undefined,
        donationsReceived: undefined,
        clanCapitalContributions: undefined,
        league: undefined,
        builderBaseLeague: undefined,
        leagueTier: undefined,
        achievements: undefined,
        labels: undefined,
        playerHouse: undefined,
        troops: undefined,
        heroes: undefined,
        spells: undefined,
        heroEquipment: undefined,
        unrecognizedKeys: [],
      },
    });
    bootResult.persistence.playerStates.save(
      createOfficialStateStore({ [bootResult.villageId]: cached }),
    );
    // 重新组装 service 以加载落盘
    const reloaded = bootstrapPersistence({ paths: bootResult.paths });
    const villageStore = new PersistentVillageStore({
      villages: reloaded.villages,
      selection: reloaded.selection,
      initialVillages: bootResult.state.listVillages(),
      initialSelectedVillageId: bootResult.villageId,
    });
    const state = new AppAuthoritativeState({ persistence: reloaded, villageStore });
    const service = new OfficialApiService({
      state,
      clock: new FakeClock(1),
      persistence: reloaded,
      tokenProvider: () => 'fake-token',
      client: new CoAPIClient({
        config: DEFAULT_CO_API_CONFIG,
        tokenProvider: () => 'fake-token',
        fetch: async () => new Response('{}', { status: 500 }),
      }),
    });
    expect(
      (
        service.playerState({ villageId: bootResult.villageId }).state?.lastGood as {
          name?: string;
        }
      )?.name,
    ).toBe('Cached');
  });
});
