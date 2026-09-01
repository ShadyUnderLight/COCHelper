import { describe, expect, it } from 'vitest';

import { catalogDurationState, catalogDurationLabel } from './duration-state';

describe('catalogDurationState', () => {
  it('映射 timed/instant/缺失类语义', () => {
    expect(catalogDurationState(3600n, null)).toEqual({ kind: 'timed', seconds: 3600n });
    expect(catalogDurationState(0n, null)).toEqual({ kind: 'instant' });
    expect(catalogDurationState(null, 'min_level_initial_no_upgrade')).toEqual({
      kind: 'initialLevel',
    });
    expect(catalogDurationState(null, 'no_time_source')).toEqual({ kind: 'notApplicable' });
    expect(catalogDurationState(null, 'time_invalid')).toEqual({ kind: 'parseFailed' });
    expect(catalogDurationState(null, 'time_missing')).toEqual({ kind: 'sourceMissing' });
    expect(catalogDurationState(null, null)).toBeNull();
    expect(catalogDurationState(-1n, null)).toEqual({
      kind: 'unknownReason',
      reason: 'negative_duration',
    });
  });

  it('生成展示文案', () => {
    expect(catalogDurationLabel({ kind: 'instant' })).toBe('即时');
    expect(catalogDurationLabel({ kind: 'sourceMissing' })).toBe('目录缺失');
  });
});
