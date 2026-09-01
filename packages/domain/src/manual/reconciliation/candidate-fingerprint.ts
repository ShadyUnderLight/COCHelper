import { sha256Fingerprint } from '@coc-helper/wire';

import { encodeSwiftSortedJson } from '../../account/wire-encode';
import type { ManualLevelDistribution } from '../types';
import { trackerItemKeyStableId } from '../types';
import type { ManualReconciliationPreview } from './types';

function encodeDistributionWire(distribution: ManualLevelDistribution | null): unknown {
  if (distribution === null) {
    return null;
  }
  return distribution.levels.map((entry) => ({
    level: entry.level,
    quantity: entry.quantity,
  }));
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
        previousDistribution: encodeDistributionWire(item.previousDistribution),
        observedDistribution: encodeDistributionWire(item.observedDistribution),
      }))
      .sort((left, right) => left.stableId.localeCompare(right.stableId)),
  };
  return sha256Fingerprint(encodeSwiftSortedJson(material));
}
