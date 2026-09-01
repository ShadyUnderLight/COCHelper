import { generateUuid } from '@coc-helper/wire';

import { baselineReferencesEqual } from '../equality';
import type { ManualReconciliationError } from '../errors';
import { createManualTrackerDiagnostic } from '../tracker-schema';
import type { TrackerItemKey } from '../types';
import { trackerItemKeyStableId } from '../types';
import {
  createManualReconciliationRecord,
  manualTrackerVillageStateWithCore,
  type ManualTrackerVillageState,
} from '../village-state';
import { computeReconciliationCandidateFingerprint } from './candidate-fingerprint';
import {
  classifyReconciliationItem,
  computeConfirmedRecordIDs,
  computeHasProtectableLocalState,
} from './classification';
import {
  rebuildObservationOnlyReconciliationCore,
  rebuildReconciliationCore,
} from './core-rebuild';
import type { ManualReconciliationEvidence } from './evidence';
import {
  effectiveReconciliationDistribution,
  reconciliationCandidateMatches,
  reconciliationClassificationMessage,
  reconciliationTimeConfidence,
  recordsForItemKey,
} from './helpers';
import { rebasedQueueAssignments } from './queue-rebase';
import type {
  ManualReconciliationDecision,
  ManualReconciliationItem,
  ManualReconciliationPreview,
} from './types';
import {
  manualReconciliationPreviewAttentionCount,
  manualReconciliationPreviewRequiresExplicitDecision,
} from './types';

export type ManualReconciliationPlan = {
  readonly preview: ManualReconciliationPreview;
  readonly state: ManualTrackerVillageState;
};

function sortReconciliationItems(
  items: readonly ManualReconciliationItem[],
): readonly ManualReconciliationItem[] {
  return items
    .slice()
    .sort((left, right) =>
      trackerItemKeyStableId(left.itemKey).localeCompare(trackerItemKeyStableId(right.itemKey)),
    );
}

function resolveItemKey(
  stableId: string,
  currentState: ManualTrackerVillageState,
  evidence: ManualReconciliationEvidence,
): TrackerItemKey | undefined {
  const fromState = currentState.core.itemStates.find(
    (state) => trackerItemKeyStableId(state.itemKey) === stableId,
  )?.itemKey;
  if (fromState !== undefined) {
    return fromState;
  }
  for (const record of currentState.core.records) {
    if (trackerItemKeyStableId(record.itemKey) === stableId) {
      return record.itemKey;
    }
  }
  return evidence.itemKeysByStableID.get(stableId);
}

export function previewReconciliation(
  evidence: ManualReconciliationEvidence,
  currentState: ManualTrackerVillageState,
  appliedAtMs: number,
): ManualReconciliationPreview {
  if (evidence.villageID !== currentState.villageID) {
    const error: ManualReconciliationError = { kind: 'villageMismatch' };
    throw error;
  }

  const previousReference = currentState.baselineReference;
  const timeConfidence = reconciliationTimeConfidence(
    evidence.previousSourceTimestampMs,
    evidence.sourceTimestampMs,
  );
  const observations = evidence.observations;
  const previousObservations = evidence.previousObservations ?? new Map();
  const existingKeys = new Set(
    currentState.core.itemStates.map((state) => trackerItemKeyStableId(state.itemKey)),
  );
  const allKeys = new Set<string>([...existingKeys, ...observations.keys()]);
  const items: ManualReconciliationItem[] = [];

  for (const stableId of [...allKeys].sort((left, right) => left.localeCompare(right))) {
    const itemKey = resolveItemKey(stableId, currentState, evidence);
    if (itemKey === undefined) {
      continue;
    }
    const state = currentState.core.itemState(itemKey);
    const records = recordsForItemKey(currentState.core.records, itemKey);
    const observation = observations.get(stableId);
    const previousObservation = previousObservations.get(stableId);
    const previousDistribution = effectiveReconciliationDistribution(state);
    const confirmed = computeConfirmedRecordIDs({
      lineageComparable: evidence.lineageComparable,
      timeConfidence,
      records,
      previousObservation,
      observation,
      sourceTimestampMs: evidence.sourceTimestampMs,
    });
    const relatedChanges = evidence.relatedChangesByStableID?.get(stableId) ?? [];
    const classification = classifyReconciliationItem({
      duplicate: evidence.duplicate,
      lineageComparable: evidence.lineageComparable,
      timeConfidence,
      hasExistingState: state !== undefined,
      hasProtectableLocalState: computeHasProtectableLocalState({
        state,
        records,
        previousDistribution,
      }),
      previousDistribution,
      observation,
      previousObservation,
      records,
      confirmedRecordIDs: confirmed,
      changes: relatedChanges,
    });
    items.push({
      itemKey,
      displayName: observation?.displayName ?? previousObservation?.displayName ?? stableId,
      classification,
      message: reconciliationClassificationMessage(classification),
      previousDistribution,
      observedDistribution: observation?.distribution ?? null,
      relatedRecordIDs: records
        .map((record) => record.recordID)
        .sort((left, right) => left.localeCompare(right)),
      confirmedRecordIDs: [...confirmed].sort((left, right) => left.localeCompare(right)),
      observedTimer: observation?.hasTimer ?? false,
      coverageComplete: observation?.coverageComplete ?? false,
      observedDistributionComplete: observation?.distributionComplete ?? false,
      observedSectionTrustGatesOpen: observation?.sectionTrustGatesOpen ?? false,
      observedTimerCoverageComplete: observation?.timerCoverageComplete ?? false,
    });
  }

  const sortedItems = sortReconciliationItems(items);
  const candidateFingerprint = computeReconciliationCandidateFingerprint({
    duplicate: evidence.duplicate,
    lineageComparable: evidence.lineageComparable,
    timeConfidence,
    newReference: evidence.newBaselineReference,
    newNormalizedPlayerTag: evidence.newNormalizedPlayerTag,
    sourceTimestampMs: evidence.sourceTimestampMs,
    items: sortedItems,
  });

  return {
    previewID: generateUuid(),
    villageID: evidence.villageID,
    previousReference,
    previousSnapshotID: evidence.previousSnapshotID ?? null,
    previousSnapshotFingerprint: evidence.previousSnapshotFingerprint ?? null,
    previousLineageID: evidence.previousLineageID ?? null,
    manualStateUpdatedAtMs: currentState.stateUpdatedAtMs,
    newReference: evidence.newBaselineReference,
    newNormalizedPlayerTag: evidence.newNormalizedPlayerTag,
    sourceTimestampMs: evidence.sourceTimestampMs,
    appliedAtMs,
    timeConfidence,
    duplicate: evidence.duplicate,
    lineageComparable: evidence.lineageComparable,
    candidateFingerprint,
    items: sortedItems,
  };
}

