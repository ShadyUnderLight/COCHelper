/**
 * Official Current War / War Log / Capital Raid 会话态（#277-E2）：
 * 纯函数，只消费 Official IPC wire DTO。
 */
import type {
  CapitalRaidPageWire,
  CapitalRaidSeasonWire,
  CapitalRaidStatePayload,
  ClanWarStatePayload,
  ClanWarWire,
  OfficialEndpointStateDto,
  WarLogEntryWire,
  WarLogPageWire,
  WarLogStatePayload,
} from '@coc-helper/contracts';

import {
  OFFICIAL_VIEW_WITHOUT_STALE_CLOCK,
  officialRefreshStatus,
  officialSourceLabel,
  type OfficialRefreshStatus,
} from './official-session';
import { resourceData, resourceLastError, type ResourceState } from './resource-state';

export type ClanWarPhase = 'notInWar' | 'preparation' | 'inWar' | 'warEnded' | 'unknown';

export type OfficialClanWarView = {
  readonly queryStatus: 'idle' | 'loading' | 'ready' | 'error';
  readonly lastQueryError: string | null;
  readonly clanTag: string | null;
  readonly refreshStatus: OfficialRefreshStatus | null;
  readonly sourceLabel: string | null;
  readonly fetchedAtMs: number | null;
  readonly lastErrorReason: string | null;
  readonly unrecognizedKeys: readonly string[];
  readonly war: ClanWarWire | null;
  readonly phase: ClanWarPhase;
  readonly canRefresh: boolean;
  readonly commandError: string | null;
};

export type OfficialWarLogView = {
  readonly queryStatus: 'idle' | 'loading' | 'ready' | 'error';
  readonly lastQueryError: string | null;
  readonly clanTag: string | null;
  readonly refreshStatus: OfficialRefreshStatus | null;
  readonly sourceLabel: string | null;
  readonly fetchedAtMs: number | null;
  readonly lastErrorReason: string | null;
  readonly unrecognizedKeys: readonly string[];
  readonly entries: readonly WarLogEntryWire[];
  readonly visibleEntries: readonly WarLogEntryWire[];
  readonly visibleCount: number;
  readonly moreState: WarLogMoreState;
  readonly knownNotPublic: boolean;
  readonly canRefresh: boolean;
  readonly canLoadMore: boolean;
  readonly commandError: string | null;
};

export type OfficialCapitalRaidView = {
  readonly queryStatus: 'idle' | 'loading' | 'ready' | 'error';
  readonly lastQueryError: string | null;
  readonly clanTag: string | null;
  readonly refreshStatus: OfficialRefreshStatus | null;
  readonly sourceLabel: string | null;
  readonly fetchedAtMs: number | null;
  readonly lastErrorReason: string | null;
  readonly unrecognizedKeys: readonly string[];
  readonly seasons: readonly CapitalRaidSeasonWire[];
  readonly hasMore: boolean;
  readonly canRefresh: boolean;
  readonly canLoadMore: boolean;
  readonly commandError: string | null;
};

export type WarLogMoreState = 'none' | 'localHidden' | 'serverMore';

export const WAR_LOG_DEFAULT_VISIBLE_COUNT = 10;
export const WAR_LOG_VISIBLE_INCREMENT = 10;

export const IDLE_OFFICIAL_CLAN_WAR_VIEW: OfficialClanWarView = {
  queryStatus: 'idle',
  lastQueryError: null,
  clanTag: null,
  refreshStatus: null,
  sourceLabel: null,
  fetchedAtMs: null,
  lastErrorReason: null,
  unrecognizedKeys: [],
  war: null,
  phase: 'unknown',
  canRefresh: false,
  commandError: null,
};

