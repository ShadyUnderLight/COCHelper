/**
 * OfficialApiService（#276-S4）核心行为：query、refresh last-good、cancel、progress。
 */

import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  CoAPIClient,
  DEFAULT_CO_API_CONFIG,
  PERSISTENCE_FILE_NAMES,
  bootstrapPersistence,
  createVillageProfile,
  type ElectronPersistencePaths,
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
    return { persistence, state, villageId, root };
  }

  function makeService(
    bootResult: ReturnType<typeof boot>,
    handler: (request: Request) => Promise<Response> | Response,
  ) {
    const client = new CoAPIClient({
      config: { ...DEFAULT_CO_API_CONFIG, maxRetryCount: 0, requestTimeoutMs: 5_000 },
      tokenProvider: () => 'fake-token',
      fetch: async (input, init) => handler(new Request(input, init)),
    });
    return new OfficialApiService({
      state: bootResult.state,
      clock: new FakeClock(1_700_000_000_000),
      persistence: bootResult.persistence,
      tokenProvider: () => 'fake-token',
      client,
    });
  }

  it('player.state 在无缓存时返回 null state', () => {
    const bootResult = boot();
    const service = makeService(bootResult, () => new Response('{}', { status: 500 }));
    const payload = service.playerState({ villageId: bootResult.villageId });
    expect(payload.playerTag).toBe('#ABCDE123');
    expect(payload.state).toBeNull();
  });

  it('api.refresh player 成功写入 last-good，失败保留缓存', async () => {
    const bootResult = boot();
    let calls = 0;
    const service = makeService(bootResult, async (request) => {
      calls += 1;
      if (request.url.includes('/players/')) {
        if (calls === 1) {
          return Response.json({
            tag: '#ABCDE123',
            name: 'Hero',
            townHallLevel: 16,
          });
        }
        return new Response('', { status: 500 });
      }
      return new Response('{}', { status: 404 });
    });

    const ok = await service.refresh({
      requestId: 'req-1' as never,
      villageId: bootResult.villageId,
      endpoints: ['player'],
    });
    expect(ok.results[0]?.status).toBe('success');
    const afterSuccess = service.playerState({ villageId: bootResult.villageId });
    expect(afterSuccess.state?.status).toBe('success');
    expect((afterSuccess.state?.lastGood as { name?: string } | undefined)?.name).toBe('Hero');

    const failed = await service.refresh({
      requestId: 'req-2' as never,
      villageId: bootResult.villageId,
      endpoints: ['player'],
    });
    expect(failed.results[0]?.status).toBe('failed');
    const afterFail = service.playerState({ villageId: bootResult.villageId });
    expect(afterFail.state?.status).toBe('failed');
    expect((afterFail.state?.lastGood as { name?: string } | undefined)?.name).toBe('Hero');
  });

  it('api.refresh clan 写入 clan.state，并广播 operation.progress', async () => {
    const bootResult = boot();
    const progress: string[] = [];
    const service = makeService(bootResult, async (request) => {
      if (request.url.includes('/clans/') && !request.url.includes('currentwar')) {
        return Response.json({
          tag: '#CLAN01',
          name: 'Clan',
        });
      }
      return new Response('{}', { status: 404 });
    });
    service.subscribeProgress((payload) => {
      progress.push(payload.phase);
    });

    const result = await service.refresh({
      requestId: 'req-clan' as never,
      clanTag: '#CLAN01',
      endpoints: ['clan'],
    });
    expect(result.results[0]?.status).toBe('success');
    expect(service.clanState({ clanTag: '#CLAN01' }).state?.status).toBe('success');
    expect(progress[0]).toBe('started');
    expect(progress).toContain('endpointStarted');
    expect(progress).toContain('endpointFinished');
    expect(progress.at(-1)).toBe('completed');
  });

  it('已 abort 的信号使 refresh 取消', async () => {
    const bootResult = boot();
    const controller = new AbortController();
    controller.abort();
    const service = makeService(bootResult, async () =>
      Response.json({ tag: '#ABCDE123', name: 'Late' }),
    );

    await expect(
      service.refresh(
        {
          requestId: 'req-cancel' as never,
          villageId: bootResult.villageId,
          endpoints: ['player'],
        },
        controller.signal,
      ),
    ).rejects.toMatchObject({ name: 'AbortError' });
  });
});
