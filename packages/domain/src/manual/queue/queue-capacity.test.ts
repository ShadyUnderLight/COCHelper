import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import {
  createLocalQueueCapacityConfig,
  localQueueCapacityConfigErrorsEqual,
  LOCAL_QUEUE_CAPACITY_MAXIMUM,
} from './capacity-config';
import { validateProjectedQueueCapacity, validateStartAgainstQueueCapacity } from './capacity-gate';
import {
  createLocalQueueKind,
  effectiveLocalQueueKindForRecord,
  LOCAL_QUEUE_KIND_BUILDER,
  LOCAL_QUEUE_KIND_EQUIPMENT,
  LOCAL_QUEUE_KIND_HERO,
  LOCAL_QUEUE_KIND_LABORATORY,
  LOCAL_QUEUE_KNOWN_KINDS,
  localQueueKindDisplayName,
  localQueueKindIsKnown,
  suggestedLocalQueueKindForItemKey,
  suggestedLocalQueueKindForItemKeyAndDuration,
  type LocalQueueKind,
} from './local-queue-kind';
import {
  createLocalQueueOccupancy,
  localQueueOccupancyAvailableSlots,
  localQueueOccupancyIsFull,
  resolveLocalQueueOccupancy,
} from './occupancy';
import { projectQueueOccupancy } from './occupancy-projection';
import { createQueueAssignmentDecision, queueAssignmentErrorsEqual } from './queue-assignment';
import {
  createManualUpgradeCoreState,
  createManualItemStateForStatus,
  createManualLevelDistributionFromPairs,
} from '../core';
import { createManualUpgradeRecord } from '../models';
import { trackerItemKeyRoot } from '../types';

const villageID = parseUuid('00000000-0000-0000-0000-000000000001')!;
const baseline = {
  revision: 'rev',
  fingerprint: 'fp',
  lineageID: 'lineage-1',
};
const provenance = {
  gameVersion: '18.400.13',
  buildTag: null,
  sourceFingerprint: null,
  manifestSchemaVersion: null,
};

function record(input: {
  readonly queueKind?: string | null;
  readonly status?: 'active' | 'completed' | 'cancelled';
  readonly rawSection?: string;
  readonly expectedEndAtMs?: number;
}) {
  return createManualUpgradeRecord({
    recordID: parseUuid('00000000-0000-0000-0000-000000000010')!,
    itemKey: trackerItemKeyRoot('home', input.rawSection ?? 'buildings', 1_000_002n),
    fromLevel: 1,
    targetLevel: 2,
    quantity: 1n,
    startedAtMs: 1_000_000,
    expectedEndAtMs: input.expectedEndAtMs ?? 3_600_000,
    durationSeconds: 2_600n,
    durationKind: 'timed',
    frozenCosts: null,
    catalogProvenance: provenance,
    baselineReference: baseline,
    queueKind: input.queueKind === undefined ? 'builder' : input.queueKind,
    status: input.status ?? 'active',
  });
}

function configForKind(queueKind: LocalQueueKind, capacity: number) {
  return createLocalQueueCapacityConfig({
    villageID,
    queueKind,
    capacity,
    updatedAtMs: 1_000_000,
  });
}

function config(capacity: number) {
  return configForKind(LOCAL_QUEUE_KIND_BUILDER, capacity);
}

function assignment(input: {
  readonly queueKind?: typeof LOCAL_QUEUE_KIND_BUILDER | typeof LOCAL_QUEUE_KIND_LABORATORY;
  readonly status?: 'userAssigned' | 'observedOnly' | 'unknown';
  readonly rawSection?: string;
}) {
  return createQueueAssignmentDecision({
    decisionID: parseUuid('00000000-0000-0000-0000-000000000020')!,
    villageID,
    itemKey: trackerItemKeyRoot('home', input.rawSection ?? 'buildings', 1_000_003n),
    baselineReference: baseline,
    queueKind: input.queueKind ?? LOCAL_QUEUE_KIND_BUILDER,
    decidedAtMs: 1_000_000,
    status: input.status ?? 'userAssigned',
  });
}

