import { describe, expect, it } from 'vitest';

import { applyOrphanCachePolicyOnStartup } from './orphan-startup';
import type { PersistenceBootstrapResult } from '@coc-helper/domain';
import { createOfficialStateStore, createTrackedClanStore } from '@coc-helper/domain';

describe('orphan startup（#276 follow-up）', () => {
  it('冷启动无 orphanSince 时不 purge（宽限期）', () => {
    const runtime = {
      canInitializeDerivedStores: true,
      villagesInMemory: [],
      loadedClanStates: createOfficialStateStore({ '#ORPHAN': { status: 'never' } as never }),
      loadedClanWarStates: createOfficialStateStore({}),
      loadedClanWarLogStates: createOfficialStateStore({}),
      loadedClanCapitalStates: createOfficialStateStore({}),
      loadedPlayerStates: createOfficialStateStore({}),
      loadedTrackedClans: createTrackedClanStore(),
      clanStates: { save: () => undefined },
      clanWarStates: { save: () => undefined },
      clanWarLogStates: { save: () => undefined },
      clanCapitalStates: { save: () => undefined },
      playerStates: { save: () => undefined },
    } as unknown as PersistenceBootstrapResult;

    const result = applyOrphanCachePolicyOnStartup(runtime, Date.now());
    expect(result.clanPurged).toBe(0);
    expect(result.playerPurged).toBe(0);
  });
});
