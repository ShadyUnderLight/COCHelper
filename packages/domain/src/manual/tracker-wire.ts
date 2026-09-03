import { parseUuid, type UuidString } from '@coc-helper/wire';

import type { CatalogUpgradeCost } from '../catalog/types';
import { ManualUpgradeCoreState } from './core';
import { baselineReferencesEqual } from './equality';
import type { ManualTrackerStoreError } from './errors';
import {
  createManualLevelDistribution,
  createManualLevelQuantity,
  MANUAL_LEVEL_DISTRIBUTION_EMPTY,
} from './level-distribution';
import {
  createManualImportedObservation,
  createManualItemState,
  createManualUpgradeRecord,
} from './models';
import { createLocalQueueCapacityConfig } from './queue/capacity-config';
import { createLocalQueueKind } from './queue/local-queue-kind';
import { createQueueAssignmentDecision } from './queue/queue-assignment';
import type {
  ManualReconciliationClassification,
  ManualReconciliationDecision,
  ManualReconciliationItem,
  ManualReconciliationRecord,
  ManualReconciliationTimeConfidence,
} from './reconciliation/types';
import {
  createManualTrackerEnvelope,
  type ManualTrackerEnvelope,
  validateManualTrackerEnvelope,
} from './tracker-envelope';
import {
  createManualTrackerDiagnostic,
  createManualTrackerMigrationMarker,
  MANUAL_TRACKER_SCHEMA,
  type ManualTrackerDiagnostic,
  type ManualTrackerMigrationMarker,
} from './tracker-schema';
import type {
  ManualBaselineReference,
  ManualCatalogProvenance,
  ManualItemState,
  ManualItemStatus,
  ManualLevelDistribution,
  ManualUpgradeRecord,
  ManualUpgradeRecordStatus,
  TrackerItemKey,
} from './types';
import {
  createManualReconciliationRecord,
  createManualTrackerVillageState,
  type ManualTrackerVillageState,
} from './village-state';
import type { TrackerBase } from '../village/tracker';

/** Electron 新根 ManualTrackerEnvelope wire（*Ms 时间戳，非 Swift Date）。 */
export function encodeManualTrackerEnvelopeWire(envelope: ManualTrackerEnvelope): string {
  const validated = validateManualTrackerEnvelope(envelope);
  return JSON.stringify({
    schemaVersion: validated.schemaVersion,
    storeVersion: validated.storeVersion,
    villages: validated.villages.map(encodeVillage),
    migrationMarker: validated.migrationMarker,
    lastDiagnostic: validated.lastDiagnostic,
  });
}

export function decodeManualTrackerEnvelopeWire(text: string): ManualTrackerEnvelope {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text) as unknown;
  } catch (error) {
    throw {
      kind: 'corrupt',
      message: error instanceof Error ? error.message : String(error),
    } satisfies ManualTrackerStoreError;
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw {
      kind: 'corrupt',
      message: '手动升级 store 顶层必须是对象。',
    } satisfies ManualTrackerStoreError;
  }
  const root = parsed as Record<string, unknown>;
  try {
    return createManualTrackerEnvelope({
      schemaVersion: requireInt(root.schemaVersion, 'schemaVersion'),
      storeVersion: requireInt(root.storeVersion, 'storeVersion'),
      villages: requireArray(root.villages, 'villages').map(decodeVillage),
      migrationMarker: decodeMigrationMarker(root.migrationMarker),
      lastDiagnostic: decodeDiagnostic(root.lastDiagnostic),
    });
  } catch (error) {
    if (isManualTrackerStoreError(error)) {
      throw error;
    }
    throw {
      kind: 'corrupt',
      message: error instanceof Error ? error.message : String(error),
    } satisfies ManualTrackerStoreError;
  }
}

