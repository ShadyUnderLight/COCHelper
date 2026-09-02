/** 官方 API 刷新并发协调（对齐 AppModel BE-6 single-flight 契约）。 */

export type RefreshCoordinatorState = {
  readonly generation: number;
  readonly inFlightTags: ReadonlySet<string>;
  readonly queuedTags: ReadonlySet<string>;
  readonly queuedAll: boolean;
  readonly resolvingTags: ReadonlySet<string>;
};

export function createRefreshCoordinatorState(input?: {
  readonly generation?: number;
  readonly inFlightTags?: ReadonlySet<string>;
  readonly queuedTags?: ReadonlySet<string>;
  readonly queuedAll?: boolean;
  readonly resolvingTags?: ReadonlySet<string>;
}): RefreshCoordinatorState {
  return {
    generation: input?.generation ?? 0,
    inFlightTags: input?.inFlightTags ?? new Set(),
    queuedTags: input?.queuedTags ?? new Set(),
    queuedAll: input?.queuedAll ?? false,
    resolvingTags: input?.resolvingTags ?? new Set(),
  };
}

export function isRefreshPending(input: {
  readonly state: RefreshCoordinatorState;
  readonly tag: string;
  readonly villageClanTags?: readonly string[];
}): boolean {
  const villageClanTags = input.villageClanTags ?? [];
  if (input.state.inFlightTags.has(input.tag)) {
    return true;
  }
  if (input.state.resolvingTags.has(input.tag)) {
    return true;
  }
  if (input.state.queuedTags.has(input.tag)) {
    return true;
  }
  if (input.state.queuedAll && villageClanTags.includes(input.tag)) {
    return true;
  }
  return false;
}

export function beginRefreshBatch(
  state: RefreshCoordinatorState,
  tags: readonly string[],
): RefreshCoordinatorState {
  return {
    ...state,
    generation: state.generation + 1,
    inFlightTags: new Set(tags),
  };
}

export function endRefreshBatch(state: RefreshCoordinatorState): RefreshCoordinatorState {
  return {
    ...state,
    inFlightTags: new Set(),
  };
}

export function enqueueRefreshTag(
  state: RefreshCoordinatorState,
  tag: string,
): RefreshCoordinatorState {
  const queuedTags = new Set(state.queuedTags);
  queuedTags.add(tag);
  return { ...state, queuedTags };
}

export function enqueueRefreshAll(state: RefreshCoordinatorState): RefreshCoordinatorState {
  return { ...state, queuedAll: true };
}

export function registerResolvingTag(
  state: RefreshCoordinatorState,
  tag: string,
): RefreshCoordinatorState {
  const resolvingTags = new Set(state.resolvingTags);
  resolvingTags.add(tag);
  return { ...state, resolvingTags };
}

export function unregisterResolvingTag(
  state: RefreshCoordinatorState,
  tag: string,
): RefreshCoordinatorState {
  const resolvingTags = new Set(state.resolvingTags);
  resolvingTags.delete(tag);
  return { ...state, resolvingTags };
}

export type DrainPendingResult = {
  readonly state: RefreshCoordinatorState;
  readonly tagsToRefresh: readonly string[];
};

export function drainPendingRefreshes(input: {
  readonly state: RefreshCoordinatorState;
  readonly villageClanTags: readonly string[];
}): DrainPendingResult {
  if (input.state.inFlightTags.size > 0) {
    return { state: input.state, tagsToRefresh: [] };
  }
  if (!input.state.queuedAll && input.state.queuedTags.size === 0) {
    return { state: input.state, tagsToRefresh: [] };
  }

  const blockedTags = input.state.resolvingTags;
  const safePending = [...input.state.queuedTags].filter((tag) => !blockedTags.has(tag));

  let shouldDrainAll = false;
  let villageTagsForDrain: string[] = [];
  let shouldClearPendingAll = false;

  if (input.state.queuedAll) {
    const blockedVillage = input.villageClanTags.filter((tag) => blockedTags.has(tag));
    if (blockedVillage.length === 0) {
      shouldDrainAll = true;
      shouldClearPendingAll = true;
      villageTagsForDrain = [...input.villageClanTags];
    } else if (safePending.length === 0) {
      return { state: input.state, tagsToRefresh: [] };
    }
  }

  const tags: string[] = [];
  if (shouldDrainAll) {
    tags.push(...villageTagsForDrain);
  }
  for (const tag of safePending) {
    if (!tags.includes(tag)) {
      tags.push(tag);
    }
  }

  const nextQueuedTags = new Set(input.state.queuedTags);
  for (const tag of safePending) {
    nextQueuedTags.delete(tag);
  }

  const nextState: RefreshCoordinatorState = {
    ...input.state,
    queuedAll: shouldClearPendingAll ? false : input.state.queuedAll,
    queuedTags: nextQueuedTags,
  };

  if (tags.length === 0) {
    return { state: nextState, tagsToRefresh: [] };
  }
  return { state: nextState, tagsToRefresh: tags };
}

