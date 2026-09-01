import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import {
  createLocalQueueCapacityConfig,
  createManualUpgradeCoreState,
  createManualItemStateForStatus,
  createManualLevelDistributionFromPairs,
  LOCAL_QUEUE_KIND_BUILDER,
  LOCAL_QUEUE_KIND_EQUIPMENT,
  LOCAL_QUEUE_KIND_HERO,
  trackerItemKeyRoot,
  validateStartAgainstQueueCapacity,
} from '@coc-helper/domain';
import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

type ContractCase = {
  readonly id: string;
  readonly requestedQueueKind: string | null;
  readonly builderCapacity?: number;
  readonly heroCapacity?: number;
  readonly equipmentCapacity?: number;
  readonly expectedError: string | null;
};

const villageID = parseUuid('00000000-0000-0000-0000-000000000001')!;
const currentBaseline = {
  revision: 'rev',
  fingerprint: 'fp',
  lineageID: 'lineage-1',
};
const core = createManualUpgradeCoreState({
  itemStates: [
    createManualItemStateForStatus({
      itemKey: trackerItemKeyRoot('home', 'buildings', 1_000_002n),
      baselineReference: currentBaseline,
      status: 'manualCompleted',
      manual: createManualLevelDistributionFromPairs([]),
    }),
  ],
});

describe('manual queue capacity contract parity seed', () => {
  const fixturePath = resolve(
    process.cwd(),
    'Tests/Golden/Fixtures/manual-queue-capacity-contract.json',
  );
  const fixture = JSON.parse(readFileSync(fixturePath, 'utf8')) as {
    cases: readonly ContractCase[];
  };

  for (const contractCase of fixture.cases) {
    it(contractCase.id, () => {
      const queueCapacityConfigs = [];
      if (contractCase.builderCapacity !== undefined) {
        queueCapacityConfigs.push(
          createLocalQueueCapacityConfig({
            villageID,
            queueKind: LOCAL_QUEUE_KIND_BUILDER,
            capacity: contractCase.builderCapacity,
            updatedAtMs: 1_000_000,
          }),
        );
      }
      if (contractCase.heroCapacity !== undefined) {
        queueCapacityConfigs.push(
          createLocalQueueCapacityConfig({
            villageID,
            queueKind: LOCAL_QUEUE_KIND_HERO,
            capacity: contractCase.heroCapacity,
            updatedAtMs: 1_000_000,
          }),
        );
      }
      if (contractCase.equipmentCapacity !== undefined) {
        queueCapacityConfigs.push(
          createLocalQueueCapacityConfig({
            villageID,
            queueKind: LOCAL_QUEUE_KIND_EQUIPMENT,
            capacity: contractCase.equipmentCapacity,
            updatedAtMs: 1_000_000,
          }),
        );
      }

      const requestedQueueKind =
        contractCase.requestedQueueKind === null
          ? null
          : contractCase.requestedQueueKind === 'builder'
            ? LOCAL_QUEUE_KIND_BUILDER
            : contractCase.requestedQueueKind === 'hero'
              ? LOCAL_QUEUE_KIND_HERO
              : LOCAL_QUEUE_KIND_EQUIPMENT;

      const result = validateStartAgainstQueueCapacity({
        durationState: { kind: 'timed', seconds: 60n },
        core,
        queueCapacityConfigs,
        queueAssignments: [],
        currentBaseline,
        storeAvailable: true,
        requestedQueueKind,
        nowMs: 1_000_000,
      });

      if (contractCase.expectedError === null) {
        expect(result).toBeNull();
        return;
      }
      expect(result?.kind).toBe(contractCase.expectedError);
    });
  }
});