function encodeVillage(state: ManualTrackerVillageState): unknown {
  return {
    villageID: state.villageID,
    schemaVersion: state.schemaVersion,
    baselineReference: state.baselineReference,
    core: {
      itemStates: state.core.itemStates.map(encodeItemState),
      records: state.core.records.map(encodeRecord),
    },
    stateUpdatedAtMs: state.stateUpdatedAtMs,
    lastSettleAtMs: state.lastSettleAtMs,
    lastImportAtMs: state.lastImportAtMs,
    diagnostics: state.diagnostics,
    reconciliationHistory: state.reconciliationHistory.map(encodeReconciliation),
    queueCapacityConfigs: state.queueCapacityConfigs.map((config) => ({
      villageID: config.villageID,
      queueKind: config.queueKind.rawValue,
      capacity: config.capacity,
      updatedAtMs: config.updatedAtMs,
      source: config.source,
    })),
    queueAssignments: state.queueAssignments.map((assignment) => ({
      decisionID: assignment.decisionID,
      villageID: assignment.villageID,
      itemKey: encodeItemKey(assignment.itemKey),
      baselineReference: assignment.baselineReference,
      queueKind: assignment.queueKind.rawValue,
      source: assignment.source,
      decidedAtMs: assignment.decidedAtMs,
      status: assignment.status,
    })),
  };
}

function decodeVillage(value: unknown): ManualTrackerVillageState {
  const record = requireObject(value, 'village');
  // 必须在 normalize 前消费 raw schemaVersion，禁止静默升级 future schema。
  const rawSchemaVersion = requireInt(record.schemaVersion, 'schemaVersion');
  if (rawSchemaVersion !== MANUAL_TRACKER_SCHEMA.village) {
    throw {
      kind: 'unsupportedSchema',
      version: rawSchemaVersion,
    } satisfies ManualTrackerStoreError;
  }

  const coreWire = requireObject(record.core, 'core');
  const core = ManualUpgradeCoreState.create({
    itemStates: requireArray(coreWire.itemStates, 'itemStates').map(decodeItemState),
    records: requireArray(coreWire.records, 'records').map(decodeRecord),
  });
  const derivedBaseline =
    core.itemStates[0]?.baselineReference ?? core.records[0]?.baselineReference ?? null;
  const rawBaseline =
    record.baselineReference === null || record.baselineReference === undefined
      ? null
      : decodeBaseline(record.baselineReference);
  if (!optionalBaselinesEqual(rawBaseline, derivedBaseline)) {
    throw {
      kind: 'corrupt',
      message: 'village baselineReference 与 core 派生值不一致。',
    } satisfies ManualTrackerStoreError;
  }

  return createManualTrackerVillageState({
    villageID: requireUuid(record.villageID, 'villageID'),
    core,
    stateUpdatedAtMs: requireFiniteNumber(record.stateUpdatedAtMs, 'stateUpdatedAtMs'),
    lastSettleAtMs: optionalFiniteNumber(record.lastSettleAtMs),
    lastImportAtMs: optionalFiniteNumber(record.lastImportAtMs),
    diagnostics: requireArray(record.diagnostics ?? [], 'diagnostics').map((entry) => {
      const diagnostic = decodeDiagnostic(entry);
      if (diagnostic === null) {
        throw new Error('diagnostics 条目无效。');
      }
      return diagnostic;
    }),
    reconciliationHistory: requireArray(
      record.reconciliationHistory ?? [],
      'reconciliationHistory',
    ).map(decodeReconciliation),
    queueCapacityConfigs: requireArray(
      record.queueCapacityConfigs ?? [],
      'queueCapacityConfigs',
    ).map((entry) => {
      const config = requireObject(entry, 'queueCapacityConfig');
      return createLocalQueueCapacityConfig({
        villageID: requireUuid(config.villageID, 'villageID'),
        queueKind: createLocalQueueKind(requireString(config.queueKind, 'queueKind')),
        capacity: requireInt(config.capacity, 'capacity'),
        updatedAtMs: requireFiniteNumber(config.updatedAtMs, 'updatedAtMs'),
        source: 'userConfigured',
      });
    }),
    queueAssignments: requireArray(record.queueAssignments ?? [], 'queueAssignments').map(
      (entry) => {
        const assignment = requireObject(entry, 'queueAssignment');
        return createQueueAssignmentDecision({
          decisionID: requireUuid(assignment.decisionID, 'decisionID'),
          villageID: requireUuid(assignment.villageID, 'villageID'),
          itemKey: decodeItemKey(assignment.itemKey),
          baselineReference: decodeBaseline(assignment.baselineReference),
          queueKind: createLocalQueueKind(requireString(assignment.queueKind, 'queueKind')),
          decidedAtMs: requireFiniteNumber(assignment.decidedAtMs, 'decidedAtMs'),
          status: requireString(assignment.status, 'status') as
            'userAssigned' | 'observedOnly' | 'unknown',
        });
      },
    ),
  });
}

