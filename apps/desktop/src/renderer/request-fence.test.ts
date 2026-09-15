import { describe, expect, it } from 'vitest';

import {
  beginFetch,
  paginationSubjectKey,
  shouldAcceptGeneration,
  shouldApplyResponse,
  shouldMergePaginationPage,
  subjectChanged,
} from './request-fence';

describe('shouldAcceptGeneration', () => {
  it('跨 session 拒绝', () => {
    expect(shouldAcceptGeneration({ sessionId: 's1', generation: 5 }, 's2', 9)).toBe(false);
  });

  it('同 session 仅接受 generation>=', () => {
    expect(shouldAcceptGeneration({ sessionId: 's1', generation: 5 }, 's1', 4)).toBe(false);
    expect(shouldAcceptGeneration({ sessionId: 's1', generation: 5 }, 's1', 6)).toBe(true);
  });
});

describe('beginFetch', () => {
  const base = {
    sessionId: 's1',
    generation: 3,
    subjectKey: 'overview',
    refreshSeq: 0,
    forced: false,
    completedCursor: null,
    maxRequestedGeneration: -1,
    lastFetchKey: null,
    currentRequestSeq: 0,
  };

  it('重复 fetchKey 跳过', () => {
    const key = 's1:3:overview:0';
    const result = beginFetch(
      { ...base, lastFetchKey: key },
      shouldAcceptGeneration,
    );
    expect(result.kind).toBe('skip');
  });

  it('强制刷新仍发起请求', () => {
    const result = beginFetch({ ...base, forced: true }, shouldAcceptGeneration);
    expect(result.kind).toBe('fetch');
    if (result.kind === 'fetch') {
      expect(result.requestSeq).toBe(1);
    }
  });

  it('旧 generation 跳过', () => {
    const result = beginFetch(
      { ...base, generation: 2, maxRequestedGeneration: 5 },
      shouldAcceptGeneration,
    );
    expect(result.kind).toBe('skip');
  });
});

describe('shouldApplyResponse', () => {
  const base = {
    requestEpoch: 1,
    currentEpoch: 1,
    requestSessionId: 's1',
    currentSessionId: 's1',
    requestSubjectKey: 's1:v1:home',
    currentSubjectKey: 's1:v1:home',
    requestSeq: 2,
    currentRequestSeq: 2,
    completedCursor: null,
    shouldAcceptGeneration,
  };

  it('旧 session 丢弃', () => {
    expect(
      shouldApplyResponse({ ...base, currentSessionId: 's2' }),
    ).toBe(false);
  });

  it('旧村庄 subject 丢弃', () => {
    expect(
      shouldApplyResponse({ ...base, currentSubjectKey: 's1:v2:home' }),
    ).toBe(false);
  });

  it('旧 requestSeq 丢弃', () => {
    expect(
      shouldApplyResponse({ ...base, currentRequestSeq: 3 }),
    ).toBe(false);
  });

  it('lifecycle epoch 变化丢弃', () => {
    expect(
      shouldApplyResponse({ ...base, currentEpoch: 2 }),
    ).toBe(false);
  });

  it('旧 generation 响应丢弃', () => {
    expect(
      shouldApplyResponse({ ...base, responseGeneration: 1, completedCursor: { sessionId: 's1', generation: 5 } }),
    ).toBe(false);
  });
});

describe('subjectChanged', () => {
  it('首次 subject 不算切换', () => {
    expect(subjectChanged(null, 'a')).toBe(false);
  });

  it('不同 subject 算切换', () => {
    expect(subjectChanged('a', 'b')).toBe(true);
  });
});

describe('pagination', () => {
  it('不同 clanTag 不合并', () => {
    const a = { clanTag: '#A', endpoint: 'warLog', cursor: null };
    const b = { clanTag: '#B', endpoint: 'warLog', cursor: null };
    expect(shouldMergePaginationPage(a, b)).toBe(false);
    expect(paginationSubjectKey(a)).not.toBe(paginationSubjectKey(b));
  });

  it('相同查询可合并', () => {
    const a = { clanTag: '#A', endpoint: 'warLog', cursor: 'c1' };
    const b = { clanTag: '#A', endpoint: 'warLog', cursor: 'c1' };
    expect(shouldMergePaginationPage(a, b)).toBe(true);
  });
});