describe('LocalQueueKind', () => {
  it('已知类别与展示名', () => {
    expect(localQueueKindIsKnown(LOCAL_QUEUE_KIND_BUILDER)).toBe(true);
    expect(localQueueKindIsKnown(LOCAL_QUEUE_KIND_LABORATORY)).toBe(true);
    expect(localQueueKindIsKnown(LOCAL_QUEUE_KIND_HERO)).toBe(true);
    expect(localQueueKindIsKnown(LOCAL_QUEUE_KIND_EQUIPMENT)).toBe(true);
    expect(LOCAL_QUEUE_KNOWN_KINDS).toEqual([
      LOCAL_QUEUE_KIND_BUILDER,
      LOCAL_QUEUE_KIND_LABORATORY,
      LOCAL_QUEUE_KIND_HERO,
      LOCAL_QUEUE_KIND_EQUIPMENT,
    ]);
    expect(localQueueKindDisplayName(LOCAL_QUEUE_KIND_BUILDER)).toBe('建筑工人');
    expect(localQueueKindDisplayName(LOCAL_QUEUE_KIND_HERO)).toBe('英雄');
    expect(localQueueKindDisplayName(LOCAL_QUEUE_KIND_EQUIPMENT)).toBe('装备');
  });

  it('section 映射到 UI 推荐类别（不是容量 gate evidence）', () => {
    const cases: Array<[string, string | null]> = [
      ['buildings', 'builder'],
      ['buildings2', 'builder'],
      ['traps', 'builder'],
      ['heroes', 'hero'],
      ['units', 'laboratory'],
      ['spells', 'laboratory'],
      ['siege_machines', 'laboratory'],
      ['equipment', 'equipment'],
      ['pets', null],
      ['future', null],
    ];
    for (const [section, expected] of cases) {
      const key = trackerItemKeyRoot('home', section, 1n);
      const kind = suggestedLocalQueueKindForItemKey(key);
      expect(kind?.rawValue ?? null).toBe(expected);
    }
  });

  it('instant 不占容量', () => {
    const key = trackerItemKeyRoot('home', 'buildings', 1n);
    expect(suggestedLocalQueueKindForItemKeyAndDuration(key, { kind: 'instant' })).toBeNull();
    expect(
      suggestedLocalQueueKindForItemKeyAndDuration(key, { kind: 'timed', seconds: 60n }),
    ).toEqual(LOCAL_QUEUE_KIND_BUILDER);
  });

  it('未知 rawValue 不是 known kind', () => {
    const kind = createLocalQueueKind('forge');
    expect(localQueueKindIsKnown(kind)).toBe(false);
    expect(kind.rawValue).toBe('forge');
  });
});

describe('LocalQueueCapacityConfig', () => {
  it('接受 0 与正数', () => {
    expect(
      createLocalQueueCapacityConfig({
        villageID,
        queueKind: LOCAL_QUEUE_KIND_BUILDER,
        capacity: 0,
        updatedAtMs: 1_000_000,
      }).capacity,
    ).toBe(0);
    expect(
      createLocalQueueCapacityConfig({
        villageID,
        queueKind: LOCAL_QUEUE_KIND_BUILDER,
        capacity: 5,
        updatedAtMs: 1_000_000,
      }).capacity,
    ).toBe(5);
  });

  it('拒绝负数与超大容量', () => {
    expect(() =>
      createLocalQueueCapacityConfig({
        villageID,
        queueKind: LOCAL_QUEUE_KIND_BUILDER,
        capacity: -1,
        updatedAtMs: 1_000_000,
      }),
    ).toThrow();
    try {
      createLocalQueueCapacityConfig({
        villageID,
        queueKind: LOCAL_QUEUE_KIND_BUILDER,
        capacity: -1,
        updatedAtMs: 1_000_000,
      });
    } catch (error) {
      expect(
        localQueueCapacityConfigErrorsEqual(error as never, {
          kind: 'invalidCapacity',
          capacity: -1,
        }),
      ).toBe(true);
    }
    try {
      createLocalQueueCapacityConfig({
        villageID,
        queueKind: LOCAL_QUEUE_KIND_BUILDER,
        capacity: LOCAL_QUEUE_CAPACITY_MAXIMUM + 1,
        updatedAtMs: 1_000_000,
      });
    } catch (error) {
      expect(
        localQueueCapacityConfigErrorsEqual(error as never, {
          kind: 'invalidCapacity',
          capacity: LOCAL_QUEUE_CAPACITY_MAXIMUM + 1,
        }),
      ).toBe(true);
    }
  });

  it('拒绝非法时间戳', () => {
    try {
      createLocalQueueCapacityConfig({
        villageID,
        queueKind: LOCAL_QUEUE_KIND_BUILDER,
        capacity: 5,
        updatedAtMs: Number.POSITIVE_INFINITY,
      });
      expect.unreachable('should throw');
    } catch (error) {
      expect(
        localQueueCapacityConfigErrorsEqual(error as never, { kind: 'invalidTimestamp' }),
      ).toBe(true);
    }
  });
});

