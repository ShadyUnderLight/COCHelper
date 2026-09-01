import { describe, expect, it } from 'vitest';

import { isBaselineReconciled } from './baseline-gate';
import { createManualUpgradeCoreState } from './core';
import { createManualLevelDistributionFromPairs } from './core';
import { createManualItemStateForStatus } from './core';
import { trackerItemKeyRoot } from './types';

const baselineA = {
  revision: 'snapshot-1',
  fingerprint: 'sha256:a',
  lineageID: 'lineage-a',
};
const baselineB = {
  revision: 'snapshot-2',
  fingerprint: 'sha256:b',
  lineageID: 'lineage-b',
};
const key = trackerItemKeyRoot('home', 'buildings', 100n);

describe('isBaselineReconciled', () => {
  it('空白 core 视为已对账', () => {
    expect(
      isBaselineReconciled({
        core: createManualUpgradeCoreState(),
        currentBaseline: null,
      }),
    ).toBe(true);
  });

  it('有 ledger 但 baseline 不匹配 → 未对账', () => {
    const core = createManualUpgradeCoreState({
      itemStates: [
        createManualItemStateForStatus({
          itemKey: key,
          baselineReference: baselineA,
          imported: createManualLevelDistributionFromPairs([[1, 1n]]),
          manual: createManualLevelDistributionFromPairs([]),
          status: 'observed',
        }),
      ],
    });
    expect(
      isBaselineReconciled({
        core,
        currentBaseline: baselineB,
      }),
    ).toBe(false);
  });

  it('stored 与 current baseline 一致 → 已对账', () => {
    const core = createManualUpgradeCoreState({
      itemStates: [
        createManualItemStateForStatus({
          itemKey: key,
          baselineReference: baselineA,
          imported: createManualLevelDistributionFromPairs([[1, 1n]]),
          manual: createManualLevelDistributionFromPairs([]),
          status: 'observed',
        }),
      ],
    });
    expect(
      isBaselineReconciled({
        core,
        currentBaseline: baselineA,
      }),
    ).toBe(true);
  });

  it('current baseline 缺失 → 未对账', () => {
    const core = createManualUpgradeCoreState({
      itemStates: [
        createManualItemStateForStatus({
          itemKey: key,
          baselineReference: baselineA,
          imported: createManualLevelDistributionFromPairs([[1, 1n]]),
          manual: createManualLevelDistributionFromPairs([]),
          status: 'observed',
        }),
      ],
    });
    expect(
      isBaselineReconciled({
        core,
        currentBaseline: null,
      }),
    ).toBe(false);
  });
});
