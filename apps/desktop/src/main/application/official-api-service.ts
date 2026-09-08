/**
 * OfficialApiService（#276-S4）：Official Player / Clan / Current War / WarLog / Capital Raid
 * 的 query、api.refresh、loadMore、operation.progress 与 last-good / 取消 / 重试接线。
 *
 * 对应父 issue 中的 OfficialPlayerService / ClanService / WarLogService /
 * CapitalRaidService / RefreshCoordinator 职责，本切片收敛为单一 Main 编排入口。
 */

import type {
  ApiRefreshEndpointResultDto,
  ApiRefreshPayload,
  ApiRefreshRequest,
  CapitalRaidLoadMorePayload,
  CapitalRaidLoadMoreRequest,
  CapitalRaidStatePayload,
  CapitalRaidStateRequest,
  ClanStatePayload,
  ClanStateRequest,
  ClanWarStatePayload,
  ClanWarStateRequest,
  OfficialEndpointKind,
  OperationProgressListener,
  OperationProgressPayload,
  PlayerStatePayload,
  PlayerStateRequest,
  WarLogLoadMorePayload,
  WarLogLoadMoreRequest,
  WarLogStatePayload,
  WarLogStateRequest,
} from '@coc-helper/contracts';
import {
  clanCapitalParserVersion,
  clanSnapshotParserVersion,
  clanWarLogParserVersion,
  clanWarParserVersion,
  CoAPIClient,
  DEFAULT_CO_API_CONFIG,
  fetchSingleOfficialEndpoint,
  isCapReached,
  isValidTag,
  MAX_CAPITAL_SEASONS_PER_TAG,
  MAX_WAR_LOG_ITEMS_PER_TAG,
  mergedCapitalRaidLoadMorePage,
  mergedPaginationPage,
  mergeOfficialStateStore,
  normalizedTag,
  officialAPICurrentClanTag,
  RefreshCoordinator,
  shouldSkipFailedOverwrite,
  trimmedPage,
  warLogEntriesEqual,
  type ClanAPIState,
  type ClanCapitalAPIState,
  type ClanWarAPIState,
  type ClanWarLogAPIState,
  type Clock,
  type CoAPITokenProvider,
  type OfficialAPIState,
  type OfficialCapitalRaidPage,
  type OfficialStateStore,
  type OfficialWarLogPage,
  type PersistenceBootstrapResult,
} from '@coc-helper/domain';

import { AppServiceError, type AppAuthoritativeState } from './app-authoritative-state';
import {
  toCapitalRaidEndpointDto,
  toClanEndpointDto,
  toClanWarEndpointDto,
  toPlayerEndpointDto,
  toWarLogEndpointDto,
} from './official-dto-mappers';
import {
  refreshOfficialPlayerState,
  skippedOfficialPlayerState,
} from './official-player-refresher';

export type OfficialApiServiceOptions = {
  readonly state: AppAuthoritativeState;
  readonly clock: Clock;
  readonly persistence: PersistenceBootstrapResult;
  readonly tokenProvider: CoAPITokenProvider;
  readonly client?: CoAPIClient;
};

export class OfficialApiService {
  private readonly state: AppAuthoritativeState;
  private readonly clock: Clock;
  private readonly persistence: PersistenceBootstrapResult;
  private readonly client: CoAPIClient;
  private readonly progressListeners = new Set<OperationProgressListener>();
  private readonly clanCoordinator = new RefreshCoordinator<void>();

  private playerStore: OfficialStateStore<OfficialAPIState>;
  private clanStore: OfficialStateStore<ClanAPIState>;
  private clanWarStore: OfficialStateStore<ClanWarAPIState>;
  private clanWarLogStore: OfficialStateStore<ClanWarLogAPIState>;
  private clanCapitalStore: OfficialStateStore<ClanCapitalAPIState>;

  private playerChain: Promise<void> = Promise.resolve();
  private clanChain: Promise<void> = Promise.resolve();

