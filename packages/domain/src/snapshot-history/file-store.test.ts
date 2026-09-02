import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account/parser';
import {
  canonicalizeSnapshotHistory,
  createSnapshotHistoryEnvelope,
  createSnapshotHistoryMigrationMarker,
  decodeSnapshotHistoryEnvelopeWire,
  encodeSnapshotHistoryEnvelopeWire,
  envelopeIsMigrated,
  FileSnapshotHistoryStore,
  validateSnapshotHistoryEnvelope,
} from './index';

const GOLDEN_IMPORTED_AT_REF_SECONDS = 807_529_133;

class GoldenClock {
  nowMs(): number {
    return (GOLDEN_IMPORTED_AT_REF_SECONDS + 978_307_200) * 1000;
  }
}

describe('snapshot history envelope wire', () => {
  it('round-trip 保留 envelope 语义', () => {
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

    const envelope = validateSnapshotHistoryEnvelope(
      createSnapshotHistoryEnvelope({
        entries: [entry],
        lineages: [
          {
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            lastEntryID: entry.snapshotID,
            lastFingerprint: entry.canonicalFingerprint,
            lastAppliedAtRefSeconds: entry.appliedAtRefSeconds,
            hasConflict: false,
            isActive: true,
          },
        ],
        migrationMarker: createSnapshotHistoryMigrationMarker(807_629_133),
      }),
    );

    const encoded = encodeSnapshotHistoryEnvelopeWire(envelope);
    const decoded = decodeSnapshotHistoryEnvelopeWire(encoded);
    const revalidated = validateSnapshotHistoryEnvelope(decoded);

    expect(revalidated.entries[0]?.canonicalFingerprint).toBe(entry.canonicalFingerprint);
    expect(revalidated.lineages).toEqual(envelope.lineages);
    expect(envelopeIsMigrated(revalidated)).toBe(true);
  });
});

describe('file snapshot history store', () => {
  it('load/save 往返且 corrupt 不覆盖原文件', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-history-'));
    const fileURL = join(directory, 'snapshot-history-v1.json');
    const store = new FileSnapshotHistoryStore(fileURL, {
      hydrationPolicy: 'testsAllowTestFixture',
    });

    expect(store.transactionJournalURL).toBe(
      join(directory, 'snapshot-history-v1.transaction.json'),
    );
    expect(store.load()).toBeNull();

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
    const envelope = validateSnapshotHistoryEnvelope(
      createSnapshotHistoryEnvelope({
        entries: [entry],
        lineages: [
          {
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            lastEntryID: entry.snapshotID,
            lastFingerprint: entry.canonicalFingerprint,
            lastAppliedAtRefSeconds: entry.appliedAtRefSeconds,
            hasConflict: false,
            isActive: true,
          },
        ],
        migrationMarker: createSnapshotHistoryMigrationMarker(807_629_133),
      }),
    );

    store.save(envelope);
    const loaded = store.load();
    expect(loaded?.entries[0]?.snapshotID).toBe(entry.snapshotID);

    const raw = store.readRawData();
    expect(raw).not.toBeNull();
    store.writeRawData(new TextEncoder().encode('{'));
    expect(() => store.load()).toThrow();
    if (raw !== null) {
      store.restoreRawData(raw);
      expect(store.load()?.entries).toHaveLength(1);
    }

    rmSync(directory, { recursive: true, force: true });
  });
});