function optionalBaselinesEqual(
  left: ManualBaselineReference | null,
  right: ManualBaselineReference | null,
): boolean {
  if (left === null || right === null) {
    return left === right;
  }
  return baselineReferencesEqual(left, right);
}

function encodeItemState(state: ManualItemState): unknown {
  return {
    itemKey: encodeItemKey(state.itemKey),
    baselineReference: state.baselineReference,
    importedObservation:
      state.importedObservation === null
        ? null
        : {
            reference: state.importedObservation.reference,
            levelDistribution: encodeDistribution(state.importedObservation.levelDistribution),
            sourceTimestampMs: state.importedObservation.sourceTimestampMs,
            observedTimer: state.importedObservation.observedTimer,
            observedTimerCoverageComplete: state.importedObservation.observedTimerCoverageComplete,
          },
    manualCompletedDistribution: encodeDistribution(state.manualCompletedDistribution),
    status: state.status,
  };
}

function decodeItemState(value: unknown): ManualItemState {
  const record = requireObject(value, 'itemState');
  const importedWire =
    record.importedObservation === null || record.importedObservation === undefined
      ? null
      : requireObject(record.importedObservation, 'importedObservation');
  return createManualItemState({
    itemKey: decodeItemKey(record.itemKey),
    baselineReference: decodeBaseline(record.baselineReference),
    importedObservation:
      importedWire === null
        ? null
        : createManualImportedObservation({
            reference: decodeBaseline(importedWire.reference),
            levelDistribution: decodeDistribution(importedWire.levelDistribution),
            sourceTimestampMs: optionalFiniteNumber(importedWire.sourceTimestampMs),
            observedTimer: Boolean(importedWire.observedTimer),
            observedTimerCoverageComplete: Boolean(importedWire.observedTimerCoverageComplete),
          }),
    manualCompletedDistribution:
      decodeDistribution(record.manualCompletedDistribution) ?? MANUAL_LEVEL_DISTRIBUTION_EMPTY,
    status: requireString(record.status, 'status') as ManualItemStatus,
  });
}

function encodeRecord(record: ManualUpgradeRecord): unknown {
  return {
    recordID: record.recordID,
    itemKey: encodeItemKey(record.itemKey),
    fromLevel: record.fromLevel,
    targetLevel: record.targetLevel,
    quantity: bigintToNumber(record.quantity),
    startedAtMs: record.startedAtMs,
    expectedEndAtMs: record.expectedEndAtMs,
    durationSeconds: bigintToNumber(record.durationSeconds),
    durationKind: record.durationKind,
    frozenCosts:
      record.frozenCosts === null
        ? null
        : record.frozenCosts.map((cost) => ({
            resource: cost.resource,
            amount: cost.amount === null ? null : bigintToNumber(cost.amount),
            rawResource: cost.rawResource,
            rawAmount: cost.rawAmount,
            parseFailed: cost.parseFailed,
          })),
    catalogProvenance: {
      gameVersion: record.catalogProvenance.gameVersion,
      buildTag: record.catalogProvenance.buildTag,
      manifestSchemaVersion: record.catalogProvenance.manifestSchemaVersion,
    },
    baselineReference: record.baselineReference,
    queueKind: record.queueKind,
    status: record.status,
  };
}