  constructor(options: OfficialApiServiceOptions) {
    this.state = options.state;
    this.clock = options.clock;
    this.persistence = options.persistence;
    this.client =
      options.client ??
      new CoAPIClient({
        config: DEFAULT_CO_API_CONFIG,
        tokenProvider: options.tokenProvider,
      });
    this.playerStore = options.persistence.loadedPlayerStates;
    this.clanStore = options.persistence.loadedClanStates;
    this.clanWarStore = options.persistence.loadedClanWarStates;
    this.clanWarLogStore = options.persistence.loadedClanWarLogStates;
    this.clanCapitalStore = options.persistence.loadedClanCapitalStates;
  }

  subscribeProgress(listener: OperationProgressListener): () => void {
    this.progressListeners.add(listener);
    return () => {
      this.progressListeners.delete(listener);
    };
  }

  playerState(request: PlayerStateRequest): PlayerStatePayload {
    const village = this.requireVillage(request.villageId);
    const playerTag = this.normalizeOptionalTag(village.tag);
    const state =
      playerTag === null ? null : (this.playerStore.states[playerTag] ?? null);
    return {
      generation: this.state.getGeneration(),
      villageId: request.villageId,
      playerTag,
      state: state === null ? null : toPlayerEndpointDto(state),
    };
  }

  clanState(request: ClanStateRequest): ClanStatePayload {
    const clanTag = this.requireClanTag(request.clanTag);
    const state = this.clanStore.states[clanTag] ?? null;
    return {
      generation: this.state.getGeneration(),
      clanTag,
      state: state === null ? null : toClanEndpointDto(state),
    };
  }

  clanWarState(request: ClanWarStateRequest): ClanWarStatePayload {
    const clanTag = this.requireClanTag(request.clanTag);
    const state = this.clanWarStore.states[clanTag] ?? null;
    return {
      generation: this.state.getGeneration(),
      clanTag,
      state: state === null ? null : toClanWarEndpointDto(state),
    };
  }

  warLogState(request: WarLogStateRequest): WarLogStatePayload {
    const clanTag = this.requireClanTag(request.clanTag);
    const state = this.clanWarLogStore.states[clanTag] ?? null;
    return {
      generation: this.state.getGeneration(),
      clanTag,
      state: state === null ? null : toWarLogEndpointDto(state),
    };
  }

  capitalRaidState(request: CapitalRaidStateRequest): CapitalRaidStatePayload {
    const clanTag = this.requireClanTag(request.clanTag);
    const state = this.clanCapitalStore.states[clanTag] ?? null;
    return {
      generation: this.state.getGeneration(),
      clanTag,
      state: state === null ? null : toCapitalRaidEndpointDto(state),
    };
  }

  async refresh(request: ApiRefreshRequest, signal?: AbortSignal): Promise<ApiRefreshPayload> {
    const endpoints = uniqueEndpoints(request.endpoints);
    this.emitProgress({
      operationId: request.requestId,
      phase: 'started',
      generation: this.state.getGeneration(),
    });

    const results: ApiRefreshEndpointResultDto[] = [];
    try {
      for (const endpoint of endpoints) {
        if (signal?.aborted) {
          this.emitProgress({
            operationId: request.requestId,
            phase: 'cancelled',
            generation: this.state.getGeneration(),
            message: '已取消',
          });
          throw abortedError();
        }
        const result = await this.refreshEndpoint(endpoint, request, signal);
        results.push(result);
        this.emitProgress({
          operationId: request.requestId,
          phase: 'endpointFinished',
          generation: this.state.getGeneration(),
          endpoint,
          tag: result.tag,
          status: result.status,
        });
      }
      this.state.notifyMutation();
      this.emitProgress({
        operationId: request.requestId,
        phase: 'completed',
        generation: this.state.getGeneration(),
      });
      return {
        generation: this.state.getGeneration(),
        results,
      };
    } catch (error) {
      if (signal?.aborted || isAbortLike(error)) {
        this.emitProgress({
          operationId: request.requestId,
          phase: 'cancelled',
          generation: this.state.getGeneration(),
          message: '已取消',
        });
        throw abortedError();
      }
      this.emitProgress({
        operationId: request.requestId,
        phase: 'failed',
        generation: this.state.getGeneration(),
        message: error instanceof Error ? error.message : '刷新失败',
      });
      throw error;
    }
  }

