import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { manualTrackerStoreErrorsEqual } from './errors';
import {
  createManualLevelDistributionFromPairs,
  createManualItemStateForStatus,
  ManualUpgradeCoreState,
} from './core';
import {
  createManualTrackerEnvelope,
  emptyManualTrackerEnvelope,
  upsertManualTrackerVillageState,
} from './tracker-envelope';
import { trackerItemKeyRoot } from './types';
import { createManualTrackerVillageState } from './village-state';

const baseline = {
  revision: 'snapshot-1',
  fingerprint: 'sha256:baseline',
  lineageID: 'lineage-1',
};
const key = trackerItemKeyRoot('home', 'buildings', 100n);
const provenance = {
  gameVersion: '18.400.13',
  buildTag: null,
  sourceFingerprint: null,
  manifestSchemaVersion: null,
};

describe('ManualTrackerEnvelope', () => {
  it('creates empty envelope with migration marker', () => {
    const villageID = parseUuid('00000000-0000-0000-0000-000000000031')!;
    const envelope = emptyManualTrackerEnvelope([villageID], 1_000);
    expect(envelope.villages).toHaveLength(1);
    expect(envelope.migrationMarker).not.toBeNull();
  });

  it('rejects duplicate recordID across villages', () => {
    const recordID = parseUuid('00000000-0000-0000-0000-000000000142')!;
    const core = ManualUpgradeCoreState.create({
      itemStates: [
        createManualItemStateForStatus({
          itemKey: key,
          baselineReference: baseline,
          manual: createManualLevelDistributionFromPairs([[10, 1n]]),
          status: 'manualCompleted',
        }),
      ],
    }).startUpgrade({
      itemKey: key,
      fromLevel: 10,
      targetLevel: 11,
      quantity: 1n,
      startedAtMs: 100_000,
      durationState: { kind: 'timed', seconds: 60n },
      frozenCosts: null,
      catalogProvenance: provenance,
      baselineReference: baseline,
      recordID,
      nowMs: 100_000,
    });
    const first = createManualTrackerVillageState({
      villageID: parseUuid('00000000-0000-0000-0000-000000000041')!,
      core,
    });
    const second = createManualTrackerVillageState({
      villageID: parseUuid('00000000-0000-0000-0000-000000000042')!,
      core,
    });
    try {
      createManualTrackerEnvelope({
        villages: [first, second],
        migrationMarker: { version: 1, completedAtMs: 0 },
      });
      expect.unreachable('expected invalid envelope');
    } catch (error) {
      expect(
        manualTrackerStoreErrorsEqual(error as never, {
          kind: 'invalidEnvelope',
          message: '存在重复的 recordID。',
        }),
      ).toBe(true);
    }
  });

  it('upserts village state', () => {
    const villageID = parseUuid('00000000-0000-0000-0000-000000000051')!;
    const envelope = emptyManualTrackerEnvelope([villageID], 1_000);
    const updated = createManualTrackerVillageState({
      villageID,
      core: ManualUpgradeCoreState.create(),
      stateUpdatedAtMs: 2_000,
    });
    const next = upsertManualTrackerVillageState(envelope, updated);
    expect(next.villages[0]?.stateUpdatedAtMs).toBe(2_000);
  });

  it('rejects unsupported schema version', () => {
    try {
      createManualTrackerEnvelope({ schemaVersion: 99, villages: [] });
      expect.unreachable('expected unsupported schema');
    } catch (error) {
      expect(
        manualTrackerStoreErrorsEqual(error as never, {
          kind: 'unsupportedSchema',
          version: 99,
        }),
      ).toBe(true);
    }
  });

  it('rejects non-empty envelope without migration marker', () => {
    const villageID = parseUuid('00000000-0000-0000-0000-000000000061')!;
    const state = createManualTrackerVillageState({
      villageID,
      core: ManualUpgradeCoreState.create(),
    });
    try {
      createManualTrackerEnvelope({ villages: [state], migrationMarker: null });
      expect.unreachable('expected invalid envelope');
    } catch (error) {
      expect(
        manualTrackerStoreErrorsEqual(error as never, {
          kind: 'invalidEnvelope',
          message: '非空 store 缺少 migration marker。',
        }),
      ).toBe(true);
    }
  });
});
