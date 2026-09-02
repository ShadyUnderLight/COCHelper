import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account/parser';
import { createVillageProfile } from '../import/types';
import type { SnapshotHistoryStoreError } from './errors';
import {
  createInMemorySnapshotHistoryStore,
  createSnapshotHistoryService,
  envelopeActiveLineage,
  envelopeIsMigrated,
  migrateSnapshotHistoryFromVillages,
} from './index';
import type { SnapshotHistoryEnvelope } from './store-types';
import type { SnapshotHistoryStore } from './store-port';

const GOLDEN_IMPORTED_AT_REF_SECONDS = 807_529_133;

class GoldenClock {
  nowMs(): number {
    return (GOLDEN_IMPORTED_AT_REF_SECONDS + 978_307_200) * 1000;
  }
}

function createStoreWithFixedLoad(initial: SnapshotHistoryEnvelope | null): SnapshotHistoryStore & {
  readonly saved: () => SnapshotHistoryEnvelope | null;
} {
  let loaded = initial;
  let saved: SnapshotHistoryEnvelope | null = null;
  return {
    fileURL: '/test/snapshot-history-v1.json',
    transactionJournalURL: null,
    load: () => loaded,
    save(envelope) {
      saved = envelope;
      loaded = envelope;
    },
    readRawData: () => null,
    writeRawData: () => undefined,
    restoreRawData: () => undefined,
    saved: () => saved,
  };
}

