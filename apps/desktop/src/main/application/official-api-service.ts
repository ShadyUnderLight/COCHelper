/**
 * OfficialApiService（#276-S4）：Official Player / Clan / Current War / WarLog / Capital Raid
 * 的 query、api.refresh、loadMore、operation.progress 与 last-good / 取消 / 重试接线。
 *
 * 对应父 issue 中的 OfficialPlayerService / ClanService / WarLogService /
 * CapitalRaidService / RefreshCoordinator 职责，本切片收敛为单一 Main 编排入口。
 *
 * 持久化约定：
 * - player-states 按 villageId 索引（playerTag 仅为 state 字段，且必须与当前村 tag 匹配才算归属）；
 * - 写盘成功后才更新内存权威 store；
 * - 取消不落盘；
 * - generation bump 绑定实际成功的 commit（与 waiter 是否仍存活无关）；
 * - 同 store + 同 tag 的 refresh/loadMore 经 KeyedMutex 串行，避免 stale success 覆盖。
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
  KeyedMutex,
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
  type OfficialEndpointState,
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

type WarLogLoadMoreOutcome = {
  readonly state: ClanWarLogAPIState;
  readonly mutated: boolean;
};

type CapitalRaidLoadMoreOutcome = {
  readonly state: ClanCapitalAPIState;
  readonly mutated: boolean;
};

type RefreshEndpointOutcome = {
  readonly dto: ApiRefreshEndpointResultDto;
  readonly persisted: boolean;
};

export class OfficialApiService {
  private readonly state: AppAuthoritativeState;
  private readonly clock: Clock;
  private readonly persistence: PersistenceBootstrapResult;
  private readonly client: CoAPIClient;
  private readonly progressListeners = new Set<OperationProgressListener>();

  /** 按操作语义拆分的 typed single-flight，禁止跨 endpoint / refresh↔loadMore 合并。 */
  private readonly playerCoordinator = new RefreshCoordinator<RefreshEndpointOutcome>();
  private readonly clanRefreshCoordinator = new RefreshCoordinator<RefreshEndpointOutcome>();
  private readonly clanWarRefreshCoordinator = new RefreshCoordinator<RefreshEndpointOutcome>();
  private readonly warLogRefreshCoordinator = new RefreshCoordinator<RefreshEndpointOutcome>();
  private readonly capitalRaidRefreshCoordinator = new RefreshCoordinator<RefreshEndpointOutcome>();
  private readonly warLogLoadMoreCoordinator = new RefreshCoordinator<WarLogLoadMoreOutcome>();
  private readonly capitalRaidLoadMoreCoordinator =
    new RefreshCoordinator<CapitalRaidLoadMoreOutcome>();
  /** 同 store + 同 tag 的 read→fetch→commit 串行（跨 refresh/loadMore）。 */
  private readonly storeMutex = new KeyedMutex();

  private playerStore: OfficialStateStore<OfficialAPIState>;
  private clanStore: OfficialStateStore<ClanAPIState>;
  private clanWarStore: OfficialStateStore<ClanWarAPIState>;
  private clanWarLogStore: OfficialStateStore<ClanWarLogAPIState>;
  private clanCapitalStore: OfficialStateStore<ClanCapitalAPIState>;

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
    const state = this.ownedPlayerState(request.villageId, playerTag) ?? null;
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
        throwIfAborted(signal);
        const { dto } = await this.refreshEndpoint(endpoint, request, signal);
        results.push(dto);
        this.emitProgress({
          operationId: request.requestId,
          phase: 'endpointFinished',
          generation: this.state.getGeneration(),
          endpoint,
          tag: dto.tag,
          status: dto.status,
        });
      }
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
      const outcome = await this.runFlight(
        this.warLogLoadMoreCoordinator,
        clanTag,
        signal,
        async (flightSignal) =>
          this.storeMutex.runExclusive(warLogStoreKey(clanTag), () =>
            this.loadMoreWarLogBody(clanTag, flightSignal),
          ),
      );
      this.emitProgress({
        operationId: request.requestId,
        phase: 'completed',
        generation: this.state.getGeneration(),
        endpoint: 'warLog',
        tag: clanTag,
        status: outcome.state.status,
      });
      return {
        generation: this.state.getGeneration(),
        clanTag,
        state: toWarLogEndpointDto(outcome.state),
      };
    } catch (error) {
      this.emitLoadMoreFailure(request.requestId, 'warLog', clanTag, error, signal);
      throw isAbortLike(error) ? abortedError() : error;
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
      const outcome = await this.runFlight(
        this.capitalRaidLoadMoreCoordinator,
        clanTag,
        signal,
        async (flightSignal) =>
          this.storeMutex.runExclusive(capitalRaidStoreKey(clanTag), () =>
            this.loadMoreCapitalRaidBody(clanTag, flightSignal),
          ),
      );
      this.emitProgress({
        operationId: request.requestId,
        phase: 'completed',
        generation: this.state.getGeneration(),
        endpoint: 'capitalRaid',
        tag: clanTag,
        status: outcome.state.status,
      });
      return {
        generation: this.state.getGeneration(),
        clanTag,
        state: toCapitalRaidEndpointDto(outcome.state),
      };
    } catch (error) {
      this.emitLoadMoreFailure(request.requestId, 'capitalRaid', clanTag, error, signal);
      throw isAbortLike(error) ? abortedError() : error;
    }
  }

  private async loadMoreWarLogBody(
    clanTag: string,
    signal: AbortSignal | undefined,
  ): Promise<WarLogLoadMoreOutcome> {
    const previous = this.clanWarLogStore.states[clanTag];
    const existingPage = previous?.lastGood?.page;

    if (existingPage === undefined) {
      const fetched = await fetchSingleOfficialEndpoint({
        tag: clanTag,
        previous: undefined,
        parserVersion: clanWarLogParserVersion,
        nowMs: this.clock.nowMs(),
        signal,
        fetch: async (tag, fetchSignal) => {
          const page = await this.client.fetchWarLog(tag, { signal: fetchSignal });
          const trimmed = trimmedPage(page, MAX_WAR_LOG_ITEMS_PER_TAG);
          return { page: trimmed, unrecognizedKeys: [] satisfies readonly string[] };
        },
      });
      throwIfCancelledEndpoint(fetched, signal);
      this.commitWarLog(clanTag, fetched);
      return { state: fetched, mutated: true };
    }

    if (
      existingPage.after === undefined ||
      isCapReached(existingPage.items.length, MAX_WAR_LOG_ITEMS_PER_TAG)
    ) {
      return { state: previous!, mutated: false };
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
    throwIfCancelledEndpoint(fetched, signal);

    if (fetched.status !== 'success' || fetched.lastGood === undefined) {
      this.commitWarLog(clanTag, fetched);
      return { state: fetched, mutated: true };
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
    this.commitWarLog(clanTag, merged);
    return { state: merged, mutated: true };
  }

  private async loadMoreCapitalRaidBody(
    clanTag: string,
    signal: AbortSignal | undefined,
  ): Promise<CapitalRaidLoadMoreOutcome> {
    const previous = this.clanCapitalStore.states[clanTag];
    const existingPage = previous?.lastGood?.page;

    if (existingPage === undefined) {
      const fetched = await fetchSingleOfficialEndpoint({
        tag: clanTag,
        previous: undefined,
        parserVersion: clanCapitalParserVersion,
        nowMs: this.clock.nowMs(),
        signal,
        fetch: async (tag, fetchSignal) => {
          const page = await this.client.fetchCapitalRaidSeasons(tag, { signal: fetchSignal });
          const trimmed = trimmedPage(page, MAX_CAPITAL_SEASONS_PER_TAG);
          return { page: trimmed, unrecognizedKeys: [] satisfies readonly string[] };
        },
      });
      throwIfCancelledEndpoint(fetched, signal);
      this.commitCapital(clanTag, fetched);
      return { state: fetched, mutated: true };
    }

    if (
      existingPage.after === undefined ||
      isCapReached(existingPage.items.length, MAX_CAPITAL_SEASONS_PER_TAG)
    ) {
      return { state: previous!, mutated: false };
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
    throwIfCancelledEndpoint(fetched, signal);

    if (fetched.status !== 'success' || fetched.lastGood === undefined) {
      this.commitCapital(clanTag, fetched);
      return { state: fetched, mutated: true };
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
    this.commitCapital(clanTag, merged);
    return { state: merged, mutated: true };
  }

  private async refreshEndpoint(
    endpoint: OfficialEndpointKind,
    request: ApiRefreshRequest,
    signal: AbortSignal | undefined,
  ): Promise<RefreshEndpointOutcome> {
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
  ): Promise<RefreshEndpointOutcome> {
    const villageId = request.villageId;
    if (villageId === undefined || villageId === null || villageId.length === 0) {
      throw new AppServiceError('validation', 'api.refresh player 必须显式传入 villageId。');
    }
    const village = this.requireVillage(villageId);
    const playerTag = this.normalizeOptionalTag(village.tag);
    const flightKey = `${villageId}:${playerTag ?? ''}`;

    return this.runFlight(
      this.playerCoordinator,
      flightKey,
      signal,
      async (flightSignal): Promise<RefreshEndpointOutcome> => {
        const expectedTag = playerTag;
        const previous = this.ownedPlayerState(villageId, playerTag);

        if (playerTag === null) {
          const skipped = skippedOfficialPlayerState(previous, '缺少有效的玩家 tag，已跳过');
          return {
            dto: {
              endpoint: 'player',
              tag: null,
              status: skipped.status,
            },
            persisted: false,
          };
        }

        const nowMs = this.clock.nowMs();
        const refreshed = await refreshOfficialPlayerState({
          tag: playerTag,
          previous,
          nowMs,
          signal: flightSignal,
          fetch: (tag, fetchSignal) => this.client.fetchPlayer(tag, fetchSignal),
        });

        const currentVillage = this.requireVillage(villageId);
        const currentTag = this.normalizeOptionalTag(currentVillage.tag);
        if (currentTag !== expectedTag) {
          return {
            dto: {
              endpoint: 'player',
              tag: playerTag,
              status: 'skipped',
            },
            persisted: false,
          };
        }

        this.commitPlayer(villageId, refreshed);
        return {
          dto: {
            endpoint: 'player',
            tag: playerTag,
            status: refreshed.status,
          },
          persisted: true,
        };
      },
    );
  }

  private async refreshClan(
    request: ApiRefreshRequest,
    signal: AbortSignal | undefined,
  ): Promise<RefreshEndpointOutcome> {
    const clanTag = this.resolveClanTag(request);
    return this.runFlight(
      this.clanRefreshCoordinator,
      clanTag,
      signal,
      async (flightSignal): Promise<RefreshEndpointOutcome> => {
        const batchStartMs = this.clock.nowMs();
        const previous = this.clanStore.states[clanTag];
        const refreshed = await fetchSingleOfficialEndpoint({
          tag: clanTag,
          previous,
          parserVersion: clanSnapshotParserVersion,
          nowMs: batchStartMs,
          signal: flightSignal,
          fetch: (tag, fetchSignal) => this.client.fetchClan(tag, fetchSignal),
        });
        throwIfCancelledEndpoint(refreshed, flightSignal);
        if (
          shouldSkipFailedOverwrite({
            refreshedState: refreshed,
            existing: this.clanStore.states[clanTag],
            batchStartMs,
          })
        ) {
          return {
            dto: {
              endpoint: 'clan',
              tag: clanTag,
              status: this.clanStore.states[clanTag]!.status,
              skippedOverwrite: true,
            },
            persisted: false,
          };
        }
        this.commitClan(clanTag, refreshed);
        return {
          dto: {
            endpoint: 'clan',
            tag: clanTag,
            status: refreshed.status,
            failureKind: refreshed.failureKind,
          },
          persisted: true,
        };
      },
    );
  }

  private async refreshClanWar(
    request: ApiRefreshRequest,
    signal: AbortSignal | undefined,
  ): Promise<RefreshEndpointOutcome> {
    const clanTag = this.resolveClanTag(request);
    return this.runFlight(
      this.clanWarRefreshCoordinator,
      clanTag,
      signal,
      async (flightSignal): Promise<RefreshEndpointOutcome> => {
        const batchStartMs = this.clock.nowMs();
        const previous = this.clanWarStore.states[clanTag];
        const refreshed = await fetchSingleOfficialEndpoint({
          tag: clanTag,
          previous,
          parserVersion: clanWarParserVersion,
          nowMs: batchStartMs,
          signal: flightSignal,
          fetch: (tag, fetchSignal) => this.client.fetchClanWar(tag, fetchSignal),
        });
        throwIfCancelledEndpoint(refreshed, flightSignal);
        if (
          shouldSkipFailedOverwrite({
            refreshedState: refreshed,
            existing: this.clanWarStore.states[clanTag],
            batchStartMs,
          })
        ) {
          return {
            dto: {
              endpoint: 'clanWar',
              tag: clanTag,
              status: this.clanWarStore.states[clanTag]!.status,
              skippedOverwrite: true,
            },
            persisted: false,
          };
        }
        this.commitClanWar(clanTag, refreshed);
        return {
          dto: {
            endpoint: 'clanWar',
            tag: clanTag,
            status: refreshed.status,
            failureKind: refreshed.failureKind,
          },
          persisted: true,
        };
      },
    );
  }

  private async refreshWarLog(
    request: ApiRefreshRequest,
    signal: AbortSignal | undefined,
  ): Promise<RefreshEndpointOutcome> {
    const clanTag = this.resolveClanTag(request);
    return this.runFlight(
      this.warLogRefreshCoordinator,
      clanTag,
      signal,
      async (flightSignal): Promise<RefreshEndpointOutcome> =>
        this.storeMutex.runExclusive(warLogStoreKey(clanTag), async () => {
          const batchStartMs = this.clock.nowMs();
          const previous = this.clanWarLogStore.states[clanTag];
          const refreshed = await fetchSingleOfficialEndpoint({
            tag: clanTag,
            previous,
            parserVersion: clanWarLogParserVersion,
            nowMs: batchStartMs,
            signal: flightSignal,
            fetch: async (tag, fetchSignal) => {
              const page = await this.client.fetchWarLog(tag, { signal: fetchSignal });
              const trimmed = trimmedPage(page, MAX_WAR_LOG_ITEMS_PER_TAG);
              return {
                page: trimmed,
                unrecognizedKeys: [] satisfies readonly string[],
              };
            },
          });
          throwIfCancelledEndpoint(refreshed, flightSignal);
          if (
            shouldSkipFailedOverwrite({
              refreshedState: refreshed,
              existing: this.clanWarLogStore.states[clanTag],
              batchStartMs,
            })
          ) {
            return {
              dto: {
                endpoint: 'warLog',
                tag: clanTag,
                status: this.clanWarLogStore.states[clanTag]!.status,
                skippedOverwrite: true,
              },
              persisted: false,
            };
          }
          this.commitWarLog(clanTag, refreshed);
          return {
            dto: {
              endpoint: 'warLog',
              tag: clanTag,
              status: refreshed.status,
              failureKind: refreshed.failureKind,
            },
            persisted: true,
          };
        }),
    );
  }

  private async refreshCapitalRaid(
    request: ApiRefreshRequest,
    signal: AbortSignal | undefined,
  ): Promise<RefreshEndpointOutcome> {
    const clanTag = this.resolveClanTag(request);
    return this.runFlight(
      this.capitalRaidRefreshCoordinator,
      clanTag,
      signal,
      async (flightSignal): Promise<RefreshEndpointOutcome> =>
        this.storeMutex.runExclusive(capitalRaidStoreKey(clanTag), async () => {
          const batchStartMs = this.clock.nowMs();
          const previous = this.clanCapitalStore.states[clanTag];
          const refreshed = await fetchSingleOfficialEndpoint({
            tag: clanTag,
            previous,
            parserVersion: clanCapitalParserVersion,
            nowMs: batchStartMs,
            signal: flightSignal,
            fetch: async (tag, fetchSignal) => {
              const page = await this.client.fetchCapitalRaidSeasons(tag, { signal: fetchSignal });
              const trimmed = trimmedPage(page, MAX_CAPITAL_SEASONS_PER_TAG);
              return {
                page: trimmed,
                unrecognizedKeys: [] satisfies readonly string[],
              };
            },
          });
          throwIfCancelledEndpoint(refreshed, flightSignal);
          if (
            shouldSkipFailedOverwrite({
              refreshedState: refreshed,
              existing: this.clanCapitalStore.states[clanTag],
              batchStartMs,
            })
          ) {
            return {
              dto: {
                endpoint: 'capitalRaid',
                tag: clanTag,
                status: this.clanCapitalStore.states[clanTag]!.status,
                skippedOverwrite: true,
              },
              persisted: false,
            };
          }
          this.commitCapital(clanTag, refreshed);
          return {
            dto: {
              endpoint: 'capitalRaid',
              tag: clanTag,
              status: refreshed.status,
              failureKind: refreshed.failureKind,
            },
            persisted: true,
          };
        }),
    );
  }

  private resolveClanTag(request: ApiRefreshRequest): string {
    const explicit = this.normalizeOptionalTag(request.clanTag ?? null);
    if (explicit !== null) {
      return explicit;
    }
    const villageId = request.villageId;
    if (villageId !== undefined && villageId !== null && villageId.length > 0) {
      const village = this.requireVillage(villageId);
      const currentPlayerTag = this.normalizeOptionalTag(village.tag);
      const playerState = this.ownedPlayerState(villageId, currentPlayerTag);
      if (playerState !== undefined) {
        const fromPlayer = officialAPICurrentClanTag(playerState);
        if (fromPlayer !== undefined) {
          return fromPlayer;
        }
      }
    }
    throw new AppServiceError(
      'validation',
      'api.refresh 部落端点必须显式传入 clanTag，或提供可解析部落的 villageId。',
    );
  }

  /**
   * villageId 槽位仅在 cached.playerTag === 当前村 tag 时归属当前玩家；
   * 否则视为无缓存，避免 A→B 改 tag 后泄漏 lastGood / clan。
   */
  private ownedPlayerState(
    villageId: string,
    currentPlayerTag: string | null,
  ): OfficialAPIState | undefined {
    if (currentPlayerTag === null) {
      return undefined;
    }
    const cached = this.playerStore.states[villageId];
    if (cached === undefined || cached.playerTag !== currentPlayerTag) {
      return undefined;
    }
    return cached;
  }

  /** 写盘成功后才替换内存权威 store，并立即 bump generation。 */
  private commitPlayer(villageId: string, state: OfficialAPIState): void {
    const next = mergeOfficialStateStore(this.playerStore, { [villageId]: state });
    this.persistence.playerStates.save(next);
    this.playerStore = next;
    this.state.notifyMutation();
  }

  private commitClan(tag: string, state: ClanAPIState): void {
    const next = mergeOfficialStateStore(this.clanStore, { [tag]: state });
    this.persistence.clanStates.save(next);
    this.clanStore = next;
    this.state.notifyMutation();
  }

  private commitClanWar(tag: string, state: ClanWarAPIState): void {
    const next = mergeOfficialStateStore(this.clanWarStore, { [tag]: state });
    this.persistence.clanWarStates.save(next);
    this.clanWarStore = next;
    this.state.notifyMutation();
  }

  private commitWarLog(tag: string, state: ClanWarLogAPIState): void {
    const next = mergeOfficialStateStore(this.clanWarLogStore, { [tag]: state });
    this.persistence.clanWarLogStates.save(next);
    this.clanWarLogStore = next;
    this.state.notifyMutation();
  }

  private commitCapital(tag: string, state: ClanCapitalAPIState): void {
    const next = mergeOfficialStateStore(this.clanCapitalStore, { [tag]: state });
    this.persistence.clanCapitalStates.save(next);
    this.clanCapitalStore = next;
    this.state.notifyMutation();
  }

  private async runFlight<T>(
    coordinator: RefreshCoordinator<T>,
    key: string,
    signal: AbortSignal | undefined,
    work: (signal: AbortSignal) => Promise<T>,
  ): Promise<T> {
    return coordinator.runSingleFlight(key, work, signal);
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

function uniqueEndpoints(endpoints: readonly OfficialEndpointKind[]): OfficialEndpointKind[] {
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

function warLogStoreKey(clanTag: string): string {
  return `warLog:${clanTag}`;
}

function capitalRaidStoreKey(clanTag: string): string {
  return `capitalRaid:${clanTag}`;
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (signal?.aborted) {
    throw abortedError();
  }
}

function throwIfCancelledEndpoint<Snapshot>(
  state: OfficialEndpointState<Snapshot>,
  signal: AbortSignal | undefined,
): void {
  if (signal?.aborted || state.failureKind === 'cancelled') {
    throw abortedError();
  }
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
