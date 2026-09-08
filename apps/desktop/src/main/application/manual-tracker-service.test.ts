import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { manualStartRequestSchema } from '@coc-helper/contracts';
import {
  bootstrapPersistence,
  createManualItemStateForStatus,
  createManualLevelDistributionFromPairs,
  createManualTrackerVillageState,
  createManualUpgradeCoreState,
  loadCatalogBundle,
  ManualUpgradeCoreState,
  manualLevelDistributionsEqual,
  manualTrackerEnvelopeState,
  PERSISTENCE_FILE_NAMES,
  projectBuildingGroupsFromProjection,
  projectUpgradeActionsForBuildingGroup,
  projectVillageCatalog,
  resolveCatalogBundleRoot,
  trackerItemKeyRoot,
  trackerItemKeyStableId,
  upsertManualTrackerVillageState,
  type CatalogBundle,
  type ElectronPersistencePaths,
  type UpgradeAction,
} from '@coc-helper/domain';
import { parseUuid } from '@coc-helper/wire';
import { afterEach, describe, expect, it } from 'vitest';

import { AppServiceError } from './app-authoritative-state';
import { createApplicationServices } from './application-services';
import { bootApplicationServices } from './app-lifecycle-service';
import { type ManualCatalogPort } from './manual-tracker-service';
import { createApplicationServicesFromPersistence } from './persistence-boundary';

class FakeClock {
  constructor(private readonly fixedMs: number) {}
  nowMs(): number {
    return this.fixedMs;
  }
}

const tempRoots: string[] = [];

function pathsFor(root: string): ElectronPersistencePaths {
  return {
    root,
    villages: join(root, PERSISTENCE_FILE_NAMES.villages),
    villagesRecovery: join(root, PERSISTENCE_FILE_NAMES.villagesRecovery),
    selection: join(root, PERSISTENCE_FILE_NAMES.selection),
    snapshotHistory: join(root, PERSISTENCE_FILE_NAMES.snapshotHistory),
    snapshotHistoryJournal: join(root, PERSISTENCE_FILE_NAMES.snapshotHistoryJournal),
    manualTracker: join(root, PERSISTENCE_FILE_NAMES.manualTracker),
    manualTrackerJournal: join(root, PERSISTENCE_FILE_NAMES.manualTrackerJournal),
    snapshotImportJournal: join(root, PERSISTENCE_FILE_NAMES.snapshotImportJournal),
    clans: join(root, PERSISTENCE_FILE_NAMES.clans),
    clanWars: join(root, PERSISTENCE_FILE_NAMES.clanWars),
    clanWarLogs: join(root, PERSISTENCE_FILE_NAMES.clanWarLogs),
    clanCapitals: join(root, PERSISTENCE_FILE_NAMES.clanCapitals),
    playerStates: join(root, PERSISTENCE_FILE_NAMES.playerStates),
    trackedClans: join(root, PERSISTENCE_FILE_NAMES.trackedClans),
    apiTokenEncrypted: join(root, PERSISTENCE_FILE_NAMES.apiTokenEncrypted),
  };
}

function bootServices(catalog?: ManualCatalogPort) {
  const root = mkdtempSync(join(tmpdir(), 'coc-e302-s3-'));
  tempRoots.push(root);
  const persistence = bootstrapPersistence({ paths: pathsFor(root) });
  if (catalog === undefined) {
    return createApplicationServicesFromPersistence(persistence, new FakeClock(1_700_000_000_000));
  }
  const clock = new FakeClock(1_700_000_000_000);
  const boot = bootApplicationServices({ clock, persistence });
  return createApplicationServices({ clock, boot, catalog });
}

async function loadRealBundle(): Promise<CatalogBundle> {
  const root = resolveCatalogBundleRoot(process.cwd());
  if (root === null) {
    throw new Error('测试找不到 GameCatalog');
  }
  return loadCatalogBundle({ root });
}