describe('QueueAssignmentDecision', () => {
  it('默认 userAssigned / userConfigured', () => {
    const decision = createQueueAssignmentDecision({
      decisionID: parseUuid('00000000-0000-0000-0000-000000000030')!,
      villageID,
      itemKey: trackerItemKeyRoot('home', 'buildings', 123n),
      baselineReference: baseline,
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      decidedAtMs: 1_000_000,
    });
    expect(decision.status).toBe('userAssigned');
    expect(decision.source).toBe('userConfigured');
  });

  it('拒绝非法 itemKey / baseline / timestamp', () => {
    expect(() =>
      createQueueAssignmentDecision({
        decisionID: parseUuid('00000000-0000-0000-0000-000000000031')!,
        villageID,
        itemKey: trackerItemKeyRoot('home', '', 0n),
        baselineReference: baseline,
        queueKind: LOCAL_QUEUE_KIND_BUILDER,
        decidedAtMs: 1_000_000,
      }),
    ).toThrow();
    try {
      createQueueAssignmentDecision({
        decisionID: parseUuid('00000000-0000-0000-0000-000000000032')!,
        villageID,
        itemKey: trackerItemKeyRoot('home', 'buildings', 123n),
        baselineReference: { revision: '  ', fingerprint: null, lineageID: null },
        queueKind: LOCAL_QUEUE_KIND_BUILDER,
        decidedAtMs: 1_000_000,
      });
    } catch (error) {
      expect(queueAssignmentErrorsEqual(error as never, { kind: 'invalidBaselineReference' })).toBe(
        true,
      );
    }
    try {
      createQueueAssignmentDecision({
        decisionID: parseUuid('00000000-0000-0000-0000-000000000033')!,
        villageID,
        itemKey: trackerItemKeyRoot('home', 'buildings', 123n),
        baselineReference: baseline,
        queueKind: LOCAL_QUEUE_KIND_BUILDER,
        decidedAtMs: Number.POSITIVE_INFINITY,
      });
    } catch (error) {
      expect(queueAssignmentErrorsEqual(error as never, { kind: 'invalidTimestamp' })).toBe(true);
    }
  });
});

