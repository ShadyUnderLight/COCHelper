/**
 * 官方玩家状态刷新（对齐 OfficialPlayerRefresher + EndpointRefresher last-good）。
 * 取消一律抛 AbortError，由上层决定不落盘。
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

function abortedError(): Error {
  const error = new Error('请求已取消。');
  error.name = 'AbortError';
  return error;
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
    if (input.signal?.aborted) {
      throw abortedError();
    }
    const snapshot = await input.fetch(input.tag, input.signal);
    if (input.signal?.aborted) {
      throw abortedError();
    }
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
    if (isCoAPIRequestCancelled(error) || input.signal?.aborted || isAbortError(error)) {
      throw abortedError();
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

function isAbortError(error: unknown): boolean {
  return (
    error instanceof Error && (error.name === 'AbortError' || error.message === '请求已取消。')
  );
}
