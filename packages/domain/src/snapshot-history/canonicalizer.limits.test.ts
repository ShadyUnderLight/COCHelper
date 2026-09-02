import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account/parser';
import {
  SnapshotHistoryCanonicalizationException,
  canonicalizeSnapshotHistory,
} from './canonicalizer';
import { SNAPSHOT_HISTORY_CANONICALIZATION_LIMITS } from './schema';

class FixedClock {
  nowMs(): number {
    return 1_700_000_000_000;
  }
}

describe('snapshot history canonicalization limits', () => {
  it('超过嵌套深度上限时 fail-closed', () => {
    let nested = '{"data":1,"lvl":1}';
    for (
      let depth = 0;
      depth < SNAPSHOT_HISTORY_CANONICALIZATION_LIMITS.maxNestedDepth + 2;
      depth += 1
    ) {
      nested = `{"data":${10 + depth},"lvl":1,"types":[${nested}]}`;
    }
    const text = `{"tag":"#P1","buildings":[${nested}]}`;
    const parsed = parseAccountSnapshot(text, { clock: new FixedClock() });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }
    expect(() =>
      canonicalizeSnapshotHistory(parsed.value, {
        villageID: parseUuid('00000000-0000-0000-0000-000000000001')!,
        lineageID: parseUuid('00000000-0000-0000-0000-000000000002')!,
        appliedAtRefSeconds: 1,
        snapshotID: parseUuid('00000000-0000-0000-0000-000000000003')!,
      }),
    ).toThrow(SnapshotHistoryCanonicalizationException);
  });
});