describe('LocalQueueOccupancyResolver', () => {
  it('无配置时不判定满', () => {
    const occupancy = resolveLocalQueueOccupancy({
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      activeRecords: [record({ queueKind: 'builder' })],
      capacityConfig: null,
      nowMs: 1_000_000,
    });
    expect(occupancy.activeManualCount).toBe(1);
    expect(occupancy.capacity).toBeNull();
    expect(localQueueOccupancyIsFull(occupancy)).toBe(false);
    expect(localQueueOccupancyAvailableSlots(occupancy)).toBeNull();
  });

  it('只按持久化 queueKind 计数，null 视为 unassigned', () => {
    const occupancy = resolveLocalQueueOccupancy({
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      activeRecords: [
        record({ queueKind: 'builder' }),
        record({ queueKind: 'builder' }),
        record({ queueKind: 'laboratory' }),
        record({ queueKind: null }),
      ],
      capacityConfig: config(2),
      nowMs: 1_000_000,
    });
    expect(occupancy.activeManualCount).toBe(2);
    expect(localQueueOccupancyIsFull(occupancy)).toBe(true);
    expect(localQueueOccupancyAvailableSlots(occupancy)).toBe(0);
  });

  it('queueKind null 的 active record 不计入任何队列占用', () => {
    expect(effectiveLocalQueueKindForRecord(record({ queueKind: null }))).toBeNull();
    const occupancy = resolveLocalQueueOccupancy({
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      activeRecords: [record({ queueKind: null })],
      capacityConfig: config(1),
      nowMs: 1_000_000,
    });
    expect(occupancy.activeManualCount).toBe(0);
    expect(localQueueOccupancyIsFull(occupancy)).toBe(false);
  });

  it('capacity 0 时已知 0 占用也视为满', () => {
    const occupancy = resolveLocalQueueOccupancy({
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      activeRecords: [],
      capacityConfig: config(0),
      nowMs: 1_000_000,
    });
    expect(localQueueOccupancyIsFull(occupancy)).toBe(true);
    expect(localQueueOccupancyAvailableSlots(occupancy)).toBe(0);
  });

  it('未对账/不可用时不给出满结论', () => {
    for (const status of ['unreconciled', 'unavailable'] as const) {
      const occupancy = createLocalQueueOccupancy({
        queueKind: LOCAL_QUEUE_KIND_BUILDER,
        activeManualCount: 0,
        confirmedImportedCount: 0,
        capacity: 0,
        status,
      });
      expect(localQueueOccupancyIsFull(occupancy)).toBe(false);
      expect(localQueueOccupancyAvailableSlots(occupancy)).toBeNull();
    }
  });

  it('忽略非 active 记录', () => {
    const occupancy = resolveLocalQueueOccupancy({
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      activeRecords: [
        record({ queueKind: 'builder', status: 'completed' }),
        record({ queueKind: 'builder', status: 'cancelled' }),
      ],
      capacityConfig: config(1),
      nowMs: 1_000_000,
    });
    expect(occupancy.activeManualCount).toBe(0);
    expect(localQueueOccupancyIsFull(occupancy)).toBe(false);
  });

  it('排除已到期未 settle 记录', () => {
    const occupancy = resolveLocalQueueOccupancy({
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      activeRecords: [record({ queueKind: 'builder', expectedEndAtMs: 3_600_000 })],
      capacityConfig: config(1),
      nowMs: 5_000_000,
    });
    expect(occupancy.activeManualCount).toBe(0);
    expect(localQueueOccupancyAvailableSlots(occupancy)).toBe(1);
  });

  it('未知 section 仍按持久化 queueKind 计入占用', () => {
    const occupancy = resolveLocalQueueOccupancy({
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      activeRecords: [record({ queueKind: 'builder', rawSection: 'future' })],
      confirmedAssignments: [
        assignment({ queueKind: LOCAL_QUEUE_KIND_BUILDER, rawSection: 'future' }),
      ],
      capacityConfig: config(1),
      nowMs: 1_000_000,
    });
    expect(occupancy.activeManualCount).toBe(1);
    expect(occupancy.confirmedImportedCount).toBe(1);
    expect(localQueueOccupancyIsFull(occupancy)).toBe(true);
  });

  it('只统计 userAssigned overlay', () => {
    const occupancy = resolveLocalQueueOccupancy({
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      activeRecords: [],
      confirmedAssignments: [
        assignment({ status: 'userAssigned' }),
        assignment({ status: 'observedOnly' }),
        assignment({ status: 'unknown' }),
        assignment({ queueKind: LOCAL_QUEUE_KIND_LABORATORY, rawSection: 'units' }),
      ],
      capacityConfig: config(2),
      nowMs: 1_000_000,
    });
    expect(occupancy.confirmedImportedCount).toBe(1);
    expect(localQueueOccupancyAvailableSlots(occupancy)).toBe(1);
  });

  it('manual + confirmed 合计判满', () => {
    const occupancy = resolveLocalQueueOccupancy({
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      activeRecords: [record({ queueKind: 'builder' })],
      confirmedAssignments: [assignment({ status: 'userAssigned' })],
      capacityConfig: config(1),
      nowMs: 1_000_000,
    });
    expect(localQueueOccupancyIsFull(occupancy)).toBe(true);
  });
});

