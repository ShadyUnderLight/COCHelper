import { useMemo, useRef } from 'react';

import type {
  ApiRefreshRequest,
  AppSnapshotPayload,
  ClanWarStatePayload,
  DesktopBridge,
} from '@coc-helper/contracts';

import {
  commandErrorFor,
  officialClanSubjectKey,
  useOfficialCommandLifecycle,
  useOfficialCommandProgress,
  useOfficialCommandState,
  useRunOfficialCommand,
  type OfficialCommandBridge,
} from './official-command';
import { OFFICIAL_VIEW_WITHOUT_STALE_CLOCK } from './official-session';
import { toOfficialClanWarView, type OfficialClanWarView } from './official-war-session';
import { useResourceQuery } from './use-resource-query';

export type BridgeClanWarClient = Pick<
  DesktopBridge,
  'clanWarState' | 'apiRefresh' | 'onOperationProgress' | 'cancel'
>;

export type OfficialClanWarApi = {
  readonly view: OfficialClanWarView;
  readonly refresh: () => Promise<void>;
  readonly refreshing: boolean;
};

export function useOfficialClanWar(
  bridge: BridgeClanWarClient & OfficialCommandBridge,
  snapshot: AppSnapshotPayload | null,
  clanTag: string | null,
  villageId: string | null,
): OfficialClanWarApi {
  const subjectKey =
    snapshot === null || clanTag === null
      ? null
      : officialClanSubjectKey(snapshot.sessionId, clanTag, 'clanWar');
  const subjectRef = useRef<string | null>(null);
  subjectRef.current = subjectKey;
  const villageIdRef = useRef(villageId);
  villageIdRef.current = villageId;
  const clanTagRef = useRef(clanTag);
  clanTagRef.current = clanTag;

  const query = useResourceQuery<ClanWarStatePayload>({
    snapshot,
    subjectKey,
    fetch: () => bridge.clanWarState({ clanTag: clanTag as string }),
    extractGeneration: (payload) => payload.generation,
    fetchErrorMessage: '当前部落对战查询失败',
  });

  const [commandState, setCommandState, opRef, epochRef] = useOfficialCommandState();
  useOfficialCommandLifecycle(bridge, subjectKey, opRef, epochRef, setCommandState);
  useOfficialCommandProgress(
    bridge,
    opRef,
    subjectRef,
    setCommandState,
    '当前部落对战刷新失败',
  );

  const refresh = useRunOfficialCommand({
    bridge,
    subjectKey: subjectKey ?? '',
    subjectRef,
    opRef,
    epochRef,
    setState: setCommandState,
    defaultFailureMessage: '当前部落对战刷新失败',
    invoke: (requestId) => {
      const currentClanTag = clanTagRef.current;
      const currentVillageId = villageIdRef.current;
      if (currentClanTag === null) {
        return Promise.resolve({
          ok: false,
          error: {
            kind: 'validation',
            code: 'invalid-request',
            messageKey: 'validation.failed',
            message: '缺少部落标签',
          },
        });
      }
      const request: ApiRefreshRequest = {
        requestId,
        endpoints: ['clanWar'],
        clanTag: currentClanTag,
        villageId: currentVillageId,
      };
      return bridge.apiRefresh(request);
    },
    onSuccess: async () => {
      await query.refresh();
    },
  });

  const view = useMemo((): OfficialClanWarView => {
    const projected = toOfficialClanWarView(clanTag, query.state, OFFICIAL_VIEW_WITHOUT_STALE_CLOCK);
    return {
      ...projected,
      commandError: commandErrorFor(commandState.commandError, subjectKey),
    };
  }, [clanTag, query.state, commandState.commandError, subjectKey]);

  return {
    view,
    refresh: async () => {
      if (subjectKey === null) {
        return;
      }
      await refresh();
    },
    refreshing: commandState.refreshing && opRef.current?.subjectKey === subjectKey,
  };
}
