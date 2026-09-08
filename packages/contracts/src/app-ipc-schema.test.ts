import { describe, expect, it } from 'vitest';

import {
  appSnapshotPayloadSchema,
  importCommitRequestSchema,
  importPreparePayloadSchema,
  isAppSnapshotPayload,
} from './app-ipc-schema';
import { isUpgradeOverviewPayload, villageDetailRequestSchema } from './projection-ipc-schema';

describe('app-ipc-schema', () => {
  it('拒绝非法 availability / villages 元素', () => {
    expect(
      isAppSnapshotPayload({
        generation: 0,
        availability: 'garbage',
        villageStatus: 'missing',
        villageError: null,
        canWrite: true,
        selectedVillageId: null,
        villages: [],
        pendingImport: null,
      }),
    ).toBe(false);

    expect(
      appSnapshotPayloadSchema.safeParse({
        generation: 0,
        availability: 'available',
        villageStatus: 'missing',
        villageError: null,
        canWrite: true,
        selectedVillageId: null,
        villages: [123],
        pendingImport: null,
      }).success,
    ).toBe(false);
  });

  it('要求 commit 携带 expectedGeneration，并校验 prepare preview 形状', () => {
    expect(importCommitRequestSchema.safeParse({}).success).toBe(false);
    expect(importCommitRequestSchema.safeParse({ expectedGeneration: 2 }).success).toBe(true);
    expect(
      importPreparePayloadSchema.safeParse({
        generation: 1,
        pending: { targetKind: 'create', snapshotTag: '#A' },
        preview: {},
      }).success,
    ).toBe(false);
  });
});

describe('projection-ipc-schema', () => {
  it('village.detail 必须显式 villageId + base', () => {
    expect(villageDetailRequestSchema.safeParse({}).success).toBe(false);
    expect(villageDetailRequestSchema.safeParse({ villageId: 'v1' }).success).toBe(false);
    expect(villageDetailRequestSchema.safeParse({ villageId: 'v1', base: 'home' }).success).toBe(
      true,
    );
  });

  it('upgrade.overview payload 拒绝缺字段', () => {
    expect(isUpgradeOverviewPayload({ generation: 0 })).toBe(false);
  });
});
