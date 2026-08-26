import { describe, expect, it } from 'vitest';

import { collectTestkitIsolationHits } from './check-testkit-isolation.mjs';

describe('testkit isolation', () => {
  it('desktop / 生产包不得依赖或打包 testkit 与 Swift oracle', () => {
    expect(collectTestkitIsolationHits()).toEqual([]);
  });
});
