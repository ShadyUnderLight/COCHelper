import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import {
  createLocalQueueCapacityConfig,
  createManualUpgradeCoreState,
  createManualItemStateForStatus,
  createManualLevelDistributionFromPairs,
  createManualUpgradeRecord,
  LOCAL_QUEUE_KIND_BUILDER,
  LOCAL_QUEUE_KIND_LABORATORY,
  localQueueOccupancyIsFull,
  resolveLocalQueueOccupancy,
  trackerItemKeyRoot,
  validateStartAgainstQueueCapacity,
} from '@coc-helper/domain';
import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { manualParityOutcomeHex } from './manual-parity';
import { assertParity } from './compare';
import { compareManualOutcomeParity } from './manual-parity-compare';
import { createSwiftOracleRunner, SWIFT_ORACLE_PROTOCOL_VERSION } from './oracle';

type StartGateCase = {
  readonly id: string;
  readonly itemSection: string;
  readonly requestedQueueKind: string | null;
  readonly builderCapacity?: number;
  readonly expectedError: string | null;
};

type OccupancyCase = {
  readonly id: string;
  readonly targetQueueKind: string;
  readonly builderCapacity: number;
  readonly records: readonly { readonly rawSection: string; readonly queueKind: string | null }[];
  readonly expectedActiveManualCount: number;
  readonly expectedFull: boolean;
};

