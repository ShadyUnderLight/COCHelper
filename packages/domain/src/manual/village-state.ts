import type { UuidString } from '@coc-helper/wire';
import { generateUuid } from '@coc-helper/wire';

import {
  baselineReferencesEqual,
  manualLevelDistributionsEqual,
  trackerItemKeysEqual,
} from './equality';
import { isManualBaselineReferenceStructurallyValid } from './models';
import { ManualUpgradeCoreState } from './core';
import type { LocalQueueCapacityConfig } from './queue/capacity-config';
import { localQueueKindsEqual } from './queue/local-queue-kind';
import type { QueueAssignmentDecision } from './queue/queue-assignment';
import type { ManualBaselineReference, ManualLevelDistribution } from './types';
import { trackerItemKeyStableId } from './types';
import type { ManualReconciliationRecord, ManualReconciliationItem } from './reconciliation/types';
import {
  MANUAL_TRACKER_SCHEMA,
  type ManualTrackerDiagnostic,
  type ManualTrackerMigrationMarker,
} from './tracker-schema';
import type { ManualTrackerStoreError } from './errors';

export type ManualTrackerVillageState = {
  readonly villageID: UuidString;
  readonly schemaVersion: number;
  readonly baselineReference: ManualBaselineReference | null;
  readonly core: ManualUpgradeCoreState;
  readonly stateUpdatedAtMs: number;
  readonly lastSettleAtMs: number | null;
  readonly lastImportAtMs: number | null;
  readonly diagnostics: readonly ManualTrackerDiagnostic[];
  readonly reconciliationHistory: readonly ManualReconciliationRecord[];
  readonly queueCapacityConfigs: readonly LocalQueueCapacityConfig[];
  readonly queueAssignments: readonly QueueAssignmentDecision[];
};

function isFiniteTimestamp(value: number | null | undefined): boolean {
  return value === null || value === undefined || Number.isFinite(value);
}

function validateReconciliationHistory(
  history: readonly ManualReconciliationRecord[],
): ManualTrackerStoreError | null {
  const ids = new Set<UuidString>();
  for (const record of history) {
    if (!isFiniteTimestamp(record.appliedAtMs)) {
      return { kind: 'invalidEnvelope', message: '对账历史无效。' };
    }
    if (!isFiniteTimestamp(record.sourceTimestampMs)) {
      return { kind: 'invalidEnvelope', message: '对账历史无效。' };
    }
    if (!isManualBaselineReferenceStructurallyValid(record.newReference)) {
      return { kind: 'invalidEnvelope', message: '对账历史无效。' };
    }
    if (
      record.previousReference !== null &&
      !isManualBaselineReferenceStructurallyValid(record.previousReference)
    ) {
      return { kind: 'invalidEnvelope', message: '对账历史无效。' };
    }
    if (ids.has(record.reconciliationID)) {
      return { kind: 'invalidEnvelope', message: '存在重复的 reconciliationID。' };
    }
    ids.add(record.reconciliationID);
  }
  return null;
}

