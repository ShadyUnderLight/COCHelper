import { describe, expect, it } from 'vitest';

import {
  INT64_BOUNDS,
  INT64_MAX,
  INT64_MIN,
  UINT64_BOUNDS,
  UINT64_MAX,
  saturatingAdd,
  saturatingMultiply,
  saturatingSubtract,
} from './index';

describe('饱和算术', () => {
  it('Int64 加减乘法在边界处钳制并标记 overflowed', () => {
    expect(saturatingAdd(INT64_MAX, 0n)).toEqual({ value: INT64_MAX, overflowed: false });
    expect(saturatingAdd(INT64_MAX, 1n)).toEqual({ value: INT64_MAX, overflowed: true });
    expect(saturatingAdd(INT64_MIN, -1n)).toEqual({ value: INT64_MIN, overflowed: true });
    expect(saturatingSubtract(INT64_MIN, 1n)).toEqual({ value: INT64_MIN, overflowed: true });
    expect(saturatingSubtract(INT64_MAX, INT64_MIN)).toEqual({
      value: INT64_MAX,
      overflowed: true,
    });
    expect(saturatingMultiply(INT64_MIN, -1n)).toEqual({
      value: INT64_MAX,
      overflowed: true,
    });
    expect(saturatingMultiply(INT64_MIN, 0n)).toEqual({ value: 0n, overflowed: false });
  });

  it('支持 UInt64 和任意显式闭区间', () => {
    expect(saturatingAdd(UINT64_MAX, 1n, UINT64_BOUNDS)).toEqual({
      value: UINT64_MAX,
      overflowed: true,
    });
    expect(saturatingSubtract(0n, 1n, UINT64_BOUNDS)).toEqual({
      value: 0n,
      overflowed: true,
    });
    expect(saturatingMultiply(12n, 12n, { min: -100n, max: 100n })).toEqual({
      value: 100n,
      overflowed: true,
    });
    expect(saturatingAdd(2n, 3n, { min: -10n, max: 10n })).toEqual({
      value: 5n,
      overflowed: false,
    });
  });

  it('拒绝反向边界', () => {
    expect(() => saturatingAdd(1n, 2n, { min: 1n, max: 0n })).toThrow(
      '饱和算术边界必须满足 min <= max',
    );
    expect(INT64_BOUNDS.min).toBe(INT64_MIN);
    expect(INT64_BOUNDS.max).toBe(INT64_MAX);
  });

  it('结果等价于独立的精确 BigInt clamp oracle', () => {
    const values = [-1000n, -129n, -1n, 0n, 1n, 127n, 128n, 1000n];
    const operations = [
      (left: bigint, right: bigint) => saturatingAdd(left, right),
      (left: bigint, right: bigint) => saturatingSubtract(left, right),
      (left: bigint, right: bigint) => saturatingMultiply(left, right),
    ];

    for (const operation of operations) {
      for (const left of values) {
        for (const right of values) {
          const exact =
            operation === operations[0]
              ? left + right
              : operation === operations[1]
                ? left - right
                : left * right;
          const expected =
            exact < INT64_MIN
              ? { value: INT64_MIN, overflowed: true }
              : exact > INT64_MAX
                ? { value: INT64_MAX, overflowed: true }
                : { value: exact, overflowed: false };
          expect(operation(left, right)).toEqual(expected);
        }
      }
    }
  });
});
