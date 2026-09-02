import type { OfficialEndpointFailureKind } from './types';

export type CoAPIError =
  | { readonly kind: 'missingCredentials' }
  | { readonly kind: 'unauthorized' }
  | { readonly kind: 'accessDenied'; readonly reason: string }
  | { readonly kind: 'notFound' }
  | { readonly kind: 'rateLimited'; readonly retryAfterSeconds: number | undefined }
  | { readonly kind: 'serverError'; readonly statusCode: number }
  | { readonly kind: 'timeout' }
  | { readonly kind: 'network'; readonly underlying: string }
  | { readonly kind: 'malformedResponse'; readonly detail: string };

export class CoAPIRequestCancelledError extends Error {
  override readonly name = 'CoAPIRequestCancelledError';
}

export function isCoAPIRequestCancelled(error: unknown): boolean {
  return error instanceof CoAPIRequestCancelledError || error instanceof DOMException && error.name === 'AbortError';
}

export function coAPIErrorKind(error: CoAPIError): OfficialEndpointFailureKind {
  switch (error.kind) {
    case 'missingCredentials':
      return 'missingCredentials';
    case 'unauthorized':
      return 'unauthorized';
    case 'accessDenied':
      return 'accessDenied';
    case 'notFound':
      return 'notFound';
    case 'rateLimited':
      return 'rateLimited';
    case 'serverError':
      return 'serverError';
    case 'timeout':
      return 'timeout';
    case 'network':
      return 'network';
    case 'malformedResponse':
      return 'malformedResponse';
  }
}

export function coAPIErrorHttpStatus(error: CoAPIError): number | undefined {
  switch (error.kind) {
    case 'unauthorized':
      return 401;
    case 'accessDenied':
      return 403;
    case 'notFound':
      return 404;
    case 'rateLimited':
      return 429;
    case 'serverError':
      return error.statusCode;
    default:
      return undefined;
  }
}

export function coAPIErrorUserFacingReason(error: CoAPIError): string {
  switch (error.kind) {
    case 'missingCredentials':
      return '未配置 API token';
    case 'unauthorized':
      return '认证失败（401）';
    case 'accessDenied':
      return `访问被拒绝：${error.reason}`;
    case 'notFound':
      return '未找到对应的玩家、部落或部落对战（404）';
    case 'rateLimited':
      return '请求被限流（429），请稍后再试';
    case 'serverError':
      return `服务器错误（${error.statusCode}）`;
    case 'timeout':
      return '请求超时';
    case 'network':
      return `网络错误（${error.underlying}）`;
    case 'malformedResponse':
      return `响应解析失败（${error.detail}）`;
  }
}

export function coAPIErrorsEqual(left: CoAPIError, right: CoAPIError): boolean {
  if (left.kind !== right.kind) {
    return false;
  }
  switch (left.kind) {
    case 'accessDenied':
      return right.kind === 'accessDenied' && left.reason === right.reason;
    case 'rateLimited':
      return right.kind === 'rateLimited' && left.retryAfterSeconds === right.retryAfterSeconds;
    case 'serverError':
      return right.kind === 'serverError' && left.statusCode === right.statusCode;
    case 'network':
      return right.kind === 'network' && left.underlying === right.underlying;
    case 'malformedResponse':
      return right.kind === 'malformedResponse' && left.detail === right.detail;
    default:
      return true;
  }
}
