import { describe, expect, it } from 'vitest';

import {
  isManualCommandEnabled,
  isManualQueryStale,
  manualStatusLabel,
  manualStatusNotice,
} from './manual-session';

const availablePayload = {
  generation: 1,
  villageId: 'v1',
  status: 'available' as const,
  error: null,
  baselineRevision: 'r1',
  baselineLineageId: 'l1',
  activeRecordCount: 0,
  itemStateCount: 0,
  activeRecords: [],
  lastSettleAtMs: null,
  lastImportAtMs: null,
  stateUpdatedAtMs: null,
};

describe('manual-session（#277-F）', () => {
  it('manualStatusLabel 覆盖五态', () => {
    expect(manualStatusLabel('available')).toBe('可用');
    expect(manualStatusLabel('empty')).toBe('暂无手动升级数据');
    expect(manualStatusLabel('unavailable')).toBe('不可用');
  });

  it('isManualCommandEnabled 需要 canWrite、available 且查询未过期', () => {
    expect(isManualCommandEnabled(availablePayload, true)).toBe(true);
    expect(isManualCommandEnabled(availablePayload, true, true)).toBe(false);
    expect(isManualCommandEnabled({ ...availablePayload, status: 'empty' }, true)).toBe(false);
  });

  it('isManualQueryStale 识别 last-good + lastError', () => {
    expect(
      isManualQueryStale({
        status: 'ready',
        payload: availablePayload,
        lastError: '刷新失败',
      }),
    ).toBe(true);
    expect(
      isManualQueryStale({
        status: 'ready',
        payload: availablePayload,
        lastError: null,
      }),
    ).toBe(false);
  });

  it('manualStatusNotice 对 empty 给出引导', () => {
    expect(
      manualStatusNotice({
        ...availablePayload,
        status: 'empty',
        baselineRevision: null,
        baselineLineageId: null,
      }),
    ).toContain('导入');
  });
});