export function shouldSkipFailedOverwrite<
  State extends {
    readonly status: string;
    readonly fetchedAtMs?: number | undefined;
  },
>(input: {
  readonly refreshedState: State;
  readonly existing: State | undefined;
  readonly batchStartMs: number;
}): boolean {
  if (input.refreshedState.status !== 'failed') {
    return false;
  }
  if (input.existing === undefined || input.existing.status !== 'success') {
    return false;
  }
  if (input.existing.fetchedAtMs === undefined) {
    return false;
  }
  return input.existing.fetchedAtMs > input.batchStartMs;
}

type SharedFlightEntry<TResult> = {
  readonly promise: Promise<TResult>;
  readonly controller: AbortController;
};

export class RefreshCoordinator<TResult> {
  private state = createRefreshCoordinatorState();
  private sharedFlights = new Map<string, SharedFlightEntry<TResult>>();

  get generation(): number {
    return this.state.generation;
  }

  getState(): RefreshCoordinatorState {
    return this.state;
  }

  isPending(tag: string, villageClanTags: readonly string[] = []): boolean {
    return isRefreshPending({ state: this.state, tag, villageClanTags });
  }

  beginBatch(tags: readonly string[]): void {
    this.state = beginRefreshBatch(this.state, tags);
  }

  endBatch(): void {
    this.state = endRefreshBatch(this.state);
  }

  enqueueTag(tag: string): void {
    this.state = enqueueRefreshTag(this.state, tag);
  }

  enqueueAll(): void {
    this.state = enqueueRefreshAll(this.state);
  }

  drain(villageClanTags: readonly string[]): readonly string[] {
    const result = drainPendingRefreshes({ state: this.state, villageClanTags });
    this.state = result.state;
    return result.tagsToRefresh;
  }

  async runSingleFlight(
    tag: string,
    run: (signal: AbortSignal) => Promise<TResult>,
    parentSignal?: AbortSignal,
  ): Promise<TResult> {
    const existing = this.sharedFlights.get(tag);
    if (existing !== undefined) {
      return awaitSharedFlight(existing, parentSignal);
    }

    const controller = new AbortController();
    if (parentSignal !== undefined) {
      if (parentSignal.aborted) {
        controller.abort(parentSignal.reason);
      } else {
        parentSignal.addEventListener(
          'abort',
          () => {
            controller.abort(parentSignal.reason);
          },
          { once: true },
        );
      }
    }

    const promise = Promise.resolve()
      .then(() => run(controller.signal))
      .finally(() => {
        const current = this.sharedFlights.get(tag);
        if (current?.controller === controller) {
          this.sharedFlights.delete(tag);
        }
        this.state = unregisterResolvingTag(this.state, tag);
      });
    const entry: SharedFlightEntry<TResult> = { promise, controller };
    this.sharedFlights.set(tag, entry);
    this.state = registerResolvingTag(this.state, tag);
    return awaitSharedFlight(entry, parentSignal);
  }
}

async function awaitSharedFlight<TResult>(
  entry: SharedFlightEntry<TResult>,
  parentSignal?: AbortSignal,
): Promise<TResult> {
  if (parentSignal?.aborted) {
    entry.controller.abort(parentSignal.reason);
  } else if (parentSignal !== undefined) {
    const onAbort = () => {
      entry.controller.abort(parentSignal.reason);
    };
    parentSignal.addEventListener('abort', onAbort, { once: true });
    try {
      return await entry.promise;
    } finally {
      parentSignal.removeEventListener('abort', onAbort);
    }
  }
  return entry.promise;
}
