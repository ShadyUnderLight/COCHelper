import {
  coAPIErrorHttpStatus,
  coAPIErrorKind,
  coAPIErrorUserFacingReason,
  isCoAPIRequestCancelled,
  type CoAPIError,
} from './co-api-error';
import {
  createOfficialEndpointState,
  snapshotUnrecognizedKeys,
  type OfficialEndpointState,
} from './endpoint-state';
import type { EndpointParserVersioning, UnrecognizedKeysProviding } from './types';
import { isValidTag, normalizedTag } from '../tag/validator';

export async function refreshOfficialEndpoints<Snapshot>(input: {
  readonly tags: readonly (string | null | undefined)[];
  readonly previous: Readonly<Record<string, OfficialEndpointState<Snapshot>>>;
  readonly parserVersion: string;
  readonly nowMs?: number;
  readonly signal?: AbortSignal | undefined;
  readonly fetch: (tag: string, signal: AbortSignal | undefined) => Promise<Snapshot>;
}): Promise<Record<string, OfficialEndpointState<Snapshot>>> {
  const uniqueTags = new Set<string>();
  for (const rawTag of input.tags) {
    const normalized = normalizedTag(rawTag);
    if (normalized !== undefined && isValidTag(normalized)) {
      uniqueTags.add(normalized);
    }
  }

  const result: Record<string, OfficialEndpointState<Snapshot>> = {};
  for (const tag of [...uniqueTags].sort()) {
    if (input.signal?.aborted) {
      break;
    }
    result[tag] = await refreshOfficialEndpointState({
      tag,
      previous: input.previous[tag],
      parserVersion: input.parserVersion,
      nowMs: input.nowMs,
      signal: input.signal,
      fetch: input.fetch,
    });
  }
  return result;
}

export async function fetchSingleOfficialEndpoint<Snapshot>(input: {
  readonly tag: string;
  readonly previous: OfficialEndpointState<Snapshot> | undefined;
  readonly parserVersion: string;
  readonly nowMs?: number;
  readonly signal?: AbortSignal | undefined;
  readonly fetch: (tag: string, signal: AbortSignal | undefined) => Promise<Snapshot>;
}): Promise<OfficialEndpointState<Snapshot>> {
  return refreshOfficialEndpointState(input);
}

async function refreshOfficialEndpointState<Snapshot>(input: {
  readonly tag: string;
  readonly previous: OfficialEndpointState<Snapshot> | undefined;
  readonly parserVersion: string;
  readonly nowMs?: number;
  readonly signal?: AbortSignal | undefined;
  readonly fetch: (tag: string, signal: AbortSignal | undefined) => Promise<Snapshot>;
}): Promise<OfficialEndpointState<Snapshot>> {
  const nowMs = input.nowMs ?? Date.now();
  const retainedParserVersion =
    input.previous?.lastGood !== undefined ? input.previous.parserVersion : input.parserVersion;
  try {
    const snapshot = await input.fetch(input.tag, input.signal);
    const unrecognized =
      isUnrecognizedKeysProviding(snapshot) ? snapshot.unrecognizedKeys : [];
    return createOfficialEndpointState({
      status: 'success',
      clanTag: input.tag,
      fetchedAtMs: nowMs,
      lastAttemptAtMs: nowMs,
      lastErrorReason: undefined,
      lastHTTPStatus: undefined,
      failureKind: undefined,
      parserVersion: input.parserVersion,
      lastGood: snapshot,
      unrecognizedKeys: unrecognized,
    });
  } catch (error) {
    if (isCoAPIError(error)) {
      return failedOfficialEndpointState(input.tag, input.previous, retainedParserVersion, nowMs, error);
    }
    if (isCoAPIRequestCancelled(error)) {
      return cancelledOfficialEndpointState(input.tag, input.previous, retainedParserVersion, nowMs);
    }
    return unknownFailedOfficialEndpointState(input.tag, input.previous, retainedParserVersion, nowMs, error);
  }
}

function failedOfficialEndpointState<Snapshot>(
  tag: string,
  previous: OfficialEndpointState<Snapshot> | undefined,
  retainedParserVersion: string,
  nowMs: number,
  error: CoAPIError,
): OfficialEndpointState<Snapshot> {
  return createOfficialEndpointState({
    status: 'failed',
    clanTag: tag,
    fetchedAtMs: previous?.fetchedAtMs,
    lastAttemptAtMs: nowMs,
    lastErrorReason: coAPIErrorUserFacingReason(error),
    lastHTTPStatus: coAPIErrorHttpStatus(error),
    failureKind: coAPIErrorKind(error),
    parserVersion: retainedParserVersion,
    lastGood: previous?.lastGood,
    unrecognizedKeys: previous?.unrecognizedKeys ?? [],
  });
}

function cancelledOfficialEndpointState<Snapshot>(
  tag: string,
  previous: OfficialEndpointState<Snapshot> | undefined,
  retainedParserVersion: string,
  nowMs: number,
): OfficialEndpointState<Snapshot> {
  return createOfficialEndpointState({
    status: 'failed',
    clanTag: tag,
    fetchedAtMs: previous?.fetchedAtMs,
    lastAttemptAtMs: nowMs,
    lastErrorReason: '已取消',
    lastHTTPStatus: undefined,
    failureKind: 'cancelled',
    parserVersion: retainedParserVersion,
    lastGood: previous?.lastGood,
    unrecognizedKeys: previous?.unrecognizedKeys ?? [],
  });
}

function unknownFailedOfficialEndpointState<Snapshot>(
  tag: string,
  previous: OfficialEndpointState<Snapshot> | undefined,
  retainedParserVersion: string,
  nowMs: number,
  error: unknown,
): OfficialEndpointState<Snapshot> {
  return createOfficialEndpointState({
    status: 'failed',
    clanTag: tag,
    fetchedAtMs: previous?.fetchedAtMs,
    lastAttemptAtMs: nowMs,
    lastErrorReason: `未知错误：${error instanceof Error ? error.constructor.name : typeof error}`,
    lastHTTPStatus: undefined,
    failureKind: 'network',
    parserVersion: retainedParserVersion,
    lastGood: previous?.lastGood,
    unrecognizedKeys: previous?.unrecognizedKeys ?? [],
  });
}

function isCoAPIError(error: unknown): error is CoAPIError {
  return (
    typeof error === 'object' &&
    error !== null &&
    'kind' in error &&
    typeof (error as CoAPIError).kind === 'string'
  );
}

function isUnrecognizedKeysProviding(value: unknown): value is UnrecognizedKeysProviding {
  return (
    typeof value === 'object' &&
    value !== null &&
    'unrecognizedKeys' in value &&
    Array.isArray((value as UnrecognizedKeysProviding).unrecognizedKeys)
  );
}

export type EndpointRefresherSnapshot = UnrecognizedKeysProviding & EndpointParserVersioning;

export function endpointRefresherParserVersion<Snapshot extends EndpointRefresherSnapshot>(
  _snapshotType: Snapshot,
): string {
  return _snapshotType.currentParserVersion;
}

export { snapshotUnrecognizedKeys };
