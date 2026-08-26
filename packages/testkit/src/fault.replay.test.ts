import { describe, expect, it } from 'vitest';

import { FAULT_REPLAY_STATUS, runFaultReplay } from './index';

describe('fault replay 独立门禁', () => {
  it('框架入口存在，实现留给 E3-01', () => {
    expect(FAULT_REPLAY_STATUS).toBe('deferred-e3-01');
    expect(() => runFaultReplay()).toThrow('Issue #275');
  });
});