  async loadMoreWarLog(
    request: WarLogLoadMoreRequest,
    signal?: AbortSignal,
  ): Promise<WarLogLoadMorePayload> {
    const clanTag = this.requireClanTag(request.clanTag);
    this.emitProgress({
      operationId: request.requestId,
      phase: 'started',
      generation: this.state.getGeneration(),
      endpoint: 'warLog',
      tag: clanTag,
    });
    try {
      const state = await this.runClanExclusive(clanTag, async () => {
        const previous = this.clanWarLogStore.states[clanTag];
        const existingPage = previous?.lastGood?.page;
        if (
          existingPage === undefined ||
          existingPage.after === undefined ||
          isCapReached(existingPage.items.length, MAX_WAR_LOG_ITEMS_PER_TAG)
        ) {
          return (
            previous ??
            (await fetchSingleOfficialEndpoint({
              tag: clanTag,
              previous: undefined,
              parserVersion: clanWarLogParserVersion,
              nowMs: this.clock.nowMs(),
              signal,
              fetch: async (tag, fetchSignal) => {
                const page = await this.client.fetchWarLog(tag, { signal: fetchSignal });
                return { page, unrecognizedKeys: [] satisfies readonly string[] };
              },
            }))
          );
        }

        const requestedCursor = existingPage.after;
        const nowMs = this.clock.nowMs();
        const fetched = await fetchSingleOfficialEndpoint({
          tag: clanTag,
          previous,
          parserVersion: clanWarLogParserVersion,
          nowMs,
          signal,
          fetch: async (tag, fetchSignal) => {
            const page = await this.client.fetchWarLog(tag, {
              after: requestedCursor,
              signal: fetchSignal,
            });
            return { page, unrecognizedKeys: [] satisfies readonly string[] };
          },
        });

        if (fetched.status !== 'success' || fetched.lastGood === undefined) {
          this.persistWarLog(clanTag, fetched, nowMs);
          return fetched;
        }

        const mergedPage = mergedPaginationPage(
          existingPage,
          fetched.lastGood.page,
          warLogEntriesEqual,
        );
        const trimmed = trimmedPage(mergedPage, MAX_WAR_LOG_ITEMS_PER_TAG);
        const merged: ClanWarLogAPIState = {
          ...fetched,
          lastGood: {
            page: trimmed,
            unrecognizedKeys: fetched.lastGood.unrecognizedKeys,
          } satisfies OfficialWarLogPage,
        };
        this.persistWarLog(clanTag, merged, nowMs);
        return merged;
      });

      this.state.notifyMutation();
      this.emitProgress({
        operationId: request.requestId,
        phase: 'completed',
        generation: this.state.getGeneration(),
        endpoint: 'warLog',
        tag: clanTag,
        status: state.status,
      });
      return {
        generation: this.state.getGeneration(),
        clanTag,
        state: toWarLogEndpointDto(state),
      };
    } catch (error) {
      this.emitLoadMoreFailure(request.requestId, 'warLog', clanTag, error, signal);
      throw error;
    }
  }

