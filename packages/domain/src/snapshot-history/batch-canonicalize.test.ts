import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account/parser';
import {
  batchCanonicalizeSnapshotHistoryEnvelope,
  canonicalizeSnapshotHistory,
  createSnapshotHistoryEnvelope,
  diagnoseEnvelopeComplexity,
} from './index';

const GOLDEN_IMPORTED_AT_REF_SECONDS = 807_529_133;

class GoldenClock {
  nowMs(): number {
    return (GOLDEN_IMPORTED_AT_REF_SECONDS + 978_307_200) * 1000;
  }
}

describe('snapshot history batch canonicalize', () => {
  it('按 entry 处理并返回复杂度诊断', () => {
    const root = resolve(process.cwd());
    const goldenText = readFileSync(
      resolve(root, 'Tests/Golden/Fixtures/account_snapshot_golden.json'),
      'utf8',
    );
    const parsed = parseAccountSnapshot(goldenText, { clock: new GoldenClock() });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }

    const entry = canonicalizeSnapshotHistory(parsed.value, {
      villageID: parseUuid('00000000-0000-0000-0000-000000000001')!,
      lineageID: parseUuid('00000000-0000-0000-0000-000000000002')!,
      appliedAtRefSeconds: 807_629_133,
      snapshotID: parseUuid('00000000-0000-0000-0000-000000000003')!,
    });

    const envelope = createSnapshotHistoryEnvelope({
      entries: [entry, entry],
      migrationMarker: { version: 1, completedAtRefSeconds: 807_629_133 },
    });

    const perEntry: number[] = [];
    const result = batchCanonicalizeSnapshotHistoryEnvelope(envelope, {
      perEntry: (_entry, index) => {
        perEntry.push(index);
      },
    });

    expect(result.processedEntryCount).toBe(2);
    expect(perEntry).toEqual([0, 1]);
    const complexity = diagnoseEnvelopeComplexity(result.envelope.entries);
    expect(complexity.entryCount).toBe(2);
    expect(complexity.totalItemCount).toBe(entry.observation.items.length * 2);
    expect(complexity.maxNestedDepth).toBeGreaterThanOrEqual(1);
  });
});
