import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import type {
  AppSnapshotPayload,
  ClanStatePayload,
  DesktopBridge,
  PlayerStatePayload,
  RequestId,
} from '@coc-helper/contracts';
import { isRequestId } from '@coc-helper/contracts';

import { formatIpcError } from './app-session';
import {
  clanAffiliationOf,
  IDLE_OFFICIAL_CLAN_VIEW,
  IDLE_OFFICIAL_PLAYER_VIEW,
  toOfficialClanView,
  toOfficialPlayerView,
  type OfficialClanView,
  type OfficialPlayerView,
} from './official-session';
import { resourceData } from './resource-state';
import { useClock } from './use-clock';
import { useResourceQuery } from './use-resource-query';

export type BridgeOfficialClient = Pick<
  DesktopBridge,
  'playerState' | 'clanState' | 'apiRefresh' | 'onOperationProgress' | 'cancel'
>;

export type OfficialVillageApi = {
  readonly player: OfficialPlayerView;
  readonly clan: OfficialClanView;
  readonly refreshPlayer: () => Promise<void>;
  readonly refreshClan: () => Promise<void>;
  readonly playerRefreshing: boolean;
  readonly clanRefreshing: boolean;
};

function createOfficialRequestId(): RequestId {
  const id = `official-${crypto.randomUUID()}`;
  if (!isRequestId(id)) {
    throw new Error('无法生成官方刷新 requestId');
  }
  return id;
}

export function useOfficialVillage(
  bridge: BridgeOfficialClient,
  snapshot: AppSnapshotPayload | null,
  villageId: string | null,
): OfficialVillageApi {
  const nowMs = useClock();
  const [playerRefreshing, setPlayerRefreshing] = useState(false);
  const [clanRefreshing, setClanRefreshing] = useState(false);
  const playerOpRef = useRef<string | null>(null);
  const clanOpRef = useRef<string | null>(null);

  const playerSubject =
    snapshot === null || villageId === null ? null : `${snapshot.sessionId}:${villageId}`;

  const playerQuery = useResourceQuery<PlayerStatePayload>({
    snapshot,
    subjectKey: playerSubject,
    fetch: () => bridge.playerState({ villageId: villageId as string }),
    extractGeneration: (payload) => payload.generation,
    fetchErrorMessage: '官方玩家数据查询失败',
  });

  const playerPayload = resourceData(playerQuery.state);
  const clanTag = playerPayload?.currentClanTag ?? null;
  const clanSubject =
    snapshot === null || clanTag === null ? null : `${snapshot.sessionId}:${clanTag}`;

  const clanQuery = useResourceQuery<ClanStatePayload>({
    snapshot,
    subjectKey: clanSubject,
    fetch: () => bridge.clanState({ clanTag: clanTag as string }),
    extractGeneration: (payload) => payload.generation,
    fetchErrorMessage: '官方部落数据查询失败',
  });

  useEffect(() => {
    return bridge.onOperationProgress((payload) => {
      const playerOp = playerOpRef.current;
      const clanOp = clanOpRef.current;
      if (payload.operationId !== playerOp && payload.operationId !== clanOp) {
        return;
      }
      if (
        payload.phase === 'completed' ||
        payload.phase === 'cancelled' ||
        payload.phase === 'failed'
      ) {
        if (payload.operationId === playerOp) {
          playerOpRef.current = null;
          setPlayerRefreshing(false);
        }
        if (payload.operationId === clanOp) {
          clanOpRef.current = null;
          setClanRefreshing(false);
        }
      }
    });
  }, [bridge]);

  const refreshEndpoint = useCallback(
    async (endpoint: 'player' | 'clan') => {
      if (snapshot === null || villageId === null) {
        return;
      }
      const requestId = createOfficialRequestId();
      if (endpoint === 'player') {
        playerOpRef.current = requestId;
        setPlayerRefreshing(true);
      } else {
        clanOpRef.current = requestId;
        setClanRefreshing(true);
      }
      try {
        const result = await bridge.apiRefresh({
          requestId,
          endpoints: [endpoint],
          villageId,
          clanTag: endpoint === 'clan' ? clanTag : null,
        });
        if (!result.ok) {
          throw new Error(formatIpcError(result.error));
        }
        if (endpoint === 'player') {
          await playerQuery.refresh();
        } else {
          await clanQuery.refresh();
        }
      } catch {
        if (endpoint === 'player') {
          setPlayerRefreshing(false);
          playerOpRef.current = null;
        } else {
          setClanRefreshing(false);
          clanOpRef.current = null;
        }
      }
    },
    [bridge, snapshot, villageId, clanTag, playerQuery, clanQuery],
  );

  const refreshPlayer = useCallback(async () => {
    await refreshEndpoint('player');
  }, [refreshEndpoint]);

  const refreshClan = useCallback(async () => {
    await refreshEndpoint('clan');
  }, [refreshEndpoint]);

  const player = useMemo(
    () =>
      villageId === null
        ? IDLE_OFFICIAL_PLAYER_VIEW
        : toOfficialPlayerView(playerQuery.state, nowMs),
    [villageId, playerQuery.state, nowMs],
  );

  const clan = useMemo(() => {
    if (villageId === null) {
      return IDLE_OFFICIAL_CLAN_VIEW;
    }
    return toOfficialClanView(clanAffiliationOf(playerPayload), clanTag, clanQuery.state, nowMs);
  }, [villageId, playerPayload, clanTag, clanQuery.state, nowMs]);

  return {
    player,
    clan,
    refreshPlayer,
    refreshClan,
    playerRefreshing,
    clanRefreshing,
  };
}
