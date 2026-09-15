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
  base: TrackerBaseDto,
): VillageDetailApi {
  const villageId = snapshot?.selectedVillageId ?? null;
  const subjectKey = useMemo(() => {
    if (snapshot === null || villageId === null) {
      return null;
    }
    return `${snapshot.sessionId}:${villageId}:${base}`;
  }, [snapshot, villageId, base]);

  const query = useResourceQuery({
    snapshot: villageId === null ? null : snapshot,
    subjectKey,
    fetch: () => bridge.villageDetail({ villageId: villageId as string, base }),
    extractGeneration: (payload) => payload.generation,
    fetchErrorMessage: '村庄详情查询失败',
  });

  if (villageId === null) {
    return { state: idleVillageDetailState(), refresh: query.refresh };
  }

  return {
    state: toVillageDetailState(query.state),
    refresh: query.refresh,
  };
}
