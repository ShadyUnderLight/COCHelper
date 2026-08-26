import { describe, expect, it } from 'vitest';

import {
  createLineageId,
  isLineageId,
  isStableId,
  makeStableId,
  parseLineageId,
  type Clock,
  type UuidSource,
} from './index';
import { parseUuid, type UuidString } from '@coc-helper/wire';

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

  it('StableId 使用语义组件和 bigint 十进制文本，不依赖数组位置', () => {
    const id = makeStableId(['home', 'buildings', 10_000_000_000_000_000_001n, 'root', '-', '']);
    expect(id).toBe('home|buildings|10000000000000000001|root|-|');
    expect(makeStableId(['home', 'buildings', 1n])).toBe(makeStableId(['home', 'buildings', 1n]));
    expect(isStableId(id)).toBe(true);
    expect(isStableId('')).toBe(false);
    expect(isStableId('home|buildings\n1')).toBe(false);
    expect(() => makeStableId([])).toThrow();
    expect(() => makeStableId(['home|buildings'])).toThrow();
  });

  it('LineageId 是带语义 brand 的大写 UUID，并通过 UuidSource 注入', () => {
    const uuid = parseUuid('00112233-4455-6677-8899-aabbccddeeff');
    expect(uuid).toBeDefined();
    const lineage = createLineageId({
      next: () => uuid!,
    });
    expect(lineage).toBe('00112233-4455-6677-8899-AABBCCDDEEFF');
    expect(isLineageId(lineage)).toBe(true);
    expect(parseLineageId('00112233-4455-6677-8899-aabbccddeeff')).toBe(lineage);
    expect(parseLineageId('not-a-uuid')).toBeUndefined();
    expect(isLineageId('00112233-4455-6677-8899-aabbccddeeff')).toBe(false);
    expect(() =>
      createLineageId({
        next: () => 'not-a-uuid' as UuidString,
      }),
    ).toThrow();
  });
});