function deferredCatalogPort(bundle: CatalogBundle): ManualCatalogPort & {
  readonly resolve: () => void;
} {
  let settle: ((value: CatalogBundle) => void) | null = null;
  const pending = new Promise<CatalogBundle>((resolve) => {
    settle = resolve;
  });
  return {
    getBundle: () => pending,
    resolve: () => {
      if (settle === null) {
        throw new Error('catalog Promise 尚未挂起');
      }
      settle(bundle);
    },
  };
}

function itemKeyDto(dataID = 1_000_001) {
  const key = trackerItemKeyRoot('home', 'buildings', BigInt(dataID));
  return {
    base: key.base,
    rawSection: key.rawSection,
    dataID,
    nestedKind: key.nestedKind,
    nestedRootIdentity: null,
    nestedPath: [] as const,
    stableId: trackerItemKeyStableId(key),
  };
}

function trackerItemKeyDtoFromAction(action: UpgradeAction) {
  const key = action.itemKey;
  return {
    base: key.base,
    rawSection: key.rawSection,
    dataID: Number(key.dataID),
    nestedKind: key.nestedKind,
    nestedRootIdentity:
      key.nestedRootIdentity === null
        ? null
        : {
            base: key.nestedRootIdentity.base,
            rawSection: key.nestedRootIdentity.rawSection,
            dataID: Number(key.nestedRootIdentity.dataID),
          },
    nestedPath: key.nestedPath.map((component) => ({
      kind: component.kind,
      dataID: Number(component.dataID),
    })),
    stableId: trackerItemKeyStableId(key),
  };
}

function findStartableGroupAction(input: {
  readonly village: ReturnType<ReturnType<typeof bootServices>['state']['listVillages']>[number];
  readonly core: ManualUpgradeCoreState;
  readonly bundle: CatalogBundle;
}): UpgradeAction {
  const projection = projectVillageCatalog({
    village: input.village,
    catalog: input.bundle.gameCatalog,
    craftTableCatalog: input.bundle.craftTableCatalog,
    seasonalPhases: input.bundle.seasonalPhaseTable,
    base: 'home',
    nowMs: 1_700_000_000_000,
    manualUpgradeCore: input.core,
  });
  const groups = projectBuildingGroupsFromProjection({
    projection,
    catalog: input.bundle.gameCatalog,
    base: 'home',
    manualUpgradeCore: input.core,
  });
  for (const group of groups) {
    for (const action of projectUpgradeActionsForBuildingGroup({
      group,
      catalog: input.bundle.gameCatalog,
    })) {
      if (
        action.isStartable &&
        action.sourceKind === 'group' &&
        action.fromLevel !== null &&
        action.targetLevel !== null &&
        action.baselineReference !== null &&
        action.catalogProvenance !== null
      ) {
        return action;
      }
    }
  }
  throw new Error('测试未找到可启动的 group upgrade action');
}

afterEach(() => {
  while (tempRoots.length > 0) {
    const root = tempRoots.pop();
    if (root !== undefined) {
      rmSync(root, { recursive: true, force: true });
    }
  }
});

