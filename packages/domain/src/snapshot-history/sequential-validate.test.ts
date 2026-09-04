import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account/parser';
import {
  canonicalizeSnapshotHistory,
  createSnapshotHistoryEnvelope,
  createSnapshotHistoryMigrationMarker,
  diagnoseEnvelopeComplexity,
  sequentialValidateSnapshotHistoryEntries,
  sequentialValidateSnapshotHistoryEntriesAsync,
} from './index';
import { SNAPSHOT_HISTORY_SCHEMA } from './schema';

const GOLDEN_IMPORTED_AT_REF_SECONDS = 807_529_133;

class GoldenClock {
  nowMs(): number {
    return (GOLDEN_IMPORTED_AT_REF_SECONDS + 978_307_200) * 1000;
  }
}

describe('snapshot history sequential validate', () => {
  it('按 entry 顺序校验且不复制 entries 数组', () => {
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
      migrationMarker: {
        version: SNAPSHOT_HISTORY_SCHEMA.envelope,
        completedAtRefSeconds: 807_629_133,
      },
    });

    const perEntry: number[] = [];
    const result = sequentialValidateSnapshotHistoryEntries(envelope, {
      perEntry: (_entry, index) => {
        perEntry.push(index);
      },
    });

    expect(result.processedEntryCount).toBe(2);
    expect(perEntry).toEqual([0, 1]);
    expect(envelope.entries).toHaveLength(2);
    const complexity = diagnoseEnvelopeComplexity(envelope.entries);
    expect(complexity.entryCount).toBe(2);
    expect(complexity.totalItemCount).toBe(entry.observation.items.length * 2);
  });

  it('1005 城墙 fixture 连续校验不复制 entries', async () => {
    const root = resolve(process.cwd());
    const largeWallsText = readFileSync(
      resolve(root, 'Tests/COCHelperCoreTests/Fixtures/perf_account_snapshot_large_walls.json'),
      'utf8',
    );
    const parsed = parseAccountSnapshot(largeWallsText, { clock: new GoldenClock() });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }

    const entry = canonicalizeSnapshotHistory(parsed.value, {
      villageID: parseUuid('00000000-0000-0000-0000-000000000004')!,
      lineageID: parseUuid('00000000-0000-0000-0000-000000000005')!,
      appliedAtRefSeconds: 807_629_133,
      snapshotID: parseUuid('00000000-0000-0000-0000-000000000006')!,
    });

    const envelope = createSnapshotHistoryEnvelope({
      entries: [entry],
      lineages: [
        {
          villageID: entry.villageID,
          lineageID: entry.lineageID,
          normalizedPlayerTag: entry.normalizedPlayerTag,
          lastEntryID: entry.snapshotID,
          lastAppliedAtRefSeconds: entry.appliedAtRefSeconds,
          hasConflict: false,
          isActive: true,
        },
      ],
      migrationMarker: createSnapshotHistoryMigrationMarker(807_629_133),
    });

    const complexity = diagnoseEnvelopeComplexity(envelope.entries);
    expect(complexity.totalItemCount).toBeGreaterThan(1000);

    for (let iteration = 0; iteration < 3; iteration += 1) {
      const result = await sequentialValidateSnapshotHistoryEntriesAsync(envelope, {
        yieldEvery: 1,
      });
      expect(result.processedEntryCount).toBe(1);
      expect(envelope.entries).toHaveLength(1);
    }
  });

  it('深层嵌套 fixture 连续校验并报告复杂度', async () => {
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
    const parsed = parseAccountSnapshot(deepNestedText, { clock: new GoldenClock() });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }

    const entry = canonicalizeSnapshotHistory(parsed.value, {
      villageID: parseUuid('00000000-0000-0000-0000-000000000007')!,
      lineageID: parseUuid('00000000-0000-0000-0000-000000000008')!,
      appliedAtRefSeconds: 807_629_133,
      snapshotID: parseUuid('00000000-0000-0000-0000-000000000009')!,
    });

    const envelope = createSnapshotHistoryEnvelope({
      entries: [entry],
      lineages: [
        {
          villageID: entry.villageID,
          lineageID: entry.lineageID,
          normalizedPlayerTag: entry.normalizedPlayerTag,
          lastEntryID: entry.snapshotID,
          lastAppliedAtRefSeconds: entry.appliedAtRefSeconds,
          hasConflict: false,
          isActive: true,
        },
      ],
      migrationMarker: createSnapshotHistoryMigrationMarker(807_629_133),
    });

    const complexity = diagnoseEnvelopeComplexity(envelope.entries);
    expect(complexity.maxNestedDepth).toBeGreaterThanOrEqual(4);
    expect(complexity.totalItemCount).toBe(entry.observation.items.length);

    const result = await sequentialValidateSnapshotHistoryEntriesAsync(envelope, {
      yieldEvery: 1,
    });
    expect(result.processedEntryCount).toBe(1);
    expect(envelope.entries).toHaveLength(1);
  });
});
