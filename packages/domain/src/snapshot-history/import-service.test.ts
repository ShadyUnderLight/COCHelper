import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account/parser';
import {
  canonicalizeSnapshotHistory,
  createSnapshotHistoryEnvelope,
  planSnapshotHistoryImport,
  snapshotHistoryDuplicateKeysMatch,
} from './index';

const FIRST_TAG = '#2QJQ8J88';
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
  capturedAtMs: number | null = null,
  importedAtMs = (GOLDEN_IMPORTED_AT_REF_SECONDS + 978_307_200) * 1000,
) {
  const fullText =
    tag === null ? text : text.includes('"tag"') ? text : `{"tag":"${tag}",${text.slice(1)}`;
  return parseAccountSnapshot(fullText, {
    clock: new FixedClock(importedAtMs),
  });
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
          lastFingerprint: baseline.canonicalFingerprint,
          lastAppliedAtRefSeconds: baseline.appliedAtRefSeconds,
          hasConflict: false,
          isActive: true,
        },
      ],
      migrationMarker: { version: 1, completedAtRefSeconds: 20 },
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
          lastFingerprint: entry.canonicalFingerprint,
          lastAppliedAtRefSeconds: entry.appliedAtRefSeconds,
          hasConflict: false,
          isActive: true,
        },
      ],
      migrationMarker: { version: 1, completedAtRefSeconds: 1 },
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
