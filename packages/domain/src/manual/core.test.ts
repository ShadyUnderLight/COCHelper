import { INT64_MAX, parseUuid, type UuidString } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import type { CatalogUpgradeCost } from '../catalog/types';
import {
  createManualLevelDistributionFromPairs,
  createManualItemStateForStatus,
  createManualUpgradeCoreState,
  ManualUpgradeCoreState,
} from './core';
import { manualUpgradeErrorEquals } from './errors';
import {
  createManualLevelDistribution,
  createManualLevelQuantity,
  manualLevelDistributionAdd,
  manualLevelDistributionFromQuantities,
} from './level-distribution';
import { createManualImportedObservation, createManualUpgradeRecord } from './models';
import { trackerItemKeyRoot } from './types';

const key = trackerItemKeyRoot('home', 'buildings', 100n);
const id = (value: string): UuidString => parseUuid(value)!;
const baseline = {
  revision: 'snapshot-1',
  lineageID: 'village-1',
};
const provenance = {
  gameVersion: '18.400.13',
  buildTag: 'catalog-test',
  manifestSchemaVersion: 1,
};

function dateMs(seconds: number): number {
  return seconds * 1000;
}

function distribution(values: readonly (readonly [number, bigint])[]) {
  return createManualLevelDistributionFromPairs(values);
}

function cost(resource = 'Gold', amount: bigint | null = 500n): CatalogUpgradeCost {
  return {
    resource,
    amount,
    rawResource: resource,
    rawAmount: null,
    parseFailed: false,
  };
}

function coreForStatus(input: {
  readonly imported?: ReturnType<typeof distribution> | null;
  readonly manual?: ReturnType<typeof distribution>;
  readonly status: 'observed' | 'manualCompleted' | 'unknown' | 'conflict';
}) {
  return createManualUpgradeCoreState({
    itemStates: [
      createManualItemStateForStatus({
        itemKey: key,
        baselineReference: baseline,
        imported: input.imported,
        manual: input.manual ?? distribution([]),
        status: input.status,
        sourceTimestampMs: dateMs(900),
      }),
    ],
  });
}

function expectManualError(
  error: unknown,
  expected: Parameters<typeof manualUpgradeErrorEquals>[1],
) {
  expect(manualUpgradeErrorEquals(error as never, expected)).toBe(true);
}

function expectThrowsManualError(
  action: () => unknown,
  expected: Parameters<typeof manualUpgradeErrorEquals>[1],
) {
  try {
    action();
    expect.unreachable('expected manual upgrade error');
  } catch (error) {
    expectManualError(error, expected);
  }
}

