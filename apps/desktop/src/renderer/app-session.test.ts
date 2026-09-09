import { describe, expect, it } from 'vitest';

import type { AppSnapshotPayload, Result } from '@coc-helper/contracts';

import {
  applyAcceptedSnapshot,
  formatIpcError,
  INITIAL_APP_SESSION,
  isCurrentEpoch,
  isEmptyVillages,
  isReadOnly,
  mergePrepareFollowUp,
  resolveCommitGeneration,
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

function previewState(preparedGeneration: number): ImportPreviewState {
  return {
    preparedGeneration,
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
}

describe('shouldAcceptSnapshot', () => {
  it('接受首个快照', () => {
    expect(shouldAcceptSnapshot(null, snapshot())).toBe(true);
  });

  it('同 session 拒绝更旧 generation', () => {
    expect(
      shouldAcceptSnapshot({ sessionId: 'session-a', generation: 3 }, snapshot({ generation: 2 })),
    ).toBe(false);
  });

  it('同 session 接受同等或更新 generation', () => {
    expect(
      shouldAcceptSnapshot({ sessionId: 'session-a', generation: 3 }, snapshot({ generation: 3 })),
    ).toBe(true);
    expect(
      shouldAcceptSnapshot({ sessionId: 'session-a', generation: 3 }, snapshot({ generation: 4 })),
    ).toBe(true);
  });

  it('已建立 session B 后拒绝延迟到达的旧 session A', () => {
    expect(
      shouldAcceptSnapshot(
        { sessionId: 'session-b', generation: 3 },
        snapshot({ sessionId: 'session-a', generation: 100 }),
      ),
    ).toBe(false);
  });

  it('不同 sessionId 一律拒绝（跨 session 只能在 cursor === null 时建立）', () => {
    expect(
      shouldAcceptSnapshot(
        { sessionId: 'session-a', generation: 9 },
        snapshot({ sessionId: 'session-b', generation: 0 }),
      ),
    ).toBe(false);
  });
});

describe('isCurrentEpoch', () => {
  it('仅匹配当前 epoch', () => {
    expect(isCurrentEpoch(2, 2)).toBe(true);
    expect(isCurrentEpoch(1, 2)).toBe(false);
  });
});

describe('mergePrepareFollowUp', () => {
  it('post-prepare snapshot 被 stale guard 拒绝时清空 preview', () => {
    const nextPreview = previewState(11);
    const snap: Result<AppSnapshotPayload> = {
      ok: true,
      value: snapshot({
        generation: 11,
        pendingImport: { targetKind: 'create', snapshotTag: null },
      }),
    };
    // 权威态已由 state.changed 推到 gen 12
    const followUp = mergePrepareFollowUp(
      { sessionId: 'session-a', generation: 12 },
      nextPreview,
      snap,
    );
    expect(followUp).toEqual({
      kind: 'stale',
      reason: '状态已变化，请重新解析预览。',
    });
  });

  it('preparedGeneration 与权威 generation 不一致时清空 preview', () => {
    const followUp = mergePrepareFollowUp(
      { sessionId: 'session-a', generation: 10 },
      previewState(11),
      {
        ok: true,
        value: snapshot({
          generation: 12,
          pendingImport: { targetKind: 'create', snapshotTag: null },
        }),
      },
    );
    expect(followUp.kind).toBe('stale');
  });

  it('generation 对齐且仍有 pending 时保留 preview', () => {
    const nextPreview = previewState(11);
    const followUp = mergePrepareFollowUp({ sessionId: 'session-a', generation: 10 }, nextPreview, {
      ok: true,
      value: snapshot({
        generation: 11,
        pendingImport: { targetKind: 'create', snapshotTag: '#X' },
      }),
    });
    expect(followUp).toEqual({
      kind: 'applied',
      snapshot: expect.objectContaining({ generation: 11 }),
      preview: nextPreview,
    });
  });

  it('snapshot 失败时清空 preview', () => {
    const followUp = mergePrepareFollowUp(
      { sessionId: 'session-a', generation: 10 },
      previewState(11),
      {
        ok: false,
        error: {
          kind: 'internal',
          code: 'internal',
          messageKey: 'internal',
          message: 'boom',
        },
      },
    );
    expect(followUp.kind).toBe('stale');
  });
});

describe('resolveCommitGeneration', () => {
  it('preview 与 cursor generation 一致时允许 commit', () => {
    expect(
      resolveCommitGeneration(previewState(11), {
        sessionId: 'session-a',
        generation: 11,
      }),
    ).toEqual({ ok: true, expectedGeneration: 11 });
  });

  it('脱钩时拒绝 commit', () => {
    expect(
      resolveCommitGeneration(previewState(11), {
        sessionId: 'session-a',
        generation: 12,
      }),
    ).toEqual({ ok: false, reason: '状态已变化，请重新解析预览。' });
  });

  it('无 preview 时拒绝', () => {
    expect(resolveCommitGeneration(null, { sessionId: 'session-a', generation: 1 })).toEqual({
      ok: false,
      reason: '没有可确认的导入预览。',
    });
  });
});

describe('applyAcceptedSnapshot', () => {
  it('pending 清空时丢弃本地 preview', () => {
    const preview = previewState(2);
    const state: AppSessionState = {
      ...INITIAL_APP_SESSION,
      status: 'ready',
      preview,
      snapshot: snapshot({
        generation: 2,
        pendingImport: { targetKind: 'create', snapshotTag: null },
      }),
    };
    const next = applyAcceptedSnapshot(state, snapshot({ generation: 3, pendingImport: null }));
    expect(next.preview).toBeNull();
    expect(next.status).toBe('ready');
  });

  it('generation 与 prepare 不一致时丢弃 preview', () => {
    const state: AppSessionState = {
      ...INITIAL_APP_SESSION,
      status: 'ready',
      preview: previewState(2),
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
    const preview = previewState(5);
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
