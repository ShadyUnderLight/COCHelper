import { manualLevelDistributionQuantityAt } from '../level-distribution';
import {
  createManualImportedObservation,
  createManualItemState,
  createManualUpgradeRecord,
} from '../models';
import { ManualUpgradeCoreState } from '../core';
import type {
  ManualBaselineReference,
  ManualItemState,
  ManualItemStatus,
  ManualUpgradeRecord,
  TrackerItemKey,
} from '../types';
import { trackerItemKeyStableId } from '../types';
import type { ReconciliationObservation } from './evidence';
import { hasReconciliationLocalState, effectiveReconciliationDistribution } from './helpers';
import type { ManualReconciliationDecision, ManualReconciliationItem } from './types';
import type { ManualReconciliationError } from '../errors';

function importedObservationFromReconciliation(
  reference: ManualBaselineReference,
  observation: ReconciliationObservation,
  sourceTimestampMs: number | null,
): ReturnType<typeof createManualImportedObservation> {
  return createManualImportedObservation({
    reference,
    levelDistribution: observation.distribution,
    sourceTimestampMs,
    observedTimer: observation.hasTimer,
    observedTimerCoverageComplete: observation.hasTimer && observation.timerCoverageComplete,
  });
}

export function shouldAdoptReconciliationItem(
  item: ManualReconciliationItem | undefined,
  decision: ManualReconciliationDecision,
  hasActiveRecord: boolean,
): boolean {
  if (item === undefined) {
    return false;
  }
  switch (decision) {
    case 'keepLocal':
      return item.classification === 'duplicate' || item.classification === 'newObservation';
    case 'acceptObserved':
      return true;
    case 'applyNonConflicting': {
      if (
        item.classification !== 'duplicate' &&
        item.classification !== 'newObservation' &&
        item.classification !== 'exactMatch' &&
        item.classification !== 'observedAhead'
      ) {
        return false;
      }
      if (
        item.classification === 'observedAhead' &&
        hasActiveRecord &&
        item.confirmedRecordIDs.length === 0
      ) {
        return false;
      }
      return true;
    }
  }
}

export function rebuildReconciliationCore(input: {
  readonly core: ManualUpgradeCoreState;
  readonly observations: ReadonlyMap<string, ReconciliationObservation>;
  readonly classifications: ReadonlyMap<string, ManualReconciliationItem>;
  readonly newReference: ManualBaselineReference;
  readonly sourceTimestampMs: number | null;
  readonly decision: ManualReconciliationDecision;
}): ManualUpgradeCoreState {
  const existingStates = new Map<string, ManualItemState>();
  for (const state of input.core.itemStates) {
    existingStates.set(trackerItemKeyStableId(state.itemKey), state);
  }
  const allStableIds = new Set<string>([...existingStates.keys(), ...input.observations.keys()]);
  const records: ManualUpgradeRecord[] = [];

  for (const oldRecord of input.core.records) {
    const item = input.classifications.get(trackerItemKeyStableId(oldRecord.itemKey));
    const hasActiveRecord = input.core.records.some(
      (record) =>
        trackerItemKeyStableId(record.itemKey) === trackerItemKeyStableId(oldRecord.itemKey) &&
        record.status === 'active',
    );
    const shouldAdopt = shouldAdoptReconciliationItem(item, input.decision, hasActiveRecord);
    const confirmed =
      shouldAdopt && (item?.confirmedRecordIDs.includes(oldRecord.recordID) ?? false);
    records.push(
      createManualUpgradeRecord({
        recordID: oldRecord.recordID,
        itemKey: oldRecord.itemKey,
        fromLevel: oldRecord.fromLevel,
        targetLevel: oldRecord.targetLevel,
        quantity: oldRecord.quantity,
        startedAtMs: oldRecord.startedAtMs,
        expectedEndAtMs: oldRecord.expectedEndAtMs,
        durationSeconds: oldRecord.durationSeconds,
        durationKind: oldRecord.durationKind,
        frozenCosts: oldRecord.frozenCosts,
        catalogProvenance: oldRecord.catalogProvenance,
        baselineReference: input.newReference,
        queueKind: oldRecord.queueKind,
        status: confirmed && oldRecord.status === 'active' ? 'completed' : oldRecord.status,
      }),
    );
  }

  const states: ManualItemState[] = [];
  const sortedStableIds = [...allStableIds].sort((left, right) => left.localeCompare(right));

  for (const stableId of sortedStableIds) {
    const old = existingStates.get(stableId);
    const observation = input.observations.get(stableId);
    const itemRecords = records.filter(
      (record) => trackerItemKeyStableId(record.itemKey) === stableId,
    );
    const originalRecords = input.core.records.filter(
      (record) => trackerItemKeyStableId(record.itemKey) === stableId,
    );
    const hasLocal = hasReconciliationLocalState(old, originalRecords);
    const item = input.classifications.get(stableId);
    const hasActiveRecord = itemRecords.some((record) => record.status === 'active');
    const adopt = shouldAdoptReconciliationItem(item, input.decision, hasActiveRecord);
    const key = old?.itemKey ?? item?.itemKey;
    if (key === undefined) {
      continue;
    }

    if (old === undefined && observation !== undefined) {
      const imported = importedObservationFromReconciliation(
        input.newReference,
        observation,
        input.sourceTimestampMs,
      );
      states.push(
        createManualItemState({
          itemKey: key,
          baselineReference: input.newReference,
          importedObservation: imported,
          status: 'observed',
        }),
      );
      continue;
    }
    if (old === undefined) {
      continue;
    }

    if (!hasLocal && observation?.distribution === null) {
      const imported = createManualImportedObservation({
        reference: input.newReference,
        levelDistribution: null,
        sourceTimestampMs: input.sourceTimestampMs,
        observedTimer: observation?.hasTimer ?? false,
        observedTimerCoverageComplete:
          observation !== undefined && observation.hasTimer && observation.timerCoverageComplete,
      });
      let status: ManualItemStatus;
      switch (old.status) {
        case 'conflict':
          status = 'conflict';
          break;
        case 'unknown':
          status = 'unknown';
          break;
        default:
          status = 'observed';
          break;
      }
      states.push(
        createManualItemState({
          itemKey: key,
          baselineReference: input.newReference,
          importedObservation: imported,
          status,
        }),
      );
      continue;
    }

    if (!hasLocal && !adopt && (old.status === 'unknown' || old.status === 'conflict')) {
      const imported = createManualImportedObservation({
        reference: input.newReference,
        levelDistribution: null,
        sourceTimestampMs: input.sourceTimestampMs,
        observedTimer: observation?.hasTimer ?? false,
        observedTimerCoverageComplete:
          observation !== undefined && observation.hasTimer && observation.timerCoverageComplete,
      });
      states.push(
        createManualItemState({
          itemKey: key,
          baselineReference: input.newReference,
          importedObservation: imported,
          status: old.status,
        }),
      );
      continue;
    }

    if (!hasLocal && adopt && observation !== undefined && observation.distribution !== null) {
      const imported = importedObservationFromReconciliation(
        input.newReference,
        observation,
        input.sourceTimestampMs,
      );
      states.push(
        createManualItemState({
          itemKey: key,
          baselineReference: input.newReference,
          importedObservation: imported,
          status: 'observed',
        }),
      );
      continue;
    }

    const preserved = effectiveReconciliationDistribution(old) ?? old.manualCompletedDistribution;
    const materialized = adopt ? (observation?.distribution ?? preserved) : preserved;
    states.push(
      createManualItemState({
        itemKey: key,
        baselineReference: input.newReference,
        importedObservation: null,
        manualCompletedDistribution: materialized,
        status: 'manualCompleted',
      }),
    );

    for (const active of itemRecords) {
      if (active.status !== 'active') {
        continue;
      }
      if (manualLevelDistributionQuantityAt(materialized, active.fromLevel) < active.quantity) {
        const error: ManualReconciliationError = {
          kind: 'invalidObservation',
          message: `观察结果无法保留进行中的本地记录 ${active.recordID}。`,
        };
        throw error;
      }
    }
  }

  return ManualUpgradeCoreState.create({ itemStates: states, records });
}

