import { describe, expect, it } from 'vitest';

import { FakeClock, SeededRandom, runSeededProperty } from './index';

describe('@coc-helper/testkit', () => {
  it('FakeClock 可推进、回拨并拒绝非有限或不安全毫秒', () => {
    const clock = new FakeClock(1_800_000_000_000);
    expect(clock.nowMs()).toBe(1_800_000_000_000);
    expect(clock.advanceBy(123)).toBe(1_800_000_000_123);
    clock.setMs(1_700_000_000_000);
    expect(clock.nowMs()).toBe(1_700_000_000_000);
    expect(() => clock.setMs(Number.NaN)).toThrow();
    expect(() => clock.advanceBy(Number.POSITIVE_INFINITY)).toThrow();
  });

  it('SeededRandom 相同 seed 可重放，不同 seed 产生独立序列', () => {
    const first = new SeededRandom(42);
    const second = new SeededRandom(42);
    const other = new SeededRandom(43);
    const firstSequence = [first.nextUint64(), first.nextUint64(), first.nextUint64()];
    const secondSequence = [second.nextUint64(), second.nextUint64(), second.nextUint64()];
    expect(firstSequence).toEqual(secondSequence);
    expect(firstSequence).toEqual([0xbdd732262feb6e95n, 0x28efe333b266f103n, 0x47526757130f9f52n]);
    expect(firstSequence).not.toEqual([other.nextUint64(), other.nextUint64(), other.nextUint64()]);
    const bounded = new SeededRandom(7);
    const boundedValue = bounded.nextBigInt(-3n, 3n);
    expect(boundedValue).toBeGreaterThanOrEqual(-3n);
    expect(boundedValue).toBeLessThanOrEqual(3n);
    expect(bounded.nextInt(-2, 2)).toBeGreaterThanOrEqual(-2);
    expect(bounded.nextInt(-2, 2)).toBeLessThanOrEqual(2);
    expect(() => bounded.nextInt(2, 1)).toThrow();
  });

  it('属性失败带 seed 和 iteration，便于重放', () => {
    expect(() =>
      runSeededProperty({
        seed: 99,
        iterations: 3,
        property: (_random, iteration) => {
          if (iteration === 2) {
            throw new Error('故意失败');
          }
        },
      }),
    ).toThrow('seed=99, iteration=2');
  });
});
