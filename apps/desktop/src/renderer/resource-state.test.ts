import { describe, expect, it } from 'vitest';

import {
  LOADING_RESOURCE,
  resourceData,
  resourceFailure,
  resourceLastError,
  resourceLoading,
  resourceSuccess,
} from './resource-state';

describe('resource-state', () => {
  it('无 last-good 失败进 failed', () => {
    const next = resourceFailure(LOADING_RESOURCE, 'boom');
    expect(next.kind).toBe('failed');
    expect(resourceData(next)).toBeNull();
    expect(resourceLastError(next)).toBe('boom');
  });

  it('有 last-good 失败进 failedWithLastGood', () => {
    const good = resourceSuccess({ id: 1 });
    const next = resourceFailure(good, 'stale');
    expect(next.kind).toBe('failedWithLastGood');
    expect(resourceData(next)).toEqual({ id: 1 });
  });

  it('refreshing 保留旧数据', () => {
    const good = resourceSuccess('x');
    const next = resourceLoading(good);
    expect(next.kind).toBe('refreshing');
    expect(resourceData(next)).toBe('x');
  });

  it('无数据时 loading', () => {
    const next = resourceLoading(null);
    expect(next.kind).toBe('loading');
  });
});
