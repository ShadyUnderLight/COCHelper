import { DEFAULT_CO_API_CONFIG, type CoAPIConfig } from './co-api-config';
import { CoAPIRequestCancelledError, type CoAPIError } from './co-api-error';
import { decodeOfficialClanSnapshot, type OfficialClanSnapshot } from './models/clan';
import { decodeOfficialClanWarSnapshot, type OfficialClanWarSnapshot } from './models/clan-war';
import {
  decodeOfficialCapitalRaidSeason,
  type OfficialCapitalRaidSeason,
} from './models/capital-raid';
import { decodeOfficialPaginatedPage, type OfficialPaginatedPage } from './models/paginated-page';
import { decodeOfficialPlayerSnapshot, type OfficialPlayerSnapshot } from './models/player';
import { decodeOfficialWarLogEntry, type OfficialWarLogEntry } from './models/war-log';
import { buildCoAPIEndpoint, type QueryItem } from './url-builder';

export type CoAPISmokeResult =
  | { readonly kind: 'success'; readonly locationCount: number }
  | { readonly kind: 'missingCredentials' }
  | { readonly kind: 'authorizationFailed'; readonly reason: string }
  | { readonly kind: 'rateLimited' }
  | { readonly kind: 'notFound' }
  | { readonly kind: 'serverError' }
  | { readonly kind: 'networkFailure'; readonly detail: string };

export type CoAPIFetch = (input: string | URL, init?: RequestInit) => Promise<Response>;

export type CoAPITokenProvider = () => string | undefined;

export type CoAPIClientOptions = {
  readonly config?: CoAPIConfig;
  readonly fetch?: CoAPIFetch;
  readonly tokenProvider: CoAPITokenProvider;
};

export type Location = {
  readonly id: number;
  readonly name: string | undefined;
  readonly isCountry: boolean | undefined;
};

export type LocationsResponse = {
  readonly items: readonly Location[];
};

export class CoAPIClient {
  readonly config: CoAPIConfig;
  private readonly fetchImpl: CoAPIFetch;
  private readonly tokenProvider: CoAPITokenProvider;

  constructor(options: CoAPIClientOptions) {
    this.config = options.config ?? DEFAULT_CO_API_CONFIG;
    this.fetchImpl = options.fetch ?? globalThis.fetch.bind(globalThis);
    this.tokenProvider = options.tokenProvider;
  }

  async request(
    path: string,
    queryItems?: readonly QueryItem[],
    signal?: AbortSignal,
  ): Promise<ArrayBuffer> {
    const url = buildCoAPIEndpoint(this.config, path, queryItems);
    const maxRetries = Math.max(0, this.config.maxRetryCount);

    for (let attempt = 0; attempt <= maxRetries; attempt += 1) {
      if (signal?.aborted) {
        throw new CoAPIRequestCancelledError();
      }
      const token = this.tokenProvider();
      if (token === undefined) {
        throw makeCoAPIError('missingCredentials');
      }

      const controller = new AbortController();
      const timeout = setTimeout(() => {
        controller.abort();
      }, this.config.requestTimeoutMs);
      const onParentAbort = () => {
        controller.abort(signal?.reason);
      };
      signal?.addEventListener('abort', onParentAbort, { once: true });

      try {
        const response = await this.fetchImpl(url, {
          method: 'GET',
          headers: { Authorization: `Bearer ${token}` },
          signal: controller.signal,
        });
        const body = await response.arrayBuffer();
        const code = response.status;
        if (code >= 200 && code < 300) {
          return body;
        }
        switch (code) {
          case 401:
            throw makeCoAPIError('unauthorized');
          case 403:
            throw makeCoAPIError('accessDenied', { reason: forbiddenReason(body) });
          case 404:
            throw makeCoAPIError('notFound');
          case 429: {
            const retryAfter = retryAfterSeconds(response, body);
            if (attempt < maxRetries) {
              await sleepForRetry(this.config, attempt, retryAfter, signal);
              continue;
            }
            throw makeCoAPIError('rateLimited', { retryAfterSeconds: retryAfter });
          }
          default:
            if (code >= 500 && code < 600) {
              throw makeCoAPIError('serverError', { statusCode: code });
            }
            throw makeCoAPIError('network', { underlying: `unexpected status ${code}` });
        }
      } catch (error) {
        if (error instanceof CoAPIRequestCancelledError) {
          throw error;
        }
        if (isAbortError(error)) {
          if (signal?.aborted) {
            throw new CoAPIRequestCancelledError();
          }
          // 内部 request timeout：与 Swift URLError.timedOut 一样可重试。
          if (attempt < maxRetries) {
            await sleepForRetry(this.config, attempt, undefined, signal);
            continue;
          }
          throw makeCoAPIError('timeout');
        }
        if (isCoAPIError(error)) {
          throw error;
        }
        if (isRetryableNetworkError(error)) {
          if (attempt < maxRetries) {
            await sleepForRetry(this.config, attempt, undefined, signal);
            continue;
          }
          throw makeCoAPIError('network', { underlying: retryableNetworkUnderlying(error) });
        }
        throw makeCoAPIError('network', {
          underlying: `unknown transport error: ${error instanceof Error ? error.constructor.name : typeof error}`,
        });
      } finally {
        clearTimeout(timeout);
        signal?.removeEventListener('abort', onParentAbort);
      }
    }

    throw makeCoAPIError('network', { underlying: 'unreachable' });
  }

