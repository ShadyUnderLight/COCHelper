import { afterEach, describe, expect, it, vi } from 'vitest';

import {
  advanceClockStoreForTests,
  clockStore,
  remainingMs,
  resetClockStoreForTests,
  useLiveClockNowForTests,
} from './clock-store';

afterEach(() => {
  resetClockStoreForTests();
  vi.useRealTimers();
});

describe('clockStore', () => {
  it('无订阅者不启动 ticker', () => {
    vi.useFakeTimers();
    resetClockStoreForTests(1000);
    vi.advanceTimersByTime(5000);
    expect(clockStore.getSnapshot()).toBe(1000);
  });

  it('有订阅时每秒 tick', () => {
    vi.useFakeTimers();
    resetClockStoreForTests(1000);
    const values: number[] = [];
    const unsubscribe = clockStore.subscribe(() => {
      values.push(clockStore.getSnapshot());
    });
    vi.advanceTimersByTime(3000);
    unsubscribe();
    expect(values.length).toBeGreaterThanOrEqual(2);
    expect(clockStore.getSnapshot()).toBeGreaterThan(1000);
  });

  it('全部退订后停止 ticker', () => {
    vi.useFakeTimers();
    resetClockStoreForTests(1000);
    const unsub = clockStore.subscribe(() => undefined);
    unsub();
    const atUnsub = clockStore.getSnapshot();
    vi.advanceTimersByTime(5000);
    expect(clockStore.getSnapshot()).toBe(atUnsub);
  });

  it('remainingMs 只做格式化', () => {
    resetClockStoreForTests(1000);
    expect(remainingMs(2500, clockStore.getSnapshot())).toBe(1500);
    advanceClockStoreForTests(2000);
    expect(remainingMs(2500, clockStore.getSnapshot())).toBe(-500);
  });

  it('首个订阅者启动 ticker 时同步系统时间', () => {
    vi.useFakeTimers();
    resetClockStoreForTests(1000);
    useLiveClockNowForTests();
    vi.setSystemTime(9_000);
    const unsubscribe = clockStore.subscribe(() => undefined);
    expect(clockStore.getSnapshot()).toBe(9_000);
    unsubscribe();
  });
});
