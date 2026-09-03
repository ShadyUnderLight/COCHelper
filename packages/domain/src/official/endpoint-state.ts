import {
  OFFICIAL_STALE_THRESHOLD_MS,
  type OfficialAPIDisplayStatus,
  type OfficialAPIRequestStatus,
  type OfficialEndpointFailureKind,
  type UnrecognizedKeysProviding,
} from './types';
import { officialAPISourceLabel } from './source-labeling';
import type { OfficialClanSnapshot } from './models/clan';
import { CLAN_SNAPSHOT_PARSER_VERSION } from './models/clan';
import type { OfficialClanWarSnapshot } from './models/clan-war';
import { CLAN_WAR_PARSER_VERSION } from './models/clan-war';
import type { OfficialWarLogPage } from './models/war-log';
import { WAR_LOG_PARSER_VERSION } from './models/war-log';
import type { OfficialCapitalRaidPage } from './models/capital-raid';
import { CAPITAL_RAID_PARSER_VERSION } from './models/capital-raid';

export type OfficialEndpointState<Snapshot> = {
  readonly status: OfficialAPIRequestStatus;
  readonly clanTag: string | undefined;
  readonly fetchedAtMs: number | undefined;
  readonly lastAttemptAtMs: number | undefined;
  readonly lastErrorReason: string | undefined;
  readonly lastHTTPStatus: number | undefined;
  readonly failureKind: OfficialEndpointFailureKind | undefined;
  readonly parserVersion: string;
  readonly lastGood: Snapshot | undefined;
  readonly unrecognizedKeys: readonly string[];
};

export function createOfficialEndpointState<Snapshot>(input: {
  readonly status: OfficialAPIRequestStatus;
  readonly clanTag?: string | undefined;
  readonly fetchedAtMs?: number | undefined;
  readonly lastAttemptAtMs?: number | undefined;
  readonly lastErrorReason?: string | undefined;
  readonly lastHTTPStatus?: number | undefined;
  readonly failureKind?: OfficialEndpointFailureKind | undefined;
  readonly parserVersion: string;
  readonly lastGood?: Snapshot | undefined;
  readonly unrecognizedKeys?: readonly string[];
}): OfficialEndpointState<Snapshot> {
  return {
    status: input.status,
    clanTag: input.clanTag,
    fetchedAtMs: input.fetchedAtMs,
    lastAttemptAtMs: input.lastAttemptAtMs,
    lastErrorReason: input.lastErrorReason,
    lastHTTPStatus: input.lastHTTPStatus,
    failureKind: input.failureKind,
    parserVersion: input.parserVersion,
    lastGood: input.lastGood,
    unrecognizedKeys: input.unrecognizedKeys ?? [],
  };
}

export function officialEndpointDisplayStatus<Snapshot>(
  state: OfficialEndpointState<Snapshot>,
  nowMs: number = Date.now(),
): OfficialAPIDisplayStatus {
  switch (state.status) {
    case 'never':
      return 'never';
    case 'loading':
      return 'loading';
    case 'success':
      return officialEndpointIsStale(state, nowMs) ? 'stale' : 'success';
    case 'failed':
      return 'failed';
    case 'skipped':
      return 'skipped';
  }
}

export function officialEndpointIsStale<Snapshot>(
  state: OfficialEndpointState<Snapshot>,
  nowMs: number = Date.now(),
): boolean {
  if (state.fetchedAtMs === undefined) {
    return false;
  }
  return nowMs - state.fetchedAtMs > OFFICIAL_STALE_THRESHOLD_MS;
}

export function officialEndpointIsCurrentParserVersion<Snapshot>(
  state: OfficialEndpointState<Snapshot>,
  currentParserVersion: string,
): boolean {
  return state.parserVersion === currentParserVersion;
}

export function officialEndpointSourceLabel<Snapshot>(
  state: OfficialEndpointState<Snapshot>,
): string | undefined {
  return officialAPISourceLabel(state.status, state.lastGood !== undefined);
}

export function snapshotUnrecognizedKeys(snapshot: UnrecognizedKeysProviding): readonly string[] {
  return snapshot.unrecognizedKeys;
}

export type ClanAPIState = OfficialEndpointState<OfficialClanSnapshot>;
export type ClanWarAPIState = OfficialEndpointState<OfficialClanWarSnapshot>;
export type ClanWarLogAPIState = OfficialEndpointState<OfficialWarLogPage>;
export type ClanCapitalAPIState = OfficialEndpointState<OfficialCapitalRaidPage>;

export const clanSnapshotParserVersion = CLAN_SNAPSHOT_PARSER_VERSION;
export const clanWarParserVersion = CLAN_WAR_PARSER_VERSION;
export const clanWarLogParserVersion = WAR_LOG_PARSER_VERSION;
export const clanCapitalParserVersion = CAPITAL_RAID_PARSER_VERSION;
