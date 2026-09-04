import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account/parser';
import {
  canonicalizeSnapshotHistory,
  createSnapshotHistoryEnvelope,
  planSnapshotHistoryImport,
  snapshotHistoryDuplicateKeysMatch,
} from './index';
import { SNAPSHOT_HISTORY_SCHEMA } from './schema';

const FIRST_TAG = '#2QJQ8J88';
const SECOND_TAG = '#2QJQ8J89';
const GOLDEN_IMPORTED_AT_REF_SECONDS = 807_529_133;
const VILLAGE_ID = parseUuid('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')!;
const LINEAGE_ID = parseUuid('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')!;
const SNAPSHOT_ID_A = parseUuid('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')!;
const SNAPSHOT_ID_B = parseUuid('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')!;

class FixedClock {
  constructor(private readonly nowMsValue: number) {}
  nowMs(): number {
    return this.nowMsValue;
  }
}

function snapshotFromText(
  text: string,
  tag: string | null = FIRST_TAG,
  _capturedAtMs: number | null = null,
  importedAtMs = (GOLDEN_IMPORTED_AT_REF_SECONDS + 978_307_200) * 1000,
) {
  const fullText =
    tag === null ? text : text.includes('"tag"') ? text : `{"tag":"${tag}",${text.slice(1)}`;
  return parseAccountSnapshot(fullText, {
    clock: new FixedClock(importedAtMs),
  });
}

function expectSnapshot(
  text: string,
  tag: string | null = FIRST_TAG,
  capturedAtMs: number | null = null,
) {
  const parsed = snapshotFromText(text, tag, capturedAtMs);
  expect(parsed.ok).toBe(true);
  if (!parsed.ok) {
    throw new Error('snapshot parse failed');
  }
  return parsed.value;
}

