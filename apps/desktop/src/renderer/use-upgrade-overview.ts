import { useCallback, useState } from 'react';

import type {
  AppSnapshotPayload,
  DesktopBridge,
  UpgradeOverviewPayload,
} from '@coc-helper/contracts';

import { INITIAL_OVERVIEW_STATE, type OverviewState } from './overview-session';
import { resourceData, resourceLastError, type ResourceState } from './resource-state';
import { useResourceQuery } from './use-resource-query';

export type BridgeOverviewClient = Pick<DesktopBridge, 'upgradeOverview'>;

export type OverviewApi = {
  readonly state: OverviewState;
  readonly selectedId: string | null;
  readonly select: (id: string) => void;
  readonly refresh: () => Promise<void>;
};

function toOverviewState(resource: ResourceState<UpgradeOverviewPayload>): OverviewState {
  const payload = resourceData(resource);
  const lastError = resourceLastError(resource);
  if (payload === null) {
    if (lastError !== null) {
      return { status: 'error', payload: null, lastError };
    }
    return INITIAL_OVERVIEW_STATE;
  }
  return { status: 'ready', payload, lastError };
}

export function useUpgradeOverview(
  bridge: BridgeOverviewClient,
  snapshot: AppSnapshotPayload | null,
): OverviewApi {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const subjectKey = snapshot === null ? null : `${snapshot.sessionId}:overview`;

  const query = useResourceQuery({
    snapshot,
    subjectKey,
    fetch: () => bridge.upgradeOverview({}),
    extractGeneration: (payload) => payload.generation,
    fetchErrorMessage: '升级追踪查询失败',
    onSessionReset: () => {
      setSelectedId(null);
    },
  });

  const select = useCallback((id: string) => {
    setSelectedId(id);
  }, []);

  return {
    state: toOverviewState(query.state),
    selectedId,
    select,
    refresh: query.refresh,
  };
}