describe('validateStartAgainstQueueCapacity', () => {
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
  const staleBaseline = {
    revision: 'rev-old',
    fingerprint: 'fp-old',
    lineageID: 'lineage-old',
  };
  const staleCore = createManualUpgradeCoreState({
    itemStates: [
      createManualItemStateForStatus({
        itemKey: trackerItemKeyRoot('home', 'buildings', 1_000_002n),
        baselineReference: staleBaseline,
        status: 'manualCompleted',
        manual: createManualLevelDistributionFromPairs([]),
      }),
    ],
  });

  it('storeAvailable=false 且显式 queueKind 时拒绝 start', () => {
    expect(
      validateStartAgainstQueueCapacity({
        durationState: { kind: 'timed', seconds: 60n },
        core,
        queueCapacityConfigs: [config(1)],
        queueAssignments: [],
        currentBaseline,
        storeAvailable: false,
        requestedQueueKind: LOCAL_QUEUE_KIND_BUILDER,
        nowMs: 1_000_000,
      }),
    ).toEqual({ kind: 'occupancyNotAvailable', status: 'unavailable' });
  });

  it('baseline unreconciled 且显式 queueKind 时拒绝 start', () => {
    expect(
      validateStartAgainstQueueCapacity({
        durationState: { kind: 'timed', seconds: 60n },
        core: staleCore,
        queueCapacityConfigs: [config(1)],
        queueAssignments: [],
        currentBaseline,
        storeAvailable: true,
        requestedQueueKind: LOCAL_QUEUE_KIND_BUILDER,
        nowMs: 1_000_000,
      }),
    ).toEqual({ kind: 'occupancyNotAvailable', status: 'unreconciled' });
  });

  it('available 且未满时放行', () => {
    expect(
      validateStartAgainstQueueCapacity({
        durationState: { kind: 'timed', seconds: 60n },
        core,
        queueCapacityConfigs: [config(1)],
        queueAssignments: [],
        currentBaseline,
        storeAvailable: true,
        requestedQueueKind: LOCAL_QUEUE_KIND_BUILDER,
        nowMs: 1_000_000,
      }),
    ).toBeNull();
  });

  it('Issue #145：builder capacity=0 + requestedQueueKind=null 允许（不参与容量校验）', () => {
    expect(
      validateStartAgainstQueueCapacity({
        durationState: { kind: 'timed', seconds: 60n },
        core,
        queueCapacityConfigs: [config(0)],
        queueAssignments: [],
        currentBaseline,
        storeAvailable: true,
        requestedQueueKind: null,
        nowMs: 1_000_000,
      }),
    ).toBeNull();
  });

  it('Issue #145：builder capacity=0 + requestedQueueKind=builder 拒绝', () => {
    expect(
      validateStartAgainstQueueCapacity({
        durationState: { kind: 'timed', seconds: 60n },
        core,
        queueCapacityConfigs: [config(0)],
        queueAssignments: [],
        currentBaseline,
        storeAvailable: true,
        requestedQueueKind: LOCAL_QUEUE_KIND_BUILDER,
        nowMs: 1_000_000,
      }),
    ).toEqual({
      kind: 'queueCapacityFull',
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      activeCount: 0,
      confirmedImportedCount: 0,
      capacity: 0,
    });
  });

  it('Issue #145：heroes + requestedQueueKind=hero 走 hero capacity', () => {
    expect(
      validateStartAgainstQueueCapacity({
        durationState: { kind: 'timed', seconds: 60n },
        core,
        queueCapacityConfigs: [configForKind(LOCAL_QUEUE_KIND_HERO, 1)],
        queueAssignments: [],
        currentBaseline,
        storeAvailable: true,
        requestedQueueKind: LOCAL_QUEUE_KIND_HERO,
        nowMs: 1_000_000,
      }),
    ).toBeNull();
  });

  it('Issue #145：equipment + requestedQueueKind=equipment 走 equipment capacity', () => {
    expect(
      validateStartAgainstQueueCapacity({
        durationState: { kind: 'timed', seconds: 60n },
        core,
        queueCapacityConfigs: [configForKind(LOCAL_QUEUE_KIND_EQUIPMENT, 1)],
        queueAssignments: [],
        currentBaseline,
        storeAvailable: true,
        requestedQueueKind: LOCAL_QUEUE_KIND_EQUIPMENT,
        nowMs: 1_000_000,
      }),
    ).toBeNull();
  });

  it('instant 升级不参与容量 gate', () => {
    expect(
      validateStartAgainstQueueCapacity({
        durationState: { kind: 'instant' },
        core,
        queueCapacityConfigs: [config(0)],
        queueAssignments: [],
        currentBaseline,
        storeAvailable: true,
        requestedQueueKind: LOCAL_QUEUE_KIND_BUILDER,
        nowMs: 1_000_000,
      }),
    ).toBeNull();
  });

  it('未配置容量的 queueKind 不参与 gate', () => {
    expect(
      validateStartAgainstQueueCapacity({
        durationState: { kind: 'timed', seconds: 60n },
        core,
        queueCapacityConfigs: [config(0)],
        queueAssignments: [],
        currentBaseline,
        storeAvailable: true,
        requestedQueueKind: LOCAL_QUEUE_KIND_LABORATORY,
        nowMs: 1_000_000,
      }),
    ).toBeNull();
  });

  it('validateProjectedQueueCapacity 在 unavailable 时不做算术', () => {
    expect(
      validateProjectedQueueCapacity({
        occupancy: createLocalQueueOccupancy({
          queueKind: LOCAL_QUEUE_KIND_BUILDER,
          activeManualCount: 99,
          confirmedImportedCount: 99,
          capacity: 0,
          status: 'unavailable',
        }),
        queueKind: LOCAL_QUEUE_KIND_BUILDER,
        capacity: 0,
      }),
    ).toEqual({ kind: 'occupancyNotAvailable', status: 'unavailable' });
  });
});

describe('projectQueueOccupancy', () => {
  it('storeAvailable=false 返回 unavailable', () => {
    const occupancy = projectQueueOccupancy({
      queueKind: LOCAL_QUEUE_KIND_BUILDER,
      core: createManualUpgradeCoreState(),
      currentBaseline: baseline,
      storeAvailable: false,
      queueCapacityConfigs: [config(1)],
      queueAssignments: [],
      nowMs: 1_000_000,
    });
    expect(occupancy.status).toBe('unavailable');
  });
});
