import { INT64_MAX, parseUuid, type UuidString } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import {
  createManualLevelDistributionFromPairs,
  createManualItemStateForStatus,
  createManualUpgradeCoreState,
  ManualUpgradeCoreState,
} from '../core';
import { manualLevelDistributionsEqual } from '../equality';
import { manualReconciliationErrorsEqual } from '../errors';
import { LOCAL_QUEUE_KIND_BUILDER } from '../queue/local-queue-kind';
import { createLocalQueueCapacityConfig } from '../queue/capacity-config';
import { createQueueAssignmentDecision } from '../queue/queue-assignment';
import { isManualItemStateQueueAssignmentConfirmable } from '../queue-assignment-eligibility';
import { trackerItemKeyRoot, trackerItemKeyStableId } from '../types';
import { createManualTrackerVillageState } from '../village-state';
import {
  buildObservationMap,
  completeObservation,
  createManualReconciliationEvidence,
  createReconciliationObservation,
} from './evidence';
import {
  manualReconciliationPreviewCount,
  manualReconciliationPreviewRequiresExplicitDecision,
} from './types';
import { computeReconciliationCandidateFingerprint } from './candidate-fingerprint';
import { reconciliationCandidateMatches } from './helpers';
import { previewReconciliation, reconcileManualTracker } from './service';

const villageID = parseUuid('00000000-0000-0000-0000-000000000143')!;
const key = trackerItemKeyRoot('home', 'buildings', 100n);
const siblingKey = trackerItemKeyRoot('home', 'buildings', 101n);
const timerKey = trackerItemKeyRoot('home', 'buildings', 101n);
const drillKey = trackerItemKeyRoot('home', 'buildings', 1_000_023n);
const timerOnlyKey = trackerItemKeyRoot('home', 'buildings', 1_000_001n);
const buildingKey = trackerItemKeyRoot('home', 'buildings', 1_000_000n);

const provenance = {
  gameVersion: '18.400.13',
  buildTag: null,
  manifestSchemaVersion: null,
};

function s(seconds: number): number {
  return seconds * 1000;
}

function reference(
  revision = 'snapshot-1',
  fingerprint = 'sha256:fp-1',
  lineageID = 'lineage-p1',
): { revision: string; fingerprint: string; lineageID: string } {
  return { revision, fingerprint, lineageID };
}

function dist(pairs: readonly (readonly [number, bigint])[]) {
  return createManualLevelDistributionFromPairs(pairs);
}

function observedState(
  ref: ReturnType<typeof reference>,
  distribution: readonly (readonly [number, bigint])[],
  updatedAt = s(1_700_000_010),
) {
  const core = createManualUpgradeCoreState({
    itemStates: [
      createManualItemStateForStatus({
        itemKey: key,
        baselineReference: ref,
        imported: dist(distribution),
        status: 'observed',
        sourceTimestampMs: s(1_700_000_000),
      }),
    ],
  });
  return createManualTrackerVillageState({
    villageID,
    core,
    stateUpdatedAtMs: updatedAt,
  });
}

function activeState(
  ref: ReturnType<typeof reference>,
  distribution: readonly (readonly [number, bigint])[] = [[10, 1n]],
  startedAt = s(1_700_000_010),
  duration = 60,
  recordID: UuidString = parseUuid('00000000-0000-0000-0000-000000000001')!,
) {
  const base = observedState(ref, distribution, startedAt);
  const core = base.core.startUpgrade({
    itemKey: key,
    fromLevel: 10,
    targetLevel: 11,
    quantity: 1n,
    startedAtMs: startedAt,
    durationState: { kind: 'timed', seconds: BigInt(duration) },
    frozenCosts: [
      { resource: 'Gold', amount: 100n, rawResource: null, rawAmount: null, parseFailed: false },
    ],
    catalogProvenance: provenance,
    baselineReference: ref,
    recordID,
    nowMs: startedAt,
  });
  return createManualTrackerVillageState({
    villageID,
    core,
    stateUpdatedAtMs: startedAt,
  });
}

function evidenceFrom(input: {
  readonly newBaselineReference: ReturnType<typeof reference>;
  readonly entries: Parameters<typeof buildObservationMap>[0];
  readonly newNormalizedPlayerTag?: string | null;
  readonly sourceTimestampMs?: number | null;
  readonly duplicate?: boolean;
  readonly lineageComparable?: boolean;
  readonly previousObservations?: ReadonlyMap<
    string,
    import('./evidence').ReconciliationObservation
  >;
  readonly relatedChangesByStableID?: ReadonlyMap<
    string,
    readonly import('./evidence').RelatedChangeEvidence[]
  >;
  readonly previousSnapshotID?: UuidString | null;
  readonly previousSnapshotFingerprint?: string | null;
  readonly previousLineageID?: string | null;
  readonly previousSourceTimestampMs?: number | null;
}) {
  const built = buildObservationMap(input.entries);
  return createManualReconciliationEvidence({
    villageID,
    observations: built.observations,
    itemKeysByStableID: built.itemKeysByStableID,
    newBaselineReference: input.newBaselineReference,
    newNormalizedPlayerTag: input.newNormalizedPlayerTag ?? '#P1',
    sourceTimestampMs:
      input.sourceTimestampMs !== undefined ? input.sourceTimestampMs : s(1_700_000_200),
    duplicate: input.duplicate ?? false,
    lineageComparable: input.lineageComparable ?? true,
    previousObservations: input.previousObservations,
    relatedChangesByStableID: input.relatedChangesByStableID,
    previousSnapshotID: input.previousSnapshotID,
    previousSnapshotFingerprint: input.previousSnapshotFingerprint,
    previousLineageID: input.previousLineageID,
    previousSourceTimestampMs:
      input.previousSourceTimestampMs !== undefined
        ? input.previousSourceTimestampMs
        : s(1_700_000_000),
  });
}

function singleItem<T extends { items: readonly unknown[] }>(value: T): T['items'][number] {
  expect(value.items).toHaveLength(1);
  return value.items[0]!;
}

