import {
  createManualLevelDistributionFromPairs,
  createManualReconciliationEvidence,
  previewReconciliation,
  trackerItemKeyStableId,
  type ManualTrackerVillageState,
  type TrackerItemKey,
} from '@coc-helper/domain';
import type { UuidString } from '@coc-helper/wire';

type WireObservation = {
  readonly distribution: readonly (readonly [number, string])[] | null;
  readonly displayName: string;
  readonly hasTimer: boolean;
  readonly coverageComplete: boolean;
  readonly distributionComplete: boolean;
  readonly sectionTrustGatesOpen: boolean;
  readonly timerCoverageComplete: boolean;
};

type WireEvidence = {
  readonly villageID: UuidString;
  readonly newBaselineReference: {
    readonly revision: string;
    readonly lineageID: string | null;
  };
  readonly newNormalizedPlayerTag: string | null;
  readonly sourceTimestampMs: number | null;
  readonly duplicate: boolean;
  readonly lineageComparable: boolean;
  readonly observations: Readonly<Record<string, WireObservation>>;
  readonly itemKeys: Readonly<Record<string, unknown>>;
  readonly previousSourceTimestampMs?: number | null;
};

export function buildManualReconciliationParityCase(input: {
  readonly id: string;
  readonly appliedAtMs: number;
  readonly evidence: WireEvidence;
  readonly currentState: ManualTrackerVillageState;
}) {
  const evidence = wireEvidenceToDomain(input.evidence);
  const preview = previewReconciliation(evidence, input.currentState, input.appliedAtMs);
  // Issue #304：outcome 直接携带去除随机 ID 的语义字段（替代 candidateFingerprint）。
  const outcome = {
    duplicate: preview.duplicate,
    lineageComparable: preview.lineageComparable,
    timeConfidence: preview.timeConfidence,
    newReference: {
      revision: preview.newReference.revision,
      lineageID: preview.newReference.lineageID,
    },
    newNormalizedPlayerTag: preview.newNormalizedPlayerTag,
    sourceTimestampMs: preview.sourceTimestampMs,
    items: preview.items
      .map((item) => ({
        stableId: trackerItemKeyStableId(item.itemKey),
        classification: item.classification,
        previousDistribution: outcomeDistribution(item.previousDistribution),
        observedDistribution: outcomeDistribution(item.observedDistribution),
        relatedRecordIDs: [...item.relatedRecordIDs].sort((left, right) =>
          left.localeCompare(right),
        ),
        confirmedRecordIDs: [...item.confirmedRecordIDs].sort((left, right) =>
          left.localeCompare(right),
        ),
        observedTimer: item.observedTimer,
        coverageComplete: item.coverageComplete,
        observedDistributionComplete: item.observedDistributionComplete,
        observedSectionTrustGatesOpen: item.observedSectionTrustGatesOpen,
        observedTimerCoverageComplete: item.observedTimerCoverageComplete,
      }))
      .sort((left, right) => left.stableId.localeCompare(right.stableId)),
  };
  return {
    request: {
      evidence: input.evidence,
      currentState: wireVillageState(input.currentState),
      appliedAtMs: input.appliedAtMs,
    },
    outcome,
  };
}

function wireEvidenceToDomain(wire: WireEvidence) {
  const observationEntries = Object.entries(wire.observations).map(([stableId, observation]) => {
    const itemKey = wire.itemKeys[stableId];
    if (itemKey === undefined) {
      throw new Error(`missing item key for ${stableId}`);
    }
    return {
      itemKey: wireItemKeyToDomain(itemKey),
      observation: {
        distribution:
          observation.distribution === null
            ? null
            : createManualLevelDistributionFromPairs(
                observation.distribution.map(
                  ([level, quantity]) => [level, BigInt(quantity)] as const,
                ),
              ),
        displayName: observation.displayName,
        hasTimer: observation.hasTimer,
        coverageComplete: observation.coverageComplete,
        distributionComplete: observation.distributionComplete,
        sectionTrustGatesOpen: observation.sectionTrustGatesOpen,
        timerCoverageComplete: observation.timerCoverageComplete,
      },
    };
  });
  return createManualReconciliationEvidence({
    villageID: wire.villageID,
    newBaselineReference: wire.newBaselineReference,
    newNormalizedPlayerTag: wire.newNormalizedPlayerTag,
    sourceTimestampMs: wire.sourceTimestampMs,
    duplicate: wire.duplicate,
    lineageComparable: wire.lineageComparable,
    previousSourceTimestampMs: wire.previousSourceTimestampMs ?? null,
    observations: new Map(),
    observationEntries,
  });
}