  async fetchLocations(signal?: AbortSignal): Promise<LocationsResponse> {
    const data = await this.request('/locations', undefined, signal);
    try {
      return decodeLocationsResponse(data);
    } catch {
      throw makeCoAPIError('malformedResponse', { detail: 'locations decode failed' });
    }
  }

  async fetchPlayer(tag: string, signal?: AbortSignal): Promise<OfficialPlayerSnapshot> {
    return this.fetchDecoded(
      `/players/${tag}`,
      decodeOfficialPlayerSnapshot,
      'player decode failed',
      signal,
    );
  }

  async fetchClan(tag: string, signal?: AbortSignal): Promise<OfficialClanSnapshot> {
    return this.fetchDecoded(
      `/clans/${tag}`,
      decodeOfficialClanSnapshot,
      'clan decode failed',
      signal,
    );
  }

  async fetchClanWar(tag: string, signal?: AbortSignal): Promise<OfficialClanWarSnapshot> {
    return this.fetchDecoded(
      `/clans/${tag}/currentwar`,
      decodeOfficialClanWarSnapshot,
      'clan war decode failed',
      signal,
    );
  }

  async fetchWarLog(
    tag: string,
    options?: {
      readonly after?: string;
      readonly before?: string;
      readonly limit?: number;
      readonly signal?: AbortSignal;
    },
  ): Promise<OfficialPaginatedPage<OfficialWarLogEntry>> {
    return this.fetchPaginated(
      tag,
      '/warlog',
      decodeOfficialWarLogEntry,
      'war log decode failed',
      options,
    );
  }

  async fetchCapitalRaidSeasons(
    tag: string,
    options?: {
      readonly after?: string;
      readonly before?: string;
      readonly limit?: number;
      readonly signal?: AbortSignal;
    },
  ): Promise<OfficialPaginatedPage<OfficialCapitalRaidSeason>> {
    return this.fetchPaginated(
      tag,
      '/capitalraidseasons',
      decodeOfficialCapitalRaidSeason,
      'capital raid decode failed',
      options,
    );
  }

