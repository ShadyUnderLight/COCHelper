/**
 * 请求生命周期态：与 Main DTO 业务态（empty/partial/conflict）分离。
 */
export type UiError = {
  readonly message: string;
};

export type ResourceState<T> =
  | { readonly kind: 'idle'; readonly data: null }
  | { readonly kind: 'loading'; readonly data: null }
  | { readonly kind: 'refreshing'; readonly data: T }
  | { readonly kind: 'ready'; readonly data: T }
  | { readonly kind: 'failed'; readonly data: null; readonly error: UiError }
  | { readonly kind: 'failedWithLastGood'; readonly data: T; readonly error: UiError };

export const IDLE_RESOURCE: ResourceState<never> = { kind: 'idle', data: null };

export const LOADING_RESOURCE: ResourceState<never> = { kind: 'loading', data: null };

export function resourceLoading<T>(previous: ResourceState<T> | null): ResourceState<T> {
  if (previous !== null && previous.data !== null) {
    return { kind: 'refreshing', data: previous.data };
  }
  return { kind: 'loading', data: null };
}

export function resourceSuccess<T>(data: T): ResourceState<T> {
  return { kind: 'ready', data };
}

export function resourceFailure<T>(
  previous: ResourceState<T> | null,
  message: string,
): ResourceState<T> {
  const error: UiError = { message };
  if (previous !== null && previous.data !== null) {
    return { kind: 'failedWithLastGood', data: previous.data, error };
  }
  return { kind: 'failed', data: null, error };
}

export function resourceData<T>(state: ResourceState<T>): T | null {
  switch (state.kind) {
    case 'idle':
    case 'loading':
    case 'failed':
      return null;
    case 'refreshing':
    case 'ready':
    case 'failedWithLastGood':
      return state.data;
    default: {
      const exhaustive: never = state;
      throw new Error(`未知资源态：${String(exhaustive)}`);
    }
  }
}

export function resourceLastError<T>(state: ResourceState<T>): string | null {
  switch (state.kind) {
    case 'failed':
      return state.error.message;
    case 'failedWithLastGood':
      return state.error.message;
    default:
      return null;
  }
}

/**
 * Render 阶段的 subject 围栏：state 必须属于当前 subject，才允许露出 ready / refreshing / failed。
 * owner 与当前 subject 不一致时（含无 last-good 的 failed）一律视为 loading。
 */
export function fencedResourceState<T>(
  state: ResourceState<T>,
  stateSubjectKey: string | null,
  subjectKey: string | null,
): ResourceState<T> {
  if (subjectKey === null) {
    return IDLE_RESOURCE;
  }
  if (stateSubjectKey !== subjectKey) {
    return LOADING_RESOURCE;
  }
  return state;
}