function decodeRecord(value: unknown): ManualUpgradeRecord {
  const record = requireObject(value, 'record');
  const frozen =
    record.frozenCosts === null || record.frozenCosts === undefined
      ? null
      : requireArray(record.frozenCosts, 'frozenCosts').map((entry) => {
          const cost = requireObject(entry, 'cost');
          return {
            resource: requireString(cost.resource, 'resource'),
            amount:
              cost.amount === null || cost.amount === undefined
                ? null
                : numberToBigint(cost.amount, 'amount'),
            rawResource:
              cost.rawResource === null || cost.rawResource === undefined
                ? null
                : requireString(cost.rawResource, 'rawResource'),
            rawAmount:
              cost.rawAmount === null || cost.rawAmount === undefined
                ? null
                : requireString(cost.rawAmount, 'rawAmount'),
            parseFailed: Boolean(cost.parseFailed),
          } satisfies CatalogUpgradeCost;
        });
  return createManualUpgradeRecord({
    recordID: requireUuid(record.recordID, 'recordID'),
    itemKey: decodeItemKey(record.itemKey),
    fromLevel: requireInt(record.fromLevel, 'fromLevel'),
    targetLevel: requireInt(record.targetLevel, 'targetLevel'),
    quantity: numberToBigint(record.quantity, 'quantity'),
    startedAtMs: requireFiniteNumber(record.startedAtMs, 'startedAtMs'),
    expectedEndAtMs: requireFiniteNumber(record.expectedEndAtMs, 'expectedEndAtMs'),
    durationSeconds: numberToBigint(record.durationSeconds, 'durationSeconds'),
    durationKind: requireString(record.durationKind, 'durationKind') as 'timed' | 'instant',
    frozenCosts: frozen,
    catalogProvenance: decodeProvenance(record.catalogProvenance),
    baselineReference: decodeBaseline(record.baselineReference),
    queueKind:
      record.queueKind === null || record.queueKind === undefined
        ? null
        : requireString(record.queueKind, 'queueKind'),
    status: requireString(record.status, 'status') as ManualUpgradeRecordStatus,
  });
}

function encodeReconciliation(record: ManualReconciliationRecord): unknown {
  return {
    reconciliationID: record.reconciliationID,
    previousReference: record.previousReference,
    newReference: record.newReference,
    decision: record.decision,
    timeConfidence: record.timeConfidence,
    sourceTimestampMs: record.sourceTimestampMs,
    duplicate: record.duplicate,
    appliedAtMs: record.appliedAtMs,
    items: record.items.map((item) => ({
      itemKey: encodeItemKey(item.itemKey),
      displayName: item.displayName,
      classification: item.classification,
      message: item.message,
      previousDistribution: encodeDistribution(item.previousDistribution),
      observedDistribution: encodeDistribution(item.observedDistribution),
      relatedRecordIDs: item.relatedRecordIDs,
      confirmedRecordIDs: item.confirmedRecordIDs,
      observedTimer: item.observedTimer,
      coverageComplete: item.coverageComplete,
      observedDistributionComplete: item.observedDistributionComplete,
      observedSectionTrustGatesOpen: item.observedSectionTrustGatesOpen,
      observedTimerCoverageComplete: item.observedTimerCoverageComplete,
    })),
  };
}