describe('ManualTrackerService（#276-S3）', () => {
  it('manual.state 只读且不 bump generation', () => {
    const services = bootServices();
    expect(services.manual).not.toBeNull();
    const villageId = services.state.listVillages()[0]!.id;
    const before = services.state.getGeneration();
    const state = services.manual!.getState({ villageId });
    expect(state.generation).toBe(before);
    expect(services.state.getGeneration()).toBe(before);
    expect(state.status === 'missing' || state.status === 'empty').toBe(true);
  });

  it('settle 无记录时不 bump generation', () => {
    const services = bootServices();
    const before = services.state.getGeneration();
    const settled = services.manual!.settle({ expectedGeneration: before });
    expect(settled.settledCount).toBe(0);
    expect(services.state.getGeneration()).toBe(before);
  });

  it('import.commit 写入 manual 后 getState 可见', () => {
    const services = bootServices();
    const prepared = services.imports.prepare({
      text: '{"tag":"#S3OK","buildings":[{"data":1000001,"lvl":1,"cnt":1}]}',
    });
    services.imports.commit(prepared.generation);
    const villageId = services.state.listVillages().find((village) => village.tag === '#S3OK')!.id;
    const state = services.manual!.getState({ villageId });
    expect(state.status).toBe('available');
    expect(state.baselineRevision).not.toBeNull();
    expect(state.itemStateCount).toBeGreaterThanOrEqual(0);
  });

  it('buildReconciledManualEnvelope 在真实 duplicate decision 下保留 manualCompleted', () => {
    const text =
      '{"tag":"#DUP","timestamp":1700000000,"buildings":[{"data":1000001,"lvl":10,"cnt":1}]}';
    const services = bootServices();
    services.imports.commit(services.imports.prepare({ text }).generation);
    const villageId = services.state.listVillages().find((village) => village.tag === '#DUP')!.id;
    const villageID = parseUuid(villageId)!;
    const itemKey = trackerItemKeyRoot('home', 'buildings', 1_000_001n);

    const envelope = services.boot.persistence!.manual!.load()!;
    const villageState = manualTrackerEnvelopeState(envelope, villageID)!;
    const existing = villageState.core.itemState(itemKey);
    expect(existing).toBeDefined();
    const aheadDist = createManualLevelDistributionFromPairs([[11, 1n]]);
    const seeded = upsertManualTrackerVillageState(
      envelope,
      createManualTrackerVillageState({
        villageID,
        core: createManualUpgradeCoreState({
          itemStates: [
            createManualItemStateForStatus({
              itemKey,
              baselineReference: existing!.baselineReference,
              imported: createManualLevelDistributionFromPairs([[10, 1n]]),
              manual: aheadDist,
              status: 'manualCompleted',
              sourceTimestampMs: 1_700_000_000_000,
            }),
          ],
        }),
        stateUpdatedAtMs: 1_700_000_000_100,
        lastImportAtMs: villageState.lastImportAtMs,
        diagnostics: villageState.diagnostics,
        reconciliationHistory: villageState.reconciliationHistory,
        queueCapacityConfigs: villageState.queueCapacityConfigs,
        queueAssignments: villageState.queueAssignments,
      }),
    );
    services.boot.persistence!.manual!.save(seeded);

    const history = services.boot.persistence!.history!.load()!;
    const active = history.entries.find((entry) => entry.villageID === villageId)!;
    const duplicateEnvelope = {
      ...history,
      duplicateMetadata: {
        ...history.duplicateMetadata,
        [active.snapshotID]: {
          lastSeenAtRefSeconds: active.appliedAtRefSeconds,
          lastSourceTimestampRefSeconds: active.sourceTimestampRefSeconds,
          duplicateImportCount: 1,
        },
      },
    };
    const reconciled = services.manual!.buildReconciledManualEnvelope({
      villageID,
      previousEntry: active,
      decision: {
        envelope: duplicateEnvelope,
        entry: active,
        lineage: {
          lineageID: active.lineageID,
          outcome: 'continued',
          reason: 'sameVillageAndTag',
          isBaseline: false,
          comparisonAllowed: true,
        },
        appended: false,
        duplicate: true,
      },
      appliedAtMs: 1_700_000_000_200,
      reconciliationDecision: 'applyNonConflicting',
      seedEnvelope: seeded,
    });

    expect(reconciled.duplicate).toBe(true);
    expect(reconciled.envelope).toBeDefined();
    const after = manualTrackerEnvelopeState(reconciled.envelope, villageID)!;
    expect(after.baselineReference?.revision.endsWith(':observation:1')).toBe(true);
    expect(
      manualLevelDistributionsEqual(
        after.core.effectiveState(itemKey)!.effectiveCompletedDistribution!,
        aheadDist,
      ),
    ).toBe(true);
    expect(after.core.itemState(itemKey)?.status).toBe('manualCompleted');
  });

  it('stale expectedGeneration 拒绝 settle', () => {
    const services = bootServices();
    expect(() => services.manual!.settle({ expectedGeneration: 999 })).toThrow(AppServiceError);
  });

  it('catalog await 期间发生并发写入时，start 在 CAS 后拒绝且不覆盖', async () => {
    const bundle = await loadRealBundle();
    const catalog = deferredCatalogPort(bundle);
    const services = bootServices(catalog);
    const prepared = services.imports.prepare({
      text: '{"tag":"#RACE","buildings":[{"data":1000001,"lvl":1,"cnt":1}]}',
    });
    services.imports.commit(prepared.generation);
    const villageId = services.state.listVillages().find((village) => village.tag === '#RACE')!.id;
    const generationBefore = services.state.getGeneration();
    const baselineBefore = services.manual!.getState({ villageId }).baselineRevision;

    const pending = services.manual!.start({
      expectedGeneration: generationBefore,
      villageId,
      itemKey: itemKeyDto(),
      fromLevel: 1,
      targetLevel: 2,
      quantity: 1,
      startedAtMs: 1_700_000_000_000,
      sourceKind: 'row',
      base: 'home',
    });
    await Promise.resolve();

    const concurrent = services.imports.prepare({
      text: '{"tag":"#RACE","buildings":[{"data":1000001,"lvl":2,"cnt":1}]}',
      villageId,
    });
    services.imports.commit(concurrent.generation);
    const generationAfter = services.state.getGeneration();
    expect(generationAfter).toBeGreaterThan(generationBefore);
    const baselineAfter = services.manual!.getState({ villageId }).baselineRevision;
    expect(baselineAfter).not.toBe(baselineBefore);

    catalog.resolve();
    await expect(pending).rejects.toMatchObject({ code: 'conflict' });
    expect(services.state.getGeneration()).toBe(generationAfter);
    expect(services.manual!.getState({ villageId }).baselineRevision).toBe(baselineAfter);
  });

  it('reconcile 不走 planImport：不增加 history duplicate，且 keepLocal 保留本地领先进度', () => {
    const services = bootServices();
    const prepared = services.imports.prepare({
      text: '{"tag":"#KEEP","buildings":[{"data":1000001,"lvl":1,"cnt":1}]}',
    });
    services.imports.commit(prepared.generation);
    const villageId = services.state.listVillages().find((village) => village.tag === '#KEEP')!.id;
    const villageID = parseUuid(villageId)!;

    const historyBefore = services.boot.persistence!.history!.load()!;
    const snapshotID = historyBefore.entries.find(
      (entry) => entry.villageID === villageId,
    )!.snapshotID;
    const duplicateBefore = historyBefore.duplicateMetadata[snapshotID]?.duplicateImportCount ?? 0;
    const entryCountBefore = historyBefore.entries.length;

    const envelope = services.boot.persistence!.manual!.load()!;
    const villageState = manualTrackerEnvelopeState(envelope, villageID)!;
    const itemKey = trackerItemKeyRoot('home', 'buildings', 1_000_001n);
    const existing = villageState.core.itemState(itemKey);
    expect(existing).toBeDefined();
    const aheadDist = createManualLevelDistributionFromPairs([[2, 1n]]);
    const localAhead = createManualTrackerVillageState({
      villageID,
      core: createManualUpgradeCoreState({
        itemStates: [
          createManualItemStateForStatus({
            itemKey,
            baselineReference: existing!.baselineReference,
            imported: aheadDist,
            status: 'observed',
            sourceTimestampMs: 1_700_000_000_000,
          }),
        ],
      }),
      stateUpdatedAtMs: 1_700_000_000_100,
      lastImportAtMs: villageState.lastImportAtMs,
      diagnostics: villageState.diagnostics,
      reconciliationHistory: villageState.reconciliationHistory,
      queueCapacityConfigs: villageState.queueCapacityConfigs,
      queueAssignments: villageState.queueAssignments,
    });
    services.boot.persistence!.manual!.save(upsertManualTrackerVillageState(envelope, localAhead));

    const generation = services.state.getGeneration();
    const result = services.manual!.reconcile({
      expectedGeneration: generation,
      villageId,
      decision: 'keepLocal',
    });
    expect(result.duplicate).toBe(false);

    const historyAfter = services.boot.persistence!.history!.load()!;
    expect(historyAfter.entries.length).toBe(entryCountBefore);
    expect(historyAfter.duplicateMetadata[snapshotID]?.duplicateImportCount ?? 0).toBe(
      duplicateBefore,
    );

    const afterState = manualTrackerEnvelopeState(
      services.boot.persistence!.manual!.load()!,
      villageID,
    )!;
    const effective = afterState.core.effectiveState(itemKey)!;
    expect(
      manualLevelDistributionsEqual(effective.effectiveCompletedDistribution!, aheadDist),
    ).toBe(true);
  });

  it('IPC schema 拒绝非法 nestedKind', () => {
    const parsed = manualStartRequestSchema.safeParse({
      expectedGeneration: 0,
      villageId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      itemKey: {
        ...itemKeyDto(),
        nestedKind: 'banana',
      },
      fromLevel: 1,
      targetLevel: 2,
      quantity: 1,
      startedAtMs: 1,
      sourceKind: 'row',
      base: 'home',
    });
    expect(parsed.success).toBe(false);
  });

  it('合法 group action 可 start；改 stale sourceKind/from/target 会 conflict', async () => {
    const bundle = await loadRealBundle();
    const services = bootServices({
      getBundle: async () => bundle,
    });
    const prepared = services.imports.prepare({
      text: '{"tag":"#GRP","buildings":[{"data":1000001,"lvl":1,"cnt":1}]}',
    });
    services.imports.commit(prepared.generation);
    const village = services.state.listVillages().find((entry) => entry.tag === '#GRP')!;
    const villageID = parseUuid(village.id)!;
    const villageState = manualTrackerEnvelopeState(
      services.boot.persistence!.manual!.load()!,
      villageID,
    )!;
    const action = findStartableGroupAction({
      village,
      core: villageState.core as ManualUpgradeCoreState,
      bundle,
    });

    const generation = services.state.getGeneration();
    const started = await services.manual!.start({
      expectedGeneration: generation,
      villageId: village.id,
      itemKey: trackerItemKeyDtoFromAction(action),
      fromLevel: action.fromLevel!,
      targetLevel: action.targetLevel!,
      quantity: Number(action.quantity),
      startedAtMs: 1_700_000_000_000,
      sourceKind: 'group',
      base: 'home',
    });
    expect(started.record.status).toBe('active');
    expect(started.generation).toBeGreaterThan(generation);

    const staleGeneration = services.state.getGeneration();
    await expect(
      services.manual!.start({
        expectedGeneration: staleGeneration,
        villageId: village.id,
        itemKey: trackerItemKeyDtoFromAction(action),
        fromLevel: action.fromLevel!,
        targetLevel: action.targetLevel!,
        quantity: Number(action.quantity),
        startedAtMs: 1_700_000_000_100,
        sourceKind: 'row',
        base: 'home',
      }),
    ).rejects.toMatchObject({ code: 'conflict' });

    await expect(
      services.manual!.start({
        expectedGeneration: staleGeneration,
        villageId: village.id,
        itemKey: trackerItemKeyDtoFromAction(action),
        fromLevel: action.fromLevel! + 1,
        targetLevel: action.targetLevel! + 1,
        quantity: Number(action.quantity),
        startedAtMs: 1_700_000_000_100,
        sourceKind: 'group',
        base: 'home',
      }),
    ).rejects.toMatchObject({ code: 'conflict' });
  });
});
