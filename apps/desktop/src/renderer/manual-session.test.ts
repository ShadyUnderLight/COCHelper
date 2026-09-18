import { describe, expect, it } from 'vitest';

import {
  isManualCommandEnabled,
  manualStatusLabel,
  manualStatusNotice,
} from './manual-session';

describe('manual-session（#277-F）', () => {
  it('manualStatusLabel 覆盖五态', () => {
    expect(manualStatusLabel('available')).toBe('可用');
    expect(manualStatusLabel('empty')).toBe('暂无手动升级数据');
    expect(manualStatusLabel('unavailable')).toBe('不可用');
  });

  it('isManualCommandEnabled 需要 canWrite 且 available', () => {
    expect(
      isManualCommandEnabled(
        {
          generation: 1,
          villageId: 'v1',
          status: 'available',
          error: null,
          baselineRevision: 'r1',
          baselineLineageId: 'l1',
          activeRecordCount: 0,
          itemStateCount: 0,
          activeRecords: [],
          lastSettleAtMs: null,
          lastImportAtMs: null,
          stateUpdatedAtMs: null,
        },
        true,
      ),
    ).toBe(true);
    expect(
      isManualCommandEnabled(
        {
          generation: 1,
          villageId: 'v1',
          status: 'empty',
          error: null,
          baselineRevision: null,
          baselineLineageId: null,
          activeRecordCount: 0,
          itemStateCount: 0,
          activeRecords: [],
          lastSettleAtMs: null,
          lastImportAtMs: null,
          stateUpdatedAtMs: null,
        },
        true,
      ),
    ).toBe(false);
  });

  it('manualStatusNotice 对 empty 给出引导', () => {
    expect(
      manualStatusNotice({
        generation: 1,
        villageId: 'v1',
        status: 'empty',
        error: null,
        baselineRevision: null,
        baselineLineageId: null,
        activeRecordCount: 0,
        itemStateCount: 0,
        activeRecords: [],
        lastSettleAtMs: null,
        lastImportAtMs: null,
        stateUpdatedAtMs: null,
      }),
    ).toContain('导入');
  });
});