  async loadMoreCapitalRaid(
    request: CapitalRaidLoadMoreRequest,
    signal?: AbortSignal,
  ): Promise<CapitalRaidLoadMorePayload> {
    const clanTag = this.requireClanTag(request.clanTag);
    this.emitProgress({
      operationId: request.requestId,
      phase: 'started',
      generation: this.state.getGeneration(),
      endpoint: 'capitalRaid',
      tag: clanTag,
    });
    try {
      const state = await this.runClanExclusive(clanTag, async () => {
        const previous = this.clanCapitalStore.states[clanTag];
        const existingPage = previous?.lastGood?.page;
        if (
          existingPage === undefined ||
          existingPage.after === undefined ||
          isCapReached(existingPage.items.length, MAX_CAPITAL_SEASONS_PER_TAG)
        ) {
          return (
            previous ??
            (await fetchSingleOfficialEndpoint({
              tag: clanTag,
              previous: undefined,
              parserVersion: clanCapitalParserVersion,
              nowMs: this.clock.nowMs(),
              signal,
              fetch: async (tag, fetchSignal) => {
                const page = await this.client.fetchCapitalRaidSeasons(tag, {
                  signal: fetchSignal,
                });
                return { page, unrecognizedKeys: [] satisfies readonly string[] };
              },
            }))
          );
        }

        const requestedCursor = existingPage.after;
        const nowMs = this.clock.nowMs();
        const fetched = await fetchSingleOfficialEndpoint({
          tag: clanTag,
          previous,
          parserVersion: clanCapitalParserVersion,
          nowMs,
          signal,
          fetch: async (tag, fetchSignal) => {
            const page = await this.client.fetchCapitalRaidSeasons(tag, {
              after: requestedCursor,
              signal: fetchSignal,
            });
            return { page, unrecognizedKeys: [] satisfies readonly string[] };
          },
        });

        if (fetched.status !== 'success' || fetched.lastGood === undefined) {
          this.persistCapital(clanTag, fetched, nowMs);
          return fetched;
        }

        const mergeResult = mergedCapitalRaidLoadMorePage(existingPage, fetched.lastGood.page);
        const trimmed = trimmedPage(mergeResult.page, MAX_CAPITAL_SEASONS_PER_TAG);
        const merged: ClanCapitalAPIState = {
          ...fetched,
          lastGood: {
            page: trimmed,
            unrecognizedKeys: fetched.lastGood.unrecognizedKeys,
          } satisfies OfficialCapitalRaidPage,
        };
        this.persistCapital(clanTag, merged, nowMs);
        return merged;
      });

      this.state.notifyMutation();
      this.emitProgress({
        operationId: request.requestId,
        phase: 'completed',
        generation: this.state.getGeneration(),
        endpoint: 'capitalRaid',
        tag: clanTag,
        status: state.status,
      });
      return {
        generation: this.state.getGeneration(),
        clanTag,
        state: toCapitalRaidEndpointDto(state),
      };
    } catch (error) {
      this.emitLoadMoreFailure(request.requestId, 'capitalRaid', clanTag, error, signal);
      throw error;
    }
  }

  private async refreshEndpoint(
    endpoint: OfficialEndpointKind,
    request: ApiRefreshRequest,
    signal: AbortSignal | undefined,
  ): Promise<ApiRefreshEndpointResultDto> {
    this.emitProgress({
      operationId: request.requestId,
      phase: 'endpointStarted',
      generation: this.state.getGeneration(),
      endpoint,
    });

    switch (endpoint) {
      case 'player':
        return this.refreshPlayer(request, signal);
      case 'clan':
        return this.refreshClan(request, signal);
      case 'clanWar':
        return this.refreshClanWar(request, signal);
      case 'warLog':
        return this.refreshWarLog(request, signal);
      case 'capitalRaid':
        return this.refreshCapitalRaid(request, signal);
    }
  }

