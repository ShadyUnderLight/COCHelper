import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import type {
  ApiRefreshRequest,
  AppSnapshotPayload,
  DesktopBridge,
  WarLogStatePayload,
} from '@coc-helper/contracts';

import {
  cancelOfficialOp,
  commandErrorFor,
  officialClanSubjectKey,
  useOfficialCommandLifecycle,
  useOfficialCommandProgress,
  useOfficialCommandState,
  useRunOfficialCommand,
  type OfficialCommandBridge,
} from './official-command';
import { OFFICIAL_VIEW_WITHOUT_STALE_CLOCK } from './official-session';
import {
  toOfficialWarLogView,
  WAR_LOG_DEFAULT_VISIBLE_COUNT,
  WAR_LOG_VISIBLE_INCREMENT,
  type OfficialWarLogView,
} from './official-war-session';
import { useResourceQuery } from './use-resource-query';

export type BridgeWarLogClient = Pick<
  DesktopBridge,
  'warLogState' | 'apiRefresh' | 'warLogLoadMore' | 'onOperationProgress' | 'cancel'
>;

export type OfficialWarLogApi = {
  readonly view: OfficialWarLogView;
  readonly refresh: () => Promise<void>;
  readonly loadMore: () => Promise<void>;
  readonly refreshing: boolean;
  readonly loadingMore: boolean;
  readonly remoteBusy: boolean;
};

export function useOfficialWarLog(
  bridge: BridgeWarLogClient & OfficialCommandBridge,
  snapshot: AppSnapshotPayload | null,
  clanTag: string | null,
  villageId: string | null,
  knownNotPublic: boolean,
): OfficialWarLogApi {
  const subjectKey =
    snapshot === null || clanTag === null || knownNotPublic
      ? null
      : officialClanSubjectKey(snapshot.sessionId, clanTag, 'warLog');
  const subjectRef = useRef<string | null>(null);
  subjectRef.current = subjectKey;
  const villageIdRef = useRef(villageId);
  villageIdRef.current = villageId;
  const clanTagRef = useRef(clanTag);
  clanTagRef.current = clanTag;

  const [visibleCount, setVisibleCount] = useState(WAR_LOG_DEFAULT_VISIBLE_COUNT);
  useEffect(() => {
    setVisibleCount(WAR_LOG_DEFAULT_VISIBLE_COUNT);
  }, [clanTag, knownNotPublic]);

  const query = useResourceQuery<WarLogStatePayload>({
    snapshot,
    subjectKey,
    fetch: () => bridge.warLogState({ clanTag: clanTag as string }),
    extractGeneration: (payload) => payload.generation,
    fetchErrorMessage: '部落对战日志查询失败',
  });

  const [refreshState, setRefreshState, refreshOpRef, refreshEpochRef] = useOfficialCommandState();
  const [loadMoreState, setLoadMoreState, loadMoreOpRef, loadMoreEpochRef] =
    useOfficialCommandState();

  useOfficialCommandLifecycle(bridge, subjectKey, refreshOpRef, refreshEpochRef, setRefreshState);
  useOfficialCommandLifecycle(
    bridge,
    subjectKey,
    loadMoreOpRef,
    loadMoreEpochRef,
    setLoadMoreState,
  );
  useOfficialCommandProgress(
    bridge,
    refreshOpRef,
    subjectRef,
    setRefreshState,
    '部落对战日志刷新失败',
  );
  useOfficialCommandProgress(
    bridge,
    loadMoreOpRef,
    subjectRef,
    setLoadMoreState,
    '部落对战日志加载更多失败',
  );

  const refreshCommand = useRunOfficialCommand({
    bridge,
    subjectKey: subjectKey ?? '',
    subjectRef,
    opRef: refreshOpRef,
    epochRef: refreshEpochRef,
    setState: setRefreshState,
    defaultFailureMessage: '部落对战日志刷新失败',
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
        endpoints: ['warLog'],
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
    defaultFailureMessage: '部落对战日志加载更多失败',
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
      return bridge.warLogLoadMore({ requestId, clanTag: currentClanTag });
    },
    onSuccess: async () => {
      await query.refresh();
    },
  });

  const view = useMemo((): OfficialWarLogView => {
    const projected = toOfficialWarLogView(
      clanTag,
      query.state,
      visibleCount,
      knownNotPublic,
      OFFICIAL_VIEW_WITHOUT_STALE_CLOCK,
    );
    return {
      ...projected,
      commandError:
        commandErrorFor(refreshState.commandError, subjectKey) ??
        commandErrorFor(loadMoreState.commandError, subjectKey),
    };
  }, [
    clanTag,
    query.state,
    visibleCount,
    knownNotPublic,
    refreshState.commandError,
    loadMoreState.commandError,
    subjectKey,
  ]);

  const refreshing = refreshState.refreshing && refreshOpRef.current?.subjectKey === subjectKey;
  const loadingMore = loadMoreState.refreshing && loadMoreOpRef.current?.subjectKey === subjectKey;
  const remoteBusy = refreshing || loadingMore;

  const refresh = useCallback(async () => {
    if (subjectKey === null || remoteBusy) {
      return;
    }
    cancelOfficialOp(bridge, loadMoreOpRef, setLoadMoreState);
    await refreshCommand();
  }, [bridge, loadMoreOpRef, refreshCommand, remoteBusy, setLoadMoreState, subjectKey]);

  const loadMore = useCallback(async () => {
    if (knownNotPublic || subjectKey === null) {
      return;
    }
    if (view.moreState === 'localHidden') {
      setVisibleCount((count) => count + WAR_LOG_VISIBLE_INCREMENT);
      return;
    }
    if (view.moreState === 'serverMore') {
      if (remoteBusy) {
        return;
      }
      cancelOfficialOp(bridge, refreshOpRef, setRefreshState);
      setVisibleCount((count) => count + WAR_LOG_VISIBLE_INCREMENT);
      await loadMoreCommand();
    }
  }, [
    bridge,
    knownNotPublic,
    loadMoreCommand,
    refreshOpRef,
    remoteBusy,
    setRefreshState,
    subjectKey,
    view.moreState,
  ]);

  return {
    view,
    refresh,
    loadMore,
    refreshing,
    loadingMore,
    remoteBusy,
  };
}
