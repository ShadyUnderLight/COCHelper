import { describe, expect, it } from 'vitest';

import {
  jsonNumber,
  sortedObjectKeys,
  swiftStringCompare,
  swiftStringLessThan,
} from '@coc-helper/wire';

import { compareParity, loadGoldenJson } from './index';

type Pair = {
  left: string;
  right: string;
  leftLessThanRight: boolean;
  equal: boolean;
};

type Fixture = {
  inputKeys: string[];
  sortedKeys: string[];
  pairs: Pair[];
};

describe('Swift String < golden（WA-2）', () => {
  const fixture = loadGoldenJson<Fixture>('swift-string-compare.json');

  it('逐对对齐 Swift String.< 与 canonical-equivalence ==', () => {
    for (const pair of fixture.pairs) {
      expect(swiftStringLessThan(pair.left, pair.right), `${pair.left} < ${pair.right}`).toBe(
        pair.leftLessThanRight,
      );
      expect(swiftStringCompare(pair.left, pair.right) === 0, `${pair.left} == ${pair.right}`).toBe(
        pair.equal,
      );
    }
  });

  it('键排序对齐 Swift Array.sorted，且不改写原始拼写', () => {
    compareParity({
      expected: fixture.sortedKeys,
      actual: [...fixture.inputKeys].sort(swiftStringCompare),
      defaultKind: 'ordering',
    });
    compareParity({
      expected: fixture.sortedKeys,
      actual: sortedObjectKeys(
        Object.fromEntries(fixture.inputKeys.map((key) => [key, jsonNumber('1')])),
      ),
      defaultKind: 'ordering',
    });
    expect(fixture.sortedKeys.some((key) => key.includes('\u0301'))).toBe(true);
  });
});