  async smoke(signal?: AbortSignal): Promise<CoAPISmokeResult> {
    try {
      const locations = await this.fetchLocations(signal);
      return { kind: 'success', locationCount: locations.items.length };
    } catch (error) {
      if (!isCoAPIError(error)) {
        return { kind: 'networkFailure', detail: 'network' };
      }
      switch (error.kind) {
        case 'missingCredentials':
          return { kind: 'missingCredentials' };
        case 'unauthorized':
          return { kind: 'authorizationFailed', reason: 'unauthorized' };
        case 'accessDenied':
          return { kind: 'authorizationFailed', reason: error.reason };
        case 'rateLimited':
          return { kind: 'rateLimited' };
        case 'notFound':
          return { kind: 'notFound' };
        case 'serverError':
          return { kind: 'serverError' };
        case 'timeout':
          return { kind: 'networkFailure', detail: 'timeout' };
        case 'network':
          return { kind: 'networkFailure', detail: 'network' };
        case 'malformedResponse':
          return { kind: 'networkFailure', detail: 'malformed response' };
      }
    }
  }

  private async fetchDecoded<T>(
    path: string,
    decode: (value: unknown) => T,
    failurePrefix: string,
    signal?: AbortSignal,
  ): Promise<T> {
    const data = await this.request(path, undefined, signal);
    try {
      return decode(JSON.parse(new TextDecoder().decode(data)));
    } catch (error) {
      throw makeCoAPIError('malformedResponse', {
        detail: decodeFailureDetail(failurePrefix, error),
      });
    }
  }

  private async fetchPaginated<Item>(
    tag: string,
    suffix: string,
    decodeItem: (entry: unknown) => Item,
    failurePrefix: string,
    options?: {
      readonly after?: string;
      readonly before?: string;
      readonly limit?: number;
      readonly signal?: AbortSignal;
    },
  ): Promise<OfficialPaginatedPage<Item>> {
    const queryItems: QueryItem[] = [];
    if (options?.after !== undefined) {
      queryItems.push({ name: 'after', value: options.after });
    }
    if (options?.before !== undefined) {
      queryItems.push({ name: 'before', value: options.before });
    }
    if (options?.limit !== undefined) {
      queryItems.push({ name: 'limit', value: String(options.limit) });
    }
    const data = await this.request(`/clans/${tag}${suffix}`, queryItems, options?.signal);
    try {
      return decodeOfficialPaginatedPage(JSON.parse(new TextDecoder().decode(data)), decodeItem);
    } catch (error) {
      throw makeCoAPIError('malformedResponse', {
        detail: decodeFailureDetail(failurePrefix, error),
      });
    }
  }
}

function decodeLocationsResponse(data: ArrayBuffer): LocationsResponse {
  const value = JSON.parse(new TextDecoder().decode(data)) as unknown;
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new TypeError('locations 必须是 object。');
  }
  const itemsRaw = (value as Record<string, unknown>).items;
  if (!Array.isArray(itemsRaw)) {
    throw new TypeError('items 必填。');
  }
  const items = itemsRaw.map((entry) => {
    if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
      throw new TypeError('location 必须是 object。');
    }
    const record = entry as Record<string, unknown>;
    if (typeof record.id !== 'number' || !Number.isInteger(record.id)) {
      throw new TypeError('location.id 必须是整数。');
    }
    return {
      id: record.id,
      name: typeof record.name === 'string' ? record.name : undefined,
      isCountry: typeof record.isCountry === 'boolean' ? record.isCountry : undefined,
    };
  });
  return { items };
}

function makeCoAPIError(
  kind: CoAPIError['kind'],
  details?: {
    readonly reason?: string;
    readonly retryAfterSeconds?: number | undefined;
    readonly statusCode?: number;
    readonly underlying?: string;
    readonly detail?: string;
  },
): CoAPIError {
  switch (kind) {
    case 'missingCredentials':
    case 'unauthorized':
    case 'notFound':
    case 'timeout':
      return { kind };
    case 'accessDenied':
      return { kind, reason: details?.reason ?? 'forbidden' };
    case 'rateLimited':
      return { kind, retryAfterSeconds: details?.retryAfterSeconds };
    case 'serverError':
      return { kind, statusCode: details?.statusCode ?? 500 };
    case 'network':
      return { kind, underlying: details?.underlying ?? 'network' };
    case 'malformedResponse':
      return { kind, detail: details?.detail ?? 'malformed' };
  }
}