export const IDLE_OFFICIAL_WAR_LOG_VIEW: OfficialWarLogView = {
  queryStatus: 'idle',
  lastQueryError: null,
  clanTag: null,
  refreshStatus: null,
  sourceLabel: null,
  fetchedAtMs: null,
  lastErrorReason: null,
  unrecognizedKeys: [],
  entries: [],
  visibleEntries: [],
  visibleCount: WAR_LOG_DEFAULT_VISIBLE_COUNT,
  moreState: 'none',
  knownNotPublic: false,
  canRefresh: false,
  canLoadMore: false,
  commandError: null,
};

export const IDLE_OFFICIAL_CAPITAL_RAID_VIEW: OfficialCapitalRaidView = {
  queryStatus: 'idle',
  lastQueryError: null,
  clanTag: null,
  refreshStatus: null,
  sourceLabel: null,
  fetchedAtMs: null,
  lastErrorReason: null,
  unrecognizedKeys: [],
  seasons: [],
  hasMore: false,
  canRefresh: false,
  canLoadMore: false,
  commandError: null,
};

export function clanWarPhase(war: ClanWarWire | null): ClanWarPhase {
  if (war === null) {
    return 'unknown';
  }
  const raw = war.state?.trim();
  if (raw === undefined || raw === '') {
    return 'unknown';
  }
  switch (raw) {
    case 'notInWar':
      return 'notInWar';
    case 'preparation':
      return 'preparation';
    case 'inWar':
      return 'inWar';
    case 'warEnded':
      return 'warEnded';
    default:
      return 'unknown';
  }
}

export function clanWarPhaseLabel(phase: ClanWarPhase, rawState: string | undefined): string {
  switch (phase) {
    case 'notInWar':
      return '当前没有进行中的部落对战';
    case 'preparation':
      return '准备日';
    case 'inWar':
      return '对战进行中';
    case 'warEnded':
      return '部落对战已结束';
    case 'unknown':
      return rawState === undefined || rawState === '' ? '战争阶段未知' : `未知阶段（${rawState}）`;
    default: {
      const exhaustive: never = phase;
      throw new Error(`未知战争阶段：${String(exhaustive)}`);
    }
  }
}

export function warLogMoreState(
  totalEntries: number,
  visibleCount: number,
  hasServerMore: boolean,
): WarLogMoreState {
  if (totalEntries === 0) {
    return 'none';
  }
  if (visibleCount < totalEntries) {
    return 'localHidden';
  }
  if (hasServerMore) {
    return 'serverMore';
  }
  return 'none';
}

export function visibleWarLogEntries(
  entries: readonly WarLogEntryWire[],
  visibleCount: number,
): readonly WarLogEntryWire[] {
  return entries.slice(0, Math.max(0, visibleCount));
}

function clanWarLastGood(state: OfficialEndpointStateDto<ClanWarWire> | null): ClanWarWire | null {
  return state?.lastGood ?? null;
}

function warLogEntries(
  state: OfficialEndpointStateDto<WarLogPageWire> | null,
): readonly WarLogEntryWire[] {
  return state?.lastGood?.page.items ?? [];
}

function capitalRaidSeasons(
  state: OfficialEndpointStateDto<CapitalRaidPageWire> | null,
): readonly CapitalRaidSeasonWire[] {
  return state?.lastGood?.page.items ?? [];
}

function endpointHasMore(state: OfficialEndpointStateDto<unknown> | null): boolean {
  return state?.hasMore === true;
}

type TaggedEndpointBase = Pick<
  OfficialClanWarView,
  | 'queryStatus'
  | 'lastQueryError'
  | 'clanTag'
  | 'refreshStatus'
  | 'sourceLabel'
  | 'fetchedAtMs'
  | 'lastErrorReason'
  | 'unrecognizedKeys'
  | 'canRefresh'
>;

function toTaggedEndpointView<
  TPayload extends { readonly clanTag: string; readonly state: OfficialEndpointStateDto | null },