const villageID = parseUuid('00000000-0000-0000-0000-000000000001')!;
const currentBaseline = {
  revision: 'rev',
  lineageID: 'lineage-1',
};
const provenance = {
  gameVersion: '18.400.13',
  buildTag: null,
  manifestSchemaVersion: null,
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

const root = process.cwd();
const oracle = createSwiftOracleRunner({ root });

function queueKindFromToken(token: string | null) {
  if (token === null) {
    return null;
  }
  if (token === 'builder') {
    return LOCAL_QUEUE_KIND_BUILDER;
  }
  if (token === 'laboratory') {
    return LOCAL_QUEUE_KIND_LABORATORY;
  }
  throw new Error(`unsupported queue kind token: ${token}`);
}

function activeRecord(input: { readonly rawSection: string; readonly queueKind: string | null }) {
  return createManualUpgradeRecord({
    recordID: parseUuid('00000000-0000-0000-0000-000000000010')!,
    itemKey: trackerItemKeyRoot('home', input.rawSection, 1_000_002n),
    fromLevel: 1,
    targetLevel: 2,
    quantity: 1n,
    startedAtMs: 1_000_000,
    expectedEndAtMs: 3_600_000,
    durationSeconds: 2_600n,
    durationKind: 'timed',
    frozenCosts: null,
    catalogProvenance: provenance,
    baselineReference: currentBaseline,
    queueKind: input.queueKind,
    status: 'active',
  });
}

describe('manual queue capacity contract parity seed', () => {
  const fixturePath = resolve(root, 'Tests/Golden/Fixtures/manual-queue-capacity-contract.json');
  const fixture = JSON.parse(readFileSync(fixturePath, 'utf8')) as {
    startGateCases: readonly StartGateCase[];
    occupancyCases: readonly OccupancyCase[];
  };

  for (const contractCase of fixture.startGateCases) {
    it(`start gate / ${contractCase.id}`, () => {
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

      const result = validateStartAgainstQueueCapacity({
        itemKey: trackerItemKeyRoot('home', contractCase.itemSection, 1_000_002n),
        durationState: { kind: 'timed', seconds: 60n },
        core,
        queueCapacityConfigs,
        queueAssignments: [],
        currentBaseline,
        storeAvailable: true,
        requestedQueueKind: queueKindFromToken(contractCase.requestedQueueKind),
        nowMs: 1_000_000,
      });

      if (contractCase.expectedError === null) {
        expect(result).toBeNull();
        return;
      }
      expect(result?.kind).toBe(contractCase.expectedError);
    });
  }

  for (const contractCase of fixture.occupancyCases) {
    it(`occupancy / ${contractCase.id}`, () => {
      const queueKind =
        contractCase.targetQueueKind === 'builder'
          ? LOCAL_QUEUE_KIND_BUILDER
          : LOCAL_QUEUE_KIND_LABORATORY;
      const occupancy = resolveLocalQueueOccupancy({
        queueKind,
        activeRecords: contractCase.records.map(activeRecord),
        capacityConfig: createLocalQueueCapacityConfig({
          villageID,
          queueKind,
          capacity: contractCase.builderCapacity,
          updatedAtMs: 1_000_000,
        }),
        nowMs: 1_000_000,
      });
      expect(occupancy.activeManualCount).toBe(contractCase.expectedActiveManualCount);
      expect(localQueueOccupancyIsFull(occupancy)).toBe(contractCase.expectedFull);
    });
  }
});

describe('manual queue capacity Swift oracle parity', () => {
  const fixturePath = resolve(root, 'Tests/Golden/Fixtures/manual-queue-capacity-contract.json');
  const fixture = JSON.parse(readFileSync(fixturePath, 'utf8')) as {
    startGateCases: readonly StartGateCase[];
    occupancyCases: readonly OccupancyCase[];
  };

  for (const contractCase of fixture.startGateCases) {
    it(`start gate / ${contractCase.id}`, async () => {
      const source = JSON.stringify({
        kind: 'startGate',
        itemSection: contractCase.itemSection,
        requestedQueueKind: contractCase.requestedQueueKind,
        builderCapacity: contractCase.builderCapacity ?? null,
      });
      const result = validateStartAgainstQueueCapacity({
        itemKey: trackerItemKeyRoot('home', contractCase.itemSection, 1_000_002n),
        durationState: { kind: 'timed', seconds: 60n },
        core,
        queueCapacityConfigs:
          contractCase.builderCapacity === undefined
            ? []
            : [
                createLocalQueueCapacityConfig({
                  villageID,
                  queueKind: LOCAL_QUEUE_KIND_BUILDER,
                  capacity: contractCase.builderCapacity,
                  updatedAtMs: 1_000_000,
                }),
              ],
        queueAssignments: [],
        currentBaseline,
        storeAvailable: true,
        requestedQueueKind: queueKindFromToken(contractCase.requestedQueueKind),
        nowMs: 1_000_000,
      });
      const typescriptHex = manualParityOutcomeHex({
        errorKind: result?.kind ?? null,
      });
      const swift = await oracle({
        protocolVersion: SWIFT_ORACLE_PROTOCOL_VERSION,
        caseId: `manual-queue-capacity/startGate/${contractCase.id}`,
        operation: 'manual-queue-capacity',
        source,
      });
      assertParity(
        compareManualOutcomeParity({
          caseId: contractCase.id,
          source,
          typescriptHex,
          swift,
        }),
      );
    });
  }

  for (const contractCase of fixture.occupancyCases) {
    it(`occupancy / ${contractCase.id}`, async () => {
      const source = JSON.stringify({
        kind: 'occupancy',
        targetQueueKind: contractCase.targetQueueKind,
        builderCapacity: contractCase.builderCapacity,
        records: contractCase.records,
      });
      const queueKind =
        contractCase.targetQueueKind === 'builder'
          ? LOCAL_QUEUE_KIND_BUILDER
          : LOCAL_QUEUE_KIND_LABORATORY;
      const occupancy = resolveLocalQueueOccupancy({
        queueKind,
        activeRecords: contractCase.records.map(activeRecord),
        capacityConfig: createLocalQueueCapacityConfig({
          villageID,
          queueKind,
          capacity: contractCase.builderCapacity,
          updatedAtMs: 1_000_000,
        }),
        nowMs: 1_000_000,
      });
      const typescriptHex = manualParityOutcomeHex({
        activeManualCount: occupancy.activeManualCount,
        full: localQueueOccupancyIsFull(occupancy) ? 1 : 0,
      });
      const swift = await oracle({
        protocolVersion: SWIFT_ORACLE_PROTOCOL_VERSION,
        caseId: `manual-queue-capacity/occupancy/${contractCase.id}`,
        operation: 'manual-queue-capacity',
        source,
      });
      assertParity(
        compareManualOutcomeParity({
          caseId: contractCase.id,
          source,
          typescriptHex,
          swift,
        }),
      );
    });
  }
});
