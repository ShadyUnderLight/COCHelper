import { PLAYER_SNAPSHOT_PARSER_VERSION } from './models/player';
import type { OfficialPlayerSnapshot } from './models/player';
import { isValidTag, normalizedTag } from '../tag/validator';
import { officialAPISourceLabel } from './source-labeling';
import { OFFICIAL_STALE_THRESHOLD_MS } from './types';
import type { OfficialAPIDisplayStatus, OfficialAPIRequestStatus } from './types';

export type OfficialAPIState = {
  readonly status: OfficialAPIRequestStatus;
  readonly playerTag: string | undefined;
  readonly fetchedAtMs: number | undefined;
  readonly lastAttemptAtMs: number | undefined;
  readonly lastErrorReason: string | undefined;
  readonly lastHTTPStatus: number | undefined;
  readonly parserVersion: string;
  readonly lastGood: OfficialPlayerSnapshot | undefined;
  readonly unrecognizedKeys: readonly string[];
};

export function createOfficialAPIState(input: {
  readonly status: OfficialAPIRequestStatus;
  readonly playerTag?: string | undefined;
  readonly fetchedAtMs?: number | undefined;
  readonly lastAttemptAtMs?: number | undefined;
  readonly lastErrorReason?: string | undefined;
  readonly lastHTTPStatus?: number | undefined;
  readonly parserVersion?: string;
  readonly lastGood?: OfficialPlayerSnapshot | undefined;
  readonly unrecognizedKeys?: readonly string[];
}): OfficialAPIState {
  return {
    status: input.status,
    playerTag: input.playerTag,
    fetchedAtMs: input.fetchedAtMs,
    lastAttemptAtMs: input.lastAttemptAtMs,
    lastErrorReason: input.lastErrorReason,
    lastHTTPStatus: input.lastHTTPStatus,
    parserVersion: input.parserVersion ?? PLAYER_SNAPSHOT_PARSER_VERSION,
    lastGood: input.lastGood,
    unrecognizedKeys: input.unrecognizedKeys ?? [],
  };
}

export function officialAPIDisplayStatus(
  state: OfficialAPIState,
  nowMs: number = Date.now(),
): OfficialAPIDisplayStatus {
  switch (state.status) {
    case 'never':
      return 'never';
    case 'loading':
      return 'loading';
    case 'success':
      return officialAPIIsStale(state, nowMs) ? 'stale' : 'success';
    case 'failed':
      return 'failed';
    case 'skipped':
      return 'skipped';
  }
}

export function officialAPIIsStale(state: OfficialAPIState, nowMs: number = Date.now()): boolean {
  if (state.fetchedAtMs === undefined) {
    return false;
  }
  return nowMs - state.fetchedAtMs > OFFICIAL_STALE_THRESHOLD_MS;
}

export function officialAPICurrentClanTag(state: OfficialAPIState): string | undefined {
  const raw = state.lastGood?.clan?.tag;
  const normalized = normalizedTag(raw);
  if (normalized === undefined || !isValidTag(normalized)) {
    return undefined;
  }
  return normalized;
}

export function officialAPISourceLabelForState(state: OfficialAPIState): string | undefined {
  return officialAPISourceLabel(state.status, state.lastGood !== undefined);
}

export function mergeOfficialAPIStateLastGood(
  state: OfficialAPIState,
  previous: OfficialAPIState | undefined,
): OfficialAPIState {
  if (previous === undefined) {
    return state;
  }
  return {
    ...state,
    lastGood: previous.lastGood,
    unrecognizedKeys: previous.unrecognizedKeys,
    fetchedAtMs: previous.fetchedAtMs,
  };
}
