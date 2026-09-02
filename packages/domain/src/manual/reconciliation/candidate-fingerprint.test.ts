import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { trackerItemKeyRoot, trackerItemKeyStableId } from '../types';
import { computeReconciliationCandidateFingerprint } from './candidate-fingerprint';
import type { ManualReconciliationPreview } from './types';

const key = trackerItemKeyRoot('home', 'buildings', 100n);
const villageID = parseUuid('00000000-0000-0000-0000-000000000143')!;
const previewID = parseUuid('00000000-0000-0000-0000-000000000001')!;

function preview(
  input: Partial<ManualReconciliationPreview> &
    Pick<ManualReconciliationPreview, 'duplicate' | 'newReference'>,
): ManualReconciliationPreview {
  return {
    previewID,
    villageID,
    previousReference: null,
    previousSnapshotID: null,
    previousSnapshotFingerprint: null,
    previousLineageID: null,
    manualStateUpdatedAtMs: 1_700_000_010_000,
    newNormalizedPlayerTag: '#P1',
    sourceTimestampMs: 1_700_000_200_000,
    appliedAtMs: 1_700_000_200_000,
    timeConfidence: 'reliableSourceTimestamp',
    lineageComparable: true,
    candidateFingerprint: 'sha256:placeholder',
    items: [
      {
        itemKey: key,
        displayName: trackerItemKeyStableId(key),
        classification: 'newObservation',
        message: '新观察',
        previousDistribution: null,
        observedDistribution: null,
        relatedRecordIDs: [],
        confirmedRecordIDs: [],
        observedTimer: false,
        coverageComplete: true,
        observedDistributionComplete: true,
        observedSectionTrustGatesOpen: true,
        observedTimerCoverageComplete: false,
      },
    ],
    ...input,
  };
}

describe('computeReconciliationCandidateFingerprint', () => {
  it('ignores ephemeral revision and lineageID for non-duplicate candidates', () => {
    const left = preview({
      duplicate: false,
      newReference: {
        revision: '00000000-0000-0000-0000-000000000201',
        fingerprint: 'sha256:stable-fp',
        lineageID: '00000000-0000-0000-0000-000000000301',
      },
    });
    const right = preview({
      duplicate: false,
      newReference: {
        revision: '00000000-0000-0000-0000-000000000202',
        fingerprint: 'sha256:stable-fp',
        lineageID: '00000000-0000-0000-0000-000000000302',
      },
    });
    expect(computeReconciliationCandidateFingerprint(left)).toBe(
      computeReconciliationCandidateFingerprint(right),
    );
  });

  it('includes revision for duplicate candidates', () => {
    const left = preview({
      duplicate: true,
      newReference: {
        revision: '00000000-0000-0000-0000-000000000401:observation:1',
        fingerprint: 'sha256:dup-fp',
        lineageID: 'lineage-dup',
      },
    });
    const right = preview({
      duplicate: true,
      newReference: {
        revision: '00000000-0000-0000-0000-000000000401:observation:2',
        fingerprint: 'sha256:dup-fp',
        lineageID: 'lineage-dup',
      },
    });
    expect(computeReconciliationCandidateFingerprint(left)).not.toBe(
      computeReconciliationCandidateFingerprint(right),
    );
  });

  it('accepts control characters in normalized player tag material', () => {
    const tagged = preview({
      duplicate: false,
      newReference: { revision: 'ignored', fingerprint: 'sha256:fp', lineageID: 'ignored' },
      newNormalizedPlayerTag: 'tag\u0001name',
    });
    expect(computeReconciliationCandidateFingerprint(tagged)).toMatch(/^sha256:[0-9a-f]{64}$/);
  });
});