describe('ManualTrackerReconciliation', () => {
  it('keeps queue capacity configs on reconcile', () => {
    const ref = reference();
    const state = createManualTrackerVillageState({
      villageID,
      core: activeState(ref).core,
      queueCapacityConfigs: [
        createLocalQueueCapacityConfig({
          villageID,
          queueKind: LOCAL_QUEUE_KIND_BUILDER,
          capacity: 3,
          updatedAtMs: s(1_700_000_010),
        }),
      ],
    });
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-1:observation:1', ref.fingerprint, ref.lineageID),
      duplicate: true,
      entries: [completeObservation(key, dist([[10, 1n]]), { hasTimer: false })],
    });
    const plan = reconcileManualTracker(evidence, state, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_700_000_200),
    });
    expect(plan.state.queueCapacityConfigs).toHaveLength(1);
  });

  it('duplicate rebase keeps active records without duplicating', () => {
    const ref = reference();
    const state = activeState(ref);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-1:observation:1', ref.fingerprint, ref.lineageID),
      duplicate: true,
      sourceTimestampMs: s(1_700_000_200),
      entries: [completeObservation(key, dist([[10, 1n]]))],
    });
    const plan = reconcileManualTracker(evidence, state, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_700_000_200),
    });
    expect(manualReconciliationPreviewCount(plan.preview, 'duplicate')).toBe(1);
    expect(plan.state.core.records.map((record) => record.recordID)).toEqual(
      state.core.records.map((record) => record.recordID),
    );
    expect(plan.state.core.records[0]?.status).toBe('active');
    expect(plan.state.reconciliationHistory).toHaveLength(1);
    expect(plan.preview.sourceTimestampMs).toBe(s(1_700_000_200));
  });

  it('reliable observed completion confirms active record once', () => {
    const ref = reference();
    const state = activeState(ref);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      previousSourceTimestampMs: s(1_700_000_000),
      previousObservations: buildObservationMap([
        completeObservation(key, dist([[10, 1n]]), { hasTimer: true, timerCoverageComplete: true }),
      ]).observations,
      entries: [completeObservation(key, dist([[11, 1n]]))],
    });
    const plan = reconcileManualTracker(evidence, state, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_700_000_200),
    });
    const item = singleItem(plan.preview);
    expect(item.classification).toBe('observedAhead');
    expect(item.confirmedRecordIDs).toEqual(state.core.records.map((record) => record.recordID));
    expect(plan.state.core.records[0]?.status).toBe('completed');
    expect(
      manualLevelDistributionsEqual(
        plan.state.core.itemState(key)!.manualCompletedDistribution,
        dist([[11, 1n]]),
      ),
    ).toBe(true);
    expect(plan.state.core.settleDue(s(1_800_000_000)).settled).toHaveLength(0);
  });

  it('early observed movement before expected end remains unknown and active', () => {
    const ref = reference();
    const state = activeState(ref, [[10, 1n]], s(1_700_000_010), 600);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      previousSourceTimestampMs: s(1_700_000_000),
      sourceTimestampMs: s(1_700_000_020),
      entries: [completeObservation(key, dist([[11, 1n]]))],
    });
    const plan = reconcileManualTracker(evidence, state, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_700_000_020),
    });
    const item = singleItem(plan.preview);
    expect(item.classification).toBe('unknown');
    expect(item.confirmedRecordIDs).toHaveLength(0);
    expect(plan.state.core.records[0]?.status).toBe('active');
  });

  it('exact observation is safe when fingerprint changes only outside item state', () => {
    const ref = reference();
    const state = observedState(ref, [[10, 1n]]);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-changed', ref.lineageID),
      entries: [completeObservation(key, dist([[10, 1n]]))],
    });
    const preview = previewReconciliation(evidence, state, s(1_700_000_200));
    expect(preview.duplicate).toBe(false);
    expect(singleItem(preview).classification).toBe('exactMatch');
    expect(manualReconciliationPreviewRequiresExplicitDecision(preview)).toBe(false);
  });

  it('one observed movement cannot confirm two matching active records', () => {
    const ref = reference();
    let core = observedState(ref, [[10, 2n]]).core;
    for (const [index, recordID] of [
      parseUuid('00000000-0000-0000-0000-000000000011')!,
      parseUuid('00000000-0000-0000-0000-000000000012')!,
    ].entries()) {
      core = core.startUpgrade({
        itemKey: key,
        fromLevel: 10,
        targetLevel: 11,
        quantity: 1n,
        startedAtMs: s(1_700_000_010 + index),
        durationState: { kind: 'timed', seconds: 60n },
        frozenCosts: [],
        catalogProvenance: provenance,
        baselineReference: ref,
        recordID,
        nowMs: s(1_700_000_010 + index),
      });
    }
    const state = createManualTrackerVillageState({
      villageID,
      core,
      stateUpdatedAtMs: s(1_700_000_011),
    });
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      previousSourceTimestampMs: s(1_700_000_000),
      previousObservations: buildObservationMap([completeObservation(key, dist([[10, 2n]]))])
        .observations,
      entries: [
        completeObservation(
          key,
          dist([
            [10, 1n],
            [11, 1n],
          ]),
        ),
      ],
    });
    const plan = reconcileManualTracker(evidence, state, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_700_000_200),
    });
    const item = singleItem(plan.preview);
    expect(item.confirmedRecordIDs).toHaveLength(1);
    expect(plan.state.core.records.filter((record) => record.status === 'completed')).toHaveLength(
      1,
    );
    expect(plan.state.core.records.filter((record) => record.status === 'active')).toHaveLength(1);
  });

  it('imported timer without target remains possible duplicate', () => {
    const ref = reference();
    const state = activeState(ref, [[10, 1n]], s(1_700_000_010), 600);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      previousSourceTimestampMs: s(1_700_000_000),
      sourceTimestampMs: s(1_700_000_020),
      entries: [
        {
          itemKey: key,
          observation: createReconciliationObservation({
            displayName: 'timer duplicate',
            hasTimer: true,
            distribution: null,
            distributionComplete: false,
            coverageComplete: false,
          }),
        },
      ],
    });
    const preview = previewReconciliation(evidence, state, s(1_700_000_020));
    const item = singleItem(preview);
    expect(item.classification).toBe('possibleDuplicate');
    expect(item.confirmedRecordIDs).toHaveLength(0);
    expect(manualReconciliationPreviewRequiresExplicitDecision(preview)).toBe(true);
  });

  it('timer disappearance without level change does not claim completion', () => {
    const ref = reference();
    const state = activeState(ref, [[10, 1n]], s(1_700_000_010), 600);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      previousSourceTimestampMs: s(1_700_000_000),
      sourceTimestampMs: s(1_700_000_020),
      previousObservations: buildObservationMap([
        completeObservation(key, dist([[10, 1n]]), {
          hasTimer: true,
          timerCoverageComplete: true,
        }),
      ]).observations,
      entries: [
        completeObservation(key, dist([[10, 1n]]), {
          hasTimer: false,
          timerCoverageComplete: true,
        }),
      ],
    });
    const preview = previewReconciliation(evidence, state, s(1_700_000_020));
    expect(singleItem(preview).classification).toBe('observedTimerEnded');
    expect(singleItem(preview).confirmedRecordIDs).toHaveLength(0);
  });

  it('older and missing timestamp never rollback manual state', () => {
    const ref = reference();
    const state = observedState(ref, [[11, 1n]]);
    const olderEvidence = evidenceFrom({
      newBaselineReference: reference('snapshot-old', 'sha256:old', ref.lineageID),
      previousSourceTimestampMs: s(1_700_000_100),
      sourceTimestampMs: s(1_700_000_000),
      entries: [completeObservation(key, dist([[10, 1n]]))],
    });
    expect(
      singleItem(previewReconciliation(olderEvidence, state, s(1_700_000_200))).classification,
    ).toBe('staleImport');

    const missingEvidence = evidenceFrom({
      newBaselineReference: reference('snapshot-missing-ts', 'sha256:missing', ref.lineageID),
      sourceTimestampMs: null,
      previousSourceTimestampMs: s(1_700_000_000),
      entries: [completeObservation(key, dist([[12, 1n]]))],
    });
    const missingPreview = previewReconciliation(missingEvidence, state, s(1_700_000_200));
    expect(missingPreview.timeConfidence).toBe('sourceTimestampAbsent');
    expect(singleItem(missingPreview).classification).toBe('unknown');
  });

  it('partial level coverage is unknown instead of deletion or zero', () => {
    const ref = reference();
    const state = observedState(ref, [[10, 1n]]);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      entries: [
        {
          itemKey: key,
          observation: createReconciliationObservation({
            displayName: 'building',
            distribution: null,
            distributionComplete: false,
            coverageComplete: false,
          }),
        },
      ],
    });
    const preview = previewReconciliation(evidence, state, s(1_700_000_200));
    expect(singleItem(preview).classification).toBe('unknown');
    expect(singleItem(preview).observedDistribution).toBeNull();
    const plan = reconcileManualTracker(evidence, state, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_700_000_200),
    });
    const rebased = plan.state.core.itemState(key)!;
    expect(rebased.status).toBe('observed');
    expect(rebased.importedObservation).not.toBeNull();
    expect(rebased.importedObservation?.levelDistribution).toBeNull();
  });

  it('new timer-only observation is retained as imported evidence', () => {
    const ref = reference();
    const state = createManualTrackerVillageState({
      villageID,
      core: ManualUpgradeCoreState.create(),
      stateUpdatedAtMs: s(1_700_000_010),
    });
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      entries: [
        completeObservation(key, dist([[10, 1n]])),
        {
          itemKey: timerKey,
          observation: createReconciliationObservation({
            displayName: 'timer-only',
            hasTimer: true,
            distribution: null,
            distributionComplete: false,
            coverageComplete: false,
          }),
        },
      ],
    });
    const plan = reconcileManualTracker(evidence, state, {
      decision: 'acceptObserved',
      appliedAtMs: s(1_700_000_200),
    });
    const rebased = plan.state.core.itemState(timerKey)!;
    expect(rebased.status).toBe('observed');
    expect(rebased.importedObservation?.observedTimer).toBe(true);
    expect(rebased.importedObservation?.levelDistribution).toBeNull();
  });

  it('partial count or timer coverage remains unknown', () => {
    const ref = reference();
    const state = observedState(ref, [[10, 1n]]);
    const missingCountEvidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      entries: [
        {
          itemKey: key,
          observation: createReconciliationObservation({
            displayName: 'partial count',
            distribution: null,
            distributionComplete: false,
            coverageComplete: false,
          }),
        },
      ],
    });
    expect(
      singleItem(previewReconciliation(missingCountEvidence, state, s(1_700_000_200)))
        .classification,
    ).toBe('unknown');

    const timerState = observedState(ref, [[10, 3n]]);
    const timerEvidence = evidenceFrom({
      newBaselineReference: reference('snapshot-3', 'sha256:fp-3', ref.lineageID),
      previousObservations: buildObservationMap([
        completeObservation(key, dist([[10, 3n]]), {
          hasTimer: true,
          timerCoverageComplete: true,
        }),
      ]).observations,
      entries: [
        completeObservation(key, dist([[11, 3n]]), {
          hasTimer: false,
          timerCoverageComplete: true,
          sectionTrustGatesOpen: false,
          coverageComplete: false,
        }),
      ],
    });
    expect(
      singleItem(previewReconciliation(timerEvidence, timerState, s(1_700_000_200))).classification,
    ).toBe('unknown');
  });

  it('partial section coverage does not block complete sibling items', () => {
    const ref = reference();
    const state = observedState(ref, [[10, 1n]]);
    const cases = [
      {
        name: 'level',
        sibling: createReconciliationObservation({
          displayName: 'sibling',
          distribution: null,
          distributionComplete: false,
          coverageComplete: false,
        }),
        siblingClassification: 'unknown' as const,
        siblingDistribution: null,
      },
      {
        name: 'count',
        sibling: createReconciliationObservation({
          displayName: 'sibling',
          distribution: null,
          distributionComplete: false,
          coverageComplete: false,
        }),
        siblingClassification: 'unknown' as const,
        siblingDistribution: null,
      },
      {
        name: 'timer',
        sibling: completeObservation(siblingKey, dist([[10, 1n]]), {
          hasTimer: true,
          coverageComplete: false,
        }).observation,
        siblingClassification: 'newObservation' as const,
        siblingDistribution: dist([[10, 1n]]),
      },
    ];
    for (const testCase of cases) {
      const evidence = evidenceFrom({
        newBaselineReference: reference(
          `snapshot-${testCase.name}`,
          `sha256:${testCase.name}`,
          ref.lineageID,
        ),
        entries: [
          completeObservation(key, dist([[11, 1n]]), {
            coverageComplete: false,
            distributionComplete: true,
            sectionTrustGatesOpen: true,
          }),
          { itemKey: siblingKey, observation: testCase.sibling },
        ],
      });
      const preview = previewReconciliation(evidence, state, s(1_700_000_200));
      const completeItem = preview.items.find((item) => item.itemKey.dataID === key.dataID)!;
      const incompleteSibling = preview.items.find(
        (item) => item.itemKey.dataID === siblingKey.dataID,
      )!;
      expect(completeItem.classification, testCase.name).toBe('observedAhead');
      expect(completeItem.coverageComplete, testCase.name).toBe(false);
      expect(
        manualLevelDistributionsEqual(completeItem.observedDistribution!, dist([[11, 1n]])),
        testCase.name,
      ).toBe(true);
      expect(incompleteSibling.classification, testCase.name).toBe(testCase.siblingClassification);
      expect(incompleteSibling.coverageComplete, testCase.name).toBe(false);
      if (testCase.siblingDistribution === null) {
        expect(incompleteSibling.observedDistribution, testCase.name).toBeNull();
      } else {
        expect(
          manualLevelDistributionsEqual(
            incompleteSibling.observedDistribution!,
            testCase.siblingDistribution,
          ),
          testCase.name,
        ).toBe(true);
      }
    }
  });

  it('manual ahead does not rollback local effective distribution', () => {
    const ref = reference();
    const state = observedState(ref, [[11, 1n]]);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      previousObservations: buildObservationMap([completeObservation(key, dist([[9, 1n]]))])
        .observations,
      entries: [completeObservation(key, dist([[10, 1n]]))],
    });
    const plan = reconcileManualTracker(evidence, state, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_700_000_200),
    });
    expect(singleItem(plan.preview).classification).toBe('manualAhead');
    expect(
      manualLevelDistributionsEqual(
        plan.state.core.effectiveState(key)!.effectiveCompletedDistribution!,
        dist([[11, 1n]]),
      ),
    ).toBe(true);
  });

  it('non-monotonic histogram movement is conflict', () => {
    const ref = reference();
    const state = observedState(ref, [
      [10, 1n],
      [12, 1n],
    ]);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      previousObservations: buildObservationMap([
        completeObservation(
          key,
          dist([
            [10, 1n],
            [12, 1n],
          ]),
        ),
      ]).observations,
      entries: [completeObservation(key, dist([[11, 2n]]))],
      relatedChangesByStableID: new Map([
        [trackerItemKeyStableId(key), [{ coverageState: 'complete' }]],
      ]),
    });
    const preview = previewReconciliation(evidence, state, s(1_700_000_200));
    expect(singleItem(preview).classification).toBe('conflict');
    expect(manualReconciliationPreviewRequiresExplicitDecision(preview)).toBe(true);
  });

  it('declared unique level increase stays unknown without verified section', () => {
    const ref = reference();
    const state = observedState(ref, [[9, 1n]]);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      entries: [
        completeObservation(key, dist([[10, 1n]]), {
          sectionTrustGatesOpen: false,
          coverageComplete: false,
        }),
      ],
    });
    expect(
      singleItem(previewReconciliation(evidence, state, s(1_700_000_200))).classification,
    ).toBe('unknown');
  });

  it('non-monotonic histogram movement with declared proof is unknown', () => {
    const ref = reference();
    const state = observedState(ref, [
      [10, 1n],
      [12, 1n],
    ]);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      entries: [
        completeObservation(key, dist([[11, 2n]]), {
          sectionTrustGatesOpen: false,
          coverageComplete: false,
        }),
      ],
      relatedChangesByStableID: new Map([
        [trackerItemKeyStableId(key), [{ coverageState: 'partial' }]],
      ]),
    });
    const preview = previewReconciliation(evidence, state, s(1_700_000_200));
    expect(singleItem(preview).classification).toBe('unknown');
    expect(manualReconciliationPreviewRequiresExplicitDecision(preview)).toBe(true);
  });

  it('non-monotonic histogram movement without proof is unknown', () => {
    const ref = reference();
    const state = observedState(ref, [
      [10, 1n],
      [12, 1n],
    ]);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      entries: [
        completeObservation(key, dist([[11, 2n]]), {
          sectionTrustGatesOpen: false,
          coverageComplete: false,
        }),
      ],
      relatedChangesByStableID: new Map([
        [trackerItemKeyStableId(key), [{ coverageState: 'partial' }]],
      ]),
    });
    const preview = previewReconciliation(evidence, state, s(1_700_000_200));
    expect(singleItem(preview).classification).toBe('unknown');
    expect(manualReconciliationPreviewRequiresExplicitDecision(preview)).toBe(true);
  });

  it('lineage mismatch requires explicit observed rebase', () => {
    const ref = reference();
    const state = observedState(ref, [[10, 1n]]);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-p2', 'sha256:fp-p2', 'lineage-p2'),
      lineageComparable: false,
      entries: [completeObservation(key, dist([[11, 1n]]))],
    });
    const safePlan = reconcileManualTracker(evidence, state, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_700_000_200),
    });
    expect(singleItem(safePlan.preview).classification).toBe('lineageMismatch');
    expect(safePlan.state.core.equals(state.core)).toBe(true);

    const accepted = reconcileManualTracker(evidence, state, {
      decision: 'acceptObserved',
      appliedAtMs: s(1_700_000_200),
    });
    expect(accepted.state.baselineReference).toEqual(accepted.preview.newReference);
    expect(accepted.state.core.records).toEqual([]);
    expect(
      manualLevelDistributionsEqual(
        accepted.state.core.effectiveState(key)!.effectiveCompletedDistribution!,
        dist([[11, 1n]]),
      ),
    ).toBe(true);
  });

  it('acceptObserved across lineage does not carry active records from old lineage', () => {
    const ref = reference();
    const state = activeState(ref);
    expect(state.core.records.some((record) => record.status === 'active')).toBe(true);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-p2', 'sha256:fp-p2', 'lineage-p2'),
      lineageComparable: false,
      entries: [completeObservation(key, dist([[11, 1n]]))],
    });
    const accepted = reconcileManualTracker(evidence, state, {
      decision: 'acceptObserved',
      appliedAtMs: s(1_700_000_200),
    });
    expect(accepted.state.core.records).toEqual([]);
    expect(accepted.state.core.activeRecords).toEqual([]);
    expect(accepted.state.baselineReference?.lineageID).toBe('lineage-p2');
    expect(
      manualLevelDistributionsEqual(
        accepted.state.core.effectiveState(key)!.importedDistribution!,
        dist([[11, 1n]]),
      ),
    ).toBe(true);
  });

  it('old manual lineage cannot auto match after history already switched', () => {
    const ref = reference();
    const state = observedState(ref, [[10, 1n]]);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-p2-2', 'sha256:fp-p2-2', 'lineage-p2'),
      lineageComparable: false,
      previousLineageID: 'lineage-p2',
      entries: [completeObservation(key, dist([[12, 1n]]))],
    });
    const preview = previewReconciliation(evidence, state, s(1_700_000_200));
    expect(preview.lineageComparable).toBe(false);
    expect(singleItem(preview).classification).toBe('lineageMismatch');
  });

  it('duplicate histogram uses aggregate distribution', () => {
    const ref = reference();
    const state = observedState(ref, [
      [10, 2n],
      [11, 1n],
    ]);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      previousObservations: buildObservationMap([
        completeObservation(
          key,
          dist([
            [10, 2n],
            [11, 1n],
          ]),
        ),
      ]).observations,
      entries: [
        completeObservation(
          key,
          dist([
            [10, 1n],
            [11, 2n],
          ]),
        ),
      ],
    });
    const preview = previewReconciliation(evidence, state, s(1_700_000_200));
    expect(preview.items).toHaveLength(1);
    expect(singleItem(preview).classification).toBe('observedAhead');
    expect(
      manualLevelDistributionsEqual(
        singleItem(preview).observedDistribution!,
        dist([
          [10, 1n],
          [11, 2n],
        ]),
      ),
    ).toBe(true);
  });

  it('duplicate import with partial section coverage still surfaces item distribution', () => {
    const ref = reference();
    const state = createManualTrackerVillageState({
      villageID,
      core: ManualUpgradeCoreState.create(),
      stateUpdatedAtMs: s(1_700_000_010),
    });
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-dup', ref.fingerprint, ref.lineageID),
      duplicate: true,
      entries: [
        completeObservation(buildingKey, dist([[14, 4n]]), {
          coverageComplete: false,
          sectionTrustGatesOpen: true,
        }),
      ],
    });
    const preview = previewReconciliation(evidence, state, s(1_785_736_400));
    const building = preview.items.find((item) => item.itemKey.dataID === buildingKey.dataID)!;
    expect(building.classification).toBe('duplicate');
    expect(building.coverageComplete).toBe(false);
    expect(manualLevelDistributionsEqual(building.observedDistribution!, dist([[14, 4n]]))).toBe(
      true,
    );
  });

  it('complete histogram item survives sibling timer-only rows', () => {
    const ref = reference('snapshot-test', 'sha256:test', 'lineage-test');
    const emptyState = createManualTrackerVillageState({
      villageID,
      core: ManualUpgradeCoreState.create(),
      stateUpdatedAtMs: s(1_700_000_010),
    });
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-test-2', 'sha256:test-2', ref.lineageID),
      lineageComparable: true,
      entries: [
        completeObservation(drillKey, dist([[1, 3n]]), {
          coverageComplete: false,
          sectionTrustGatesOpen: false,
        }),
        {
          itemKey: timerOnlyKey,
          observation: createReconciliationObservation({
            displayName: 'timer-only',
            hasTimer: true,
            distribution: null,
            distributionComplete: false,
            coverageComplete: false,
            sectionTrustGatesOpen: false,
          }),
        },
      ],
    });
    const preview = previewReconciliation(evidence, emptyState, s(1_785_557_000));
    expect(
      preview.items.find((item) => item.itemKey.dataID === drillKey.dataID)!.classification,
    ).toBe('newObservation');
    expect(
      preview.items.find((item) => item.itemKey.dataID === timerOnlyKey.dataID)!.classification,
    ).toBe('unknown');
    const plan = reconcileManualTracker(evidence, emptyState, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_785_557_000),
    });
    const rebased = plan.state.core.itemState(drillKey)!;
    expect(rebased.status).toBe('observed');
    expect(
      manualLevelDistributionsEqual(
        rebased.importedObservation!.levelDistribution!,
        dist([[1, 3n]]),
      ),
    ).toBe(true);
  });

  it('non-histogram level-only items produce distribution beside partial histogram section', () => {
    const ref = reference();
    const emptyState = createManualTrackerVillageState({
      villageID,
      core: ManualUpgradeCoreState.create(),
      stateUpdatedAtMs: s(1_700_000_010),
    });
    const cases = [
      ['heroes', 1_000_001n, 30],
      ['units', 4_000_000n, 8],
      ['spells', 26_000_000n, 5],
      ['equipment', 106_000_000n, 15],
    ] as const;
    const entries = cases.map(([section, dataID, level]) =>
      completeObservation(trackerItemKeyRoot('home', section, dataID), dist([[level, 1n]]), {
        sectionTrustGatesOpen: false,
        coverageComplete: false,
      }),
    );
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-mixed', 'sha256:mixed', ref.lineageID),
      entries,
    });
    const preview = previewReconciliation(evidence, emptyState, s(1_700_000_100));
    for (const [section, dataID, level] of cases) {
      const item = preview.items.find(
        (entry) => entry.itemKey.rawSection === section && entry.itemKey.dataID === dataID,
      )!;
      expect(item.classification, section).toBe('newObservation');
      expect(manualLevelDistributionsEqual(item.observedDistribution!, dist([[level, 1n]]))).toBe(
        true,
      );
    }
  });

  it('placeholder observed state adopts complete item without coverage field', () => {
    const ref = reference('snapshot-test', 'sha256:test', 'lineage-test');
    const placeholder = createManualItemStateForStatus({
      itemKey: drillKey,
      baselineReference: ref,
      imported: null,
      status: 'observed',
      sourceTimestampMs: s(1_785_557_000),
    });
    const currentState = createManualTrackerVillageState({
      villageID,
      core: ManualUpgradeCoreState.create({ itemStates: [placeholder] }),
      stateUpdatedAtMs: s(1_700_000_010),
      lastImportAtMs: s(1_700_000_010),
    });
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-test-2', 'sha256:test-2', ref.lineageID),
      entries: [
        completeObservation(drillKey, dist([[1, 3n]]), {
          sectionTrustGatesOpen: false,
          coverageComplete: false,
        }),
      ],
    });
    const preview = previewReconciliation(evidence, currentState, s(1_785_557_000));
    expect(
      preview.items.find((item) => item.itemKey.dataID === drillKey.dataID)!.classification,
    ).toBe('newObservation');
    const plan = reconcileManualTracker(evidence, currentState, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_785_557_000),
    });
    expect(
      manualLevelDistributionsEqual(
        plan.state.core.itemState(drillKey)!.importedObservation!.levelDistribution!,
        dist([[1, 3n]]),
      ),
    ).toBe(true);
  });

  it('timer item is not queue confirmable when section timer coverage partial', () => {
    const ref = reference();
    const emptyState = createManualTrackerVillageState({
      villageID,
      core: ManualUpgradeCoreState.create(),
      stateUpdatedAtMs: s(1_700_000_010),
    });
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      entries: [
        completeObservation(key, dist([[10, 1n]]), {
          hasTimer: true,
          timerCoverageComplete: false,
          coverageComplete: false,
          sectionTrustGatesOpen: false,
        }),
        completeObservation(siblingKey, dist([[10, 1n]]), {
          sectionTrustGatesOpen: false,
          coverageComplete: false,
        }),
      ],
    });
    const plan = reconcileManualTracker(evidence, emptyState, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_700_000_100),
    });
    const timerItem = plan.state.core.itemState(key)!;
    expect(timerItem.importedObservation?.observedTimer).toBe(true);
    expect(timerItem.importedObservation?.levelDistribution).not.toBeNull();
    expect(isManualItemStateQueueAssignmentConfirmable(timerItem)).toBe(false);
  });

  it.each(['unknown', 'conflict'] as const)(
    'attention %s state stays unknown without verified section trust',
    (status) => {
      const ref = reference('snapshot-test', 'sha256:test', 'lineage-test');
      const attention = createManualItemStateForStatus({
        itemKey: drillKey,
        baselineReference: ref,
        imported: null,
        status,
        sourceTimestampMs: s(1_785_557_000),
      });
      const currentState = createManualTrackerVillageState({
        villageID,
        core: ManualUpgradeCoreState.create({ itemStates: [attention] }),
        stateUpdatedAtMs: s(1_700_000_010),
        lastImportAtMs: s(1_700_000_010),
      });
      const evidence = evidenceFrom({
        newBaselineReference: reference('snapshot-test-2', 'sha256:test-2', ref.lineageID),
        entries: [
          completeObservation(drillKey, dist([[1, 3n]]), {
            sectionTrustGatesOpen: false,
            coverageComplete: false,
          }),
        ],
      });
      const preview = previewReconciliation(evidence, currentState, s(1_785_557_000));
      const drillPreview = preview.items.find((item) => item.itemKey.dataID === drillKey.dataID)!;
      expect(drillPreview.classification).toBe('unknown');
      expect(manualReconciliationPreviewRequiresExplicitDecision(preview)).toBe(true);
      const plan = reconcileManualTracker(evidence, currentState, {
        decision: 'applyNonConflicting',
        appliedAtMs: s(1_785_557_000),
      });
      const rebased = plan.state.core.itemState(drillKey)!;
      expect(rebased.status).toBe(status);
      expect(rebased.importedObservation?.levelDistribution).toBeNull();
    },
  );

  it('stale preview is rejected before state mutation', () => {
    const ref = reference();
    const state = observedState(ref, [[10, 1n]]);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      entries: [completeObservation(key, dist([[11, 1n]]))],
    });
    const preview = previewReconciliation(evidence, state, s(1_700_000_200));
    const changedState = createManualTrackerVillageState({
      villageID,
      core: state.core,
      stateUpdatedAtMs: s(1_700_000_201),
    });
    try {
      reconcileManualTracker(evidence, changedState, {
        expectedPreview: preview,
        decision: 'applyNonConflicting',
        appliedAtMs: s(1_700_000_200),
      });
      expect.unreachable('expected stale preview');
    } catch (error) {
      expect(manualReconciliationErrorsEqual(error as never, { kind: 'stalePreview' })).toBe(true);
    }
  });

  it('candidate change invalidates preview', () => {
    const ref = reference();
    const state = observedState(ref, [[10, 1n]]);
    const previewA = previewReconciliation(
      evidenceFrom({
        newBaselineReference: reference('snapshot-a', 'sha256:fp-a', ref.lineageID),
        entries: [completeObservation(key, dist([[11, 1n]]))],
      }),
      state,
      s(1_700_000_200),
    );
    const evidenceB = evidenceFrom({
      newBaselineReference: reference('snapshot-b', 'sha256:fp-b', ref.lineageID),
      entries: [completeObservation(key, dist([[12, 1n]]))],
    });
    try {
      reconcileManualTracker(evidenceB, state, {
        expectedPreview: previewA,
        decision: 'applyNonConflicting',
        appliedAtMs: s(1_700_000_200),
      });
      expect.unreachable('expected stale preview');
    } catch (error) {
      expect(manualReconciliationErrorsEqual(error as never, { kind: 'stalePreview' })).toBe(true);
    }
  });

  it('same snapshot metadata with changed observation invalidates preview', () => {
    const ref = reference();
    const state = observedState(ref, [[10, 1n]]);
    const sharedReference = reference('snapshot-same', 'sha256:fp-same', ref.lineageID);
    const previewA = previewReconciliation(
      evidenceFrom({
        newBaselineReference: sharedReference,
        duplicate: true,
        entries: [completeObservation(key, dist([[11, 1n]]))],
      }),
      state,
      s(1_700_000_200),
    );
    const evidenceB = evidenceFrom({
      newBaselineReference: sharedReference,
      duplicate: true,
      entries: [completeObservation(key, dist([[12, 1n]]))],
    });
    try {
      reconcileManualTracker(evidenceB, state, {
        expectedPreview: previewA,
        decision: 'applyNonConflicting',
        appliedAtMs: s(1_700_000_200),
      });
      expect.unreachable('expected stale preview');
    } catch (error) {
      expect(manualReconciliationErrorsEqual(error as never, { kind: 'stalePreview' })).toBe(true);
    }
  });

  it('candidate fingerprint ignores ephemeral snapshot revision and lineage IDs for non-duplicate candidates', () => {
    const state = createManualTrackerVillageState({
      villageID,
      core: createManualUpgradeCoreState({ itemStates: [] }),
      stateUpdatedAtMs: s(1_700_000_010),
    });
    const sharedObservation = completeObservation(key, dist([[10, 1n]]));
    const previewA = previewReconciliation(
      evidenceFrom({
        newBaselineReference: reference(
          '00000000-0000-0000-0000-000000000201',
          'sha256:stable-fp',
          '00000000-0000-0000-0000-000000000301',
        ),
        entries: [sharedObservation],
      }),
      state,
      s(1_700_000_200),
    );
    const previewB = previewReconciliation(
      evidenceFrom({
        newBaselineReference: reference(
          '00000000-0000-0000-0000-000000000202',
          'sha256:stable-fp',
          '00000000-0000-0000-0000-000000000302',
        ),
        entries: [sharedObservation],
      }),
      state,
      s(1_700_000_200),
    );
    expect(previewA.newReference.revision).not.toBe(previewB.newReference.revision);
    expect(previewA.newReference.lineageID).not.toBe(previewB.newReference.lineageID);
    expect(previewA.candidateFingerprint).toBe(previewB.candidateFingerprint);
    expect(reconciliationCandidateMatches(previewA, previewB)).toBe(true);
    expect(() =>
      reconcileManualTracker(
        evidenceFrom({
          newBaselineReference: reference(
            previewB.newReference.revision,
            previewB.newReference.fingerprint ?? 'sha256:stable-fp',
            previewB.newReference.lineageID ?? 'lineage-unknown',
          ),
          entries: [sharedObservation],
        }),
        state,
        {
          expectedPreview: previewA,
          decision: 'applyNonConflicting',
          appliedAtMs: s(1_700_000_200),
        },
      ),
    ).not.toThrow();
  });

  it('candidate fingerprint includes revision for duplicate candidates', () => {
    const state = createManualTrackerVillageState({
      villageID,
      core: createManualUpgradeCoreState({ itemStates: [] }),
      stateUpdatedAtMs: s(1_700_000_010),
    });
    const sharedObservation = completeObservation(key, dist([[10, 1n]]));
    const previewA = previewReconciliation(
      evidenceFrom({
        duplicate: true,
        newBaselineReference: reference(
          '00000000-0000-0000-0000-000000000401:observation:1',
          'sha256:dup-fp',
          'lineage-dup',
        ),
        entries: [sharedObservation],
      }),
      state,
      s(1_700_000_200),
    );
    const previewB = previewReconciliation(
      evidenceFrom({
        duplicate: true,
        newBaselineReference: reference(
          '00000000-0000-0000-0000-000000000401:observation:2',
          'sha256:dup-fp',
          'lineage-dup',
        ),
        entries: [sharedObservation],
      }),
      state,
      s(1_700_000_200),
    );
    expect(previewA.candidateFingerprint).not.toBe(previewB.candidateFingerprint);
    expect(reconciliationCandidateMatches(previewA, previewB)).toBe(false);
  });

  it('candidate fingerprint supports INT64_MAX distributions', () => {
    const ref = reference();
    const int64Distribution = dist([[10, INT64_MAX]]);
    const state = createManualTrackerVillageState({
      villageID,
      core: createManualUpgradeCoreState({ itemStates: [] }),
    });
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-int64', 'sha256:fp-int64', ref.lineageID),
      entries: [completeObservation(key, int64Distribution)],
    });
    const preview = previewReconciliation(evidence, state, s(1_700_000_200));
    expect(preview.candidateFingerprint.length).toBeGreaterThan(0);
    expect(preview.items[0]?.observedDistribution).not.toBeNull();

    const fingerprint = computeReconciliationCandidateFingerprint({
      duplicate: false,
      lineageComparable: true,
      timeConfidence: 'reliableSourceTimestamp',
      newReference: reference('snapshot-int64', 'sha256:fp-int64', ref.lineageID),
      newNormalizedPlayerTag: '#P1',
      sourceTimestampMs: s(1_700_000_200),
      items: [
        {
          itemKey: key,
          displayName: trackerItemKeyStableId(key),
          classification: 'exactMatch',
          message: '观察一致',
          previousDistribution: int64Distribution,
          observedDistribution: int64Distribution,
          relatedRecordIDs: [],
          confirmedRecordIDs: [],
          observedTimer: false,
          coverageComplete: true,
          observedDistributionComplete: true,
          observedSectionTrustGatesOpen: true,
          observedTimerCoverageComplete: false,
        },
      ],
    });
    expect(fingerprint.length).toBeGreaterThan(0);
  });

  it('same preview metadata with changed timerCoverageComplete invalidates preview', () => {
    const ref = reference();
    const state = createManualTrackerVillageState({
      villageID,
      core: createManualUpgradeCoreState({ itemStates: [] }),
    });
    const sharedReference = reference('snapshot-same', 'sha256:fp-same', ref.lineageID);
    const sharedObservation = {
      hasTimer: true,
      timerCoverageComplete: true,
      distributionComplete: true,
      coverageComplete: true,
    } as const;
    const previewA = previewReconciliation(
      evidenceFrom({
        newBaselineReference: sharedReference,
        entries: [completeObservation(key, dist([[10, 1n]]), sharedObservation)],
      }),
      state,
      s(1_700_000_200),
    );
    const previewB = previewReconciliation(
      evidenceFrom({
        newBaselineReference: sharedReference,
        entries: [
          completeObservation(key, dist([[10, 1n]]), {
            ...sharedObservation,
            timerCoverageComplete: false,
          }),
        ],
      }),
      state,
      s(1_700_000_200),
    );
    expect(previewA.candidateFingerprint).not.toBe(previewB.candidateFingerprint);
    try {
      reconcileManualTracker(
        evidenceFrom({
          newBaselineReference: sharedReference,
          entries: [
            completeObservation(key, dist([[10, 1n]]), {
              ...sharedObservation,
              timerCoverageComplete: false,
            }),
          ],
        }),
        state,
        {
          expectedPreview: previewA,
          decision: 'applyNonConflicting',
          appliedAtMs: s(1_700_000_200),
        },
      );
      expect.unreachable('expected stale preview');
    } catch (error) {
      expect(manualReconciliationErrorsEqual(error as never, { kind: 'stalePreview' })).toBe(true);
    }
  });

  it('createReconciliationObservation defaults distributionComplete from normalized distribution', () => {
    const observation = createReconciliationObservation({
      displayName: 'building',
    });
    expect(observation.distribution).toBeNull();
    expect(observation.distributionComplete).toBe(false);
    expect(observation.coverageComplete).toBe(false);

    const timerOnly = createReconciliationObservation({
      displayName: 'building',
      hasTimer: true,
      timerCoverageComplete: true,
    });
    expect(timerOnly.distribution).toBeNull();
    expect(timerOnly.distributionComplete).toBe(false);
    expect(timerOnly.hasTimer).toBe(true);
    expect(timerOnly.timerCoverageComplete).toBe(true);
  });

  it('wrong village ID is rejected', () => {
    const ref = reference();
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      entries: [completeObservation(key, dist([[11, 1n]]))],
    });
    try {
      previewReconciliation(
        { ...evidence, villageID: parseUuid('00000000-0000-0000-0000-000000000999')! },
        observedState(ref, [[10, 1n]]),
        s(1_700_000_200),
      );
      expect.unreachable('expected village mismatch');
    } catch (error) {
      expect(manualReconciliationErrorsEqual(error as never, { kind: 'villageMismatch' })).toBe(
        true,
      );
    }
  });

  function stateWithAssignment(ref: ReturnType<typeof reference>) {
    const base = observedState(ref, [[10, 1n]]);
    const assignment = createQueueAssignmentDecision({
      decisionID: parseUuid('00000000-0000-0000-0000-000000000301')!,
      villageID,
      itemKey: key,
      baselineReference: ref,
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      decidedAtMs: s(1_700_000_010),
    });
    return createManualTrackerVillageState({
      villageID,
      core: base.core,
      queueAssignments: [assignment],
    });
  }

  it('keeps user assigned within same lineage', () => {
    const ref = reference();
    const state = stateWithAssignment(ref);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-dup', ref.fingerprint, ref.lineageID),
      duplicate: true,
      entries: [
        completeObservation(key, dist([[10, 1n]]), {
          hasTimer: true,
          timerCoverageComplete: true,
          distributionComplete: true,
        }),
      ],
    });
    const plan = reconcileManualTracker(evidence, state, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_700_000_200),
    });
    expect(plan.state.queueAssignments).toHaveLength(1);
    expect(plan.state.queueAssignments[0]?.status).toBe('userAssigned');
  });

  it('degrades cross-lineage assignment to unknown', () => {
    const ref = reference();
    const state = stateWithAssignment(ref);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-p2', 'sha256:fp-p2', 'lineage-p2'),
      lineageComparable: true,
      entries: [completeObservation(key, dist([[11, 1n]]))],
    });
    const plan = reconcileManualTracker(evidence, state, {
      decision: 'acceptObserved',
      appliedAtMs: s(1_700_000_200),
    });
    expect(plan.state.queueAssignments).toHaveLength(1);
    expect(plan.state.queueAssignments[0]?.status).toBe('unknown');
  });

  it('degrades timer-ended assignment to observedOnly', () => {
    const ref = reference();
    const state = stateWithAssignment(ref);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      entries: [
        completeObservation(key, dist([[10, 1n]]), {
          hasTimer: false,
          timerCoverageComplete: true,
        }),
      ],
    });
    const plan = reconcileManualTracker(evidence, state, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_700_000_200),
    });
    expect(plan.state.queueAssignments).toHaveLength(1);
    expect(plan.state.queueAssignments[0]?.status).toBe('observedOnly');
  });

  it('never creates assignments automatically', () => {
    const ref = reference();
    const state = observedState(ref, [[10, 1n]]);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-dup', ref.fingerprint, ref.lineageID),
      duplicate: true,
      entries: [
        completeObservation(key, dist([[10, 1n]]), {
          hasTimer: true,
          timerCoverageComplete: true,
        }),
      ],
    });
    const plan = reconcileManualTracker(evidence, state, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_700_000_200),
    });
    expect(plan.state.queueAssignments).toHaveLength(0);
  });

  it('degrades assignment when coverage incomplete', () => {
    const ref = reference();
    const state = stateWithAssignment(ref);
    const evidence = evidenceFrom({
      newBaselineReference: reference('snapshot-2', 'sha256:fp-2', ref.lineageID),
      entries: [
        completeObservation(key, dist([[10, 1n]]), {
          hasTimer: true,
          timerCoverageComplete: true,
          distributionComplete: false,
          coverageComplete: false,
        }),
        {
          itemKey: siblingKey,
          observation: createReconciliationObservation({
            displayName: 'partial sibling',
            distribution: null,
            distributionComplete: false,
            coverageComplete: false,
          }),
        },
      ],
    });
    const plan = reconcileManualTracker(evidence, state, {
      decision: 'applyNonConflicting',
      appliedAtMs: s(1_700_000_200),
    });
    expect(plan.state.queueAssignments).toHaveLength(1);
    expect(plan.state.queueAssignments[0]?.status).toBe('observedOnly');
  });
});