function wireItemKeyToDomain(value: unknown): TrackerItemKey {
  if (typeof value !== 'object' || value === null) {
    throw new Error('invalid wire item key');
  }
  const record = value as Record<string, unknown>;
  return {
    base: record.base as TrackerItemKey['base'],
    rawSection: String(record.rawSection),
    dataID: BigInt(String(record.dataID)),
    nestedKind: record.nestedKind as TrackerItemKey['nestedKind'],
    nestedRootIdentity: (record.nestedRootIdentity as TrackerItemKey['nestedRootIdentity']) ?? null,
    nestedPath: (record.nestedPath as TrackerItemKey['nestedPath']) ?? [],
  };
}

function wireVillageState(state: ManualTrackerVillageState) {
  return {
    villageID: state.villageID,
    core: {
      itemStates: state.core.itemStates.map((itemState) => ({
        itemKey: wireItemKey(itemState.itemKey),
        baselineReference: itemState.baselineReference,
        importedObservation:
          itemState.importedObservation === null
            ? null
            : {
                reference: itemState.importedObservation.reference,
                levelDistribution: wireDistribution(
                  itemState.importedObservation.levelDistribution,
                ),
                sourceTimestampMs: itemState.importedObservation.sourceTimestampMs,
                observedTimer: itemState.importedObservation.observedTimer,
                observedTimerCoverageComplete:
                  itemState.importedObservation.observedTimerCoverageComplete,
              },
        manualCompletedDistribution: wireDistribution(itemState.manualCompletedDistribution),
        status: itemState.status,
      })),
      records: state.core.records.map((record) => ({
        recordID: record.recordID,
        itemKey: wireItemKey(record.itemKey),
        fromLevel: record.fromLevel,
        targetLevel: record.targetLevel,
        quantity: record.quantity.toString(),
        startedAtMs: record.startedAtMs,
        expectedEndAtMs: record.expectedEndAtMs,
        durationSeconds: record.durationSeconds.toString(),
        durationKind: record.durationKind,
        frozenCosts: record.frozenCosts,
        catalogProvenance: record.catalogProvenance,
        baselineReference: record.baselineReference,
        queueKind: record.queueKind,
        status: record.status,
      })),
    },
    stateUpdatedAtMs: state.stateUpdatedAtMs,
  };
}

function wireItemKey(key: TrackerItemKey) {
  return {
    base: key.base,
    rawSection: key.rawSection,
    dataID: wireDataID(key.dataID),
    nestedKind: key.nestedKind,
    nestedRootIdentity: key.nestedRootIdentity,
    nestedPath: key.nestedPath,
  };
}

function wireDataID(value: bigint): number {
  const asNumber = Number(value);
  if (!Number.isSafeInteger(asNumber) || BigInt(asNumber) !== value) {
    throw new RangeError(`wire 编码超出 JS safe integer：${value.toString()}`);
  }
  return asNumber;
}

function wireDistribution(
  distribution:
    ManualTrackerVillageState['core']['itemStates'][number]['manualCompletedDistribution'] | null,
) {
  if (distribution === null) {
    return null;
  }
  return distribution.levels.map((entry) => [String(entry.level), entry.quantity.toString()]);
}

function outcomeDistribution(
  distribution:
    | ManualTrackerVillageState['core']['itemStates'][number]['manualCompletedDistribution']
    | null
    | undefined,
) {
  if (distribution === null || distribution === undefined) {
    return null;
  }
  return distribution.levels.map((entry) => ({
    level: entry.level,
    quantity: entry.quantity.toString(),
  }));
}
