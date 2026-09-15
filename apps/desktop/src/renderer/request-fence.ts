/**
 * 异步资源围栏：纯函数判断请求是否仍有效。
 * 不解释业务 DTO；分页合并与 command 状态机由页面模块负责。
 */
import { isCurrentEpoch } from './app-session';

export type FenceCursor = {
  readonly sessionId: string;
  readonly generation: number;
};

export type ShouldAcceptGeneration = (
  current: FenceCursor | null,
  sessionId: string,
  generation: number,
) => boolean;

export type BeginFetchInput = {
  readonly sessionId: string;
  readonly generation: number;
  readonly subjectKey: string;
  readonly refreshSeq: number;
  readonly forced: boolean;
  readonly completedCursor: FenceCursor | null;
  readonly maxRequestedGeneration: number;
  readonly lastFetchKey: string | null;
  readonly currentRequestSeq: number;
};

export type BeginFetchResult =
  | { readonly kind: 'skip'; readonly fetchKey: string }
  | {
      readonly kind: 'fetch';
      readonly fetchKey: string;
      readonly requestSeq: number;
      readonly nextMaxRequestedGeneration: number;
    };

export type ApplyResponseInput = {
  readonly requestEpoch: number;
  readonly currentEpoch: number;
  readonly requestSessionId: string;
  readonly currentSessionId: string | null;
  readonly requestSubjectKey: string;
  readonly currentSubjectKey: string | null;
  readonly requestSeq: number;
  readonly currentRequestSeq: number;
  readonly responseGeneration?: number;
  readonly completedCursor: FenceCursor | null;
  readonly shouldAcceptGeneration: ShouldAcceptGeneration;
};

export type PaginationSubject = {
  readonly clanTag: string;
  readonly endpoint: string;
  readonly cursor: string | null;
};

export function shouldAcceptGeneration(
  current: FenceCursor | null,
  sessionId: string,
  generation: number,
): boolean {
  if (current === null) {
    return true;
  }
  if (sessionId !== current.sessionId) {
    return false;
  }
  return generation >= current.generation;
}

export function buildFetchKey(
  sessionId: string,
  generation: number,
  subjectKey: string,
  refreshSeq: number,
): string {
  return `${sessionId}:${generation}:${subjectKey}:${refreshSeq}`;
}

export function beginFetch(
  input: BeginFetchInput,
  shouldAccept: ShouldAcceptGeneration,
): BeginFetchResult {
  const fetchKey = buildFetchKey(
    input.sessionId,
    input.generation,
    input.subjectKey,
    input.refreshSeq,
  );
  if (fetchKey === input.lastFetchKey) {
    return { kind: 'skip', fetchKey };
  }
  if (!input.forced && !shouldAccept(input.completedCursor, input.sessionId, input.generation)) {
    return { kind: 'skip', fetchKey };
  }
  if (!input.forced && input.generation < input.maxRequestedGeneration) {
    return { kind: 'skip', fetchKey };
  }
  const requestSeq = input.currentRequestSeq + 1;
  return {
    kind: 'fetch',
    fetchKey,
    requestSeq,
    nextMaxRequestedGeneration: Math.max(input.maxRequestedGeneration, input.generation),
  };
}

export function shouldApplyResponse(input: ApplyResponseInput): boolean {
  if (!isCurrentEpoch(input.requestEpoch, input.currentEpoch)) {
    return false;
  }
  if (input.currentSessionId !== input.requestSessionId) {
    return false;
  }
  if (input.requestSeq !== input.currentRequestSeq) {
    return false;
  }
  if (input.currentSubjectKey !== input.requestSubjectKey) {
    return false;
  }
  if (input.responseGeneration !== undefined) {
    if (
      !input.shouldAcceptGeneration(
        input.completedCursor,
        input.requestSessionId,
        input.responseGeneration,
      )
    ) {
      return false;
    }
  }
  return true;
}

export function paginationSubjectKey(subject: PaginationSubject): string {
  return `${subject.clanTag}:${subject.endpoint}:${subject.cursor ?? ''}`;
}

export function shouldMergePaginationPage(
  expected: PaginationSubject,
  incoming: PaginationSubject,
): boolean {
  return paginationSubjectKey(expected) === paginationSubjectKey(incoming);
}

export function subjectChanged(previousSubjectKey: string | null, nextSubjectKey: string): boolean {
  return previousSubjectKey !== null && previousSubjectKey !== nextSubjectKey;
}