>(clanTag: string | null, resource: ResourceState<TPayload>, nowMs: number): TaggedEndpointBase {
  if (clanTag === null) {
    return {
      queryStatus: 'idle',
      lastQueryError: null,
      clanTag: null,
      refreshStatus: null,
      sourceLabel: null,
      fetchedAtMs: null,
      lastErrorReason: null,
      unrecognizedKeys: [],
      canRefresh: false,
    };
  }
  const lastQueryError = resourceLastError(resource);
  const payload = resourceData(resource);
  if (payload !== null && payload.clanTag !== clanTag) {
    return {
      queryStatus: 'loading',
      lastQueryError: null,
      clanTag,
      refreshStatus: null,
      sourceLabel: null,
      fetchedAtMs: null,
      lastErrorReason: null,
      unrecognizedKeys: [],
      canRefresh: true,
    };
  }
  if (payload === null) {
    if (lastQueryError !== null) {
      return {
        queryStatus: 'error',
        lastQueryError,
        clanTag,
        refreshStatus: null,
        sourceLabel: null,
        fetchedAtMs: null,
        lastErrorReason: null,
        unrecognizedKeys: [],
        canRefresh: true,
      };
    }
    return {
      queryStatus: resource.kind === 'idle' ? 'idle' : 'loading',
      lastQueryError: null,
      clanTag,
      refreshStatus: null,
      sourceLabel: null,
      fetchedAtMs: null,
      lastErrorReason: null,
      unrecognizedKeys: [],
      canRefresh: true,
    };
  }
  const state = payload.state;
  const hasLastGood = state?.lastGood !== undefined;
  return {
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
    canRefresh: true,
  };
}

export function toOfficialClanWarView(
  clanTag: string | null,
  resource: ResourceState<ClanWarStatePayload>,
  nowMs: number = OFFICIAL_VIEW_WITHOUT_STALE_CLOCK,
): OfficialClanWarView {
  const base = toTaggedEndpointView(clanTag, resource, nowMs);
  const war = clanTag === null ? null : clanWarLastGood(resourceData(resource)?.state ?? null);
  return {
    ...base,
    war,
    phase: clanWarPhase(war),
    commandError: null,
  };
}

export function toOfficialWarLogView(
  clanTag: string | null,
  resource: ResourceState<WarLogStatePayload>,
  visibleCount: number,
  knownNotPublic: boolean,
  nowMs: number = OFFICIAL_VIEW_WITHOUT_STALE_CLOCK,
): OfficialWarLogView {
  if (knownNotPublic) {
    return {
      ...IDLE_OFFICIAL_WAR_LOG_VIEW,
      clanTag,
      knownNotPublic: true,
      queryStatus: 'ready',
      canRefresh: false,
      canLoadMore: false,
    };
  }
  const base = toTaggedEndpointView(clanTag, resource, nowMs);
  const entries = clanTag === null ? [] : warLogEntries(resourceData(resource)?.state ?? null);
  const hasServerMore =
    clanTag === null ? false : endpointHasMore(resourceData(resource)?.state ?? null);
  const moreState = warLogMoreState(entries.length, visibleCount, hasServerMore);
  return {
    ...base,
    entries,
    visibleEntries: visibleWarLogEntries(entries, visibleCount),
    visibleCount,
    moreState,
    knownNotPublic: false,
    canLoadMore: moreState !== 'none',
    commandError: null,
  };
}

export function toOfficialCapitalRaidView(
  clanTag: string | null,
  resource: ResourceState<CapitalRaidStatePayload>,
  nowMs: number = OFFICIAL_VIEW_WITHOUT_STALE_CLOCK,
): OfficialCapitalRaidView {
  const base = toTaggedEndpointView(clanTag, resource, nowMs);
  const seasons = clanTag === null ? [] : capitalRaidSeasons(resourceData(resource)?.state ?? null);
  const hasMore = clanTag === null ? false : endpointHasMore(resourceData(resource)?.state ?? null);
  return {
    ...base,
    seasons,
    hasMore,
    canLoadMore: hasMore,
    commandError: null,
  };
}

