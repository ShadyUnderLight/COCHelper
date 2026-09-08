import { describe, expect, it } from 'vitest';

import { KeyedMutex } from './keyed-mutex';

describe('KeyedMutex', () => {
  it('同 key 串行；不同 key 可并行', async () => {
    const mutex = new KeyedMutex();
    const order: string[] = [];
    let releaseA!: () => void;
    const gateA = new Promise<void>((resolve) => {
      releaseA = resolve;
    });

    const a = mutex.runExclusive('k1', async () => {
      order.push('a-start');
      await gateA;
      order.push('a-end');
      return 1;
    });
    const b = mutex.runExclusive('k1', async () => {
      order.push('b');
      return 2;
    });
    const c = mutex.runExclusive('k2', async () => {
      order.push('c');
      return 3;
    });

    await Promise.resolve();
    await Promise.resolve();
    expect(order).toContain('a-start');
    expect(order).toContain('c');
    expect(order).not.toContain('b');

    releaseA();
    await expect(Promise.all([a, b, c])).resolves.toEqual([1, 2, 3]);
    expect(order.indexOf('a-end')).toBeLessThan(order.indexOf('b'));
  });
});