function decodeReconciliation(value: unknown): ManualReconciliationRecord {
  const record = requireObject(value, 'reconciliation');
  const items: ManualReconciliationItem[] = requireArray(record.items, 'items').map((entry) => {
    const item = requireObject(entry, 'reconciliationItem');
    return {
      itemKey: decodeItemKey(item.itemKey),
      displayName: requireString(item.displayName, 'displayName'),
      classification: requireString(
        item.classification,
        'classification',
      ) as ManualReconciliationClassification,
      message: requireString(item.message, 'message'),
      previousDistribution: decodeDistribution(item.previousDistribution),
      observedDistribution: decodeDistribution(item.observedDistribution),
      relatedRecordIDs: requireArray(item.relatedRecordIDs ?? [], 'relatedRecordIDs').map((id) =>
        requireUuid(id, 'relatedRecordID'),
      ),
      confirmedRecordIDs: requireArray(item.confirmedRecordIDs ?? [], 'confirmedRecordIDs').map(
        (id) => requireUuid(id, 'confirmedRecordID'),
      ),
      observedTimer: Boolean(item.observedTimer),
      coverageComplete: Boolean(item.coverageComplete),
      observedDistributionComplete: Boolean(item.observedDistributionComplete),
      observedSectionTrustGatesOpen: Boolean(item.observedSectionTrustGatesOpen),
      observedTimerCoverageComplete: Boolean(item.observedTimerCoverageComplete),
    };
  });
  return createManualReconciliationRecord({
    reconciliationID: requireUuid(record.reconciliationID, 'reconciliationID'),
    previousReference:
      record.previousReference === null || record.previousReference === undefined
        ? null
        : decodeBaseline(record.previousReference),
    newReference: decodeBaseline(record.newReference),
    decision: requireString(record.decision, 'decision') as ManualReconciliationDecision,
    timeConfidence: requireString(
      record.timeConfidence,
      'timeConfidence',
    ) as ManualReconciliationTimeConfidence,
    sourceTimestampMs: optionalFiniteNumber(record.sourceTimestampMs),
    duplicate: Boolean(record.duplicate),
    appliedAtMs: requireFiniteNumber(record.appliedAtMs, 'appliedAtMs'),
    items,
  });
}

function encodeItemKey(key: TrackerItemKey): unknown {
  return {
    base: key.base,
    rawSection: key.rawSection,
    dataID: bigintToNumber(key.dataID),
    nestedKind: key.nestedKind,
    nestedRootIdentity:
      key.nestedRootIdentity === null
        ? null
        : {
            base: key.nestedRootIdentity.base,
            rawSection: key.nestedRootIdentity.rawSection,
            dataID: bigintToNumber(key.nestedRootIdentity.dataID),
          },
    nestedPath: key.nestedPath.map((component) => ({
      kind: component.kind,
      dataID: bigintToNumber(component.dataID),
    })),
  };
}

function decodeItemKey(value: unknown): TrackerItemKey {
  const record = requireObject(value, 'itemKey');
  const nestedRoot =
    record.nestedRootIdentity === null || record.nestedRootIdentity === undefined
      ? null
      : requireObject(record.nestedRootIdentity, 'nestedRootIdentity');
  return {
    base: requireString(record.base, 'base') as TrackerBase,
    rawSection: requireString(record.rawSection, 'rawSection'),
    dataID: numberToBigint(record.dataID, 'dataID'),
    nestedKind: requireString(record.nestedKind, 'nestedKind') as TrackerItemKey['nestedKind'],
    nestedRootIdentity:
      nestedRoot === null
        ? null
        : {
            base: requireString(nestedRoot.base, 'base') as TrackerBase,
            rawSection: requireString(nestedRoot.rawSection, 'rawSection'),
            dataID: numberToBigint(nestedRoot.dataID, 'dataID'),
          },
    nestedPath: requireArray(record.nestedPath ?? [], 'nestedPath').map((entry) => {
      const component = requireObject(entry, 'nestedPath');
      return {
        kind: requireString(component.kind, 'kind') as TrackerItemKey['nestedKind'],
        dataID: numberToBigint(component.dataID, 'dataID'),
      };
    }),
  };
}

function encodeDistribution(distribution: ManualLevelDistribution | null): unknown {
  if (distribution === null) {
    return null;
  }
  return distribution.levels.map((entry) => ({
    level: entry.level,
    quantity: bigintToNumber(entry.quantity),
  }));
}

function decodeDistribution(value: unknown): ManualLevelDistribution | null {
  if (value === null || value === undefined) {
    return null;
  }
  const levels = requireArray(value, 'levelDistribution').map((entry) => {
    const level = requireObject(entry, 'levelQuantity');
    return createManualLevelQuantity(
      requireInt(level.level, 'level'),
      numberToBigint(level.quantity, 'quantity'),
    );
  });
  return createManualLevelDistribution(levels);
}