/** 跨 lineage 且 acceptObserved：只从注入观察重建 core，旧 records/manual state 不进入新 core。 */
export function rebuildObservationOnlyReconciliationCore(input: {
  readonly observations: ReadonlyMap<string, ReconciliationObservation>;
  readonly classifications: ReadonlyMap<string, ManualReconciliationItem>;
  readonly itemKeysByStableID: ReadonlyMap<string, TrackerItemKey>;
  readonly newReference: ManualBaselineReference;
  readonly sourceTimestampMs: number | null;
  readonly decision: ManualReconciliationDecision;
}): ManualUpgradeCoreState {
  if (input.decision !== 'acceptObserved') {
    const error: ManualReconciliationError = {
      kind: 'invalidObservation',
      message: '跨 lineage 重建只支持 acceptObserved。',
    };
    throw error;
  }

  const states: ManualItemState[] = [];
  const sortedStableIds = [...input.observations.keys()].sort((left, right) =>
    left.localeCompare(right),
  );

  for (const stableId of sortedStableIds) {
    const observation = input.observations.get(stableId);
    if (observation === undefined) {
      continue;
    }
    const itemKey =
      input.itemKeysByStableID.get(stableId) ?? input.classifications.get(stableId)?.itemKey;
    if (itemKey === undefined) {
      continue;
    }
    const item = input.classifications.get(stableId);
    if (!shouldAdoptReconciliationItem(item, input.decision, false)) {
      continue;
    }

    if (observation.distribution !== null) {
      states.push(
        createManualItemState({
          itemKey,
          baselineReference: input.newReference,
          importedObservation: importedObservationFromReconciliation(
            input.newReference,
            observation,
            input.sourceTimestampMs,
          ),
          status: 'observed',
        }),
      );
      continue;
    }

    states.push(
      createManualItemState({
        itemKey,
        baselineReference: input.newReference,
        importedObservation: createManualImportedObservation({
          reference: input.newReference,
          levelDistribution: null,
          sourceTimestampMs: input.sourceTimestampMs,
          observedTimer: observation.hasTimer,
          observedTimerCoverageComplete: observation.hasTimer && observation.timerCoverageComplete,
        }),
        status: 'observed',
      }),
    );
  }

  return ManualUpgradeCoreState.create({ itemStates: states, records: [] });
}
