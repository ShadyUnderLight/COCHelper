import { describe, expect, it } from 'vitest';

import type { Clock, UuidSource } from './index';
import { parseUuid } from '@coc-helper/wire';

describe('@coc-helper/domain shared seams', () => {
  it('Clock 使用 Unix epoch 毫秒且不隐式读取系统时间', () => {
    const clock: Clock = {
      nowMs: () => 1_800_000_000_123,
    };
    expect(clock.nowMs()).toBe(1_800_000_000_123);
  });

  it('UuidSource 只约束身份来源，不重新定义 UUID 格式', () => {
    const uuid = parseUuid('00112233-4455-6677-8899-AABBCCDDEEFF');
    expect(uuid).toBeDefined();
    const source: UuidSource = {
      next: () => uuid!,
    };
    expect(source.next()).toBe(uuid);
  });
});
