import { describe, expect, it } from 'vitest';

import { RequestCancellationRegistry } from './request-cancellation';

describe('RequestCancellationRegistry', () => {
  it('按 sender 和 requestId 注册、取消、完成请求', () => {
    const registry = new RequestCancellationRegistry();
    const signal = registry.start(1, 'request-a');

    expect(signal.aborted).toBe(false);
    expect(registry.cancel(1, 'request-a')).toBe(true);
    expect(signal.aborted).toBe(true);
    expect(registry.cancel(1, 'request-a')).toBe(false);
    expect(registry.finish(1, 'request-a')).toBe(true);
    expect(registry.cancel(1, 'request-a')).toBe(false);
    expect(registry.finish(1, 'request-a')).toBe(false);
  });

  it('隔离相同 requestId 的不同 sender，拒绝同 sender 重复注册', () => {
    const registry = new RequestCancellationRegistry();
    const first = registry.start(1, 'shared-id');
    const second = registry.start(2, 'shared-id');

    expect(() => registry.start(1, 'shared-id')).toThrow('requestId 已在该 sender 下注册');
    expect(registry.cancel(1, 'shared-id')).toBe(true);
    expect(first.aborted).toBe(true);
    expect(second.aborted).toBe(false);
  });

  it('未知、迟到和重复 cancel 都是 no-op', () => {
    const registry = new RequestCancellationRegistry();
    const signal = registry.start(1, 'request-a');

    expect(registry.cancel(1, 'unknown')).toBe(false);
    expect(registry.cancel(2, 'request-a')).toBe(false);
    expect(registry.finish(1, 'request-a')).toBe(true);
    expect(registry.cancel(1, 'request-a')).toBe(false);
    expect(signal.aborted).toBe(false);
  });

  it('sender 清理会取消并移除该 sender 的全部请求', () => {
    const registry = new RequestCancellationRegistry();
    const first = registry.start(1, 'request-a');
    const second = registry.start(1, 'request-b');
    const other = registry.start(2, 'request-c');

    expect(registry.clearSender(1)).toBe(2);
    expect(first.aborted).toBe(true);
    expect(second.aborted).toBe(true);
    expect(other.aborted).toBe(false);
    expect(registry.clearSender(1)).toBe(0);
    expect(registry.finish(2, 'request-c')).toBe(true);
  });

  it('直接注册也拒绝不符合协议的 requestId', () => {
    const registry = new RequestCancellationRegistry();
    expect(() => registry.start(1, '')).toThrow('requestId 不合法');
    expect(registry.cancel(1, '')).toBe(false);
  });
});
