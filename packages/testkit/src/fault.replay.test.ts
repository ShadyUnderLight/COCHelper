import { describe, expect, it } from 'vitest';

import {
  makeReplayToken,
  parseReplayToken,
  replaySeededProperty,
  serializeReplayToken,
} from './replay';

describe('fault replay token', () => {
  it('使用十进制 seed 和 iteration 往返序列化', () => {
    const token = makeReplayToken(99, 2);
    expect(parseReplayToken(serializeReplayToken(token))).toEqual(token);
  });

  it('相同 token 能重放到同一个失败 iteration', () => {
    const token = makeReplayToken(99, 2);
    expect(() =>
      replaySeededProperty(token, (_random, iteration) => {
        if (iteration === 2) {
          throw new Error('故意注入 fault');
        }
      }),
    ).toThrow('seed=99, iteration=2');
  });
});
