import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account/parser';
import { canonicalizeSnapshotHistory, snapshotHistoryDuplicateKeysMatch } from './index';

class FixedClock {
  nowMs(): number {
    return 1_700_000_000_000;
  }
}

describe('snapshot history duplicate key 属性', () => {
  it('同 entry 自匹配且 parser 元数据变化仍视为 duplicate', () => {
    const villageID = parseUuid('00000000-0000-0000-0000-000000000001')!;
    const lineageID = parseUuid('00000000-0000-0000-0000-000000000002')!;

    for (let iteration = 0; iteration < 100; iteration += 1) {
      const level = 1 + (iteration % 50);
      const text = `{"tag":"#P1","buildings":[{"data":1000013,"lvl":${level}}]}`;
      const parsed = parseAccountSnapshot(text, { clock: new FixedClock() });
      expect(parsed.ok).toBe(true);
      if (!parsed.ok) {
        return;
      }

      const left = canonicalizeSnapshotHistory(parsed.value, {
        villageID,
        lineageID,
        appliedAtRefSeconds: iteration,
        snapshotID: parseUuid('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')!,
      });
      const right = {
        ...canonicalizeSnapshotHistory(parsed.value, {
          villageID,
          lineageID,
          appliedAtRefSeconds: iteration + 1000,
          snapshotID: parseUuid('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')!,
        }),
        parserVersion: 'account-json-9.9',
      };

      expect(snapshotHistoryDuplicateKeysMatch(left, left), `iteration=${iteration}`).toBe(true);
      expect(snapshotHistoryDuplicateKeysMatch(left, right), `iteration=${iteration}`).toBe(true);
      expect(snapshotHistoryDuplicateKeysMatch(right, left), `iteration=${iteration}`).toBe(true);
    }
  });

  it('内容变化后不视为 duplicate', () => {
    const villageID = parseUuid('00000000-0000-0000-0000-000000000001')!;
    const lineageID = parseUuid('00000000-0000-0000-0000-000000000002')!;
    const leftParsed = parseAccountSnapshot(
      '{"tag":"#P1","buildings":[{"data":1000013,"lvl":1}]}',
      {
        clock: new FixedClock(),
      },
    );
    const rightParsed = parseAccountSnapshot(
      '{"tag":"#P1","buildings":[{"data":1000013,"lvl":2}]}',
      {
        clock: new FixedClock(),
      },
    );
    expect(leftParsed.ok).toBe(true);
    expect(rightParsed.ok).toBe(true);
    if (!leftParsed.ok || !rightParsed.ok) {
      return;
    }

    const left = canonicalizeSnapshotHistory(leftParsed.value, {
      villageID,
      lineageID,
      appliedAtRefSeconds: 1,
    });
    const right = canonicalizeSnapshotHistory(rightParsed.value, {
      villageID,
      lineageID,
      appliedAtRefSeconds: 2,
    });
    expect(snapshotHistoryDuplicateKeysMatch(left, right)).toBe(false);
  });
});
