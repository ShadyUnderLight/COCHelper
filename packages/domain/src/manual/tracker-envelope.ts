import type { UuidString } from '@coc-helper/wire';

import { ManualUpgradeCoreState } from './core';
import { baselineReferencesEqual } from './equality';
import { isManualBaselineReferenceStructurallyValid } from './models';
import {
  createManualTrackerMigrationMarker,
  MANUAL_TRACKER_SCHEMA,
  type ManualTrackerDiagnostic,
  type ManualTrackerMigrationMarker,
} from './tracker-schema';
import type { ManualTrackerStoreError } from './errors';
import { createManualTrackerVillageState, type ManualTrackerVillageState } from './village-state';

export type ManualTrackerEnvelope = {
  readonly schemaVersion: number;
  readonly storeVersion: number;
  readonly villages: readonly ManualTrackerVillageState[];
  readonly migrationMarker: ManualTrackerMigrationMarker | null;
  readonly lastDiagnostic: ManualTrackerDiagnostic | null;
};

export function createManualTrackerEnvelope(input: {
  readonly schemaVersion?: number;
  readonly storeVersion?: number;
  readonly villages?: readonly ManualTrackerVillageState[];
  readonly migrationMarker?: ManualTrackerMigrationMarker | null;
  readonly lastDiagnostic?: ManualTrackerDiagnostic | null;
}): ManualTrackerEnvelope {
  const envelope: ManualTrackerEnvelope = {
    schemaVersion: input.schemaVersion ?? MANUAL_TRACKER_SCHEMA.envelope,
    storeVersion: input.storeVersion ?? MANUAL_TRACKER_SCHEMA.store,
    villages: sortVillages(input.villages ?? []),
    migrationMarker: input.migrationMarker ?? null,
    lastDiagnostic: input.lastDiagnostic ?? null,
  };
  validateManualTrackerEnvelope(envelope);
  return envelope;
}

export function emptyManualTrackerEnvelope(
  villageIDs: readonly UuidString[],
  nowMs: number = Date.now(),
): ManualTrackerEnvelope {
  const safeNow = Number.isFinite(nowMs) ? nowMs : 0;
  const uniqueVillageIDs = [...new Set(villageIDs)].sort((left, right) =>
    left.localeCompare(right),
  );
  return createManualTrackerEnvelope({
    villages: uniqueVillageIDs.map((villageID) =>
      createManualTrackerVillageState({
        villageID,
        core: ManualUpgradeCoreState.create(),
        stateUpdatedAtMs: safeNow,
      }),
    ),
    migrationMarker: createManualTrackerMigrationMarker({ completedAtMs: safeNow }),
  });
}

function sortVillages(
  villages: readonly ManualTrackerVillageState[],
): readonly ManualTrackerVillageState[] {
  return villages.slice().sort((left, right) => left.villageID.localeCompare(right.villageID));
}

export function validateManualTrackerEnvelope(
  envelope: ManualTrackerEnvelope,
): ManualTrackerEnvelope {
  if (envelope.schemaVersion !== MANUAL_TRACKER_SCHEMA.envelope) {
    throw {
      kind: 'unsupportedSchema',
      version: envelope.schemaVersion,
    } satisfies ManualTrackerStoreError;
  }
  if (envelope.storeVersion !== MANUAL_TRACKER_SCHEMA.store) {
    throw {
      kind: 'unsupportedSchema',
      version: envelope.storeVersion,
    } satisfies ManualTrackerStoreError;
  }
  if (
    envelope.migrationMarker !== null &&
    envelope.migrationMarker.version !== MANUAL_TRACKER_SCHEMA.envelope
  ) {
    throw {
      kind: 'unsupportedSchema',
      version: envelope.migrationMarker.version,
    } satisfies ManualTrackerStoreError;
  }
  if (
    envelope.migrationMarker !== null &&
    !Number.isFinite(envelope.migrationMarker.completedAtMs)
  ) {
    throw {
      kind: 'invalidEnvelope',
      message: 'migration marker 时间无效。',
    } satisfies ManualTrackerStoreError;
  }
  if (envelope.lastDiagnostic !== null && !Number.isFinite(envelope.lastDiagnostic.recordedAtMs)) {
    throw {
      kind: 'invalidEnvelope',
      message: 'store 诊断时间无效。',
    } satisfies ManualTrackerStoreError;
  }
  if (envelope.migrationMarker === null && envelope.villages.length > 0) {
    throw {
      kind: 'invalidEnvelope',
      message: '非空 store 缺少 migration marker。',
    } satisfies ManualTrackerStoreError;
  }

  const villageIDs = new Set<UuidString>();
  const recordIDs = new Set<UuidString>();
  for (const state of envelope.villages) {
    if (villageIDs.has(state.villageID)) {
      throw {
        kind: 'invalidEnvelope',
        message: '存在重复的 villageID。',
      } satisfies ManualTrackerStoreError;
    }
    villageIDs.add(state.villageID);
    if (state.schemaVersion !== MANUAL_TRACKER_SCHEMA.village) {
      throw {
        kind: 'unsupportedSchema',
        version: state.schemaVersion,
      } satisfies ManualTrackerStoreError;
    }
    if (state.baselineReference !== null) {
      if (!isManualBaselineReferenceStructurallyValid(state.baselineReference)) {
        throw {
          kind: 'invalidEnvelope',
          message: 'baseline reference 无效。',
        } satisfies ManualTrackerStoreError;
      }
    } else if (state.core.itemStates.length > 0 || state.core.records.length > 0) {
      throw {
        kind: 'invalidEnvelope',
        message: '非空村庄状态缺少 baseline reference。',
      } satisfies ManualTrackerStoreError;
    }
    for (const record of state.core.records) {
      if (recordIDs.has(record.recordID)) {
        throw {
          kind: 'invalidEnvelope',
          message: '存在重复的 recordID。',
        } satisfies ManualTrackerStoreError;
      }
      recordIDs.add(record.recordID);
      if (!baselineReferencesEqual(state.baselineReference!, record.baselineReference)) {
        throw {
          kind: 'invalidEnvelope',
          message: 'record 的 baseline 不属于其 village state。',
        } satisfies ManualTrackerStoreError;
      }
    }
  }
  return envelope;
}

export function manualTrackerEnvelopeState(
  envelope: ManualTrackerEnvelope,
  villageID: UuidString,
): ManualTrackerVillageState | undefined {
  return envelope.villages.find((state) => state.villageID === villageID);
}

export function upsertManualTrackerVillageState(
  envelope: ManualTrackerEnvelope,
  state: ManualTrackerVillageState,
): ManualTrackerEnvelope {
  const villages = envelope.villages.filter((entry) => entry.villageID !== state.villageID);
  villages.push(state);
  return createManualTrackerEnvelope({
    schemaVersion: envelope.schemaVersion,
    storeVersion: envelope.storeVersion,
    villages: sortVillages(villages),
    migrationMarker: envelope.migrationMarker,
    lastDiagnostic: envelope.lastDiagnostic,
  });
}

export function manualTrackerEnvelopeIsMigrated(envelope: ManualTrackerEnvelope): boolean {
  return envelope.migrationMarker?.version === MANUAL_TRACKER_SCHEMA.envelope;
}

export function manualTrackerEnvelopeIsEmpty(envelope: ManualTrackerEnvelope): boolean {
  return (
    envelope.villages.length === 0 ||
    envelope.villages.every(
      (state) => state.core.itemStates.length === 0 && state.core.records.length === 0,
    )
  );
}