  private async refreshPlayer(
    request: ApiRefreshRequest,
    signal: AbortSignal | undefined,
  ): Promise<ApiRefreshEndpointResultDto> {
    const villageId = request.villageId;
    if (villageId === undefined || villageId === null || villageId.length === 0) {
      throw new AppServiceError('validation', 'api.refresh player 必须显式传入 villageId。');
    }
    const village = this.requireVillage(villageId);
    const playerTag = this.normalizeOptionalTag(village.tag);
    const expectedTag = playerTag;

    return this.runPlayerExclusive(async () => {
      const previous =
        playerTag === null ? undefined : this.playerStore.states[playerTag];
      if (playerTag === null) {
        const skipped = skippedOfficialPlayerState(previous, '缺少有效的玩家 tag，已跳过');
        if (village.tag !== null) {
          // 无合法 tag 不落盘 keyed store
        }
        return {
          endpoint: 'player' as const,
          tag: null,
          status: skipped.status,
        };
      }

      const nowMs = this.clock.nowMs();
      const refreshed = await refreshOfficialPlayerState({
        tag: playerTag,
        previous,
        nowMs,
        signal,
        fetch: (tag, fetchSignal) => this.client.fetchPlayer(tag, fetchSignal),
      });

      const currentVillage = this.requireVillage(villageId);
      const currentTag = this.normalizeOptionalTag(currentVillage.tag);
      if (currentTag !== expectedTag) {
        return {
          endpoint: 'player' as const,
          tag: playerTag,
          status: 'skipped',
        };
      }

      this.playerStore = mergeOfficialStateStore(this.playerStore, { [playerTag]: refreshed });
      this.persistence.playerStates.save(this.playerStore);
      return {
        endpoint: 'player' as const,
        tag: playerTag,
        status: refreshed.status,
      };
    });
  }

  private async refreshClan(
    request: ApiRefreshRequest,
    signal: AbortSignal | undefined,
  ): Promise<ApiRefreshEndpointResultDto> {
    const clanTag = this.resolveClanTag(request);
    return this.runClanExclusive(clanTag, async () => {
      const batchStartMs = this.clock.nowMs();
      this.clanCoordinator.beginBatch([clanTag]);
      try {
        const previous = this.clanStore.states[clanTag];
        const refreshed = await fetchSingleOfficialEndpoint({
          tag: clanTag,
          previous,
          parserVersion: clanSnapshotParserVersion,
          nowMs: batchStartMs,
          signal,
          fetch: (tag, fetchSignal) => this.client.fetchClan(tag, fetchSignal),
        });
        if (
          shouldSkipFailedOverwrite({
            refreshedState: refreshed,
            existing: this.clanStore.states[clanTag],
            batchStartMs,
          })
        ) {
          return {
            endpoint: 'clan' as const,
            tag: clanTag,
            status: this.clanStore.states[clanTag]!.status,
            skippedOverwrite: true,
          };
        }
        this.clanStore = mergeOfficialStateStore(this.clanStore, { [clanTag]: refreshed });
        this.persistence.clanStates.save(this.clanStore);
        return {
          endpoint: 'clan' as const,
          tag: clanTag,
          status: refreshed.status,
          failureKind: refreshed.failureKind,
        };
      } finally {
        this.clanCoordinator.endBatch();
      }
    });
  }

  private async refreshClanWar(
    request: ApiRefreshRequest,
    signal: AbortSignal | undefined,
  ): Promise<ApiRefreshEndpointResultDto> {
    const clanTag = this.resolveClanTag(request);
    return this.runClanExclusive(clanTag, async () => {
      const batchStartMs = this.clock.nowMs();
      const previous = this.clanWarStore.states[clanTag];
      const refreshed = await fetchSingleOfficialEndpoint({
        tag: clanTag,
        previous,
        parserVersion: clanWarParserVersion,
        nowMs: batchStartMs,
        signal,
        fetch: (tag, fetchSignal) => this.client.fetchClanWar(tag, fetchSignal),
      });
      if (
        shouldSkipFailedOverwrite({
          refreshedState: refreshed,
          existing: this.clanWarStore.states[clanTag],
          batchStartMs,
        })
      ) {
        return {
          endpoint: 'clanWar' as const,
          tag: clanTag,
          status: this.clanWarStore.states[clanTag]!.status,
          skippedOverwrite: true,
        };
      }
      this.clanWarStore = mergeOfficialStateStore(this.clanWarStore, { [clanTag]: refreshed });
      this.persistence.clanWarStates.save(this.clanWarStore);
      return {
        endpoint: 'clanWar' as const,
        tag: clanTag,
        status: refreshed.status,
        failureKind: refreshed.failureKind,
      };
    });
  }

