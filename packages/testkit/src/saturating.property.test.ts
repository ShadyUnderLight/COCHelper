import { describe, expect, it } from 'vitest';

import {
  INT64_MAX,
  INT64_MIN,
  saturatingAdd,
  saturatingMultiply,
  saturatingSubtract,
} from '@coc-helper/wire';

import { runSeededProperty } from './property';

describe('饱和算术确定性属性', () => {
  it('对全 64 位附近样本等价于独立 BigInt oracle', () => {
    runSeededProperty({
      seed: 0x267n,
      iterations: 2_000,
      property: (random, iteration) => {
        const left = signed64(random.nextUint64()) + random.nextBigInt(-1024n, 1024n);
        const right = signed64(random.nextUint64()) + random.nextBigInt(-1024n, 1024n);
        const operation = random.nextInt(0, 2);
        const exact =
          operation === 0 ? left + right : operation === 1 ? left - right : left * right;
        const expected = clampInt64(exact);
        const actual =
          operation === 0
            ? saturatingAdd(left, right)
            : operation === 1
              ? saturatingSubtract(left, right)
              : saturatingMultiply(left, right);

        expect(actual, `iteration=${iteration} left=${left} right=${right}`).toEqual(expected);
      },
    });
  });
});

function signed64(value: bigint): bigint {
  return value >= 1n << 63n ? value - (1n << 64n) : value;
}

function clampInt64(value: bigint): { value: bigint; overflowed: boolean } {
  if (value < INT64_MIN) {
    return { value: INT64_MIN, overflowed: true };
  }
  if (value > INT64_MAX) {
    return { value: INT64_MAX, overflowed: true };
  }
  return { value, overflowed: false };
}
