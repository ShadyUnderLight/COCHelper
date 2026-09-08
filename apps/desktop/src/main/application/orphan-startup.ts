/**
 * E3-02（#276）冷启动 orphan 自愈策略。
 *
 * 决策（#276 follow-up / #306）：不单独落盘 orphanSinceByTag。
 * 冷启动传入空 orphanSince → policy 走宽限期（无 since → orphan，不立即 purge）。
 * 因此本路径在无持久化 since 时对 purge 实际为 no-op，但显式接线保留未来可扩展点。
 */

import {
  applyOrphanCachePolicy,
  createOfficialStateStore,
  type OfficialStateStore,
  type PersistenceBootstrapResult,
  type TrackedClanStore,
  type VillageProfile,
} from '@coc-helper/domain';

export type OrphanStartupResult = {
  readonly clanPurged: number;
  readonly clanWarPurged: number;
  readonly clanWarLogPurged: number;
  readonly clanCapitalPurged: number;
  readonly playerPurged: number;
};

export function applyOrphanCachePolicyOnStartup(
  runtime: PersistenceBootstrapResult,
  nowMs: number,
): OrphanStartupResult {
  if (!runtime.canInitializeDerivedStores) {
    return {
      clanPurged: 0,
      clanWarPurged: 0,
      clanWarLogPurged: 0,
      clanCapitalPurged: 0,
      playerPurged: 0,
    };
  }

  const villageClanTags = collectVillageClanTags(
    runtime.villagesInMemory,
    runtime.loadedPlayerStates,
  );
  const trackedClanTags = collectTrackedClanTags(runtime.loadedTrackedClans);
  const playerTags = collectPlayerTags(runtime.villagesInMemory);
  /** 冷启动无持久化 orphanSince：空 map → 宽限期，不 purge。 */
  const orphanSinceByTag: Readonly<Record<string, number>> = {};

  const clanNext = applyAndMaybeSave(runtime.loadedClanStates, runtime.clanStates, {
    villageClanTags,
    trackedClanTags,
    endpointKind: 'clan',
    orphanSinceByTag,
    nowMs,
  });
  const clanWarNext = applyAndMaybeSave(runtime.loadedClanWarStates, runtime.clanWarStates, {
    villageClanTags,
    trackedClanTags,
    endpointKind: 'clan',
    orphanSinceByTag,
    nowMs,
  });
  const clanWarLogNext = applyAndMaybeSave(
    runtime.loadedClanWarLogStates,
    runtime.clanWarLogStates,
    {
      villageClanTags,
      trackedClanTags,
      endpointKind: 'clan',
      orphanSinceByTag,
      nowMs,
    },
  );
  const clanCapitalNext = applyAndMaybeSave(
    runtime.loadedClanCapitalStates,
    runtime.clanCapitalStates,
    {
      villageClanTags,
      trackedClanTags,
      endpointKind: 'clan',
      orphanSinceByTag,
      nowMs,
    },
  );
  const playerNext = applyAndMaybeSave(runtime.loadedPlayerStates, runtime.playerStates, {
    villageClanTags,
    trackedClanTags,
    playerTags,
    endpointKind: 'player',
    orphanSinceByTag,
    nowMs,
  });

  return {
    clanPurged: clanNext.purged,
    clanWarPurged: clanWarNext.purged,
    clanWarLogPurged: clanWarLogNext.purged,
    clanCapitalPurged: clanCapitalNext.purged,
    playerPurged: playerNext.purged,
  };
}

function applyAndMaybeSave<T>(
  loaded: OfficialStateStore<T>,
  fileStore: { save(store: OfficialStateStore<T>): void },
  input: {
    readonly villageClanTags: readonly string[];
    readonly trackedClanTags: readonly string[];
    readonly playerTags?: readonly string[];
    readonly endpointKind: 'clan' | 'player';
    readonly orphanSinceByTag: Readonly<Record<string, number>>;
    readonly nowMs: number;
  },
): { readonly purged: number; readonly store: OfficialStateStore<T> } {
  const before = Object.keys(loaded.states).length;
  const nextStates = applyOrphanCachePolicy(loaded.states, input);
  const after = Object.keys(nextStates).length;
  const purged = before - after;
  const store = createOfficialStateStore(nextStates);
  if (purged > 0) {
    try {
      fileStore.save(store);
    } catch {
      // fail-open：自愈写盘失败不阻断启动。
    }
  }
  return { purged, store };
}

function collectPlayerTags(villages: readonly VillageProfile[]): readonly string[] {
  const tags: string[] = [];
  for (const village of villages) {
    if (village.tag !== null && village.tag.length > 0) {
      tags.push(village.tag);
    }
  }
  return tags;
}

function collectTrackedClanTags(tracked: TrackedClanStore): readonly string[] {
  return tracked.profiles.map((profile) => profile.clanTag);
}

function collectVillageClanTags(
  villages: readonly VillageProfile[],
  playerStates: OfficialStateStore<import('@coc-helper/domain').OfficialAPIState>,
): readonly string[] {
  const tags = new Set<string>();
  for (const village of villages) {
    if (village.tag === null) {
      continue;
    }
    const state = playerStates.states[village.tag];
    const clanTag = state?.lastGood?.clan?.tag;
    if (typeof clanTag === 'string' && clanTag.length > 0) {
      tags.add(clanTag);
    }
  }
  return [...tags];
}
