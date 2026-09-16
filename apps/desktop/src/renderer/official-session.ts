/**
 * Official Player / Clan 会话态（#277-E1）：纯函数，只消费 Official IPC DTO。
 * stale 用注入 nowMs + contracts 阈值，不在组件里各自 tick。
 */
import type {
  ClanStatePayload,
  OfficialAPIRequestStatusWire,
  OfficialClanSummaryDto,
  OfficialPlayerSummaryDto,
  PlayerStatePayload,
} from '@coc-helper/contracts';
import { OFFICIAL_STALE_THRESHOLD_MS } from '@coc-helper/contracts';

import { resourceData, resourceLastError, type ResourceState } from './resource-state';

export type OfficialRefreshStatus =
  | 'never'
  | 'loading'
  | 'success'
  | 'stale'
  | 'failedWithLastGood'
  | 'failedWithoutLastGood'
  | 'skipped';

export type ClanAffiliation = 'unknown' | 'none' | 'tagged';

export type OfficialPlayerView = {
  readonly queryStatus: 'idle' | 'loading' | 'ready' | 'error';
  readonly lastQueryError: string | null;
  readonly playerTag: string | null;
  readonly currentClanTag: string | null;
  readonly refreshStatus: OfficialRefreshStatus | null;
  readonly sourceLabel: string | null;
  readonly fetchedAtMs: number | null;
  readonly lastErrorReason: string | null;
  readonly unrecognizedKeys: readonly string[];
  readonly summary: OfficialPlayerSummaryDto | null;
  readonly canRefresh: boolean;
  readonly commandError: string | null;
};

export type OfficialClanView = {
  readonly affiliation: ClanAffiliation;
  readonly queryStatus: 'idle' | 'loading' | 'ready' | 'error';
  readonly lastQueryError: string | null;
  readonly clanTag: string | null;
  readonly refreshStatus: OfficialRefreshStatus | null;
  readonly sourceLabel: string | null;
  readonly fetchedAtMs: number | null;
  readonly lastErrorReason: string | null;
  readonly unrecognizedKeys: readonly string[];
  readonly summary: OfficialClanSummaryDto | null;
  readonly canRefresh: boolean;
  readonly commandError: string | null;
};

export const IDLE_OFFICIAL_PLAYER_VIEW: OfficialPlayerView = {
  queryStatus: 'idle',
  lastQueryError: null,
  playerTag: null,
  currentClanTag: null,
  refreshStatus: null,
  sourceLabel: null,
  fetchedAtMs: null,
  lastErrorReason: null,
  unrecognizedKeys: [],
  summary: null,
  canRefresh: false,
  commandError: null,
};

export const IDLE_OFFICIAL_CLAN_VIEW: OfficialClanView = {
  affiliation: 'unknown',
  queryStatus: 'idle',
  lastQueryError: null,
  clanTag: null,
  refreshStatus: null,
  sourceLabel: null,
  fetchedAtMs: null,
  lastErrorReason: null,
  unrecognizedKeys: [],
  summary: null,
  canRefresh: false,
  commandError: null,
};

export function officialRefreshStatus(
  status: OfficialAPIRequestStatusWire,
  hasLastGood: boolean,
  fetchedAtMs: number | undefined,
  nowMs: number,
): OfficialRefreshStatus {
  switch (status) {
    case 'never':
      return 'never';
    case 'loading':
      return 'loading';
    case 'skipped':
      return 'skipped';
    case 'success':
      return isOfficialStale(fetchedAtMs, nowMs) ? 'stale' : 'success';
    case 'failed':
      return hasLastGood ? 'failedWithLastGood' : 'failedWithoutLastGood';
    default: {
      const exhaustive: never = status;
      throw new Error(`未知官方请求态：${String(exhaustive)}`);
    }
  }
}

export function isOfficialStale(fetchedAtMs: number | undefined, nowMs: number): boolean {
  if (fetchedAtMs === undefined) {
    return false;
  }
  return nowMs - fetchedAtMs > OFFICIAL_STALE_THRESHOLD_MS;
}

export function officialSourceLabel(
  status: OfficialAPIRequestStatusWire,
  hasLastGood: boolean,
): string | null {
  switch (status) {
    case 'success':
      return '官方 API 数据';
    case 'failed':
      return hasLastGood ? '缓存的官方 API 数据' : null;
    default:
      return null;
  }
}

export function clanAffiliationOf(player: PlayerStatePayload | null): ClanAffiliation {
  if (player === null || player.summary === null) {
    return 'unknown';
  }
  return player.currentClanTag === null ? 'none' : 'tagged';
}

export function clanTypeLabel(raw: string | null): string | null {
  if (raw === null) {
    return null;
  }
  switch (raw) {
    case 'open':
      return '任何人都可加入';
    case 'inviteOnly':
      return '只有被批准才能加入';
    case 'closed':
      return '不可加入';
    default:
      return '未知';
  }
}

export function warLogPublicLabel(value: boolean | null): string | null {
  if (value === null) {
    return null;
  }
  return value ? '公开' : '不公开';
}

export function formatFetchedAt(fetchedAtMs: number | null): string | null {
  if (fetchedAtMs === null) {
    return null;
  }
  return new Date(fetchedAtMs).toLocaleString('zh-CN', {
    dateStyle: 'medium',
    timeStyle: 'short',
  });
}

