import {
  createRefreshCoordinatorState,
  drainPendingRefreshes,
  isRefreshPending,
  RefreshCoordinator,
  shouldSkipFailedOverwrite,
} from './refresh-coordinator';
import { CoAPIRequestCancelledError } from './co-api-error';
import { describe, expect, it } from 'vitest';

describe('RefreshCoordinator predicates', () => {
  it('isRefreshPending 覆盖三个来源', () => {
    expect(
      isRefreshPending({
        state: createRefreshCoordinatorState({ inFlightTags: new Set(['#A']) }),
        tag: '#A',
      }),
    ).toBe(true);
    expect(
      isRefreshPending({
        state: createRefreshCoordinatorState({ queuedTags: new Set(['#B']) }),
        tag: '#B',
      }),
    ).toBe(true);
    expect(
      isRefreshPending({
        state: createRefreshCoordinatorState({ queuedAll: true }),
        tag: '#C',
        villageClanTags: ['#C'],
      }),
    ).toBe(true);
    expect(
      isRefreshPending({
        state: createRefreshCoordinatorState({ queuedAll: true }),
        tag: '#X',
        villageClanTags: ['#C'],
      }),
    ).toBe(false);
  });

  it('shouldSkipFailedOverwrite 防回退', () => {
    expect(
      shouldSkipFailedOverwrite({
        refreshedState: { status: 'failed' },
        existing: { status: 'success', fetchedAtMs: 2_000 },
        batchStartMs: 1_000,
      }),
    ).toBe(true);
    expect(
      shouldSkipFailedOverwrite({
        refreshedState: { status: 'failed' },
        existing: { status: 'success', fetchedAtMs: 1_000 },
        batchStartMs: 1_000,
      }),
    ).toBe(false);
  });

  it('drainPending 消费安全 tag', () => {
    const drained = drainPendingRefreshes({
      state: createRefreshCoordinatorState({
        queuedTags: new Set(['#A', '#B']),
        resolvingTags: new Set(['#B']),
      }),
      villageClanTags: [],
    });
    expect(drained.tagsToRefresh).toEqual(['#A']);
    expect(drained.state.queuedTags.has('#B')).toBe(true);
  });
});

describe('RefreshCoordinator single-flight', () => {
  it('同 tag 共享一次请求', async () => {
    const coordinator = new RefreshCoordinator<string>();
    let count = 0;
    const run = () =>
      coordinator.runSingleFlight('#TAG', async () => {
        count += 1;
        await new Promise((resolve) => setTimeout(resolve, 10));
        return 'ok';
      });
    const [a, b] = await Promise.all([run(), run()]);
    expect(a).toBe('ok');
    expect(b).toBe('ok');
    expect(count).toBe(1);
  });

  it('generation 在批次开始时递增', () => {
    const coordinator = new RefreshCoordinator<void>();
    expect(coordinator.generation).toBe(0);
    coordinator.beginBatch(['#A']);
    expect(coordinator.generation).toBe(1);
    coordinator.endBatch();
    coordinator.beginBatch(['#B']);
    expect(coordinator.generation).toBe(2);
  });

  it('run() 同步 throw 不 poison 该 tag', async () => {
    const coordinator = new RefreshCoordinator<string>();
    await expect(
      coordinator.runSingleFlight('#TAG', () => {
        throw new Error('sync validation failed');
      }),
    ).rejects.toThrow('sync validation failed');

    let count = 0;
    const result = await coordinator.runSingleFlight('#TAG', async () => {
      count += 1;
      return 'recovered';
    });
    expect(result).toBe('recovered');
    expect(count).toBe(1);
  });

  it('同一 parent 取消时全部 waiter 收到取消', async () => {
    const coordinator = new RefreshCoordinator<string>();
    const parent = new AbortController();
    const run = () =>
      coordinator.runSingleFlight(
        '#TAG',
        async (signal) => {
          await new Promise((resolve) => setTimeout(resolve, 50));
          if (signal.aborted) {
            throw new CoAPIRequestCancelledError();
          }
          return 'ok';
        },
        parent.signal,
      );
    const pending = Promise.all([run(), run()]);
    parent.abort();
    await expect(pending).rejects.toMatchObject({ name: 'AbortError' });
  });

  it('独立 parent 取消时不影响其他 waiter', async () => {
    const coordinator = new RefreshCoordinator<string>();
    const parentA = new AbortController();
    const parentB = new AbortController();
    let runs = 0;

    const runA = coordinator.runSingleFlight(
      '#TAG',
      async (signal) => {
        runs += 1;
        await new Promise((resolve) => setTimeout(resolve, 40));
        if (signal.aborted) {
          throw new CoAPIRequestCancelledError();
        }
        return 'ok';
      },
      parentA.signal,
    );
    const runB = coordinator.runSingleFlight(
      '#TAG',
      async () => {
        throw new Error('follower callback 不应执行');
      },
      parentB.signal,
    );

    await Promise.resolve();
    parentB.abort();
    await expect(runB).rejects.toMatchObject({ name: 'AbortError' });
    await expect(runA).resolves.toBe('ok');
    expect(runs).toBe(1);
  });

  it('唯一 waiter 取消时以 AbortError 结束且不 poison', async () => {
    const coordinator = new RefreshCoordinator<string>();
    const parent = new AbortController();
    const flight = coordinator.runSingleFlight(
      '#TAG',
      async (signal) => {
        await new Promise<void>((resolve, reject) => {
          const timer = setTimeout(() => resolve(), 50);
          signal.addEventListener(
            'abort',
            () => {
              clearTimeout(timer);
              reject(new CoAPIRequestCancelledError());
            },
            { once: true },
          );
        });
        return 'ok';
      },
      parent.signal,
    );
    await Promise.resolve();
    parent.abort();
    await expect(flight).rejects.toMatchObject({ name: 'AbortError' });

    await expect(coordinator.runSingleFlight('#TAG', async () => 'recovered')).resolves.toBe(
      'recovered',
    );
  });

  it('取消后立即重试不 join 已 abort 的 flight', async () => {
    const coordinator = new RefreshCoordinator<string>();
    const parent = new AbortController();
    let runs = 0;
    let releaseHang!: () => void;
    const hang = new Promise<void>((resolve) => {
      releaseHang = resolve;
    });

    const first = coordinator.runSingleFlight(
      '#TAG',
      async (signal) => {
        runs += 1;
        await new Promise<void>((resolve, reject) => {
          const onAbort = () => {
            reject(new CoAPIRequestCancelledError());
          };
          if (signal.aborted) {
            onAbort();
            return;
          }
          signal.addEventListener('abort', onAbort, { once: true });
          void hang.then(() => {
            signal.removeEventListener('abort', onAbort);
            resolve();
          });
        });
        return 'first';
      },
      parent.signal,
    );
    await Promise.resolve();
    parent.abort();
    await expect(first).rejects.toMatchObject({ name: 'AbortError' });

    const second = coordinator.runSingleFlight('#TAG', async () => {
      runs += 1;
      return 'second';
    });
    releaseHang();
    await expect(second).resolves.toBe('second');
    expect(runs).toBe(2);
  });
});
