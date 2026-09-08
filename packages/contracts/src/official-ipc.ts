/**
 * #276-S4 Official API typed IPC：query / api.refresh / loadMore / operation.progress。
 * command 必须显式 villageId 或 clanTag；长请求携带 requestId 以支持取消。
 */

import type { Result } from './result';
import type {
  EndpointStateWire,
  OfficialEndpointFailureKindWire,
  OfficialAPIRequestStatusWire,
} from './official-wire';
import type { RequestId } from './ipc';

export const PLAYER_STATE_CHANNEL = 'player.state' as const;
export const CLAN_STATE_CHANNEL = 'clan.state' as const;
export const CLAN_WAR_STATE_CHANNEL = 'clanWar.state' as const;
export const WAR_LOG_STATE_CHANNEL = 'warLog.state' as const;
export const CAPITAL_RAID_STATE_CHANNEL = 'capitalRaid.state' as const;
export const API_REFRESH_CHANNEL = 'api.refresh' as const;
export const WAR_LOG_LOAD_MORE_CHANNEL = 'warLog.loadMore' as const;
export const CAPITAL_RAID_LOAD_MORE_CHANNEL = 'capitalRaid.loadMore' as const;
export const OPERATION_PROGRESS_CHANNEL = 'operation.progress' as const;

export const OFFICIAL_IPC_CHANNELS = [
  PLAYER_STATE_CHANNEL,
  CLAN_STATE_CHANNEL,
  CLAN_WAR_STATE_CHANNEL,
  WAR_LOG_STATE_CHANNEL,
  CAPITAL_RAID_STATE_CHANNEL,
  API_REFRESH_CHANNEL,
  WAR_LOG_LOAD_MORE_CHANNEL,
  CAPITAL_RAID_LOAD_MORE_CHANNEL,
  OPERATION_PROGRESS_CHANNEL,
] as const;

export const OFFICIAL_ENDPOINT_KINDS = [
  'player',
  'clan',
  'clanWar',
  'warLog',
  'capitalRaid',
] as const;

export type OfficialEndpointKind = (typeof OFFICIAL_ENDPOINT_KINDS)[number];

/** 玩家 lastGood：JSON 可序列化快照（与 domain OfficialPlayerSnapshot 同形）。 */
export type OfficialPlayerSnapshotWire = Readonly<Record<string, unknown>> & {
  readonly unrecognizedKeys?: readonly string[];
};

export type OfficialEndpointStateDto<Snapshot = unknown> = EndpointStateWire<Snapshot> & {
  readonly hasMore?: boolean;
};

export type PlayerStateRequest = {
  readonly villageId: string;
};

export type PlayerStatePayload = {
  readonly generation: number;
  readonly villageId: string;
  readonly playerTag: string | null;
  readonly state: OfficialEndpointStateDto | null;
};

export type PlayerStateResponse = Result<PlayerStatePayload>;

export type ClanStateRequest = {
  readonly clanTag: string;
};

export type ClanStatePayload = {
  readonly generation: number;
  readonly clanTag: string;
  readonly state: OfficialEndpointStateDto | null;
};

export type ClanStateResponse = Result<ClanStatePayload>;

export type ClanWarStateRequest = {
  readonly clanTag: string;
};

export type ClanWarStatePayload = {
  readonly generation: number;
  readonly clanTag: string;
  readonly state: OfficialEndpointStateDto | null;
};

export type ClanWarStateResponse = Result<ClanWarStatePayload>;

export type WarLogStateRequest = {
  readonly clanTag: string;
};

export type WarLogStatePayload = {
  readonly generation: number;
  readonly clanTag: string;
  readonly state: OfficialEndpointStateDto | null;
};

export type WarLogStateResponse = Result<WarLogStatePayload>;

export type CapitalRaidStateRequest = {
  readonly clanTag: string;
};

export type CapitalRaidStatePayload = {
  readonly generation: number;
  readonly clanTag: string;
  readonly state: OfficialEndpointStateDto | null;
};

export type CapitalRaidStateResponse = Result<CapitalRaidStatePayload>;

/**
 * api.refresh：显式目标。
 * - player 需要 villageId；
 * - clan 端点需要 clanTag，或可由该村 player last-good 解析出部落 tag。
 */
export type ApiRefreshRequest = {
  readonly requestId: RequestId;
  readonly endpoints: readonly OfficialEndpointKind[];
  readonly villageId?: string | null;
  readonly clanTag?: string | null;
};

export type ApiRefreshEndpointResultDto = {
  readonly endpoint: OfficialEndpointKind;
  readonly tag: string | null;
  readonly status: OfficialAPIRequestStatusWire;
  readonly failureKind?: OfficialEndpointFailureKindWire;
  readonly skippedOverwrite?: boolean;
};

export type ApiRefreshPayload = {
  readonly generation: number;
  readonly results: readonly ApiRefreshEndpointResultDto[];
};

export type ApiRefreshResponse = Result<ApiRefreshPayload>;

export type WarLogLoadMoreRequest = {
  readonly requestId: RequestId;
  readonly clanTag: string;
};

export type WarLogLoadMorePayload = {
  readonly generation: number;
  readonly clanTag: string;
  readonly state: OfficialEndpointStateDto;
};

export type WarLogLoadMoreResponse = Result<WarLogLoadMorePayload>;

export type CapitalRaidLoadMoreRequest = {
  readonly requestId: RequestId;
  readonly clanTag: string;
};

export type CapitalRaidLoadMorePayload = {
  readonly generation: number;
  readonly clanTag: string;
  readonly state: OfficialEndpointStateDto;
};

export type CapitalRaidLoadMoreResponse = Result<CapitalRaidLoadMorePayload>;

export type OperationProgressPhase =
  'started' | 'endpointStarted' | 'endpointFinished' | 'completed' | 'cancelled' | 'failed';

export type OperationProgressPayload = {
  readonly operationId: string;
  readonly phase: OperationProgressPhase;
  readonly generation: number;
  readonly endpoint?: OfficialEndpointKind;
  readonly tag?: string | null;
  readonly status?: OfficialAPIRequestStatusWire;
  readonly message?: string | null;
};

export type OperationProgressListener = (payload: OperationProgressPayload) => void;

export type OfficialIpcBridge = {
  playerState: (request: PlayerStateRequest) => Promise<PlayerStateResponse>;
  clanState: (request: ClanStateRequest) => Promise<ClanStateResponse>;
  clanWarState: (request: ClanWarStateRequest) => Promise<ClanWarStateResponse>;
  warLogState: (request: WarLogStateRequest) => Promise<WarLogStateResponse>;
  capitalRaidState: (request: CapitalRaidStateRequest) => Promise<CapitalRaidStateResponse>;
  apiRefresh: (request: ApiRefreshRequest) => Promise<ApiRefreshResponse>;
  warLogLoadMore: (request: WarLogLoadMoreRequest) => Promise<WarLogLoadMoreResponse>;
  capitalRaidLoadMore: (
    request: CapitalRaidLoadMoreRequest,
  ) => Promise<CapitalRaidLoadMoreResponse>;
  onOperationProgress: (listener: OperationProgressListener) => () => void;
};

export const OFFICIAL_IPC_BRIDGE_KEYS = [
  'playerState',
  'clanState',
  'clanWarState',
  'warLogState',
  'capitalRaidState',
  'apiRefresh',
  'warLogLoadMore',
  'capitalRaidLoadMore',
  'onOperationProgress',
] as const satisfies ReadonlyArray<keyof OfficialIpcBridge>;
