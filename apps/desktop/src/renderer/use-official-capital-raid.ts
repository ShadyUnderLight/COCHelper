import { useMemo, useRef } from 'react';

import type {
  ApiRefreshRequest,
  AppSnapshotPayload,
  CapitalRaidStatePayload,
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
import { toOfficialCapitalRaidView, type OfficialCapitalRaidView } from './official-war-session';
import { useResourceQuery } from './use-resource-query';

export type BridgeCapitalRaidClient = Pick<
  DesktopBridge,
  'capitalRaidState' | 'apiRefresh' | 'capitalRaidLoadMore' | 'onOperationProgress' | 'cancel'
>;

export type OfficialCapitalRaidApi = {
  readonly view: OfficialCapitalRaidView;
  readonly refresh: () => Promise<void>;
  readonly loadMore: () => Promise<void>;
  readonly refreshing: boolean;
  readonly loadingMore: boolean;
};

export function useOfficialCapitalRaid(
  bridge: BridgeCapitalRaidClient & OfficialCommandBridge,
  snapshot: AppSnapshotPayload | null,
  clanTag: string | null,
  villageId: string | null,
): OfficialCapitalRaidApi {
  const subjectKey =
    snapshot === null || clanTag === null
      ? null
      : officialClanSubjectKey(snapshot.sessionId, clanTag, 'capitalRaid');
  const subjectRef = useRef<string | null>(null);
  subjectRef.current = subjectKey;
  const villageIdRef = useRef(villageId);
  villageIdRef.current = villageId;
  const clanTagRef = useRef(clanTag);
  clanTagRef.current = clanTag;

  const query = useResourceQuery<CapitalRaidStatePayload>({
    snapshot,
    subjectKey,
    fetch: () => bridge.capitalRaidState({ clanTag: clanTag as string }),
    extractGeneration: (payload) => payload.generation,
    fetchErrorMessage: '突袭周末查询失败',
  });

  const [refreshState, setRefreshState, refreshOpRef, refreshEpochRef] = useOfficialCommandState();
  const [loadMoreState, setLoadMoreState, loadMoreOpRef, loadMoreEpochRef] = useOfficialCommandState();

  useOfficialCommandLifecycle(bridge, subjectKey, refreshOpRef, refreshEpochRef, setRefreshState);
  useOfficialCommandLifecycle(bridge, subjectKey, loadMoreOpRef, loadMoreEpochRef, setLoadMoreState);
  useOfficialCommandProgress(
    bridge,
    refreshOpRef,
    subjectRef,
    setRefreshState,
    '突袭周末刷新失败',
  );
  useOfficialCommandProgress(
    bridge,
    loadMoreOpRef,
    subjectRef,
    setLoadMoreState,
    '突袭周末加载更多失败',
  );

  const refresh = useRunOfficialCommand({
    bridge,
    subjectKey: subjectKey ?? '',
    subjectRef,
    opRef: refreshOpRef,
    epochRef: refreshEpochRef,
    setState: setRefreshState,
    defaultFailureMessage: '突袭周末刷新失败',
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
        endpoints: ['capitalRaid'],
        clanTag: currentClanTag,
        villageId: currentVillageId,
      };
      return bridge.apiRefresh(request);
    },
    onSuccess: async () => {
      await query.refresh();
    },
  });

  const loadMoreCommand = useRunOfficialCommand({
    bridge,
    subjectKey: subjectKey ?? '',
    subjectRef,
    opRef: loadMoreOpRef,
    epochRef: loadMoreEpochRef,
    setState: setLoadMoreState,
    defaultFailureMessage: '突袭周末加载更多失败',
    invoke: (requestId) => {
      const currentClanTag = clanTagRef.current;
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
      return bridge.capitalRaidLoadMore({ requestId, clanTag: currentClanTag });
    },
    onSuccess: async () => {
      await query.refresh();
    },
  });

  const view = useMemo((): OfficialCapitalRaidView => {
    const projected = toOfficialCapitalRaidView(
      clanTag,
      query.state,
      OFFICIAL_VIEW_WITHOUT_STALE_CLOCK,
    );
    return {
      ...projected,
      commandError:
        commandErrorFor(refreshState.commandError, subjectKey) ??
        commandErrorFor(loadMoreState.commandError, subjectKey),
    };
  }, [clanTag, query.state, refreshState.commandError, loadMoreState.commandError, subjectKey]);

  return {
    view,
    refresh: async () => {
      if (subjectKey === null) {
        return;
      }
      await refresh();
    },
    loadMore: async () => {
      if (subjectKey === null || !view.hasMore) {
        return;
      }
      await loadMoreCommand();
    },
    refreshing: refreshState.refreshing && refreshOpRef.current?.subjectKey === subjectKey,
    loadingMore: loadMoreState.refreshing && loadMoreOpRef.current?.subjectKey === subjectKey,
  };
}
