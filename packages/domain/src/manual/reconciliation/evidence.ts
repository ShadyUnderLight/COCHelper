import type { UuidString } from '@coc-helper/wire';

import type { ManualBaselineReference, ManualLevelDistribution, TrackerItemKey } from '../types';
import { trackerItemKeyStableId } from '../types';

export type ReconciliationObservation = {
  readonly distribution: ManualLevelDistribution | null;
  readonly displayName: string;
  readonly hasTimer: boolean;
  readonly coverageComplete: boolean;
  readonly distributionComplete: boolean;
  readonly sectionTrustGatesOpen: boolean;
  readonly timerCoverageComplete: boolean;
};

export type RelatedChangeCoverageState = 'complete' | 'partial' | 'unavailable';

export type RelatedChangeEvidence = {
  readonly coverageState: RelatedChangeCoverageState;
};

export type ManualReconciliationEvidence = {
  readonly villageID: UuidString;
  readonly newBaselineReference: ManualBaselineReference;
  readonly newNormalizedPlayerTag: string | null;
  readonly sourceTimestampMs: number | null;
  readonly duplicate: boolean;
  readonly lineageComparable: boolean;
  readonly observations: ReadonlyMap<string, ReconciliationObservation>;
  readonly itemKeysByStableID: ReadonlyMap<string, TrackerItemKey>;
  readonly previousObservations?: ReadonlyMap<string, ReconciliationObservation>;
  readonly relatedChangesByStableID?: ReadonlyMap<string, readonly RelatedChangeEvidence[]>;
  readonly previousSnapshotID?: UuidString | null;
  readonly previousSnapshotFingerprint?: string | null;
  readonly previousLineageID?: string | null;
  readonly previousSourceTimestampMs?: number | null;
};

export function observationMapKey(key: TrackerItemKey | string): string {
  return typeof key === 'string' ? key : trackerItemKeyStableId(key);
}

export function getReconciliationObservation(
  observations: ReadonlyMap<string, ReconciliationObservation>,
  itemKey: TrackerItemKey,
): ReconciliationObservation | undefined {
  return observations.get(trackerItemKeyStableId(itemKey));
}

export function createReconciliationObservation(input: {
  readonly distribution?: ManualLevelDistribution | null;
  readonly displayName: string;
  readonly hasTimer?: boolean;
  readonly coverageComplete?: boolean;
  readonly distributionComplete?: boolean;
  readonly sectionTrustGatesOpen?: boolean;
  readonly timerCoverageComplete?: boolean;
}): ReconciliationObservation {
  const distribution = input.distribution ?? null;
  const distributionComplete = input.distributionComplete ?? distribution !== null;
  return {
    distribution,
    displayName: input.displayName,
    hasTimer: input.hasTimer ?? false,
    coverageComplete: input.coverageComplete ?? distributionComplete,
    distributionComplete,
    sectionTrustGatesOpen: input.sectionTrustGatesOpen ?? true,
    timerCoverageComplete: input.timerCoverageComplete ?? !(input.hasTimer ?? false),
  };
}

export function buildObservationMap(
  entries: readonly {
    readonly itemKey: TrackerItemKey;
    readonly observation: ReconciliationObservation;
  }[],
): {
  readonly observations: ReadonlyMap<string, ReconciliationObservation>;
  readonly itemKeysByStableID: ReadonlyMap<string, TrackerItemKey>;
} {
  const observations = new Map<string, ReconciliationObservation>();
  const itemKeysByStableID = new Map<string, TrackerItemKey>();
  for (const entry of entries) {
    const stableId = trackerItemKeyStableId(entry.itemKey);
    observations.set(stableId, entry.observation);
    itemKeysByStableID.set(stableId, entry.itemKey);
  }
  return { observations, itemKeysByStableID };
}

export function createManualReconciliationEvidence(
  input: Omit<ManualReconciliationEvidence, 'observations' | 'itemKeysByStableID'> & {
    readonly observations: ReadonlyMap<string, ReconciliationObservation>;
    readonly itemKeysByStableID?: ReadonlyMap<string, TrackerItemKey>;
    readonly observationEntries?: readonly {
      readonly itemKey: TrackerItemKey;
      readonly observation: ReconciliationObservation;
    }[];
  },
): ManualReconciliationEvidence {
  if (input.observationEntries !== undefined) {
    const built = buildObservationMap(input.observationEntries);
    return {
      ...input,
      observations: built.observations,
      itemKeysByStableID: built.itemKeysByStableID,
    };
  }
  return {
    ...input,
    itemKeysByStableID: input.itemKeysByStableID ?? new Map(),
  };
}

export function completeObservation(
  itemKey: TrackerItemKey,
  distribution: ManualLevelDistribution,
  input: {
    readonly hasTimer?: boolean;
    readonly coverageComplete?: boolean;
    readonly distributionComplete?: boolean;
    readonly sectionTrustGatesOpen?: boolean;
    readonly timerCoverageComplete?: boolean;
    readonly displayName?: string;
  } = {},
): { readonly itemKey: TrackerItemKey; readonly observation: ReconciliationObservation } {
  const hasTimer = input.hasTimer ?? false;
  return {
    itemKey,
    observation: createReconciliationObservation({
      distribution,
      displayName: input.displayName ?? trackerItemKeyStableId(itemKey),
      hasTimer,
      coverageComplete: input.coverageComplete ?? true,
      distributionComplete: input.distributionComplete ?? true,
      sectionTrustGatesOpen: input.sectionTrustGatesOpen ?? true,
      timerCoverageComplete: input.timerCoverageComplete ?? !hasTimer,
    }),
  };
}
