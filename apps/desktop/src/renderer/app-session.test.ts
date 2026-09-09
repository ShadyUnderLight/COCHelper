import { describe, expect, it } from 'vitest';

import type { AppSnapshotPayload } from '@coc-helper/contracts';

import {
  applyAcceptedSnapshot,
  formatIpcError,
  INITIAL_APP_SESSION,
  isEmptyVillages,
  isReadOnly,
  shouldAcceptSnapshot,
  type AppSessionState,
  type ImportPreviewState,
} from './app-session';

function snapshot(overrides: Partial<AppSnapshotPayload> = {}): AppSnapshotPayload {
  return {
    sessionId: 'session-a',
    generation: 1,
    availability: 'available',
    villageStatus: 'available',
    villageError: null,
    canWrite: true,
    hasPendingJournal: false,
    recoveryNotice: null,
    selectedVillageId: null,
    villages: [],
    pendingImport: null,
    ...overrides,
  };
}

describe('shouldAcceptSnapshot', () => {
  it('接受首个快照', () => {
    expect(shouldAcceptSnapshot(null, snapshot())).toBe(true);
  });

  it('同 session 拒绝更旧 generation', () => {
    expect(
      shouldAcceptSnapshot(
        { sessionId: 'session-a', generation: 3 },
        snapshot({ generation: 2 }),
      ),
    ).toBe(false);
  });

  it('同 session 接受同等或更新 generation', () => {
    expect(
      shouldAcceptSnapshot(
        { sessionId: 'session-a', generation: 3 },
        snapshot({ generation: 3 }),
      ),
    ).toBe(true);
    expect(
      shouldAcceptSnapshot(
        { sessionId: 'session-a', generation: 3 },
        snapshot({ generation: 4 }),
      ),
    ).toBe(true);
  });

  it('新 sessionId 即使 generation 更小也接受', () => {
    expect(
      shouldAcceptSnapshot(
        { sessionId: 'session-a', generation: 9 },
        snapshot({ sessionId: 'session-b', generation: 0 }),
      ),
    ).toBe(true);
  });
});

describe('applyAcceptedSnapshot', () => {
  it('pending 清空时丢弃本地 preview', () => {
    const preview: ImportPreviewState = {
      preparedGeneration: 2,
      preview: {
        snapshot: {
          importedAt: 1,
          originalText: '{}',
          objectSections: {},
          numericSections: {},
          boosts: {},
          unknownTopLevelKeys: [],
          diagnostics: [],
        },
        targetKind: 'create',
      },
    };
    const state: AppSessionState = {
      ...INITIAL_APP_SESSION,
      status: 'ready',
      preview,
      snapshot: snapshot({ generation: 2, pendingImport: { targetKind: 'create', snapshotTag: null } }),
    };
    const next = applyAcceptedSnapshot(
      state,
      snapshot({ generation: 3, pendingImport: null }),
    );
    expect(next.preview).toBeNull();
    expect(next.status).toBe('ready');
  });

  it('generation 与 prepare 不一致时丢弃 preview', () => {
    const preview: ImportPreviewState = {
      preparedGeneration: 2,
      preview: {
        snapshot: {
          importedAt: 1,
          originalText: '{}',
          objectSections: {},
          numericSections: {},
          boosts: {},
          unknownTopLevelKeys: [],
          diagnostics: [],
        },
        targetKind: 'create',
      },
    };
    const state: AppSessionState = {
      ...INITIAL_APP_SESSION,
      status: 'ready',
      preview,
    };
    const next = applyAcceptedSnapshot(
      state,
      snapshot({
        generation: 4,
        pendingImport: { targetKind: 'create', snapshotTag: null },
      }),
    );
    expect(next.preview).toBeNull();
  });

  it('generation 匹配时保留 preview', () => {
    const preview: ImportPreviewState = {
      preparedGeneration: 5,
      preview: {
        snapshot: {
          importedAt: 1,
          originalText: '{}',
          objectSections: {},
          numericSections: {},
          boosts: {},
          unknownTopLevelKeys: [],
          diagnostics: [],
        },
        targetKind: 'create',
      },
    };
    const state: AppSessionState = {
      ...INITIAL_APP_SESSION,
      status: 'ready',
      preview,
    };
    const next = applyAcceptedSnapshot(
      state,
      snapshot({
        generation: 5,
        pendingImport: { targetKind: 'create', snapshotTag: '#TAG' },
      }),
    );
    expect(next.preview).toBe(preview);
  });
});

describe('helpers', () => {
  it('识别 empty / read-only', () => {
    expect(isEmptyVillages(snapshot({ villageStatus: 'empty' }))).toBe(true);
    expect(isReadOnly(snapshot({ canWrite: false }))).toBe(true);
    expect(isReadOnly(snapshot({ villageStatus: 'readOnly' }))).toBe(true);
  });

  it('conflict 错误带过期提示', () => {
    expect(
      formatIpcError({
        kind: 'validation',
        code: 'conflict',
        messageKey: 'conflict',
        message: 'expectedGeneration 不匹配',
      }),
    ).toContain('conflict');
  });
});
