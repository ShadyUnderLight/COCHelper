import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account/parser';
import { canonicalizeSnapshotHistory, diagnoseSnapshotHistoryComplexity } from './index';

class FixedClock {
  nowMs(): number {
    return 1_700_000_000_000;
  }
}

describe('diagnoseSnapshotHistoryComplexity', () => {
  it('空 entries 返回零值诊断', () => {
    expect(diagnoseSnapshotHistoryComplexity([])).toEqual({
      entryCount: 0,
      totalItemCount: 0,
      maxNestedDepth: 0,
      maxItemsPerEntry: 0,
      largestEntrySnapshotID: null,
    });
  });

  it('统计 item 总数、最大嵌套深度与最大 entry', () => {
    const deepNestedText = JSON.stringify({
      tag: '#P1',
      buildings: [
        {
          data: 1_000_001,
          types: [
            {
              data: 777,
              modules: [
                {
                  data: 888,
                  modules: [{ data: 999 }],
                },
              ],
            },
          ],
        },
      ],
    });
    const shallowText = JSON.stringify({
      tag: '#P1',
      buildings: [{ data: 1_000_013, lvl: 1 }],
    });

    const parsedDeep = parseAccountSnapshot(deepNestedText, { clock: new FixedClock() });
    const parsedShallow = parseAccountSnapshot(shallowText, { clock: new FixedClock() });
    expect(parsedDeep.ok).toBe(true);
    expect(parsedShallow.ok).toBe(true);
    if (!parsedDeep.ok || !parsedShallow.ok) {
      return;
    }

    const deepEntry = canonicalizeSnapshotHistory(parsedDeep.value, {
      villageID: parseUuid('00000000-0000-0000-0000-000000000001')!,
      lineageID: parseUuid('00000000-0000-0000-0000-000000000002')!,
      appliedAtRefSeconds: 1,
      snapshotID: parseUuid('00000000-0000-0000-0000-000000000010')!,
    });
    const shallowEntry = canonicalizeSnapshotHistory(parsedShallow.value, {
      villageID: parseUuid('00000000-0000-0000-0000-000000000001')!,
      lineageID: parseUuid('00000000-0000-0000-0000-000000000002')!,
      appliedAtRefSeconds: 2,
      snapshotID: parseUuid('00000000-0000-0000-0000-000000000011')!,
    });

    const diagnostic = diagnoseSnapshotHistoryComplexity([shallowEntry, deepEntry]);
    expect(diagnostic.entryCount).toBe(2);
    expect(diagnostic.totalItemCount).toBe(
      shallowEntry.observation.items.length + deepEntry.observation.items.length,
    );
    expect(diagnostic.maxNestedDepth).toBeGreaterThanOrEqual(4);
    expect(diagnostic.maxItemsPerEntry).toBe(
      Math.max(shallowEntry.observation.items.length, deepEntry.observation.items.length),
    );
    expect(diagnostic.largestEntrySnapshotID).toBe(
      shallowEntry.observation.items.length >= deepEntry.observation.items.length
        ? shallowEntry.snapshotID
        : deepEntry.snapshotID,
    );
  });
});