function isCoAPIError(error: unknown): error is CoAPIError {
  return typeof error === 'object' && error !== null && 'kind' in error;
}

function isAbortError(error: unknown): boolean {
  return (
    typeof error === 'object' && error !== null && 'name' in error && error.name === 'AbortError'
  );
}

function errorTypeName(error: unknown): string | undefined {
  if (typeof error !== 'object' || error === null) {
    return undefined;
  }
  if ('name' in error && typeof error.name === 'string' && error.name.length > 0) {
    return error.name;
  }
  if ('constructor' in error && typeof error.constructor === 'function') {
    return error.constructor.name;
  }
  return undefined;
}

function errorMessage(error: unknown): string {
  if (
    typeof error === 'object' &&
    error !== null &&
    'message' in error &&
    typeof error.message === 'string'
  ) {
    return error.message;
  }
  return '';
}

/** 可重试 transport 错误（对齐 Swift URLError 四类，不含 timedOut——后者走 AbortError 路径）。 */
function isRetryableNetworkError(error: unknown): boolean {
  if (isAbortError(error)) {
    return false;
  }
  const message = errorMessage(error).toLowerCase();
  if (
    message.includes('failed to fetch') ||
    message.includes('network') ||
    message.includes('connection') ||
    message.includes('connect') ||
    message.includes('econnrefused') ||
    message.includes('enotfound')
  ) {
    return true;
  }
  // fetch/undici 连接类失败常以 TypeError 抛出（消息因 runtime 而异）。
  return errorTypeName(error) === 'TypeError';
}

function retryableNetworkUnderlying(error: unknown): string {
  const message = errorMessage(error);
  if (message.length > 0) {
    return `transport error (${message})`;
  }
  return 'transport error';
}

async function sleepForRetry(
  config: CoAPIConfig,
  attempt: number,
  retryAfterSeconds: number | undefined,
  signal?: AbortSignal,
): Promise<void> {
  const exponential = config.baseRetryDelayMs * 2 ** attempt;
  const serverHint = retryAfterSeconds !== undefined ? Math.max(0, retryAfterSeconds) * 1000 : 0;
  const cap = Math.max(0, config.maxRetryDelayMs);
  const delay =
    serverHint > 0
      ? Math.min(Math.max(exponential, serverHint), Math.max(cap, serverHint))
      : Math.min(Math.max(0, exponential), cap);
  const ms = Number.isFinite(delay) ? Math.min(delay, 3_600_000) : 0;
  await sleep(ms, signal);
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new CoAPIRequestCancelledError());
      return;
    }
    const timer = setTimeout(resolve, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(new CoAPIRequestCancelledError());
    };
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}

function forbiddenReason(body: ArrayBuffer): string {
  const maxReasonLength = 200;
  try {
    const object = JSON.parse(new TextDecoder().decode(body)) as Record<string, unknown>;
    const reason = object.reason;
    if (typeof reason === 'string' && reason.length > 0) {
      return reason.slice(0, maxReasonLength);
    }
  } catch {
    // ignore
  }
  return 'forbidden';
}

function retryAfterSeconds(response: Response, body: ArrayBuffer): number | undefined {
  const headerValue = response.headers.get('Retry-After');
  if (headerValue !== null) {
    const seconds = Number.parseInt(headerValue.trim(), 10);
    if (Number.isInteger(seconds)) {
      return seconds;
    }
  }
  try {
    const object = JSON.parse(new TextDecoder().decode(body)) as Record<string, unknown>;
    if (typeof object.retryAfter === 'number' && Number.isInteger(object.retryAfter)) {
      return object.retryAfter;
    }
  } catch {
    // ignore
  }
  return undefined;
}

function decodeFailureDetail(prefix: string, error: unknown): string {
  if (error instanceof Error && error.message.length > 0) {
    return `${prefix}: ${error.message}`;
  }
  return prefix;
}
