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
  OFFICIAL_VIEW_WITHOUT_STALE_CLOCK,
  officialPlayerSubjectKey,
  toOfficialClanView,
  toOfficialPlayerView,
  type OfficialClanView,
  type OfficialPlayerView,
} from './official-session';
import { resourceData } from './resource-state';
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

type OfficialOp = {
  readonly requestId: RequestId;
  readonly subjectKey: string;
};

type CommandError = {
  readonly subjectKey: string;
  readonly message: string;
};

function createOfficialRequestId(): RequestId {
  const id = `official-${crypto.randomUUID()}`;
  if (!isRequestId(id)) {
    throw new Error('无法生成官方刷新 requestId');
  }
  return id;
}

function commandErrorFor(error: CommandError | null, subjectKey: string | null): string | null {
  if (error === null || subjectKey === null || error.subjectKey !== subjectKey) {
    return null;
  }
  return error.message;
}

export function useOfficialVillage(
  bridge: BridgeOfficialClient,
  snapshot: AppSnapshotPayload | null,
  villageId: string | null,
): OfficialVillageApi {
  const [playerRefreshing, setPlayerRefreshing] = useState(false);
  const [clanRefreshing, setClanRefreshing] = useState(false);
  const [playerCommandError, setPlayerCommandError] = useState<CommandError | null>(null);
  const [clanCommandError, setClanCommandError] = useState<CommandError | null>(null);
  const playerOpRef = useRef<OfficialOp | null>(null);
  const clanOpRef = useRef<OfficialOp | null>(null);
  const playerEpochRef = useRef(0);
  const clanEpochRef = useRef(0);
  const villageIdRef = useRef(villageId);
  villageIdRef.current = villageId;
  const playerSubjectRef = useRef<string | null>(null);
  const clanSubjectRef = useRef<string | null>(null);

  const villageTag =
    snapshot === null || villageId === null
      ? null
      : (snapshot.villages.find((village) => village.id === villageId)?.tag ?? null);
  const playerSubject =
    snapshot === null || villageId === null
      ? null
      : officialPlayerSubjectKey(snapshot.sessionId, villageId, villageTag);
  playerSubjectRef.current = playerSubject;

  const playerQuery = useResourceQuery<PlayerStatePayload>({
    snapshot,
    subjectKey: playerSubject,
    fetch: () => bridge.playerState({ villageId: villageId as string }),
    extractGeneration: (payload) => payload.generation,
    fetchErrorMessage: '官方玩家数据查询失败',
  });

  const refreshPlayerQuery = playerQuery.refresh;
  const rawPlayerPayload = resourceData(playerQuery.state);
  const playerPayload =
    villageId !== null && rawPlayerPayload !== null && rawPlayerPayload.villageId === villageId
      ? rawPlayerPayload
      : null;
  const clanTag = playerPayload?.currentClanTag ?? null;
  const clanTagRef = useRef(clanTag);
  clanTagRef.current = clanTag;
  const clanSubject =
    snapshot === null || clanTag === null ? null : `${snapshot.sessionId}:${clanTag}`;
  clanSubjectRef.current = clanSubject;

  const clanQuery = useResourceQuery<ClanStatePayload>({
    snapshot,
    subjectKey: clanSubject,
    fetch: () => bridge.clanState({ clanTag: clanTag as string }),
    extractGeneration: (payload) => payload.generation,
    fetchErrorMessage: '官方部落数据查询失败',
  });

  const refreshClanQuery = clanQuery.refresh;

  useEffect(() => {
    return bridge.onOperationProgress((payload) => {
      const playerOp = playerOpRef.current;
      const clanOp = clanOpRef.current;
      if (
        payload.operationId !== playerOp?.requestId &&
        payload.operationId !== clanOp?.requestId
      ) {
        return;
      }
      if (payload.phase !== 'cancelled' && payload.phase !== 'failed') {
        return;
      }
      const failedMessage =
        payload.phase === 'failed' ? (payload.message ?? '官方数据刷新失败') : null;
      if (playerOp !== null && payload.operationId === playerOp.requestId) {
        playerOpRef.current = null;
        setPlayerRefreshing(false);
        if (failedMessage !== null && playerSubjectRef.current === playerOp.subjectKey) {
          setPlayerCommandError({ subjectKey: playerOp.subjectKey, message: failedMessage });
        }
      }
      if (clanOp !== null && payload.operationId === clanOp.requestId) {
        clanOpRef.current = null;
        setClanRefreshing(false);
        if (failedMessage !== null && clanSubjectRef.current === clanOp.subjectKey) {
          setClanCommandError({ subjectKey: clanOp.subjectKey, message: failedMessage });
        }
      }
    });
  }, [bridge]);

  useEffect(() => {
    const playerOp = playerOpRef.current;
    if (playerOp !== null && (playerSubject === null || playerOp.subjectKey !== playerSubject)) {
      playerEpochRef.current += 1;
      playerOpRef.current = null;
      setPlayerRefreshing(false);
      bridge.cancel({ requestId: playerOp.requestId });
    }
    setPlayerCommandError(null);
  }, [bridge, playerSubject]);

  useEffect(() => {
    const clanOp = clanOpRef.current;
    if (clanOp !== null && (clanSubject === null || clanOp.subjectKey !== clanSubject)) {
      clanEpochRef.current += 1;
      clanOpRef.current = null;
      setClanRefreshing(false);
      bridge.cancel({ requestId: clanOp.requestId });
    }
    setClanCommandError(null);
  }, [bridge, clanSubject]);

  useEffect(() => {
    return () => {
      playerEpochRef.current += 1;
      clanEpochRef.current += 1;
      const playerOp = playerOpRef.current;
      const clanOp = clanOpRef.current;
      playerOpRef.current = null;
      clanOpRef.current = null;
      if (playerOp !== null) {
        bridge.cancel({ requestId: playerOp.requestId });
      }
      if (clanOp !== null) {
        bridge.cancel({ requestId: clanOp.requestId });
      }
    };
  }, [bridge]);

  const refreshEndpoint = useCallback(
    async (endpoint: 'player' | 'clan') => {
      const currentVillageId = villageIdRef.current;
      const currentClanTag = clanTagRef.current;
      const currentPlayerSubject = playerSubjectRef.current;
      const currentClanSubject = clanSubjectRef.current;
      if (snapshot === null || currentVillageId === null || currentPlayerSubject === null) {
        return;
      }
      if (endpoint === 'clan' && (currentClanTag === null || currentClanSubject === null)) {
        return;
      }
      const subjectKey = endpoint === 'player' ? currentPlayerSubject : currentClanSubject;
      if (subjectKey === null) {
        return;
      }
      const epochRef = endpoint === 'player' ? playerEpochRef : clanEpochRef;
      const opRef = endpoint === 'player' ? playerOpRef : clanOpRef;
      const previous = opRef.current;
      if (previous !== null) {
        bridge.cancel({ requestId: previous.requestId });
      }
      epochRef.current += 1;
      const epoch = epochRef.current;
      const requestId = createOfficialRequestId();
      const op: OfficialOp = { requestId, subjectKey };
      opRef.current = op;
      if (endpoint === 'player') {
        setPlayerRefreshing(true);
        setPlayerCommandError(null);
      } else {
        setClanRefreshing(true);
        setClanCommandError(null);
      }

      const stillCurrent = (): boolean => {
        if (epochRef.current !== epoch) {
          return false;
        }
        if (endpoint === 'player') {
          return playerSubjectRef.current === subjectKey;
        }
        return clanSubjectRef.current === subjectKey;
      };

      const fail = (message: string): void => {
        if (!stillCurrent()) {
          return;
        }
        if (endpoint === 'player') {
          if (playerOpRef.current?.requestId === requestId) {
            playerOpRef.current = null;
          }
          setPlayerRefreshing(false);
          setPlayerCommandError({ subjectKey, message });
        } else {
          if (clanOpRef.current?.requestId === requestId) {
            clanOpRef.current = null;
          }
          setClanRefreshing(false);
          setClanCommandError({ subjectKey, message });
        }
      };

      try {
        const result = await bridge.apiRefresh({
          requestId,
          endpoints: [endpoint],
          villageId: currentVillageId,
          clanTag: endpoint === 'clan' ? currentClanTag : null,
        });
        if (!stillCurrent()) {
          return;
        }
        if (!result.ok) {
          fail(formatIpcError(result.error));
          return;
        }
        if (endpoint === 'player') {
          await refreshPlayerQuery();
        } else {
          await refreshClanQuery();
        }
        if (!stillCurrent()) {
          return;
        }
        if (endpoint === 'player') {
          if (playerOpRef.current?.requestId === requestId) {
            playerOpRef.current = null;
          }
          setPlayerRefreshing(false);
          setPlayerCommandError(null);
        } else {
          if (clanOpRef.current?.requestId === requestId) {
            clanOpRef.current = null;
          }
          setClanRefreshing(false);
          setClanCommandError(null);
        }
      } catch (error: unknown) {
        fail(error instanceof Error ? error.message : '官方数据刷新失败');
      }
    },
    [bridge, snapshot, refreshPlayerQuery, refreshClanQuery],
  );

  const refreshPlayer = useCallback(async () => {
    await refreshEndpoint('player');
  }, [refreshEndpoint]);

  const refreshClan = useCallback(async () => {
    await refreshEndpoint('clan');
  }, [refreshEndpoint]);

  const player = useMemo((): OfficialPlayerView => {
    const view =
      villageId === null
        ? IDLE_OFFICIAL_PLAYER_VIEW
        : toOfficialPlayerView(playerQuery.state, OFFICIAL_VIEW_WITHOUT_STALE_CLOCK, villageId);
    return { ...view, commandError: commandErrorFor(playerCommandError, playerSubject) };
  }, [villageId, playerQuery.state, playerCommandError, playerSubject]);

  const clan = useMemo((): OfficialClanView => {
    if (villageId === null) {
      return {
        ...IDLE_OFFICIAL_CLAN_VIEW,
        commandError: commandErrorFor(clanCommandError, clanSubject),
      };
    }
    const view = toOfficialClanView(
      clanAffiliationOf(playerPayload),
      clanTag,
      clanQuery.state,
      OFFICIAL_VIEW_WITHOUT_STALE_CLOCK,
    );
    return { ...view, commandError: commandErrorFor(clanCommandError, clanSubject) };
  }, [villageId, playerPayload, clanTag, clanQuery.state, clanCommandError, clanSubject]);

  return {
    player,
    clan,
    refreshPlayer,
    refreshClan,
    playerRefreshing: playerRefreshing && playerOpRef.current?.subjectKey === playerSubject,
    clanRefreshing: clanRefreshing && clanOpRef.current?.subjectKey === clanSubject,
  };
}
