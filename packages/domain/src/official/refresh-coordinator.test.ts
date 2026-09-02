import {
  createRefreshCoordinatorState,
  drainPendingRefreshes,
  isRefreshPending,
  RefreshCoordinator,
  shouldSkipFailedOverwrite,
} from './refresh-coordinator';
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
});
