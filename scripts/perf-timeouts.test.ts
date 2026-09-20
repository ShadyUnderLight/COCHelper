import { afterEach, describe, expect, it, vi } from 'vitest';

import {
  evaluateWithTimeout,
  PerfTimeoutError,
  remainingTimeoutMs,
  withHardTimeout,
} from './perf-timeouts.mjs';

afterEach(() => {
  vi.useRealTimers();
});

describe('perf timeouts', () => {
  it('剩余 deadline 不会重新授予完整 timeout，过期时直接失败', () => {
    expect(remainingTimeoutMs(1_000, 'sidebar', 900)).toBe(100);
    expect(() => remainingTimeoutMs(1_000, 'sidebar', 1_000)).toThrowError(PerfTimeoutError);
  });

  it('永不 resolve 的 promise 会在 hard timeout 处失败', async () => {
    vi.useFakeTimers();
    const pending = withHardTimeout(() => new Promise(() => undefined), 100, 'bridge');
    const assertion = expect(pending).rejects.toMatchObject({
      name: 'PerfTimeoutError',
      label: 'bridge',
      timeoutMs: 100,
    });

    await vi.advanceTimersByTimeAsync(100);
    await assertion;
  });

  it('operation rejection 会原样传播且不被 timeout 覆盖', async () => {
    await expect(
      withHardTimeout(
        async () => {
          throw new Error('operation failed');
        },
        100,
        'operation',
      ),
    ).rejects.toThrow('operation failed');
  });

  it('evaluateWithTimeout 为 page.evaluate 提供同一 hard timeout 边界', async () => {
    vi.useFakeTimers();
    const page = {
      evaluate: vi.fn(() => new Promise(() => undefined)),
    };
    const pending = evaluateWithTimeout(page, () => undefined, undefined, 50, 'snapshot');
    const assertion = expect(pending).rejects.toBeInstanceOf(PerfTimeoutError);

    await vi.advanceTimersByTimeAsync(50);
    await assertion;
    expect(page.evaluate).toHaveBeenCalledTimes(1);
  });
});