export function createManualTrackerVillageState(input: {
  readonly villageID: UuidString;
  readonly core: ManualUpgradeCoreState;
  readonly stateUpdatedAtMs?: number;
  readonly lastSettleAtMs?: number | null;
  readonly lastImportAtMs?: number | null;
  readonly diagnostics?: readonly ManualTrackerDiagnostic[];
  readonly reconciliationHistory?: readonly ManualReconciliationRecord[];
  readonly queueCapacityConfigs?: readonly LocalQueueCapacityConfig[];
  readonly queueAssignments?: readonly QueueAssignmentDecision[];
}): ManualTrackerVillageState {
  const stateUpdatedAtMs = input.stateUpdatedAtMs ?? Date.now();
  if (!Number.isFinite(stateUpdatedAtMs)) {
    throw {
      kind: 'invalidEnvelope',
      message: 'stateUpdatedAt 无效。',
    } satisfies ManualTrackerStoreError;
  }
  if (!isFiniteTimestamp(input.lastSettleAtMs)) {
    throw {
      kind: 'invalidEnvelope',
      message: 'lastSettleAt 无效。',
    } satisfies ManualTrackerStoreError;
  }
  if (!isFiniteTimestamp(input.lastImportAtMs)) {
    throw {
      kind: 'invalidEnvelope',
      message: 'lastImportAt 无效。',
    } satisfies ManualTrackerStoreError;
  }
  const diagnostics = input.diagnostics ?? [];
  if (!diagnostics.every((entry) => Number.isFinite(entry.recordedAtMs))) {
    throw {
      kind: 'invalidEnvelope',
      message: '村庄诊断时间无效。',
    } satisfies ManualTrackerStoreError;
  }
  const reconciliationHistory = input.reconciliationHistory ?? [];
  const historyError = validateReconciliationHistory(reconciliationHistory);
  if (historyError !== null) {
    throw historyError;
  }
  const queueCapacityConfigs = input.queueCapacityConfigs ?? [];
  if (queueCapacityConfigs.length > 64) {
    throw {
      kind: 'invalidEnvelope',
      message: '本地容量配置数量超过上限。',
    } satisfies ManualTrackerStoreError;
  }
  const queueKinds = new Set<string>();
  for (const config of queueCapacityConfigs) {
    if (config.villageID !== input.villageID) {
      throw {
        kind: 'invalidEnvelope',
        message: '本地容量配置的村庄与所属村庄不一致。',
      } satisfies ManualTrackerStoreError;
    }
    if (!Number.isFinite(config.updatedAtMs)) {
      throw {
        kind: 'invalidEnvelope',
        message: '本地容量配置时间无效。',
      } satisfies ManualTrackerStoreError;
    }
    if (queueKinds.has(config.queueKind.rawValue)) {
      throw {
        kind: 'invalidEnvelope',
        message: '存在重复的本地容量类别配置。',
      } satisfies ManualTrackerStoreError;
    }
    queueKinds.add(config.queueKind.rawValue);
  }
  const queueAssignments = input.queueAssignments ?? [];
  if (queueAssignments.length > 4096) {
    throw {
      kind: 'invalidEnvelope',
      message: '队列分配数量超过上限。',
    } satisfies ManualTrackerStoreError;
  }
  const assignmentIDs = new Set<UuidString>();
  for (const assignment of queueAssignments) {
    if (assignment.villageID !== input.villageID) {
      throw {
        kind: 'invalidEnvelope',
        message: '队列分配的村庄与所属村庄不一致。',
      } satisfies ManualTrackerStoreError;
    }
    if (!Number.isFinite(assignment.decidedAtMs)) {
      throw {
        kind: 'invalidEnvelope',
        message: '队列分配时间无效。',
      } satisfies ManualTrackerStoreError;
    }
    if (assignmentIDs.has(assignment.decisionID)) {
      throw {
        kind: 'invalidEnvelope',
        message: '存在重复的队列分配 ID。',
      } satisfies ManualTrackerStoreError;
    }
    assignmentIDs.add(assignment.decisionID);
  }

  const references = new Set<string>();
  for (const state of input.core.itemStates) {
    references.add(JSON.stringify(state.baselineReference));
  }
  for (const record of input.core.records) {
    references.add(JSON.stringify(record.baselineReference));
  }
  if (references.size > 1) {
    throw {
      kind: 'invalidEnvelope',
      message: '同一村庄包含多个 baseline reference。',
    } satisfies ManualTrackerStoreError;
  }
  for (const record of input.core.records) {
    if (record.startedAtMs > stateUpdatedAtMs) {
      throw {
        kind: 'invalidEnvelope',
        message: '升级记录的 startedAt 不能晚于 stateUpdatedAt。',
      } satisfies ManualTrackerStoreError;
    }
  }

  const baselineReference =
    input.core.itemStates[0]?.baselineReference ?? input.core.records[0]?.baselineReference ?? null;

  return {
    villageID: input.villageID,
    schemaVersion: MANUAL_TRACKER_SCHEMA.village,
    baselineReference,
    core: input.core,
    stateUpdatedAtMs,
    lastSettleAtMs: input.lastSettleAtMs ?? null,
    lastImportAtMs: input.lastImportAtMs ?? null,
    diagnostics,
    reconciliationHistory,
    queueCapacityConfigs,
    queueAssignments,
  };
}

export function emptyManualTrackerVillageState(
  villageID: UuidString,
  nowMs: number = Date.now(),
): ManualTrackerVillageState {
  const safeNow = Number.isFinite(nowMs) ? nowMs : 0;
  return createManualTrackerVillageState({
    villageID,
    core: inputCoreEmpty(),
    stateUpdatedAtMs: safeNow,
  });
}

function inputCoreEmpty(): ManualUpgradeCoreState {
  return ManualUpgradeCoreState.create();
}

