import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import {
  createManualItemStateForStatus,
  createManualLevelDistributionFromPairs,
  createManualUpgradeCoreState,
  createManualTrackerVillageState,
  trackerItemKeyRoot,
  trackerItemKeyStableId,
} from '@coc-helper/domain';
import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { manualParityOutcomeHex } from './manual-parity';
import { assertParity } from './compare';
import { compareManualOutcomeParity } from './manual-parity-compare';
import { buildManualReconciliationParityCase } from './manual-reconciliation-parity-case';
import { createSwiftOracleRunner, SWIFT_ORACLE_PROTOCOL_VERSION } from './oracle';

const root = process.cwd();
const oracle = createSwiftOracleRunner({ root });
const villageID = parseUuid('00000000-0000-0000-0000-000000000143')!;
const key = trackerItemKeyRoot('home', 'buildings', 100n);
const baselineA = {
  revision: 'snapshot-1',
  lineageID: 'lineage-p1',
};

const fixturePath = resolve(
  root,
  'Tests/Golden/Fixtures/manual-reconciliation-preview-contract.json',
);
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8')) as {
  cases: readonly { id: string }[];
};
/** 与 fixture.cases 同步维护；漏加 case 会在下方静态断言失败。 */
const implementedCaseIds = ['new-observation-empty-state', 'exact-match-observed-state'] as const;

describe('manual reconciliation Swift oracle parity', () => {
  it('manifest fixture caseId 与 parity 实现一一对应', () => {
    expect([...implementedCaseIds].sort()).toEqual(fixture.cases.map((item) => item.id).sort());
  });

  it('new observation on empty state', async () => {
    await assertReconciliationParity({
      id: 'new-observation-empty-state',
      appliedAtMs: 1_700_000_200_000,
      evidence: {
        villageID,
        newBaselineReference: {
          revision: 'snapshot-2',
          lineageID: baselineA.lineageID,
        },
        newNormalizedPlayerTag: '#P1',
        sourceTimestampMs: 1_700_000_200_000,
        duplicate: false,
        lineageComparable: true,
        observations: {
          [trackerItemKeyStableId(key)]: {
            distribution: [[10, '1']],
            displayName: trackerItemKeyStableId(key),
            hasTimer: false,
            coverageComplete: true,
            distributionComplete: true,
            sectionTrustGatesOpen: true,
            timerCoverageComplete: false,
          },
        },
        itemKeys: {
          [trackerItemKeyStableId(key)]: wireItemKey(key),
        },
        previousSourceTimestampMs: 1_700_000_000_000,
      },
      currentState: createManualTrackerVillageState({
        villageID,
        core: createManualUpgradeCoreState({ itemStates: [] }),
        stateUpdatedAtMs: 1_700_000_010_000,
      }),
    });
  });

  it('exact match observed state', async () => {
    await assertReconciliationParity({
      id: 'exact-match-observed-state',
      appliedAtMs: 1_700_000_200_000,
      evidence: {
        villageID,
        newBaselineReference: {
          revision: 'snapshot-2',
          lineageID: baselineA.lineageID,
        },
        newNormalizedPlayerTag: '#P1',
        sourceTimestampMs: 1_700_000_200_000,
        duplicate: false,
        lineageComparable: true,
        observations: {
          [trackerItemKeyStableId(key)]: {
            distribution: [[10, '1']],
            displayName: trackerItemKeyStableId(key),
            hasTimer: false,
            coverageComplete: true,
            distributionComplete: true,
            sectionTrustGatesOpen: true,
            timerCoverageComplete: false,
          },
        },
        itemKeys: {
          [trackerItemKeyStableId(key)]: wireItemKey(key),
        },
        previousSourceTimestampMs: 1_700_000_000_000,
      },
      currentState: createManualTrackerVillageState({
        villageID,
        core: createManualUpgradeCoreState({
          itemStates: [
            createManualItemStateForStatus({
              itemKey: key,
              baselineReference: baselineA,
              imported: createManualLevelDistributionFromPairs([[10, 1n]]),
              status: 'observed',
              sourceTimestampMs: 1_700_000_000_000,
            }),
          ],
        }),
        stateUpdatedAtMs: 1_700_000_010_000,
      }),
    });
  });
});

async function assertReconciliationParity(
  input: Parameters<typeof buildManualReconciliationParityCase>[0],
) {
  const built = buildManualReconciliationParityCase(input);
  const source = JSON.stringify(built.request);
  const typescriptHex = manualParityOutcomeHex(built.outcome);
  const swift = await oracle({
    protocolVersion: SWIFT_ORACLE_PROTOCOL_VERSION,
    caseId: `manual-reconciliation/${input.id}`,
    operation: 'manual-reconciliation-preview',
    source,
  });
  assertParity(
    compareManualOutcomeParity({
      caseId: input.id,
      typescriptHex,
      swift,
    }),
  );
}

function wireItemKey(key: ReturnType<typeof trackerItemKeyRoot>) {
  return {
    base: key.base,
    rawSection: key.rawSection,
    dataID: Number(key.dataID),
    nestedKind: key.nestedKind,
    nestedRootIdentity: null,
    nestedPath: [],
  };
}