describe('snapshot history import service', () => {
  it('同 lineage duplicate 只更新 metadata 不追加 entry', () => {
    const baseText = `{"tag":"${FIRST_TAG}","buildings":[]}`;
    const base = snapshotFromText(baseText, FIRST_TAG, 10_000);
    expect(base.ok).toBe(true);
    if (!base.ok) {
      return;
    }

    const baseline = canonicalizeSnapshotHistory(base.value, {
      villageID: VILLAGE_ID,
      lineageID: LINEAGE_ID,
      appliedAtRefSeconds: 20,
      isBaseline: true,
      baselineReason: 'initial',
    });

    const envelope = createSnapshotHistoryEnvelope({
      entries: [baseline],
      lineages: [
        {
          villageID: VILLAGE_ID,
          lineageID: baseline.lineageID,
          normalizedPlayerTag: FIRST_TAG,
          lastEntryID: baseline.snapshotID,
          lastAppliedAtRefSeconds: baseline.appliedAtRefSeconds,
          hasConflict: false,
          isActive: true,
        },
      ],
      migrationMarker: { version: SNAPSHOT_HISTORY_SCHEMA.envelope, completedAtRefSeconds: 20 },
    });

    const duplicateText = `{"buildings":[],"tag":"${FIRST_TAG}"}`;
    const duplicateSnapshot = snapshotFromText(duplicateText, FIRST_TAG, 30_000);
    expect(duplicateSnapshot.ok).toBe(true);
    if (!duplicateSnapshot.ok) {
      return;
    }

    const decision = planSnapshotHistoryImport({
      snapshot: duplicateSnapshot.value,
      villageID: VILLAGE_ID,
      currentTag: FIRST_TAG,
      hasCurrentSnapshot: true,
      envelope,
      appliedAtRefSeconds: 31,
    });

    expect(decision.duplicate).toBe(true);
    expect(decision.appended).toBe(false);
    expect(decision.envelope.entries).toHaveLength(1);
    const entryID = decision.entry.snapshotID;
    expect(decision.envelope.duplicateMetadata[entryID]?.duplicateImportCount).toBe(1);
    expect(decision.envelope.duplicateMetadata[entryID]?.lastSourceTimestampRefSeconds).toBe(
      duplicateSnapshot.value.capturedAtMs === null ? null : expect.any(Number),
    );
  });

  it('duplicate key 忽略 parserVersion 与时间戳', () => {
    const text = `{"tag":"${FIRST_TAG}","timestamp":100,"heroes":[{"data":1,"lvl":1,"timer":90}]}`;
    const baseParsed = snapshotFromText(text, FIRST_TAG, 10_000);
    expect(baseParsed.ok).toBe(true);
    if (!baseParsed.ok) {
      return;
    }
    const base = canonicalizeSnapshotHistory(baseParsed.value, {
      villageID: VILLAGE_ID,
      lineageID: LINEAGE_ID,
      appliedAtRefSeconds: 1,
      snapshotID: SNAPSHOT_ID_A,
    });
    const shifted = {
      ...base,
      snapshotID: SNAPSHOT_ID_B,
      appliedAtRefSeconds: 99,
      sourceTimestampRefSeconds: 50,
      parserVersion: 'account-json-9.9',
    };
    expect(snapshotHistoryDuplicateKeysMatch(base, shifted)).toBe(true);
  });

  it('A→B→A 保留三条 immutable entry', () => {
    const base = snapshotFromText('{"buildings":[]}', FIRST_TAG);
    expect(base.ok).toBe(true);
    if (!base.ok) {
      return;
    }
    const baseline = canonicalizeSnapshotHistory(base.value, {
      villageID: VILLAGE_ID,
      lineageID: LINEAGE_ID,
      appliedAtRefSeconds: 1,
      isBaseline: true,
      baselineReason: 'initial',
    });
    const envelope = createSnapshotHistoryEnvelope({
      entries: [baseline],
      lineages: [
        {
          villageID: VILLAGE_ID,
          lineageID: baseline.lineageID,
          normalizedPlayerTag: FIRST_TAG,
          lastEntryID: baseline.snapshotID,
          lastAppliedAtRefSeconds: baseline.appliedAtRefSeconds,
          hasConflict: false,
          isActive: true,
        },
      ],
      migrationMarker: { version: SNAPSHOT_HISTORY_SCHEMA.envelope, completedAtRefSeconds: 1 },
    });

    const changed = planSnapshotHistoryImport({
      snapshot: expectSnapshot('{"buildings":[],"unknown":1}', FIRST_TAG),
      villageID: VILLAGE_ID,
      currentTag: FIRST_TAG,
      hasCurrentSnapshot: true,
      envelope,
      appliedAtRefSeconds: 2,
    });
    expect(changed.appended).toBe(true);
    expect(changed.duplicate).toBe(false);
    expect(changed.envelope.entries).toHaveLength(2);
    expect(changed.lineage.outcome).toBe('continued');

    const reverted = planSnapshotHistoryImport({
      snapshot: expectSnapshot('{"buildings":[]}', FIRST_TAG),
      villageID: VILLAGE_ID,
      currentTag: FIRST_TAG,
      hasCurrentSnapshot: true,
      envelope: changed.envelope,
      appliedAtRefSeconds: 2.5,
    });
    expect(reverted.appended).toBe(true);
    expect(reverted.envelope.entries).toHaveLength(3);
    expect(reverted.lineage.outcome).toBe('continued');
  });

  it('tag 变化创建新 active lineage 而非 duplicate', () => {
    const base = snapshotFromText('{"buildings":[]}', FIRST_TAG);
    expect(base.ok).toBe(true);
    if (!base.ok) {
      return;
    }
    const baseline = canonicalizeSnapshotHistory(base.value, {
      villageID: VILLAGE_ID,
      lineageID: LINEAGE_ID,
      appliedAtRefSeconds: 10,
      isBaseline: true,
      baselineReason: 'initial',
    });
    const envelope = createSnapshotHistoryEnvelope({
      entries: [baseline],
      lineages: [
        {
          villageID: VILLAGE_ID,
          lineageID: baseline.lineageID,
          normalizedPlayerTag: FIRST_TAG,
          lastEntryID: baseline.snapshotID,
          lastAppliedAtRefSeconds: baseline.appliedAtRefSeconds,
          hasConflict: false,
          isActive: true,
        },
      ],
      migrationMarker: { version: SNAPSHOT_HISTORY_SCHEMA.envelope, completedAtRefSeconds: 10 },
    });
    const lineage1ID = baseline.lineageID;

    const tagChanged = planSnapshotHistoryImport({
      snapshot: expectSnapshot(`{"tag":"${SECOND_TAG}","heroes":[{"data":1,"lvl":2}]}`, SECOND_TAG),
      villageID: VILLAGE_ID,
      currentTag: FIRST_TAG,
      hasCurrentSnapshot: true,
      envelope,
      appliedAtRefSeconds: 31,
    });
    expect(tagChanged.appended).toBe(true);
    expect(tagChanged.duplicate).toBe(false);
    expect(tagChanged.lineage.outcome).toBe('newLineage');
    expect(tagChanged.envelope.lineages).toHaveLength(2);
    const activeLineage = tagChanged.envelope.lineages.find(
      (lineage) => lineage.villageID === VILLAGE_ID && lineage.isActive,
    );
    expect(activeLineage?.lineageID).not.toBe(lineage1ID);
    expect(activeLineage?.normalizedPlayerTag).toBe(SECOND_TAG);
    expect(
      tagChanged.envelope.entries.filter(
        (entry) => entry.villageID === VILLAGE_ID && entry.lineageID === lineage1ID,
      ),
    ).toHaveLength(1);
    expect(
      tagChanged.envelope.entries.filter(
        (entry) => entry.villageID === VILLAGE_ID && entry.lineageID === activeLineage?.lineageID,
      ),
    ).toHaveLength(1);
  });

  it('连续 duplicate import 递增 duplicateImportCount', () => {
    const baseText = `{"tag":"${FIRST_TAG}","buildings":[]}`;
    const base = snapshotFromText(baseText, FIRST_TAG, 10_000);
    expect(base.ok).toBe(true);
    if (!base.ok) {
      return;
    }
    const baseline = canonicalizeSnapshotHistory(base.value, {
      villageID: VILLAGE_ID,
      lineageID: LINEAGE_ID,
      appliedAtRefSeconds: 20,
      isBaseline: true,
      baselineReason: 'initial',
    });
    let envelope = createSnapshotHistoryEnvelope({
      entries: [baseline],
      lineages: [
        {
          villageID: VILLAGE_ID,
          lineageID: baseline.lineageID,
          normalizedPlayerTag: FIRST_TAG,
          lastEntryID: baseline.snapshotID,
          lastAppliedAtRefSeconds: baseline.appliedAtRefSeconds,
          hasConflict: false,
          isActive: true,
        },
      ],
      migrationMarker: { version: SNAPSHOT_HISTORY_SCHEMA.envelope, completedAtRefSeconds: 20 },
    });

    const firstDuplicate = planSnapshotHistoryImport({
      snapshot: expectSnapshot(`{"buildings":[],"tag":"${FIRST_TAG}"}`, FIRST_TAG, 30_000),
      villageID: VILLAGE_ID,
      currentTag: FIRST_TAG,
      hasCurrentSnapshot: true,
      envelope,
      appliedAtRefSeconds: 31,
    });
    expect(firstDuplicate.duplicate).toBe(true);
    expect(firstDuplicate.envelope.entries).toHaveLength(1);
    const entryID = firstDuplicate.entry.snapshotID;
    expect(firstDuplicate.envelope.duplicateMetadata[entryID]?.duplicateImportCount).toBe(1);

    envelope = firstDuplicate.envelope;
    const secondDuplicate = planSnapshotHistoryImport({
      snapshot: expectSnapshot(baseText, FIRST_TAG, 40_000),
      villageID: VILLAGE_ID,
      currentTag: FIRST_TAG,
      hasCurrentSnapshot: true,
      envelope,
      appliedAtRefSeconds: 41,
    });
    expect(secondDuplicate.duplicate).toBe(true);
    expect(secondDuplicate.envelope.entries).toHaveLength(1);
    expect(secondDuplicate.envelope.duplicateMetadata[entryID]?.duplicateImportCount).toBe(2);
  });

  it('current tag 不匹配时 fail-closed', () => {
    const base = snapshotFromText('{"buildings":[]}', FIRST_TAG);
    expect(base.ok).toBe(true);
    if (!base.ok) {
      return;
    }
    const entry = canonicalizeSnapshotHistory(base.value, {
      villageID: VILLAGE_ID,
      lineageID: LINEAGE_ID,
      appliedAtRefSeconds: 1,
      isBaseline: true,
      baselineReason: 'initial',
    });
    const envelope = createSnapshotHistoryEnvelope({
      entries: [entry],
      lineages: [
        {
          villageID: VILLAGE_ID,
          lineageID: entry.lineageID,
          normalizedPlayerTag: FIRST_TAG,
          lastEntryID: entry.snapshotID,
          lastAppliedAtRefSeconds: entry.appliedAtRefSeconds,
          hasConflict: false,
          isActive: true,
        },
      ],
      migrationMarker: { version: SNAPSHOT_HISTORY_SCHEMA.envelope, completedAtRefSeconds: 1 },
    });

    const changed = snapshotFromText('{"unknown":1}', FIRST_TAG);
    expect(changed.ok).toBe(true);
    if (!changed.ok) {
      return;
    }

    expect(() =>
      planSnapshotHistoryImport({
        snapshot: changed.value,
        villageID: VILLAGE_ID,
        currentTag: '#2QJQ8J89',
        hasCurrentSnapshot: true,
        envelope,
        appliedAtRefSeconds: 2,
      }),
    ).toThrow();
  });
});
