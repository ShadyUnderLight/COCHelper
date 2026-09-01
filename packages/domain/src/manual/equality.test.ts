import { INT64_MAX, parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import {
  createManualLevelDistribution,
  createManualLevelQuantity,
  manualLevelDistributionAddChecked,
} from './level-distribution';
import {
  manualItemStatesEqual,
  manualUpgradeCoresEqual,
  manualUpgradeRecordsEqual,
} from './equality';
import { manualUpgradeErrorEquals } from './errors';
import { createManualItemStateForStatus, createManualUpgradeCoreState } from './core';
import { createManualUpgradeRecord } from './models';
import { trackerItemKeyRoot } from './types';

const key = trackerItemKeyRoot('home', 'buildings', 100n);
const baseline = {
  revision: 'snapshot-1',
  fingerprint: 'sha256:baseline',
  lineageID: 'village-1',
};
const provenance = {
  gameVersion: '18.400.13',
  buildTag: 'catalog-test',
  sourceFingerprint: 'sha256:catalog',
  manifestSchemaVersion: 1,
};
const recordId = (value: string) => parseUuid(value)!;

function expectManualError(error: unknown, expected: Parameters<typeof manualUpgradeErrorEquals>[1]) {
  expect(manualUpgradeErrorEquals(error as never, expected)).toBe(true);
}

describe('manual domain equality', () => {
  it('manualItemStatesEqual 不会因 bigint 抛异常', () => {
    const state = createManualItemStateForStatus({
      itemKey: key,
      baselineReference: baseline,
      imported: createManualLevelDistribution([createManualLevelQuantity(12, 100n)]),
      status: 'observed',
    });
    expect(manualItemStatesEqual(state, state)).toBe(true);
  });

  it('manualUpgradeRecordsEqual 比较 frozenCosts 与完整 catalog provenance', () => {
    const baseRecord = createManualUpgradeRecord({
      recordID: recordId('00000000-0000-0000-0000-000000000001'),
      itemKey: key,
      fromLevel: 10,
      targetLevel: 11,
      quantity: 1n,
      startedAtMs: 1_000_000,
      expectedEndAtMs: 1_010_000,
      durationSeconds: 10n,
      durationKind: 'timed',
      frozenCosts: [
        {
          resource: 'Gold',
          amount: 500n,
          rawResource: 'Gold',
          rawAmount: null,
          parseFailed: false,
        },
      ],
      catalogProvenance: provenance,
      baselineReference: baseline,
    });
    expect(manualUpgradeRecordsEqual(baseRecord, baseRecord)).toBe(true);

    const changedProvenance = createManualUpgradeRecord({
      ...baseRecord,
      catalogProvenance: {
        ...provenance,
        sourceFingerprint: 'sha256:changed',
      },
    });
    expect(manualUpgradeRecordsEqual(baseRecord, changedProvenance)).toBe(false);

    const changedFrozen = createManualUpgradeRecord({
      ...baseRecord,
      frozenCosts: [
        {
          resource: 'Gold',
          amount: 501n,
          rawResource: 'Gold',
          rawAmount: null,
          parseFailed: false,
        },
      ],
    });
    expect(manualUpgradeRecordsEqual(baseRecord, changedFrozen)).toBe(false);
  });

  it('ManualUpgradeCoreState.equals 与 contentFingerprint 字段集合一致', () => {
    const state = createManualItemStateForStatus({
      itemKey: key,
      baselineReference: baseline,
      manual: createManualLevelDistribution([createManualLevelQuantity(10, 1n)]),
      status: 'manualCompleted',
    });
    const record = createManualUpgradeRecord({
      recordID: recordId('00000000-0000-0000-0000-000000000002'),
      itemKey: key,
      fromLevel: 10,
      targetLevel: 11,
      quantity: 1n,
      startedAtMs: 1_000_000,
      expectedEndAtMs: 1_010_000,
      durationSeconds: 10n,
      durationKind: 'timed',
      frozenCosts: null,
      catalogProvenance: provenance,
      baselineReference: baseline,
      status: 'active',
    });
    const coreA = createManualUpgradeCoreState({ itemStates: [state], records: [record] });
    const coreB = createManualUpgradeCoreState({
      itemStates: [state],
      records: [
        createManualUpgradeRecord({
          ...record,
          catalogProvenance: {
            ...provenance,
            buildTag: 'changed-tag',
          },
        }),
      ],
    });
    expect(coreA.equals(coreA)).toBe(true);
    expect(coreA.equals(coreB)).toBe(false);
    expect(coreA.contentFingerprint).not.toBe(coreB.contentFingerprint);
    expect(manualUpgradeCoresEqual(coreA, coreB)).toBe(false);
  });
});

describe('manual Int64 invariants', () => {
  it('createManualLevelDistribution 拒绝非法 level/quantity', () => {
    expect(() =>
      createManualLevelDistribution([{ level: -1, quantity: -5n }]),
    ).toThrow();
    try {
      createManualLevelDistribution([{ level: -1, quantity: -5n }]);
    } catch (error) {
      expectManualError(error, { kind: 'invalidLevel' });
    }

    expect(() =>
      createManualLevelDistribution([{ level: 1.5, quantity: 10n } as never]),
    ).toThrow();
    try {
      createManualLevelDistribution([{ level: 1.5, quantity: 10n } as never]);
    } catch (error) {
      expectManualError(error, { kind: 'invalidLevel' });
    }
  });

  it('manualLevelDistributionAddChecked 对 invalid level 返回 invalidLevel', () => {
    const distribution = createManualLevelDistribution([createManualLevelQuantity(1, 1n)]);
    try {
      manualLevelDistributionAddChecked(distribution, -1, 1n);
      expect.unreachable('expected invalidLevel');
    } catch (error) {
      expectManualError(error, { kind: 'invalidLevel' });
    }
  });

  it('createManualUpgradeRecord 拒绝超过 INT64_MAX 的 quantity/durationSeconds', () => {
    const overflowQuantity = INT64_MAX + 1n;
    expect(() =>
      createManualUpgradeRecord({
        recordID: recordId('00000000-0000-0000-0000-000000000003'),
        itemKey: key,
        fromLevel: 10,
        targetLevel: 11,
        quantity: overflowQuantity,
        startedAtMs: 1_000_000,
        expectedEndAtMs: 1_010_000,
        durationSeconds: 10n,
        durationKind: 'timed',
        frozenCosts: null,
        catalogProvenance: provenance,
        baselineReference: baseline,
      }),
    ).toThrow();
    try {
      createManualUpgradeRecord({
        recordID: recordId('00000000-0000-0000-0000-000000000003'),
        itemKey: key,
        fromLevel: 10,
        targetLevel: 11,
        quantity: overflowQuantity,
        startedAtMs: 1_000_000,
        expectedEndAtMs: 1_010_000,
        durationSeconds: 10n,
        durationKind: 'timed',
        frozenCosts: null,
        catalogProvenance: provenance,
        baselineReference: baseline,
      });
    } catch (error) {
      expectManualError(error, { kind: 'invalidQuantity' });
    }

    expect(() =>
      createManualUpgradeRecord({
        recordID: recordId('00000000-0000-0000-0000-000000000004'),
        itemKey: key,
        fromLevel: 10,
        targetLevel: 11,
        quantity: 1n,
        startedAtMs: 1_000_000,
        expectedEndAtMs: 1_000_000,
        durationSeconds: INT64_MAX + 1n,
        durationKind: 'instant',
        frozenCosts: null,
        catalogProvenance: provenance,
        baselineReference: baseline,
      }),
    ).toThrow();
  });
});
