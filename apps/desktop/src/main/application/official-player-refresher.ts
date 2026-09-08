/**
 * 官方玩家状态刷新（对齐 OfficialPlayerRefresher + EndpointRefresher last-good / cancel）。
 */

import {
  coAPIErrorHttpStatus,
  coAPIErrorUserFacingReason,
  createOfficialAPIState,
  isCoAPIRequestCancelled,
  PLAYER_SNAPSHOT_PARSER_VERSION,
  type CoAPIError,
  type OfficialAPIState,
  type OfficialPlayerSnapshot,
} from '@coc-helper/domain';

function isCoAPIError(error: unknown): error is CoAPIError {
  return (
    typeof error === 'object' &&
    error !== null &&
    'kind' in error &&
    typeof (error as CoAPIError).kind === 'string'
  );
}

export async function refreshOfficialPlayerState(input: {
  readonly tag: string;
  readonly previous: OfficialAPIState | undefined;
  readonly nowMs: number;
  readonly signal?: AbortSignal;
  readonly fetch: (tag: string, signal: AbortSignal | undefined) => Promise<OfficialPlayerSnapshot>;
}): Promise<OfficialAPIState> {
  const retainedParserVersion =
    input.previous?.lastGood !== undefined
      ? input.previous.parserVersion
      : PLAYER_SNAPSHOT_PARSER_VERSION;
  try {
    const snapshot = await input.fetch(input.tag, input.signal);
    return createOfficialAPIState({
      status: 'success',
      playerTag: input.tag,
      fetchedAtMs: input.nowMs,
      lastAttemptAtMs: input.nowMs,
      lastErrorReason: undefined,
      lastHTTPStatus: undefined,
      parserVersion: PLAYER_SNAPSHOT_PARSER_VERSION,
      lastGood: snapshot,
      unrecognizedKeys: snapshot.unrecognizedKeys,
    });
  } catch (error) {
    if (isCoAPIRequestCancelled(error) || input.signal?.aborted) {
      return createOfficialAPIState({
        status: 'failed',
        playerTag: input.tag,
        fetchedAtMs: input.previous?.fetchedAtMs,
        lastAttemptAtMs: input.nowMs,
        lastErrorReason: '已取消',
        lastHTTPStatus: undefined,
        parserVersion: retainedParserVersion,
        lastGood: input.previous?.lastGood,
        unrecognizedKeys: input.previous?.unrecognizedKeys ?? [],
      });
    }
    if (isCoAPIError(error)) {
      return createOfficialAPIState({
        status: 'failed',
        playerTag: input.tag,
        fetchedAtMs: input.previous?.fetchedAtMs,
        lastAttemptAtMs: input.nowMs,
        lastErrorReason: coAPIErrorUserFacingReason(error),
        lastHTTPStatus: coAPIErrorHttpStatus(error),
        parserVersion: retainedParserVersion,
        lastGood: input.previous?.lastGood,
        unrecognizedKeys: input.previous?.unrecognizedKeys ?? [],
      });
    }
    return createOfficialAPIState({
      status: 'failed',
      playerTag: input.tag,
      fetchedAtMs: input.previous?.fetchedAtMs,
      lastAttemptAtMs: input.nowMs,
      lastErrorReason: `未知错误：${error instanceof Error ? error.constructor.name : typeof error}`,
      lastHTTPStatus: undefined,
      parserVersion: retainedParserVersion,
      lastGood: input.previous?.lastGood,
      unrecognizedKeys: input.previous?.unrecognizedKeys ?? [],
    });
  }
}

export function skippedOfficialPlayerState(
  previous: OfficialAPIState | undefined,
  reason: string,
): OfficialAPIState {
  return createOfficialAPIState({
    status: 'skipped',
    playerTag: previous?.playerTag,
    fetchedAtMs: previous?.fetchedAtMs,
    lastAttemptAtMs: previous?.lastAttemptAtMs,
    lastErrorReason: reason,
    lastHTTPStatus: previous?.lastHTTPStatus,
    parserVersion: previous?.parserVersion ?? PLAYER_SNAPSHOT_PARSER_VERSION,
    lastGood: previous?.lastGood,
    unrecognizedKeys: previous?.unrecognizedKeys ?? [],
  });
}