describe('snapshot history service', () => {
  it('loadOrMigrate 从村庄快照种子化 envelope', () => {
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
    const store = createInMemorySnapshotHistoryStore();
    const service = createSnapshotHistoryService(store);

    const migrated = service.loadOrMigrate({
      villages: [
        createVillageProfile({
          id: villageID,
          name: 'Test Village',
          accountSnapshot: parsed.value,
        }),
      ],
      nowRefSeconds: 807_629_133,
    });

    expect(envelopeIsMigrated(migrated)).toBe(true);
    expect(migrated.entries).toHaveLength(1);
    expect(migrated.lineages).toHaveLength(1);

    const again = service.loadOrMigrate({
      villages: [],
      nowRefSeconds: 807_729_133,
    });
    expect(again.entries).toHaveLength(1);
  });

  it('已有 history entries 但 marker 缺失时 preserving upgrade，不从 villages 重建', () => {
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

    const existingWithoutMarker: SnapshotHistoryEnvelope = {
      ...seeded,
      migrationMarker: null,
    };
    const store = createStoreWithFixedLoad(existingWithoutMarker);
    const service = createSnapshotHistoryService(store);

    const otherVillageID = parseUuid('00000000-0000-0000-0000-000000000099')!;
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
    expect(store.saved()?.entries[0]?.snapshotID).toBe(preservedSnapshotID);
  });

  it('已有 history entries 且 marker 版本不兼容时拒绝覆盖', () => {
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
    const existingWithBadMarker: SnapshotHistoryEnvelope = {
      ...seeded,
      migrationMarker: { version: 999, completedAtRefSeconds: 807_629_133 },
    };
    const store = createStoreWithFixedLoad(existingWithBadMarker);
    const service = createSnapshotHistoryService(store);

    let thrown: SnapshotHistoryStoreError | undefined;
    try {
      service.loadOrMigrate({
        villages: [
          createVillageProfile({
            id: villageID,
            name: 'Test Village',
            accountSnapshot: parsed.value,
          }),
        ],
        nowRefSeconds: 807_729_133,
      });
    } catch (error) {
      thrown = error as SnapshotHistoryStoreError;
    }

    expect(thrown).toEqual({ kind: 'unsupportedSchema', version: 999 });
    expect(store.saved()).toBeNull();
  });

  it('两村交错导入 A→B→A 不互相污染 active lineage', () => {
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

    const firstVillageID = parseUuid('00000000-0000-0000-0000-000000000011')!;
    const secondVillageID = parseUuid('00000000-0000-0000-0000-000000000012')!;
    const store = createInMemorySnapshotHistoryStore();
    const service = createSnapshotHistoryService(store);

    const baseline = service.loadOrMigrate({
      villages: [
        createVillageProfile({
          id: firstVillageID,
          name: '村庄 A',
          accountSnapshot: parsed.value,
        }),
        createVillageProfile({
          id: secondVillageID,
          name: '村庄 B',
          accountSnapshot: parsed.value,
        }),
      ],
      nowRefSeconds: 807_629_133,
    });

    expect(baseline.entries).toHaveLength(2);
    expect(baseline.lineages).toHaveLength(2);

    const baselineBEntryID = envelopeActiveLineage(baseline, secondVillageID)!.lastEntryID;
    const baselineBFingerprint = envelopeActiveLineage(baseline, secondVillageID)!.lastFingerprint;

    const a1Parsed = parseAccountSnapshot('{"tag":"#GOLDEN01","buildings":[],"unknown":1}', {
      clock: new GoldenClock(),
    });
    expect(a1Parsed.ok).toBe(true);
    if (!a1Parsed.ok) {
      return;
    }

    const a1 = service.planImport({
      snapshot: a1Parsed.value,
      villageID: firstVillageID,
      currentTag: a1Parsed.value.tag,
      hasCurrentSnapshot: true,
      envelope: baseline,
      appliedAtRefSeconds: 807_729_133,
    });
    expect(a1.appended).toBe(true);
    expect(a1.envelope.entries.filter((entry) => entry.villageID === firstVillageID)).toHaveLength(
      2,
    );
    expect(a1.envelope.entries.filter((entry) => entry.villageID === secondVillageID)).toHaveLength(
      1,
    );
    expect(envelopeActiveLineage(a1.envelope, firstVillageID)?.lastEntryID).toBe(
      a1.entry.snapshotID,
    );
    expect(envelopeActiveLineage(a1.envelope, secondVillageID)?.lastEntryID).toBe(baselineBEntryID);
    expect(envelopeActiveLineage(a1.envelope, secondVillageID)?.lastFingerprint).toBe(
      baselineBFingerprint,
    );

    const b1Parsed = parseAccountSnapshot('{"tag":"#GOLDEN01","buildings":[],"unknown":2}', {
      clock: new GoldenClock(),
    });
    expect(b1Parsed.ok).toBe(true);
    if (!b1Parsed.ok) {
      return;
    }

    const b1 = service.planImport({
      snapshot: b1Parsed.value,
      villageID: secondVillageID,
      currentTag: b1Parsed.value.tag,
      hasCurrentSnapshot: true,
      envelope: a1.envelope,
      appliedAtRefSeconds: 807_829_133,
    });
    expect(b1.appended).toBe(true);
    expect(b1.envelope.entries.filter((entry) => entry.villageID === firstVillageID)).toHaveLength(
      2,
    );
    expect(b1.envelope.entries.filter((entry) => entry.villageID === secondVillageID)).toHaveLength(
      2,
    );
    expect(envelopeActiveLineage(b1.envelope, firstVillageID)?.lastEntryID).toBe(
      a1.entry.snapshotID,
    );
    expect(envelopeActiveLineage(b1.envelope, secondVillageID)?.lastEntryID).toBe(
      b1.entry.snapshotID,
    );

    const a2Parsed = parseAccountSnapshot('{"tag":"#GOLDEN01","buildings":[]}', {
      clock: new GoldenClock(),
    });
    expect(a2Parsed.ok).toBe(true);
    if (!a2Parsed.ok) {
      return;
    }

    const a2 = service.planImport({
      snapshot: a2Parsed.value,
      villageID: firstVillageID,
      currentTag: a2Parsed.value.tag,
      hasCurrentSnapshot: true,
      envelope: b1.envelope,
      appliedAtRefSeconds: 807_929_133,
    });
    expect(a2.appended).toBe(true);
    expect(a2.envelope.entries.filter((entry) => entry.villageID === firstVillageID)).toHaveLength(
      3,
    );
    expect(a2.envelope.entries.filter((entry) => entry.villageID === secondVillageID)).toHaveLength(
      2,
    );
    expect(envelopeActiveLineage(a2.envelope, firstVillageID)?.lastEntryID).toBe(
      a2.entry.snapshotID,
    );
    expect(envelopeActiveLineage(a2.envelope, secondVillageID)?.lastEntryID).toBe(
      b1.entry.snapshotID,
    );
    expect(
      a2.envelope.entries.find(
        (entry) => entry.villageID === secondVillageID && entry.snapshotID === baselineBEntryID,
      )?.canonicalFingerprint,
    ).toBe(baselineBFingerprint);
  });
});
