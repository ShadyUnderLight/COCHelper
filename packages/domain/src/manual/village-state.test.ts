import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import {
  createManualLevelDistributionFromPairs,
  createManualItemStateForStatus,
  ManualUpgradeCoreState,
} from './core';
import { manualTrackerStoreErrorsEqual } from './errors';
import { LOCAL_QUEUE_KIND_BUILDER } from './queue/local-queue-kind';
import { createLocalQueueCapacityConfig } from './queue/capacity-config';
import { createQueueAssignmentDecision } from './queue/queue-assignment';
import { trackerItemKeyRoot } from './types';
import {
  createManualTrackerVillageState,
  manualTrackerVillageStateWithCore,
  manualTrackerVillageStatesEqual,
} from './village-state';

const villageID = parseUuid('00000000-0000-0000-0000-000000000011')!;
const key = trackerItemKeyRoot('home', 'buildings', 100n);
const baseline = {
  revision: 'snapshot-1',
  lineageID: 'lineage-1',
};
const provenance = {
  gameVersion: '18.400.13',
  buildTag: null,
  manifestSchemaVersion: null,
};

function manualCompletedCore(): ManualUpgradeCoreState {
  return ManualUpgradeCoreState.create({
    itemStates: [
      createManualItemStateForStatus({
        itemKey: key,
        baselineReference: baseline,
        manual: createManualLevelDistributionFromPairs([[10, 1n]]),
        status: 'manualCompleted',
      }),
    ],
  });
}

describe('ManualTrackerVillageState', () => {
  it('rejects record starting after stateUpdatedAt', () => {
    const startedAtMs = 200_000;
    const core = manualCompletedCore().startUpgrade({
      itemKey: key,
      fromLevel: 10,
      targetLevel: 11,
      quantity: 1n,
      startedAtMs,
      durationState: { kind: 'timed', seconds: 60n },
      frozenCosts: null,
      catalogProvenance: provenance,
      baselineReference: baseline,
      recordID: parseUuid('00000000-0000-0000-0000-000000000099')!,
      nowMs: startedAtMs,
    });
    expect(() =>
      createManualTrackerVillageState({
        villageID: parseUuid('00000000-0000-0000-0000-000000000022')!,
        core,
        stateUpdatedAtMs: 100_000,
      }),
    ).toThrowError(
      expect.objectContaining({
        kind: 'invalidEnvelope',
        message: '升级记录的 startedAt 不能晚于 stateUpdatedAt。',
      }),
    );
  });

  it('rejects cross-village queue capacity config', () => {
    const config = createLocalQueueCapacityConfig({
      villageID: parseUuid('00000000-0000-0000-0000-000000000099')!,
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      capacity: 3,
      updatedAtMs: 1_000,
    });
    try {
      createManualTrackerVillageState({
        villageID,
        core: ManualUpgradeCoreState.create(),
        queueCapacityConfigs: [config],
      });
      expect.unreachable('expected invalid envelope');
    } catch (error) {
      expect(
        manualTrackerStoreErrorsEqual(error as never, {
          kind: 'invalidEnvelope',
          message: '本地容量配置的村庄与所属村庄不一致。',
        }),
      ).toBe(true);
    }
  });

  it('rejects duplicate queue kind capacity config', () => {
    const first = createLocalQueueCapacityConfig({
      villageID,
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      capacity: 2,
      updatedAtMs: 1_000,
    });
    const second = createLocalQueueCapacityConfig({
      villageID,
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      capacity: 3,
      updatedAtMs: 1_000,
    });
    try {
      createManualTrackerVillageState({
        villageID,
        core: ManualUpgradeCoreState.create(),
        queueCapacityConfigs: [first, second],
      });
      expect.unreachable('expected invalid envelope');
    } catch (error) {
      expect(
        manualTrackerStoreErrorsEqual(error as never, {
          kind: 'invalidEnvelope',
          message: '存在重复的本地容量类别配置。',
        }),
      ).toBe(true);
    }
  });

  it('round-trips queue assignments', () => {
    const assignment = createQueueAssignmentDecision({
      decisionID: parseUuid('00000000-0000-0000-0000-000000000201')!,
      villageID,
      itemKey: key,
      baselineReference: baseline,
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      decidedAtMs: 1_000,
    });
    const state = createManualTrackerVillageState({
      villageID,
      core: ManualUpgradeCoreState.create(),
      queueAssignments: [assignment],
    });
    expect(state.queueAssignments).toEqual([assignment]);
  });

  it('manualTrackerVillageStatesEqual compares collection contents not just lengths', () => {
    const base = createManualTrackerVillageState({
      villageID,
      core: ManualUpgradeCoreState.create(),
      diagnostics: [
        {
          kind: 'conflict',
          code: 'a',
          message: 'first',
          recordedAtMs: 1_000,
        },
      ],
    });
    const differentDiagnostics = createManualTrackerVillageState({
      villageID,
      core: ManualUpgradeCoreState.create(),
      diagnostics: [
        {
          kind: 'conflict',
          code: 'b',
          message: 'second',
          recordedAtMs: 1_000,
        },
      ],
    });
    expect(manualTrackerVillageStatesEqual(base, differentDiagnostics)).toBe(false);
  });

  it('manualTrackerVillageStateWithCore can clear nullable timestamps', () => {
    const state = createManualTrackerVillageState({
      villageID,
      core: ManualUpgradeCoreState.create(),
      lastSettleAtMs: 2_000,
      lastImportAtMs: 3_000,
    });
    const cleared = manualTrackerVillageStateWithCore(state, {
      lastSettleAtMs: null,
      lastImportAtMs: null,
    });
    expect(cleared.lastSettleAtMs).toBeNull();
    expect(cleared.lastImportAtMs).toBeNull();
  });
});