  private async refreshWarLog(
    request: ApiRefreshRequest,
    signal: AbortSignal | undefined,
  ): Promise<ApiRefreshEndpointResultDto> {
    const clanTag = this.resolveClanTag(request);
    return this.runClanExclusive(clanTag, async () => {
      const batchStartMs = this.clock.nowMs();
      const previous = this.clanWarLogStore.states[clanTag];
      const refreshed = await fetchSingleOfficialEndpoint({
        tag: clanTag,
        previous,
        parserVersion: clanWarLogParserVersion,
        nowMs: batchStartMs,
        signal,
        fetch: async (tag, fetchSignal) => {
          const page = await this.client.fetchWarLog(tag, { signal: fetchSignal });
          const trimmed = trimmedPage(page, MAX_WAR_LOG_ITEMS_PER_TAG);
          return {
            page: trimmed,
            unrecognizedKeys: [] satisfies readonly string[],
          };
        },
      });
      if (
        shouldSkipFailedOverwrite({
          refreshedState: refreshed,
          existing: this.clanWarLogStore.states[clanTag],
          batchStartMs,
        })
      ) {
        return {
          endpoint: 'warLog' as const,
          tag: clanTag,
          status: this.clanWarLogStore.states[clanTag]!.status,
          skippedOverwrite: true,
        };
      }
      this.persistWarLog(clanTag, refreshed, batchStartMs);
      return {
        endpoint: 'warLog' as const,
        tag: clanTag,
        status: refreshed.status,
        failureKind: refreshed.failureKind,
      };
    });
  }

  private async refreshCapitalRaid(
    request: ApiRefreshRequest,
    signal: AbortSignal | undefined,
  ): Promise<ApiRefreshEndpointResultDto> {
    const clanTag = this.resolveClanTag(request);
    return this.runClanExclusive(clanTag, async () => {
      const batchStartMs = this.clock.nowMs();
      const previous = this.clanCapitalStore.states[clanTag];
      const refreshed = await fetchSingleOfficialEndpoint({
        tag: clanTag,
        previous,
        parserVersion: clanCapitalParserVersion,
        nowMs: batchStartMs,
        signal,
        fetch: async (tag, fetchSignal) => {
          const page = await this.client.fetchCapitalRaidSeasons(tag, { signal: fetchSignal });
          const trimmed = trimmedPage(page, MAX_CAPITAL_SEASONS_PER_TAG);
          return {
            page: trimmed,
            unrecognizedKeys: [] satisfies readonly string[],
          };
        },
      });
      if (
        shouldSkipFailedOverwrite({
          refreshedState: refreshed,
          existing: this.clanCapitalStore.states[clanTag],
          batchStartMs,
        })
      ) {
        return {
          endpoint: 'capitalRaid' as const,
          tag: clanTag,
          status: this.clanCapitalStore.states[clanTag]!.status,
          skippedOverwrite: true,
        };
      }
      this.persistCapital(clanTag, refreshed, batchStartMs);
      return {
        endpoint: 'capitalRaid' as const,
        tag: clanTag,
        status: refreshed.status,
        failureKind: refreshed.failureKind,
      };
    });
  }

