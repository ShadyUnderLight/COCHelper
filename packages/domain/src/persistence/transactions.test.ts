import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { createVillageProfile } from '../import/types';
import { FileManualTrackerStore } from '../manual/file-store';
import { emptyManualTrackerEnvelope } from '../manual/tracker-envelope';
import {
  createSnapshotHistoryEnvelope,
  createSnapshotHistoryMigrationMarker,
  FileSnapshotHistoryStore,
  validateSnapshotHistoryEnvelope,
} from '../snapshot-history';
import { createCountingFault, createThrowingFault } from './fault';
import {
  quarantinePendingJournal,
  quarantinedJournalPath,
  reviveQuarantinedJournalIfNeeded,
} from './journal-quarantine';
import { ManualTrackerTransactionCoordinator } from './manual-tracker-transaction';
import { SnapshotImportTransactionCoordinator } from './snapshot-import-transaction';
import { encodeVillageStoreBytes } from './village-codec';
import { VillageFileStore } from './village-file-store';
import { encodeManualTrackerEnvelopeWire } from '../manual/tracker-wire';

describe('ManualTrackerTransactionCoordinator', () => {
  it('commit 成功后清理 journal；prepared 中断可回滚', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-manual-tx-'));
    const villagesURL = join(directory, 'villages-v1.json');
    const manualURL = join(directory, 'manual-tracker-v1.json');
    const journalURL = join(directory, 'manual-tracker-v1.transaction.json');

    const current = new VillageFileStore(villagesURL);
    const manual = new FileManualTrackerStore(manualURL);
    const villageID = parseUuid('00000000-0000-0000-0000-000000000051')!;
    const previousVillages = [createVillageProfile({ id: villageID, name: '旧村' })];
    current.save(previousVillages);
    manual.save(emptyManualTrackerEnvelope([villageID], 1_000));

    const coordinator = new ManualTrackerTransactionCoordinator({
      current,
      manual,
      journalURL,
    });
    const nextVillages = [
      createVillageProfile({ id: villageID, name: '旧村' }),
      createVillageProfile({
        id: parseUuid('00000000-0000-0000-0000-000000000052')!,
        name: '新村',
      }),
    ];
    coordinator.commit({
      currentData: encodeVillageStoreBytes(nextVillages),
      envelope: emptyManualTrackerEnvelope(
        [villageID, parseUuid('00000000-0000-0000-0000-000000000052')!],
        2_000,
      ),
    });
    expect(existsSync(journalURL)).toBe(false);
    const loaded = current.load();
    expect(loaded.kind).toBe('loaded');
    if (loaded.kind === 'loaded') {
      expect(loaded.villages).toHaveLength(2);
    }

    const failing = new ManualTrackerTransactionCoordinator({
      current,
      manual,
      journalURL,
      fault: createThrowingFault('beforeRename', (path) => path === journalURL),
    });
    const before = current.readData();
    expect(() =>
      failing.commit({
        currentData: encodeVillageStoreBytes(previousVillages),
        envelope: emptyManualTrackerEnvelope([villageID], 3_000),
      }),
    ).toThrow();
    expect(current.readData()).toEqual(before);

    rmSync(directory, { recursive: true, force: true });
  });

  it('committed journal 可在重启后前滚', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-manual-recover-'));
    const villagesURL = join(directory, 'villages-v1.json');
    const manualURL = join(directory, 'manual-tracker-v1.json');
    const journalURL = join(directory, 'manual-tracker-v1.transaction.json');
    const current = new VillageFileStore(villagesURL);
    const manual = new FileManualTrackerStore(manualURL);
    const villageID = parseUuid('00000000-0000-0000-0000-000000000061')!;
    current.save([createVillageProfile({ id: villageID, name: 'A' })]);
    manual.save(emptyManualTrackerEnvelope([villageID], 1_000));

    const next = [createVillageProfile({ id: villageID, name: 'B' })];
    const newManual = emptyManualTrackerEnvelope([villageID], 2_000);
    const coordinator = new ManualTrackerTransactionCoordinator({
      current,
      manual,
      journalURL,
    });
    const previousCurrent = current.readData();
    const previousManual = manual.readRawData();
    writeFileSync(
      journalURL,
      JSON.stringify({
        phase: 'committed',
        previousCurrentData:
          previousCurrent === null
            ? null
            : Buffer.from(previousCurrent).toString('base64'),
        newCurrentData: Buffer.from(encodeVillageStoreBytes(next)).toString('base64'),
        previousManualData:
          previousManual === null ? null : Buffer.from(previousManual).toString('base64'),
        newManualData: Buffer.from(encodeManualTrackerEnvelopeWire(newManual)).toString(
          'base64',
        ),
      }),
    );

    const beforeRecover = current.load();
    expect(beforeRecover.kind).toBe('loaded');
    if (beforeRecover.kind === 'loaded') {
      expect(beforeRecover.villages[0]?.name).toBe('A');
    }
    coordinator.recoverIfNeeded();
    const loaded = current.load();
    expect(loaded.kind).toBe('loaded');
    if (loaded.kind === 'loaded') {
      expect(loaded.villages[0]?.name).toBe('B');
    }
    expect(existsSync(journalURL)).toBe(false);
    expect(manual.load()?.migrationMarker?.completedAtMs).toBe(2_000);
    rmSync(directory, { recursive: true, force: true });
  });
});