describe('ManualUpgradeCoreState', () => {
  it('相同输入结构相等，mutation 产生不等的新值（Issue #304 无 fingerprint）', () => {
    const coreA = coreForStatus({
      imported: distribution([[1, 2n]]),
      status: 'observed',
    });
    const coreB = coreForStatus({
      imported: distribution([[1, 2n]]),
      status: 'observed',
    });
    expect(coreA.equals(coreB)).toBe(true);

    const recordID = id('00000000-0000-0000-0000-000000000001');
    let core = coreForStatus({
      imported: distribution([[12, 100n]]),
      status: 'observed',
    });
    const beforeStart = core;
    core = core.startUpgrade({
      itemKey: key,
      fromLevel: 12,
      targetLevel: 13,
      quantity: 1n,
      startedAtMs: dateMs(1_000),
      durationState: { kind: 'timed', seconds: 10n },
      frozenCosts: [cost()],
      catalogProvenance: provenance,
      baselineReference: baseline,
      recordID,
      nowMs: dateMs(1_000),
    });
    expect(core.equals(beforeStart)).toBe(false);
    expect(core.activeRecords).toHaveLength(1);

    const beforeCancel = core;
    core = core.cancelUpgrade(recordID);
    expect(core.equals(beforeCancel)).toBe(false);
    expect(core.activeRecords).toHaveLength(0);

    const adjustRecordID = id('00000000-0000-0000-0000-000000000002');
    core = core.startUpgrade({
      itemKey: key,
      fromLevel: 12,
      targetLevel: 13,
      quantity: 1n,
      startedAtMs: dateMs(1_020),
      durationState: { kind: 'timed', seconds: 10n },
      frozenCosts: [cost()],
      catalogProvenance: provenance,
      baselineReference: baseline,
      recordID: adjustRecordID,
      nowMs: dateMs(1_020),
    });
    const beforeAdjust = core;
    core = core.adjustStartTime(adjustRecordID, dateMs(1_025), dateMs(1_025));
    expect(core.equals(beforeAdjust)).toBe(false);

    const beforeSettle = core;
    ({ core } = core.settleDue(dateMs(1_040)));
    expect(core.equals(beforeSettle)).toBe(false);
  });

  it('settleDue 空操作返回同一实例', () => {
    const recordID = id('00000000-0000-0000-0000-000000000001');
    const core = coreForStatus({
      imported: distribution([[12, 100n]]),
      status: 'observed',
    }).startUpgrade({
      itemKey: key,
      fromLevel: 12,
      targetLevel: 13,
      quantity: 1n,
      startedAtMs: dateMs(1_000),
      durationState: { kind: 'timed', seconds: 10n },
      frozenCosts: [cost()],
      catalogProvenance: provenance,
      baselineReference: baseline,
      recordID,
      nowMs: dateMs(1_000),
    });
    const result = core.settleDue(dateMs(1_009));
    expect(result.settled).toEqual([]);
    expect(result.core).toBe(core);
  });

  it('settleDue 真正结算产生新值', () => {
    const recordID = id('00000000-0000-0000-0000-000000000001');
    const core = coreForStatus({
      imported: distribution([[12, 100n]]),
      status: 'observed',
    }).startUpgrade({
      itemKey: key,
      fromLevel: 12,
      targetLevel: 13,
      quantity: 1n,
      startedAtMs: dateMs(1_000),
      durationState: { kind: 'timed', seconds: 10n },
      frozenCosts: [cost()],
      catalogProvenance: provenance,
      baselineReference: baseline,
      recordID,
      nowMs: dateMs(1_000),
    });
    const beforeSettle = core;

    const result = core.settleDue(dateMs(1_010));
    expect(result.settled).toHaveLength(1);
    expect(result.settled[0]?.status).toBe('completed');
    expect(result.core.equals(beforeSettle)).toBe(false);
  });

  it('timed upgrade 预留源数量并在到期后幂等结算', () => {
    const recordID = id('00000000-0000-0000-0000-000000000001');
    let core = coreForStatus({
      imported: distribution([[12, 100n]]),
      status: 'observed',
    });
    core = core.startUpgrade({
      itemKey: key,
      fromLevel: 12,
      targetLevel: 13,
      quantity: 1n,
      startedAtMs: dateMs(1_000),
      durationState: { kind: 'timed', seconds: 10n },
      frozenCosts: [cost()],
      catalogProvenance: provenance,
      baselineReference: baseline,
      recordID,
      nowMs: dateMs(1_000),
    });

    const active = core.effectiveState(key);
    expect(active?.importedDistribution?.quantityAt(12)).toBe(100n);
    expect(active?.manualCompletedDistribution.quantityAt(12)).toBe(100n);
    expect(active?.effectiveCompletedDistribution?.quantityAt(12)).toBe(99n);
    expect(active?.activeTargetDistribution.quantityAt(13)).toBe(1n);
    expect(active?.activeTargetLevel).toBe(13);

    expect(core.settleDue(dateMs(1_009)).settled).toEqual([]);
    expect(core.activeRecords).toHaveLength(1);

    const settled = core.settleDue(dateMs(1_010));
    expect(settled.settled.map((record) => record.recordID)).toEqual([recordID]);
    expect(settled.settled[0]?.status).toBe('completed');
    core = settled.core;
    expect(core.settleDue(dateMs(2_000)).settled).toEqual([]);
    expect(core.completedHistory).toHaveLength(1);

    const completed = core.effectiveState(key);
    expect(completed?.activeTargetDistribution.isEmpty).toBe(true);
    expect(completed?.effectiveCompletedDistribution?.quantityAt(12)).toBe(99n);
    expect(completed?.effectiveCompletedDistribution?.quantityAt(13)).toBe(1n);
  });

  it('instant upgrade 立即完成并保留 frozen 数据', () => {
    const recordID = id('00000000-0000-0000-0000-000000000002');
    let core = coreForStatus({
      manual: distribution([[1, 1n]]),
      status: 'manualCompleted',
    });
    core = core.startUpgrade({
      itemKey: key,
      fromLevel: 1,
      targetLevel: 2,
      quantity: 1n,
      startedAtMs: dateMs(1_000),
      durationState: { kind: 'instant' },
      frozenCosts: [{ ...cost('DarkElixir', null), rawAmount: 'not-a-number', parseFailed: true }],
      catalogProvenance: provenance,
      baselineReference: baseline,
      recordID,
      nowMs: dateMs(1_000),
    });

    const record = core.records.find((entry) => entry.recordID === recordID);
    expect(record?.status).toBe('completed');
    expect(core.activeRecords).toHaveLength(0);
    expect(core.effectiveState(key)?.effectiveCompletedDistribution?.quantityAt(2)).toBe(1n);
    expectThrowsManualError(() => core.cancelUpgrade(recordID), {
      kind: 'cannotCancelCompleted',
      recordID,
    });
  });

  it('unavailable duration 不修改 state', () => {
    const unavailable = [
      null,
      { kind: 'initialLevel' as const },
      { kind: 'notApplicable' as const },
      { kind: 'sourceMissing' as const },
      { kind: 'parseFailed' as const },
      { kind: 'unknownReason' as const, reason: 'future-reason' },
    ];

    unavailable.forEach((durationState, offset) => {
      const before = coreForStatus({
        manual: distribution([[10, 1n]]),
        status: 'manualCompleted',
      });
      expect(() =>
        before.startUpgrade({
          itemKey: key,
          fromLevel: 10,
          targetLevel: 11,
          quantity: 1n,
          startedAtMs: dateMs(1_000),
          durationState,
          frozenCosts: null,
          catalogProvenance: provenance,
          baselineReference: baseline,
          recordID: id(`00000000-0000-0000-0000-${String(offset + 10).padStart(12, '0')}`),
          nowMs: dateMs(1_000),
        }),
      ).toThrow();
      expect(before.equals(before)).toBe(true);
    });

    const zeroDuration = coreForStatus({
      manual: distribution([[10, 1n]]),
      status: 'manualCompleted',
    });
    expectThrowsManualError(
      () =>
        zeroDuration.startUpgrade({
          itemKey: key,
          fromLevel: 10,
          targetLevel: 11,
          quantity: 1n,
          startedAtMs: dateMs(1_000),
          durationState: { kind: 'timed', seconds: 0n },
          frozenCosts: null,
          catalogProvenance: provenance,
          baselineReference: baseline,
          nowMs: dateMs(1_000),
        }),
      { kind: 'invalidDuration' },
    );

    const future = coreForStatus({
      manual: distribution([[10, 1n]]),
      status: 'manualCompleted',
    });
    expectThrowsManualError(
      () =>
        future.startUpgrade({
          itemKey: key,
          fromLevel: 10,
          targetLevel: 11,
          quantity: 1n,
          startedAtMs: dateMs(1_001),
          durationState: { kind: 'instant' },
          frozenCosts: null,
          catalogProvenance: provenance,
          baselineReference: baseline,
          nowMs: dateMs(1_000),
        }),
      { kind: 'futureStart' },
    );
  });

  it('cancel 释放预留；adjust 走同一路径结算', () => {
    const firstID = id('00000000-0000-0000-0000-000000000010');
    const secondID = id('00000000-0000-0000-0000-000000000011');
    let core = coreForStatus({
      manual: distribution([[10, 2n]]),
      status: 'manualCompleted',
    });
    core = core.startUpgrade({
      itemKey: key,
      fromLevel: 10,
      targetLevel: 11,
      quantity: 1n,
      startedAtMs: dateMs(1_000),
      durationState: { kind: 'timed', seconds: 10n },
      frozenCosts: null,
      catalogProvenance: provenance,
      baselineReference: baseline,
      recordID: firstID,
      nowMs: dateMs(1_000),
    });
    core = core.cancelUpgrade(firstID);
    expect(core.effectiveState(key)?.effectiveCompletedDistribution?.quantityAt(10)).toBe(2n);
    expect(core.activeRecords).toHaveLength(0);
    expectThrowsManualError(() => core.cancelUpgrade(firstID), {
      kind: 'recordNotActive',
      recordID: firstID,
    });

    core = core.startUpgrade({
      itemKey: key,
      fromLevel: 10,
      targetLevel: 11,
      quantity: 1n,
      startedAtMs: dateMs(1_000),
      durationState: { kind: 'timed', seconds: 10n },
      frozenCosts: null,
      catalogProvenance: provenance,
      baselineReference: baseline,
      recordID: secondID,
      nowMs: dateMs(1_000),
    });
    core = core.adjustStartTime(secondID, dateMs(990), dateMs(1_000));
    const adjusted = core.records.find((record) => record.recordID === secondID);
    expect(adjusted?.status).toBe('completed');
    expect(adjusted?.expectedEndAtMs).toBe(dateMs(1_000));
    expect(core.effectiveState(key)?.effectiveCompletedDistribution?.quantityAt(11)).toBe(1n);
  });

  it('due records 按 end time 与 recordID 稳定排序', () => {
    const firstID = id('00000000-0000-0000-0000-000000000020');
    const secondID = id('00000000-0000-0000-0000-000000000021');
    let core = coreForStatus({
      manual: distribution([[10, 2n]]),
      status: 'manualCompleted',
    });
    for (const recordID of [secondID, firstID]) {
      core = core.startUpgrade({
        itemKey: key,
        fromLevel: 10,
        targetLevel: 11,
        quantity: 1n,
        startedAtMs: dateMs(1_000),
        durationState: { kind: 'timed', seconds: 10n },
        frozenCosts: null,
        catalogProvenance: provenance,
        baselineReference: baseline,
        recordID,
        nowMs: dateMs(1_000),
      });
    }
    const settled = core.settleDue(dateMs(1_010));
    expect(settled.settled.map((record) => record.recordID)).toEqual([firstID, secondID]);
    expect(settled.core.effectiveState(key)?.effectiveCompletedDistribution?.quantityAt(11)).toBe(
      2n,
    );
  });

  it('unknown/conflict/baseline mismatch fail-closed', () => {
    expectThrowsManualError(
      () =>
        coreForStatus({ status: 'unknown' }).startUpgrade({
          itemKey: key,
          fromLevel: 1,
          targetLevel: 2,
          quantity: 1n,
          startedAtMs: dateMs(1_000),
          durationState: { kind: 'instant' },
          frozenCosts: null,
          catalogProvenance: provenance,
          baselineReference: baseline,
          nowMs: dateMs(1_000),
        }),
      { kind: 'unavailableItemState', itemKey: key },
    );

    expectThrowsManualError(
      () =>
        coreForStatus({ status: 'conflict' }).startUpgrade({
          itemKey: key,
          fromLevel: 1,
          targetLevel: 2,
          quantity: 1n,
          startedAtMs: dateMs(1_000),
          durationState: { kind: 'instant' },
          frozenCosts: null,
          catalogProvenance: provenance,
          baselineReference: baseline,
          nowMs: dateMs(1_000),
        }),
      { kind: 'conflictingItemState', itemKey: key },
    );

    expectThrowsManualError(
      () =>
        coreForStatus({
          manual: distribution([[1, 1n]]),
          status: 'manualCompleted',
        }).startUpgrade({
          itemKey: key,
          fromLevel: 1,
          targetLevel: 2,
          quantity: 1n,
          startedAtMs: dateMs(1_000),
          durationState: { kind: 'instant' },
          frozenCosts: null,
          catalogProvenance: provenance,
          baselineReference: {
            revision: 'snapshot-2',
            lineageID: null,
          },
          nowMs: dateMs(1_000),
        }),
      { kind: 'baselineMismatch', itemKey: key },
    );
  });

  it('拒绝超出 materialized source 的 active reservation', () => {
    const itemState = createManualItemStateForStatus({
      itemKey: key,
      baselineReference: baseline,
      manual: distribution([[10, 1n]]),
      status: 'manualCompleted',
    });
    const record = createManualUpgradeRecord({
      recordID: id('00000000-0000-0000-0000-000000000003'),
      itemKey: key,
      fromLevel: 10,
      targetLevel: 11,
      quantity: 2n,
      startedAtMs: dateMs(1_000),
      expectedEndAtMs: dateMs(1_010),
      durationSeconds: 10n,
      durationKind: 'timed',
      frozenCosts: null,
      catalogProvenance: provenance,
      baselineReference: baseline,
    });
    expectThrowsManualError(
      () => ManualUpgradeCoreState.create({ itemStates: [itemState], records: [record] }),
      {
        kind: 'insufficientQuantity',
        level: 10,
        requested: 2n,
        available: 1n,
      },
    );
  });

  it('empty core 合法', () => {
    const core = ManualUpgradeCoreState.create();
    expect(core.itemStates).toEqual([]);
    expect(core.records).toEqual([]);
  });

  it('非整数或 NaN targetLevel 不会提交 mutation', () => {
    const before = coreForStatus({
      imported: distribution([[10, 1n]]),
      status: 'observed',
    });
    const baseInput = {
      itemKey: key,
      fromLevel: 10,
      quantity: 1n,
      startedAtMs: dateMs(1_000),
      durationState: { kind: 'instant' as const },
      frozenCosts: null,
      catalogProvenance: provenance,
      baselineReference: baseline,
      nowMs: dateMs(1_000),
    };

    for (const targetLevel of [10.5, Number.NaN]) {
      expectThrowsManualError(
        () =>
          before.startUpgrade({
            ...baseInput,
            targetLevel,
          }),
        { kind: 'invalidLevel' },
      );
      expect(before.equals(before)).toBe(true);
      expect(before.records).toHaveLength(0);
    }
  });

  it('非整数 fromLevel 在 startUpgrade 返回 invalidLevel 且不修改 core', () => {
    const before = coreForStatus({
      imported: distribution([[10, 1n]]),
      status: 'observed',
    });
    expectThrowsManualError(
      () =>
        before.startUpgrade({
          itemKey: key,
          fromLevel: -1,
          targetLevel: 11,
          quantity: 1n,
          startedAtMs: dateMs(1_000),
          durationState: { kind: 'instant' },
          frozenCosts: null,
          catalogProvenance: provenance,
          baselineReference: baseline,
          nowMs: dateMs(1_000),
        }),
      { kind: 'invalidLevel' },
    );
    expect(before.equals(before)).toBe(true);
    expect(before.activeRecords).toHaveLength(0);
  });
});

describe('ManualLevelDistribution Int64 边界', () => {
  it('总量超过 INT64_MAX 时拒绝', () => {
    expectThrowsManualError(
      () =>
        createManualLevelDistribution([
          createManualLevelQuantity(1, INT64_MAX),
          createManualLevelQuantity(2, 1n),
        ]),
      { kind: 'arithmeticOverflow' },
    );
  });

  it('fromQuantities/add 在 Int64 溢出时返回 undefined', () => {
    const almostMax = manualLevelDistributionFromQuantities(
      new Map<number, bigint>([[1, INT64_MAX]]),
    );
    expect(almostMax).toBeDefined();
    expect(manualLevelDistributionAdd(almostMax!, 2, 1n)).toBeUndefined();
  });

  it('imported observation baseline 必须匹配 item baseline', () => {
    expect(() =>
      createManualItemStateForStatus({
        itemKey: key,
        baselineReference: baseline,
        imported: distribution([[10, 1n]]),
        status: 'observed',
      }),
    ).not.toThrow();

    expect(() =>
      createManualImportedObservation({
        reference: { revision: 'snapshot-2', lineageID: null },
        levelDistribution: distribution([[10, 1n]]),
      }),
    ).not.toThrow();
  });
});
