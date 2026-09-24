import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import {
  createManualItemStateForStatus,
  createManualLevelDistributionFromPairs,
  createManualUpgradeCoreState,
  createManualUpgradeRecord,
} from '../manual';
import { createVillageProfile } from '../import/types';
import { trackerItemKeyRoot } from '../manual/types';
import { upgradeOverviewState } from './upgrade-overview-projection';

const NOW_MS = 1_700_000_000_000;
const ITEM_KEY = trackerItemKeyRoot('home', 'buildings', 1_000_001n);
const BASELINE_REFERENCE = { revision: 'fixture-1', lineageID: null };

function completedRecord(recordID: string) {
  return createManualUpgradeRecord({
    recordID: parseUuid(recordID)!,
    itemKey: ITEM_KEY,
    fromLevel: 1,
    targetLevel: 2,
    quantity: 1n,
    startedAtMs: NOW_MS - 301_000,
    expectedEndAtMs: NOW_MS - 1_000,
    durationSeconds: 300n,
    durationKind: 'timed',
    frozenCosts: null,
    catalogProvenance: { gameVersion: '18.400.13', buildTag: null, manifestSchemaVersion: null },
    baselineReference: BASELINE_REFERENCE,
    status: 'completed',
  });
}

describe('upgrade overview recent completion identity', () => {
  it('同一项目、等级和完成时间在不同村庄仍有唯一 ID', () => {
    const villages = [
      createVillageProfile({ id: 'village-a', name: '村庄 A' }),
      createVillageProfile({ id: 'village-b', name: '村庄 B' }),
    ];
    const state = upgradeOverviewState({
      villages,
      catalog: null,
      manualUpgradeCores: {
        'village-a': createManualUpgradeCoreState({
          itemStates: [
            createManualItemStateForStatus({
              itemKey: ITEM_KEY,
              baselineReference: BASELINE_REFERENCE,
              imported: createManualLevelDistributionFromPairs([[1, 1n]]),
              manual: createManualLevelDistributionFromPairs([[2, 1n]]),
              status: 'manualCompleted',
            }),
          ],
          records: [completedRecord('00000000-0000-0000-0000-000000000001')],
        }),
        'village-b': createManualUpgradeCoreState({
          itemStates: [
            createManualItemStateForStatus({
              itemKey: ITEM_KEY,
              baselineReference: BASELINE_REFERENCE,
              imported: createManualLevelDistributionFromPairs([[1, 1n]]),
              manual: createManualLevelDistributionFromPairs([[2, 1n]]),
              status: 'manualCompleted',
            }),
          ],
          records: [completedRecord('00000000-0000-0000-0000-000000000001')],
        }),
      },
      nowMs: NOW_MS,
    });

    expect(state.completedRecently).toHaveLength(2);
    expect(new Set(state.completedRecently.map((record) => record.id)).size).toBe(2);
    expect(state.completedRecently.map((record) => record.villageID).sort()).toEqual([
      'village-a',
      'village-b',
    ]);
  });

  it('同一村庄的不同底层记录也有唯一 ID', () => {
    const village = createVillageProfile({ id: 'village-a', name: '村庄 A' });
    const state = upgradeOverviewState({
      villages: [village],
      catalog: null,
      manualUpgradeCores: {
        'village-a': createManualUpgradeCoreState({
          itemStates: [
            createManualItemStateForStatus({
              itemKey: ITEM_KEY,
              baselineReference: BASELINE_REFERENCE,
              imported: createManualLevelDistributionFromPairs([[1, 2n]]),
              manual: createManualLevelDistributionFromPairs([[2, 2n]]),
              status: 'manualCompleted',
            }),
          ],
          records: [
            completedRecord('00000000-0000-0000-0000-000000000001'),
            completedRecord('00000000-0000-0000-0000-000000000002'),
          ],
        }),
      },
      nowMs: NOW_MS,
    });

    expect(state.completedRecently).toHaveLength(2);
    expect(new Set(state.completedRecently.map((record) => record.id)).size).toBe(2);
  });
});
