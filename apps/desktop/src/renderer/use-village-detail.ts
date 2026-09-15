import { useMemo } from 'react';

import type {
  AppSnapshotPayload,
  DesktopBridge,
  TrackerBaseDto,
  VillageDetailPayload,
} from '@coc-helper/contracts';

import {
  INITIAL_VILLAGE_DETAIL_STATE,
  idleVillageDetailState,
  type VillageDetailState,
} from './village-detail-session';
import { resourceData, resourceLastError, type ResourceState } from './resource-state';
import { useResourceQuery } from './use-resource-query';

export type BridgeVillageClient = Pick<DesktopBridge, 'villageDetail'>;

export type VillageDetailTarget = {
  readonly villageId: string;
  readonly base: TrackerBaseDto;
};

export type VillageDetailApi = {
  readonly state: VillageDetailState;
  readonly refresh: () => Promise<void>;
};

function toVillageDetailState(resource: ResourceState<VillageDetailPayload>): VillageDetailState {
  const payload = resourceData(resource);
  const lastError = resourceLastError(resource);
  if (payload === null) {
    if (lastError !== null) {
      return { status: 'error', payload: null, lastError };
    }
    return INITIAL_VILLAGE_DETAIL_STATE;
  }
  return { status: 'ready', payload, lastError };
}

export function useVillageDetail(
  bridge: BridgeVillageClient,
  snapshot: AppSnapshotPayload | null,
  target: VillageDetailTarget | null,
): VillageDetailApi {
  const subjectKey = useMemo(() => {
    if (snapshot === null || target === null) {
      return null;
    }
    return `${snapshot.sessionId}:${target.villageId}:${target.base}`;
  }, [snapshot, target]);

  const query = useResourceQuery({
    snapshot,
    subjectKey,
    fetch: () =>
      bridge.villageDetail({
        villageId: target?.villageId as string,
        base: target?.base as TrackerBaseDto,
      }),
    extractGeneration: (payload) => payload.generation,
    fetchErrorMessage: '村庄详情查询失败',
  });

  if (target === null) {
    return { state: idleVillageDetailState(), refresh: query.refresh };
  }

  return {
    state: toVillageDetailState(query.state),
    refresh: query.refresh,
  };
}
