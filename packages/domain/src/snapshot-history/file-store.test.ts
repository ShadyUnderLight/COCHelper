import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account/parser';
import { createVillageProfile } from '../import/types';
import {
  canonicalizeSnapshotHistory,
  createSnapshotHistoryEnvelope,
  createSnapshotHistoryMigrationMarker,
  createSnapshotHistoryService,
  decodeSnapshotHistoryEnvelopeWire,
  encodeSnapshotHistoryEnvelopeWire,
  envelopeIsMigrated,
  FileSnapshotHistoryStore,
  migrateSnapshotHistoryFromVillages,
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

  it('legacy wire envelope 经 FileSnapshotHistoryStore.load + loadOrMigrate preserving upgrade', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-history-legacy-'));
    const fileURL = join(directory, 'snapshot-history-v1.json');
    const store = new FileSnapshotHistoryStore(fileURL, {
      hydrationPolicy: 'testsAllowTestFixture',
    });

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

    const villageID = parseUuid('00000000-0000-0000-0000-000000000001')!;
    const seeded = migrateSnapshotHistoryFromVillages(
      {
        villages: [
          createVillageProfile({
            id: villageID,
            name: 'Test Village',
            accountSnapshot: parsed.value,
          }),
        ],
        nowRefSeconds: 807_629_133,
      },
      807_629_133,
    );
    const preservedSnapshotID = seeded.entries[0]!.snapshotID;
    const preservedFingerprint = seeded.entries[0]!.canonicalFingerprint;

    const legacyWire = encodeSnapshotHistoryEnvelopeWire({
      ...seeded,
      migrationMarker: null,
    });
    store.writeRawData(new TextEncoder().encode(legacyWire));

    const loaded = store.load();
    expect(loaded).not.toBeNull();
    expect(loaded?.migrationMarker).toBeNull();
    expect(loaded?.entries[0]?.snapshotID).toBe(preservedSnapshotID);

    const otherVillageID = parseUuid('00000000-0000-0000-0000-000000000099')!;
    const service = createSnapshotHistoryService(store);
    const upgraded = service.loadOrMigrate({
      villages: [
        createVillageProfile({
          id: otherVillageID,
          name: 'Would Overwrite',
          accountSnapshot: parsed.value,
        }),
      ],
      nowRefSeconds: 807_729_133,
    });

    expect(upgraded.entries).toHaveLength(1);
    expect(upgraded.entries[0]?.snapshotID).toBe(preservedSnapshotID);
    expect(upgraded.entries[0]?.canonicalFingerprint).toBe(preservedFingerprint);
    expect(envelopeIsMigrated(upgraded)).toBe(true);

    const reloaded = store.load();
    expect(reloaded?.entries[0]?.snapshotID).toBe(preservedSnapshotID);
    expect(envelopeIsMigrated(reloaded!)).toBe(true);

    rmSync(directory, { recursive: true, force: true });
  });

  it('save 仍拒绝 unmigrated persisted envelope', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-history-strict-save-'));
    const fileURL = join(directory, 'snapshot-history-v1.json');
    const store = new FileSnapshotHistoryStore(fileURL, {
      hydrationPolicy: 'testsAllowTestFixture',
    });

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
    const legacy = createSnapshotHistoryEnvelope({
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
      migrationMarker: null,
    });

    expect(() => store.save(legacy)).toThrow();

    rmSync(directory, { recursive: true, force: true });
  });

  it('save 拒绝 integrity 被篡改的 envelope', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-history-tamper-save-'));
    const fileURL = join(directory, 'snapshot-history-v1.json');
    const store = new FileSnapshotHistoryStore(fileURL, {
      hydrationPolicy: 'testsAllowTestFixture',
    });

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
      entries: [
        {
          ...entry,
          integrityFingerprint: entry.canonicalFingerprint,
        },
      ],
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
    });

    expect(() => store.save(envelope)).toThrow();

    rmSync(directory, { recursive: true, force: true });
  });
});
