import { describe, expect, it } from 'vitest';

import { GenerationBoundSlot, STALE_PENDING_MESSAGE } from './pending-slot';

function stale(): never {
  throw new Error(STALE_PENDING_MESSAGE);
}

describe('GenerationBoundSlot', () => {
  it('fresh 取回值，null 取回 null 且不触发 onStale', () => {
    const slot = new GenerationBoundSlot<string>();
    let staleCalls = 0;
    expect(
      slot.takeLive(7, () => {
        staleCalls += 1;
        throw new Error('unreachable');
      }),
    ).toBeNull();
    slot.store('a', 7);
    expect(
      slot.takeLive(7, () => {
        staleCalls += 1;
        throw new Error('unreachable');
      }),
    ).toBe('a');
    expect(staleCalls).toBe(0);
    expect(slot.peek()).toBe('a');
  });

  it('stale 时清理并调用 onStale，之后取回 null', () => {
    const slot = new GenerationBoundSlot<string>();
    slot.store('a', 10);
    expect(() => slot.takeLive(11, stale)).toThrow(STALE_PENDING_MESSAGE);
    expect(slot.peek()).toBeNull();
    let staleCalls = 0;
    expect(
      slot.takeLive(11, () => {
        staleCalls += 1;
        throw new Error('unreachable');
      }),
    ).toBeNull();
    expect(staleCalls).toBe(0);
  });

  it('后存覆盖先存，clear 清空', () => {
    const slot = new GenerationBoundSlot<string>();
    slot.store('a', 1);
    slot.store('b', 2);
    expect(slot.peek()).toBe('b');
    slot.clear();
    expect(slot.peek()).toBeNull();
  });
});
