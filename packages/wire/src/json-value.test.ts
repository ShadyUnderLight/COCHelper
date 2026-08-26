import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  jsonNumber,
  sortedObjectKeys,
  swiftStringCompare,
  swiftStringLessThan,
} from './json-value';

const fixturePath = join(process.cwd(), 'Tests/Golden/Fixtures/swift-string-compare.json');

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
  const fixture = JSON.parse(readFileSync(fixturePath, 'utf8')) as Fixture;

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
    expect([...fixture.inputKeys].sort(swiftStringCompare)).toEqual(fixture.sortedKeys);
    expect(
      sortedObjectKeys(Object.fromEntries(fixture.inputKeys.map((key) => [key, jsonNumber('1')]))),
    ).toEqual(fixture.sortedKeys);
    expect(fixture.sortedKeys.some((key) => key.includes('\u0301'))).toBe(true);
  });
});