export function clanWarRefreshStatusLine(view: OfficialClanWarView): string | null {
  if (view.clanTag === null) {
    return '该玩家当前不在部落中';
  }
  if (view.queryStatus === 'loading') {
    return '正在加载当前部落对战…';
  }
  if (view.queryStatus === 'error' && view.war === null) {
    return '当前部落对战状态读取失败';
  }
  return endpointStatusLine(
    '当前部落对战',
    view.refreshStatus,
    view.fetchedAtMs,
    view.lastErrorReason,
  );
}

export function warLogRefreshStatusLine(view: OfficialWarLogView): string | null {
  if (view.knownNotPublic) {
    return '部落对战日志不公开';
  }
  if (view.clanTag === null) {
    return '该玩家当前不在部落中';
  }
  if (view.queryStatus === 'loading') {
    return '正在加载部落对战日志…';
  }
  if (view.queryStatus === 'error' && view.entries.length === 0) {
    return '部落对战日志读取失败';
  }
  return endpointStatusLine(
    '部落对战日志',
    view.refreshStatus,
    view.fetchedAtMs,
    view.lastErrorReason,
  );
}

export function capitalRaidRefreshStatusLine(view: OfficialCapitalRaidView): string | null {
  if (view.clanTag === null) {
    return '该玩家当前不在部落中';
  }
  if (view.queryStatus === 'loading') {
    return '正在加载突袭周末数据…';
  }
  if (view.queryStatus === 'error' && view.seasons.length === 0) {
    return '突袭周末数据读取失败';
  }
  return endpointStatusLine('突袭周末', view.refreshStatus, view.fetchedAtMs, view.lastErrorReason);
}

function endpointStatusLine(
  kind: string,
  status: OfficialRefreshStatus | null,
  fetchedAtMs: number | null,
  lastErrorReason: string | null,
): string {
  const fetched =
    fetchedAtMs === null
      ? null
      : new Date(fetchedAtMs).toLocaleString('zh-CN', {
          dateStyle: 'medium',
          timeStyle: 'short',
        });
  switch (status) {
    case null:
    case 'never':
      return `尚未获取${kind}`;
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

export function warLogEntryLabel(entry: WarLogEntryWire): string {
  const result = entry.result ?? '未知结果';
  const end = entry.endTime ?? '未知时间';
  const opponent = entry.opponent?.name ?? entry.opponent?.tag ?? '未知对手';
  return `${end} · ${result} · 对手 ${opponent}`;
}

export function capitalRaidSeasonLabel(season: CapitalRaidSeasonWire): string {
  const start = season.startTime ?? '未知开始';
  const end = season.endTime ?? '未知结束';
  const loot = season.capitalTotalLoot;
  const lootText = loot === undefined ? '' : ` · 都城金币 ${loot}`;
  return `${start} — ${end}${lootText}`;
}

function formatWarSideScore(
  label: string,
  stars: number | undefined,
  destructionPercentage: number | undefined,
): string | null {
  const starText = stars === undefined ? null : `${stars}★`;
  const destructionText = destructionPercentage === undefined ? null : `${destructionPercentage}%`;
  if (starText === null && destructionText === null) {
    return label;
  }
  const metrics = [starText, destructionText].filter((part) => part !== null).join(' ');
  return metrics === '' ? label : `${label} ${metrics}`;
}

export function clanWarScoreLine(war: ClanWarWire): string | null {
  const clan = war.clan;
  const opponent = war.opponent;
  if (clan === undefined && opponent === undefined) {
    return null;
  }
  const left = formatWarSideScore(
    clan?.name ?? clan?.tag ?? '我方',
    clan?.stars,
    clan?.destructionPercentage,
  );
  const right = formatWarSideScore(
    opponent?.name ?? opponent?.tag ?? '对方',
    opponent?.stars,
    opponent?.destructionPercentage,
  );
  if (left === null || right === null) {
    return null;
  }
  return `${left} vs ${right}`;
}
