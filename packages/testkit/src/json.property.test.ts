import { describe, expect, it } from 'vitest';

import { bytesToHex, canonicalBytes, canonicalize, parseJson } from '@coc-helper/wire';

import { runSeededProperty } from './property';

describe('lossless JSON 确定性属性', () => {
  it('随机生成的整数数组 canonicalize 后保持幂等', () => {
    runSeededProperty({
      seed: 0x2672026n,
      iterations: 500,
      property: (random, iteration) => {
        const values = Array.from({ length: 5 }, () => random.nextBigInt(-(1n << 70n), 1n << 70n));
        const source = `{"__proto__":{"values":[${values.join(',')}]}}`;
        const first = canonicalize(parseJson(source));
        const second = canonicalize(parseJson(new TextDecoder().decode(canonicalBytes(first))));
        expect(bytesToHex(canonicalBytes(second)), `iteration=${iteration}`).toBe(
          bytesToHex(canonicalBytes(first)),
        );
      },
    });
  });
});