export function toOfficialPlayerView(
  resource: ResourceState<PlayerStatePayload>,
  nowMs: number,
  expectedVillageId?: string | null,
): OfficialPlayerView {
  if (expectedVillageId === null) {
    return IDLE_OFFICIAL_PLAYER_VIEW;
  }
  const lastQueryError = resourceLastError(resource);
  const payload = resourceData(resource);
  if (
    payload !== null &&
    expectedVillageId !== undefined &&
    payload.villageId !== expectedVillageId
  ) {
    return { ...IDLE_OFFICIAL_PLAYER_VIEW, queryStatus: 'loading' };
  }
  if (payload === null) {
    if (lastQueryError !== null) {
      return { ...IDLE_OFFICIAL_PLAYER_VIEW, queryStatus: 'error', lastQueryError };
    }
    if (resource.kind === 'idle') {
      return IDLE_OFFICIAL_PLAYER_VIEW;
    }
    return { ...IDLE_OFFICIAL_PLAYER_VIEW, queryStatus: 'loading' };
  }
  const state = payload.state;
  const hasLastGood = payload.summary !== null;
  return {
    queryStatus: lastQueryError !== null ? 'error' : 'ready',
    lastQueryError,
    playerTag: payload.playerTag,
    currentClanTag: payload.currentClanTag,
    refreshStatus:
      state === null
        ? null
        : officialRefreshStatus(state.status, hasLastGood, state.fetchedAt, nowMs),
    sourceLabel: state === null ? null : officialSourceLabel(state.status, hasLastGood),
    fetchedAtMs: state?.fetchedAt ?? null,
    lastErrorReason: state?.lastErrorReason ?? null,
    unrecognizedKeys: state?.unrecognizedKeys ?? [],
    summary: payload.summary,
    canRefresh: payload.playerTag !== null,
    commandError: null,
  };
}

export function toOfficialClanView(
  affiliation: ClanAffiliation,
  clanTag: string | null,
  resource: ResourceState<ClanStatePayload>,
  nowMs: number,
): OfficialClanView {
  if (affiliation !== 'tagged' || clanTag === null) {
    return {
      ...IDLE_OFFICIAL_CLAN_VIEW,
      affiliation,
      clanTag,
      canRefresh: false,
    };
  }
  const lastQueryError = resourceLastError(resource);
  const payload = resourceData(resource);
  if (payload !== null && payload.clanTag !== clanTag) {
    return {
      ...IDLE_OFFICIAL_CLAN_VIEW,
      affiliation,
      clanTag,
      queryStatus: 'loading',
      canRefresh: true,
    };
  }
  if (payload === null) {
    if (lastQueryError !== null) {
      return {
        ...IDLE_OFFICIAL_CLAN_VIEW,
        affiliation,
        clanTag,
        queryStatus: 'error',
        lastQueryError,
        canRefresh: true,
      };
    }
    return {
      ...IDLE_OFFICIAL_CLAN_VIEW,
      affiliation,
      clanTag,
      queryStatus: resource.kind === 'idle' ? 'idle' : 'loading',
      canRefresh: true,
    };
  }
  const state = payload.state;
  const hasLastGood = payload.summary !== null;
  return {
    affiliation,
    queryStatus: lastQueryError !== null ? 'error' : 'ready',
    lastQueryError,
    clanTag,
    refreshStatus:
      state === null
        ? null
        : officialRefreshStatus(state.status, hasLastGood, state.fetchedAt, nowMs),
    sourceLabel: state === null ? null : officialSourceLabel(state.status, hasLastGood),
    fetchedAtMs: state?.fetchedAt ?? null,
    lastErrorReason: state?.lastErrorReason ?? null,
    unrecognizedKeys: state?.unrecognizedKeys ?? [],
    summary: payload.summary,
    canRefresh: true,
    commandError: null,
  };
}

export function playerRefreshStatusLine(view: OfficialPlayerView): string {
  if (view.queryStatus === 'loading') {
    return '正在加载官方玩家数据…';
  }
  if (view.queryStatus === 'idle') {
    return '先选择村庄查看官方数据';
  }
  return endpointStatusLine(
    '官方数据',
    view.refreshStatus,
    view.fetchedAtMs,
    view.lastErrorReason,
    view.playerTag,
  );
}

export function clanRefreshStatusLine(view: OfficialClanView): string | null {
  if (view.affiliation === 'unknown') {
    return '尚未获取玩家数据，无法确认部落归属';
  }
  if (view.affiliation === 'none') {
    return '该玩家当前不在部落中';
  }
  return endpointStatusLine(
    '部落数据',
    view.refreshStatus,
    view.fetchedAtMs,
    view.lastErrorReason,
    view.clanTag,
  );
}

function endpointStatusLine(
  kind: string,
  status: OfficialRefreshStatus | null,
  fetchedAtMs: number | null,
  lastErrorReason: string | null,
  tag: string | null,
): string {
  const fetched = formatFetchedAt(fetchedAtMs);
  switch (status) {
    case null:
    case 'never':
      return tag === null ? `缺少有效标签，无法获取${kind}` : `尚未获取${kind}`;
    case 'loading':
      return `正在获取${kind}…`;
    case 'success':
      return fetched === null ? `已获取${kind}` : `已获取 · ${fetched}`;
    case 'stale':
      return fetched === null ? `${kind}已过期` : `数据已过期（上次获取 ${fetched}）`;
    case 'failedWithLastGood':
      return lastErrorReason === null
        ? '获取失败，已保留上次成功数据'
        : `获取失败：${lastErrorReason}`;
    case 'failedWithoutLastGood':
      return lastErrorReason === null ? '获取失败' : `获取失败：${lastErrorReason}`;
    case 'skipped':
      return lastErrorReason ?? '已跳过';
    default: {
      const exhaustive: never = status;
      throw new Error(`未知刷新展示态：${String(exhaustive)}`);
    }
  }
}
