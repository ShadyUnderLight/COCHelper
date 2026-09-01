import { sha256Fingerprint } from '@coc-helper/wire';

import type { ManualLevelDistribution } from '../types';
import { trackerItemKeyStableId } from '../types';
import type { ManualReconciliationPreview } from './types';

function encodeDistributionForFingerprint(distribution: ManualLevelDistribution | null): unknown {
  if (distribution === null) {
    return null;
  }
  return distribution.levels.map((entry) => ({
    level: entry.level,
    quantity: entry.quantity.toString(),
  }));
}

function encodeReconciliationCandidateMaterial(value: unknown): unknown {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') {
    return value;
  }
  if (typeof value === 'number') {
    return value;
  }
  if (typeof value === 'bigint') {
    throw new RangeError(
      `reconciliation candidate fingerprint material must not contain bigint: ${value.toString()}`,
    );
  }
  if (Array.isArray(value)) {
    return value.map((entry) => encodeReconciliationCandidateMaterial(entry));
  }
  if (typeof value === 'object') {
    const record = value as Record<string, unknown>;
    const encoded: Record<string, unknown> = {};
    for (const key of Object.keys(record).sort()) {
      encoded[key] = encodeReconciliationCandidateMaterial(record[key]);
    }
    return encoded;
  }
  return value;
}

function encodeReconciliationCandidateJson(value: unknown): string {
  return JSON.stringify(encodeReconciliationCandidateMaterial(value));
}

export function computeReconciliationCandidateFingerprint(
  preview: Pick<
    ManualReconciliationPreview,
    | 'duplicate'
    | 'lineageComparable'
    | 'timeConfidence'
    | 'newReference'
    | 'newNormalizedPlayerTag'
    | 'sourceTimestampMs'
    | 'items'
  >,
): string {
  const material = {
    duplicate: preview.duplicate,
    lineageComparable: preview.lineageComparable,
    timeConfidence: preview.timeConfidence,
    newReference: preview.newReference,
    newNormalizedPlayerTag: preview.newNormalizedPlayerTag,
    sourceTimestampMs: preview.sourceTimestampMs,
    items: preview.items
      .map((item) => ({
        stableId: trackerItemKeyStableId(item.itemKey),
        classification: item.classification,
        confirmedRecordIDs: [...item.confirmedRecordIDs].sort((left, right) =>
          left.localeCompare(right),
        ),
        relatedRecordIDs: [...item.relatedRecordIDs].sort((left, right) =>
          left.localeCompare(right),
        ),
        observedTimer: item.observedTimer,
        coverageComplete: item.coverageComplete,
        observedDistributionComplete: item.observedDistributionComplete,
        observedSectionTrustGatesOpen: item.observedSectionTrustGatesOpen,
        observedTimerCoverageComplete: item.observedTimerCoverageComplete,
        previousDistribution: encodeDistributionForFingerprint(item.previousDistribution),
        observedDistribution: encodeDistributionForFingerprint(item.observedDistribution),
      }))
      .sort((left, right) => left.stableId.localeCompare(right.stableId)),
  };
  return sha256Fingerprint(encodeReconciliationCandidateJson(material));
}
