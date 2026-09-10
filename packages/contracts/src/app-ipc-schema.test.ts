import { describe, expect, it } from 'vitest';

import {
  appSnapshotPayloadSchema,
  importCommitRequestSchema,
  importPreparePayloadSchema,
  isAppSnapshotPayload,
  isQuickCommitPayload,
  isQuickDiscardPayload,
  isQuickPreparePayload,
  quickCommitRequestSchema,
  quickDiscardRequestSchema,
  quickImportPreviewWireSchema,
  quickPreparePayloadSchema,
  quickPrepareRequestSchema,
} from './app-ipc-schema';
import { isUpgradeOverviewPayload, villageDetailRequestSchema } from './projection-ipc-schema';

describe('app-ipc-schema', () => {
  it('拒绝非法 availability / villages 元素', () => {
    expect(
      isAppSnapshotPayload({
        sessionId: 's1',
        generation: 0,
        availability: 'garbage',
        villageStatus: 'missing',
        villageError: null,
        canWrite: true,
        hasPendingJournal: false,
        recoveryNotice: null,
        selectedVillageId: null,
        villages: [],
        pendingImport: null,
      }),
    ).toBe(false);

    expect(
      appSnapshotPayloadSchema.safeParse({
        sessionId: 's1',
        generation: 0,
        availability: 'available',
        villageStatus: 'missing',
        villageError: null,
        canWrite: true,
        hasPendingJournal: false,
        recoveryNotice: null,
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

  it('quick 通道：prepare 必须显式 targetVillageId，commit/discard 必须 CAS', () => {
    expect(quickPrepareRequestSchema.safeParse({}).success).toBe(false);
    expect(quickPrepareRequestSchema.safeParse({ targetVillageId: 'v1' }).success).toBe(true);
    // 不得传文本：renderer 无权提供剪贴板内容，文本只能由 Main 读取。
    expect(quickPrepareRequestSchema.safeParse({ targetVillageId: 'v1', text: '{}' }).success).toBe(
      false,
    );
    expect(quickCommitRequestSchema.safeParse({}).success).toBe(false);
    expect(quickCommitRequestSchema.safeParse({ expectedGeneration: 3 }).success).toBe(true);
    expect(quickDiscardRequestSchema.safeParse({}).success).toBe(false);
    expect(quickDiscardRequestSchema.safeParse({ expectedGeneration: 3 }).success).toBe(true);
  });

  it('quick preview wire 拒绝缺字段', () => {
    expect(quickImportPreviewWireSchema.safeParse({}).success).toBe(false);
    const preview = {
      snapshot: {
        importedAt: 1,
        originalText: '{}',
        objectSections: {},
        numericSections: {},
        boosts: {},
        unknownTopLevelKeys: [],
        diagnostics: [],
      },
      targetVillageId: 'v1',
      targetVillageName: 'A',
      targetVillageTag: null,
      targetVillageHasSnapshot: false,
      replacesSameTag: false,
      destinationDescription: '将建立「A」的账号快照并导入',
    };
    expect(quickImportPreviewWireSchema.safeParse(preview).success).toBe(true);
    expect(quickPreparePayloadSchema.safeParse({ generation: 1, preview }).success).toBe(true);
    expect(isQuickPreparePayload({ generation: 1, preview })).toBe(true);
    expect(isQuickPreparePayload({ generation: 1 })).toBe(false);
    expect(isQuickCommitPayload({ generation: 2, selectedVillageId: 'v1' })).toBe(true);
    expect(isQuickDiscardPayload({ generation: 2 })).toBe(true);
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