export function manualTrackerVillageStateWithCore(
  state: ManualTrackerVillageState,
  input: {
    readonly core?: ManualUpgradeCoreState;
    readonly stateUpdatedAtMs?: number;
    readonly lastSettleAtMs?: number | null;
    readonly lastImportAtMs?: number | null;
    readonly diagnostics?: readonly ManualTrackerDiagnostic[];
    readonly reconciliationHistory?: readonly ManualReconciliationRecord[];
    readonly queueCapacityConfigs?: readonly LocalQueueCapacityConfig[];
    readonly queueAssignments?: readonly QueueAssignmentDecision[];
  },
): ManualTrackerVillageState {
  return createManualTrackerVillageState({
    villageID: state.villageID,
    core: input.core ?? state.core,
    stateUpdatedAtMs: input.stateUpdatedAtMs ?? state.stateUpdatedAtMs,
    lastSettleAtMs:
      input.lastSettleAtMs !== undefined ? input.lastSettleAtMs : state.lastSettleAtMs,
    lastImportAtMs:
      input.lastImportAtMs !== undefined ? input.lastImportAtMs : state.lastImportAtMs,
    diagnostics: input.diagnostics ?? state.diagnostics,
    reconciliationHistory: input.reconciliationHistory ?? state.reconciliationHistory,
    queueCapacityConfigs: input.queueCapacityConfigs ?? state.queueCapacityConfigs,
    queueAssignments: input.queueAssignments ?? state.queueAssignments,
  });
}

export function manualTrackerVillageStatesEqual(
  left: ManualTrackerVillageState,
  right: ManualTrackerVillageState,
): boolean {
  return (
    left.villageID === right.villageID &&
    left.schemaVersion === right.schemaVersion &&
    baselineReferencesEqual(
      left.baselineReference ?? emptyBaseline(),
      right.baselineReference ?? emptyBaseline(),
    ) &&
    left.core.equals(right.core) &&
    left.stateUpdatedAtMs === right.stateUpdatedAtMs &&
    left.lastSettleAtMs === right.lastSettleAtMs &&
    left.lastImportAtMs === right.lastImportAtMs &&
    manualTrackerDiagnosticsEqual(left.diagnostics, right.diagnostics) &&
    manualReconciliationHistoryEqual(left.reconciliationHistory, right.reconciliationHistory) &&
    localQueueCapacityConfigsEqual(left.queueCapacityConfigs, right.queueCapacityConfigs) &&
    queueAssignmentsEqual(left.queueAssignments, right.queueAssignments)
  );
}

function manualTrackerDiagnosticsEqual(
  left: readonly ManualTrackerDiagnostic[],
  right: readonly ManualTrackerDiagnostic[],
): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index += 1) {
    const leftEntry = left[index]!;
    const rightEntry = right[index]!;
    if (
      leftEntry.kind !== rightEntry.kind ||
      leftEntry.code !== rightEntry.code ||
      leftEntry.message !== rightEntry.message ||
      leftEntry.recordedAtMs !== rightEntry.recordedAtMs
    ) {
      return false;
    }
  }
  return true;
}

function manualReconciliationHistoryEqual(
  left: readonly ManualReconciliationRecord[],
  right: readonly ManualReconciliationRecord[],
): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index += 1) {
    if (!manualReconciliationRecordsEqual(left[index]!, right[index]!)) {
      return false;
    }
  }
  return true;
}

function manualReconciliationRecordsEqual(
  left: ManualReconciliationRecord,
  right: ManualReconciliationRecord,
): boolean {
  return (
    left.reconciliationID === right.reconciliationID &&
    left.decision === right.decision &&
    left.timeConfidence === right.timeConfidence &&
    left.sourceTimestampMs === right.sourceTimestampMs &&
    left.duplicate === right.duplicate &&
    left.appliedAtMs === right.appliedAtMs &&
    baselineReferencesEqual(
      left.previousReference ?? emptyBaseline(),
      right.previousReference ?? emptyBaseline(),
    ) &&
    baselineReferencesEqual(left.newReference, right.newReference) &&
    manualReconciliationItemsEqual(left.items, right.items)
  );
}

function manualReconciliationItemsEqual(
  left: readonly ManualReconciliationItem[],
  right: readonly ManualReconciliationItem[],
): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index += 1) {
    if (!manualReconciliationItemEqual(left[index]!, right[index]!)) {
      return false;
    }
  }
  return true;
}