function decodeBaseline(value: unknown): ManualBaselineReference {
  const record = requireObject(value, 'baselineReference');
  return {
    revision: requireString(record.revision, 'revision'),
    fingerprint:
      record.fingerprint === null || record.fingerprint === undefined
        ? null
        : requireString(record.fingerprint, 'fingerprint'),
    lineageID:
      record.lineageID === null || record.lineageID === undefined
        ? null
        : requireString(record.lineageID, 'lineageID'),
  };
}

function decodeProvenance(value: unknown): ManualCatalogProvenance {
  const record = requireObject(value, 'catalogProvenance');
  return {
    gameVersion: requireString(record.gameVersion, 'gameVersion'),
    buildTag:
      record.buildTag === null || record.buildTag === undefined
        ? null
        : requireString(record.buildTag, 'buildTag'),
    manifestSchemaVersion:
      record.manifestSchemaVersion === null || record.manifestSchemaVersion === undefined
        ? null
        : requireInt(record.manifestSchemaVersion, 'manifestSchemaVersion'),
  };
}

function decodeMigrationMarker(value: unknown): ManualTrackerMigrationMarker | null {
  if (value === null || value === undefined) {
    return null;
  }
  const record = requireObject(value, 'migrationMarker');
  return createManualTrackerMigrationMarker({
    version: requireInt(record.version, 'version'),
    completedAtMs: requireFiniteNumber(record.completedAtMs, 'completedAtMs'),
  });
}

function decodeDiagnostic(value: unknown): ManualTrackerDiagnostic | null {
  if (value === null || value === undefined) {
    return null;
  }
  const record = requireObject(value, 'diagnostic');
  return createManualTrackerDiagnostic({
    kind: requireString(record.kind, 'kind') as ManualTrackerDiagnostic['kind'],
    code: requireString(record.code, 'code'),
    message: requireString(record.message, 'message'),
    recordedAtMs: requireFiniteNumber(record.recordedAtMs, 'recordedAtMs'),
  });
}

function bigintToNumber(value: bigint): number {
  const asNumber = Number(value);
  if (!Number.isSafeInteger(asNumber) || BigInt(asNumber) !== value) {
    throw new RangeError(`wire 编码超出 JS safe integer：${value.toString()}`);
  }
  return asNumber;
}

function numberToBigint(value: unknown, label: string): bigint {
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) {
    throw new Error(`${label} 必须是 safe integer。`);
  }
  return BigInt(value);
}

function requireObject(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`${label} 必须是对象。`);
  }
  return value as Record<string, unknown>;
}

function requireArray(value: unknown, label: string): unknown[] {
  if (!Array.isArray(value)) {
    throw new Error(`${label} 必须是数组。`);
  }
  return value;
}

function requireString(value: unknown, label: string): string {
  if (typeof value !== 'string') {
    throw new Error(`${label} 必须是字符串。`);
  }
  return value;
}

function requireInt(value: unknown, label: string): number {
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    throw new Error(`${label} 必须是整数。`);
  }
  return value;
}

function requireFiniteNumber(value: unknown, label: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error(`${label} 必须是有限数字。`);
  }
  return value;
}

function optionalFiniteNumber(value: unknown): number | null {
  if (value === null || value === undefined) {
    return null;
  }
  return requireFiniteNumber(value, 'timestamp');
}

function requireUuid(value: unknown, label: string): UuidString {
  const text = requireString(value, label);
  const parsed = parseUuid(text);
  if (parsed === undefined) {
    throw new Error(`${label} 不是合法 UUID。`);
  }
  return parsed;
}

function isManualTrackerStoreError(error: unknown): error is ManualTrackerStoreError {
  return (
    typeof error === 'object' &&
    error !== null &&
    'kind' in error &&
    typeof (error as ManualTrackerStoreError).kind === 'string'
  );
}