export function reconcileManualTracker(
  evidence: ManualReconciliationEvidence,
  currentState: ManualTrackerVillageState,
  input: {
    readonly expectedPreview?: ManualReconciliationPreview;
    readonly decision: ManualReconciliationDecision;
    readonly appliedAtMs: number;
  },
): ManualReconciliationPlan {
  if (input.expectedPreview !== undefined) {
    const expected = input.expectedPreview;
    const previousReferenceMatches =
      (expected.previousReference === null && currentState.baselineReference === null) ||
      (expected.previousReference !== null &&
        currentState.baselineReference !== null &&
        baselineReferencesEqual(expected.previousReference, currentState.baselineReference));
    if (
      expected.villageID !== evidence.villageID ||
      !previousReferenceMatches ||
      expected.previousSnapshotID !== (evidence.previousSnapshotID ?? null) ||
      expected.previousSnapshotFingerprint !== (evidence.previousSnapshotFingerprint ?? null) ||
      expected.previousLineageID !== (evidence.previousLineageID ?? null) ||
      expected.manualStateUpdatedAtMs !== currentState.stateUpdatedAtMs
    ) {
      const error: ManualReconciliationError = { kind: 'stalePreview' };
      throw error;
    }
  }

  const preview = previewReconciliation(evidence, currentState, input.appliedAtMs);
  if (
    input.expectedPreview !== undefined &&
    !reconciliationCandidateMatches(input.expectedPreview, preview)
  ) {
    const error: ManualReconciliationError = { kind: 'stalePreview' };
    throw error;
  }

  const classifications = new Map<string, ManualReconciliationItem>();
  for (const item of preview.items) {
    classifications.set(trackerItemKeyStableId(item.itemKey), item);
  }

  const canCrossLineage = preview.lineageComparable || input.decision === 'acceptObserved';
  const observationOnlyCrossLineage =
    !preview.lineageComparable && input.decision === 'acceptObserved';
  const rebuiltCore = observationOnlyCrossLineage
    ? rebuildObservationOnlyReconciliationCore({
        observations: evidence.observations,
        classifications,
        itemKeysByStableID: evidence.itemKeysByStableID,
        newReference: preview.newReference,
        sourceTimestampMs: preview.sourceTimestampMs,
        decision: input.decision,
      })
    : canCrossLineage
      ? rebuildReconciliationCore({
          core: currentState.core,
          observations: evidence.observations,
          classifications,
          newReference: preview.newReference,
          sourceTimestampMs: preview.sourceTimestampMs,
          decision: input.decision,
        })
      : currentState.core;

  const diagnostics = [...currentState.diagnostics];
  if (manualReconciliationPreviewRequiresExplicitDecision(preview)) {
    diagnostics.push(
      createManualTrackerDiagnostic({
        kind: 'conflict',
        code: 'snapshot_reconciliation_attention',
        message: `本次导入有 ${manualReconciliationPreviewAttentionCount(preview)} 个项目需要保留本地状态或显式接受观察。`,
        recordedAtMs: input.appliedAtMs,
      }),
    );
  }

  const record = createManualReconciliationRecord({
    previousReference: preview.previousReference,
    newReference: preview.newReference,
    decision: input.decision,
    timeConfidence: preview.timeConfidence,
    sourceTimestampMs: preview.sourceTimestampMs,
    duplicate: preview.duplicate,
    appliedAtMs: input.appliedAtMs,
    items: preview.items,
  });

  const state = manualTrackerVillageStateWithCore(currentState, {
    core: rebuiltCore,
    stateUpdatedAtMs: input.appliedAtMs,
    lastImportAtMs: input.appliedAtMs,
    diagnostics,
    reconciliationHistory: [...currentState.reconciliationHistory, record],
    queueAssignments: rebasedQueueAssignments(
      currentState.queueAssignments,
      preview.newReference,
      evidence.observations,
    ),
  });

  return { preview, state };
}