function manualReconciliationItemEqual(
  left: ManualReconciliationItem,
  right: ManualReconciliationItem,
): boolean {
  return (
    trackerItemKeysEqual(left.itemKey, right.itemKey) &&
    left.displayName === right.displayName &&
    left.classification === right.classification &&
    left.message === right.message &&
    distributionsEqual(left.previousDistribution, right.previousDistribution) &&
    distributionsEqual(left.observedDistribution, right.observedDistribution) &&
    uuidArraysEqual(left.relatedRecordIDs, right.relatedRecordIDs) &&
    uuidArraysEqual(left.confirmedRecordIDs, right.confirmedRecordIDs) &&
    left.observedTimer === right.observedTimer &&
    left.coverageComplete === right.coverageComplete &&
    left.observedDistributionComplete === right.observedDistributionComplete &&
    left.observedSectionTrustGatesOpen === right.observedSectionTrustGatesOpen &&
    left.observedTimerCoverageComplete === right.observedTimerCoverageComplete
  );
}

function distributionsEqual(
  left: ManualLevelDistribution | null,
  right: ManualLevelDistribution | null,
): boolean {
  if (left === null || right === null) {
    return left === right;
  }
  return manualLevelDistributionsEqual(left, right);
}

function uuidArraysEqual(left: readonly UuidString[], right: readonly UuidString[]): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) {
      return false;
    }
  }
  return true;
}

function localQueueCapacityConfigsEqual(
  left: readonly LocalQueueCapacityConfig[],
  right: readonly LocalQueueCapacityConfig[],
): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index += 1) {
    const leftEntry = left[index]!;
    const rightEntry = right[index]!;
    if (
      leftEntry.villageID !== rightEntry.villageID ||
      !localQueueKindsEqual(leftEntry.queueKind, rightEntry.queueKind) ||
      leftEntry.capacity !== rightEntry.capacity ||
      leftEntry.updatedAtMs !== rightEntry.updatedAtMs ||
      leftEntry.source !== rightEntry.source
    ) {
      return false;
    }
  }
  return true;
}

function queueAssignmentsEqual(
  left: readonly QueueAssignmentDecision[],
  right: readonly QueueAssignmentDecision[],
): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index += 1) {
    const leftEntry = left[index]!;
    const rightEntry = right[index]!;
    if (
      leftEntry.decisionID !== rightEntry.decisionID ||
      leftEntry.villageID !== rightEntry.villageID ||
      !trackerItemKeysEqual(leftEntry.itemKey, rightEntry.itemKey) ||
      !baselineReferencesEqual(leftEntry.baselineReference, rightEntry.baselineReference) ||
      !localQueueKindsEqual(leftEntry.queueKind, rightEntry.queueKind) ||
      leftEntry.source !== rightEntry.source ||
      leftEntry.decidedAtMs !== rightEntry.decidedAtMs ||
      leftEntry.status !== rightEntry.status
    ) {
      return false;
    }
  }
  return true;
}

function emptyBaseline(): ManualBaselineReference {
  return { revision: '', lineageID: null };
}

export function createManualReconciliationRecord(input: {
  readonly reconciliationID?: UuidString;
  readonly previousReference: ManualBaselineReference | null;
  readonly newReference: ManualBaselineReference;
  readonly decision: import('./reconciliation/types').ManualReconciliationDecision;
  readonly timeConfidence: import('./reconciliation/types').ManualReconciliationTimeConfidence;
  readonly sourceTimestampMs: number | null;
  readonly duplicate: boolean;
  readonly appliedAtMs: number;
  readonly items: readonly import('./reconciliation/types').ManualReconciliationItem[];
}): ManualReconciliationRecord {
  const sortedItems = input.items
    .slice()
    .sort((left, right) =>
      trackerItemKeyStableId(left.itemKey).localeCompare(trackerItemKeyStableId(right.itemKey)),
    );
  return {
    reconciliationID: input.reconciliationID ?? generateUuid(),
    previousReference: input.previousReference,
    newReference: input.newReference,
    decision: input.decision,
    timeConfidence: input.timeConfidence,
    sourceTimestampMs: input.sourceTimestampMs,
    duplicate: input.duplicate,
    appliedAtMs: input.appliedAtMs,
    items: sortedItems,
  };
}

export type { ManualTrackerMigrationMarker };