describe('SnapshotImportTransactionCoordinator', () => {
  it('一方写失败回滚且不留半提交', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-import-tx-'));
    const villagesURL = join(directory, 'villages-v1.json');
    const historyURL = join(directory, 'snapshot-history-v1.json');
    const journalURL = join(directory, 'snapshot-import-v1.transaction.json');
    const current = new VillageFileStore(villagesURL);
    const history = new FileSnapshotHistoryStore(historyURL, {
      hydrationPolicy: 'testsAllowTestFixture',
    });
    const villageID = parseUuid('00000000-0000-0000-0000-000000000071')!;
    current.save([createVillageProfile({ id: villageID, name: '村' })]);
    history.save(
      validateSnapshotHistoryEnvelope(
        createSnapshotHistoryEnvelope({
          entries: [],
          lineages: [],
          migrationMarker: createSnapshotHistoryMigrationMarker(1),
        }),
      ),
    );

    const failingHistory = new FileSnapshotHistoryStore(historyURL, {
      hydrationPolicy: 'testsAllowTestFixture',
      fault: createCountingFault('beforeRename', 1, (path) => path === historyURL),
    });
    const coordinator = new SnapshotImportTransactionCoordinator({
      current,
      history: failingHistory,
      journalURL,
    });
    const beforeVillages = current.readData();
    const beforeHistory = failingHistory.readRawData();
    expect(() =>
      coordinator.commit({
        currentData: encodeVillageStoreBytes([
          createVillageProfile({ id: villageID, name: '新名' }),
        ]),
        envelope: validateSnapshotHistoryEnvelope(
          createSnapshotHistoryEnvelope({
            entries: [],
            lineages: [],
            migrationMarker: createSnapshotHistoryMigrationMarker(2),
          }),
        ),
      }),
    ).toThrow();
    expect(current.readData()).toEqual(beforeVillages);
    expect(failingHistory.readRawData()).toEqual(beforeHistory);
    expect(existsSync(journalURL)).toBe(false);
    rmSync(directory, { recursive: true, force: true });
  });
});

describe('journal quarantine', () => {
  it('quarantine 后可复活并保留证据', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-quarantine-'));
    const journalURL = join(directory, 'manual-tracker-v1.transaction.json');
    writeFileSync(journalURL, '{"phase":"committed"}');
    quarantinePendingJournal(journalURL);
    expect(existsSync(journalURL)).toBe(false);
    expect(existsSync(quarantinedJournalPath(journalURL))).toBe(true);
    expect(reviveQuarantinedJournalIfNeeded(journalURL)).toBe(true);
    expect(readFileSync(journalURL, 'utf8')).toBe('{"phase":"committed"}');
    rmSync(directory, { recursive: true, force: true });
  });
});
