import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { isSha256Fingerprint, parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account/parser';
import {
  canonicalizeSnapshotHistory,
  createSnapshotHistoryEnvelope,
  validateSnapshotHistoryEnvelope,
  validateSnapshotHistoryEntryIntegrity,
} from './index';

const GOLDEN_IMPORTED_AT_REF_SECONDS = 807_529_133;
const GOLDEN_APPLIED_AT_REF_SECONDS = 807_629_133;

class GoldenClock {
  nowMs(): number {
    return (GOLDEN_IMPORTED_AT_REF_SECONDS + 978_307_200) * 1000;
  }
}

describe('snapshot history envelope validate', () => {
  it('合法 golden entry 通过 envelope 校验', () => {
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
      appliedAtRefSeconds: GOLDEN_APPLIED_AT_REF_SECONDS,
      snapshotID: parseUuid('00000000-0000-0000-0000-000000000003')!,
    });

    const envelope = createSnapshotHistoryEnvelope({
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
      migrationMarker: {
        version: 1,
        completedAtRefSeconds: GOLDEN_APPLIED_AT_REF_SECONDS,
      },
    });

    expect(() => validateSnapshotHistoryEnvelope(envelope)).not.toThrow();
    expect(() => validateSnapshotHistoryEntryIntegrity(entry)).not.toThrow();
    expect(isSha256Fingerprint(entry.canonicalFingerprint)).toBe(true);
  });

  it('无效 fingerprint 格式被拒绝', () => {
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
      appliedAtRefSeconds: GOLDEN_APPLIED_AT_REF_SECONDS,
      snapshotID: parseUuid('00000000-0000-0000-0000-000000000003')!,
    });
    const tampered = {
      ...entry,
      canonicalFingerprint: 'not-a-sha256' as typeof entry.canonicalFingerprint,
    };
    expect(() =>
      validateSnapshotHistoryEnvelope(
        createSnapshotHistoryEnvelope({
          entries: [tampered],
          migrationMarker: { version: 1, completedAtRefSeconds: 1 },
        }),
      ),
    ).toThrow();
  });

  it('篡改 lineage normalizedPlayerTag 被拒绝', () => {
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
      appliedAtRefSeconds: GOLDEN_APPLIED_AT_REF_SECONDS,
      snapshotID: parseUuid('00000000-0000-0000-0000-000000000003')!,
    });
    const envelope = createSnapshotHistoryEnvelope({
      entries: [entry],
      lineages: [
        {
          villageID: entry.villageID,
          lineageID: entry.lineageID,
          normalizedPlayerTag: '#TAMPERED',
          lastEntryID: entry.snapshotID,
          lastFingerprint: entry.canonicalFingerprint,
          lastAppliedAtRefSeconds: entry.appliedAtRefSeconds,
          hasConflict: false,
          isActive: true,
        },
      ],
      migrationMarker: {
        version: 1,
        completedAtRefSeconds: GOLDEN_APPLIED_AT_REF_SECONDS,
      },
    });

    expect(() => validateSnapshotHistoryEnvelope(envelope)).toThrow();
  });
});