  private resolveClanTag(request: ApiRefreshRequest): string {
    const explicit = this.normalizeOptionalTag(request.clanTag ?? null);
    if (explicit !== null) {
      return explicit;
    }
    const villageId = request.villageId;
    if (villageId !== undefined && villageId !== null && villageId.length > 0) {
      const village = this.requireVillage(villageId);
      const playerTag = this.normalizeOptionalTag(village.tag);
      if (playerTag !== null) {
        const playerState = this.playerStore.states[playerTag];
        if (playerState !== undefined) {
          const fromPlayer = officialAPICurrentClanTag(playerState);
          if (fromPlayer !== undefined) {
            return fromPlayer;
          }
        }
      }
    }
    throw new AppServiceError(
      'validation',
      'api.refresh 部落端点必须显式传入 clanTag，或提供可解析部落的 villageId。',
    );
  }

  private persistWarLog(tag: string, state: ClanWarLogAPIState, _nowMs: number): void {
    this.clanWarLogStore = mergeOfficialStateStore(this.clanWarLogStore, { [tag]: state });
    this.persistence.clanWarLogStates.save(this.clanWarLogStore);
  }

  private persistCapital(tag: string, state: ClanCapitalAPIState, _nowMs: number): void {
    this.clanCapitalStore = mergeOfficialStateStore(this.clanCapitalStore, { [tag]: state });
    this.persistence.clanCapitalStates.save(this.clanCapitalStore);
  }

  private runPlayerExclusive<T>(work: () => Promise<T>): Promise<T> {
    const run = this.playerChain.then(work, work);
    this.playerChain = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  private runClanExclusive<T>(tag: string, work: () => Promise<T>): Promise<T> {
    if (this.clanCoordinator.isPending(tag)) {
      this.clanCoordinator.enqueueTag(tag);
    }
    const run = this.clanChain.then(work, work);
    this.clanChain = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  private requireVillage(villageId: string) {
    const village = this.state.listVillages().find((entry) => entry.id === villageId);
    if (village === undefined) {
      throw new AppServiceError('notFound', `村庄不存在：${villageId}`);
    }
    return village;
  }

  private requireClanTag(raw: string): string {
    const tag = this.normalizeOptionalTag(raw);
    if (tag === null) {
      throw new AppServiceError('validation', 'clanTag 不合法。');
    }
    return tag;
  }

  private normalizeOptionalTag(raw: string | null | undefined): string | null {
    const normalized = normalizedTag(raw);
    if (normalized === undefined || !isValidTag(normalized)) {
      return null;
    }
    return normalized;
  }

  private emitProgress(payload: OperationProgressPayload): void {
    for (const listener of this.progressListeners) {
      listener(payload);
    }
  }

  private emitLoadMoreFailure(
    operationId: string,
    endpoint: OfficialEndpointKind,
    tag: string,
    error: unknown,
    signal: AbortSignal | undefined,
  ): void {
    if (signal?.aborted || isAbortLike(error)) {
      this.emitProgress({
        operationId,
        phase: 'cancelled',
        generation: this.state.getGeneration(),
        endpoint,
        tag,
        message: '已取消',
      });
      return;
    }
    this.emitProgress({
      operationId,
      phase: 'failed',
      generation: this.state.getGeneration(),
      endpoint,
      tag,
      message: error instanceof Error ? error.message : '加载失败',
    });
  }
}

function uniqueEndpoints(
  endpoints: readonly OfficialEndpointKind[],
): OfficialEndpointKind[] {
  const seen = new Set<OfficialEndpointKind>();
  const result: OfficialEndpointKind[] = [];
  for (const endpoint of endpoints) {
    if (!seen.has(endpoint)) {
      seen.add(endpoint);
      result.push(endpoint);
    }
  }
  return result;
}

function isAbortLike(error: unknown): boolean {
  return (
    (error instanceof Error && error.name === 'AbortError') ||
    (typeof error === 'object' &&
      error !== null &&
      'name' in error &&
      (error as { name?: unknown }).name === 'AbortError')
  );
}

function abortedError(): Error {
  const error = new Error('请求已取消。');
  error.name = 'AbortError';
  return error;
}
