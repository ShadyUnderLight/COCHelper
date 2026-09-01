import { describe, expect, it } from 'vitest';

import { createSeasonalPhaseTable, catalogAvailabilityLabel } from './seasonal-phase';

describe('SeasonalPhaseTable', () => {
  const table = createSeasonalPhaseTable({
    schemaVersion: 1,
    phases: [
      {
        phaseID: 'p',
        name: '阶段',
        fromMs: 1_000_000,
        untilMs: 2_000_000,
        itemKeys: ['buildings:103000000'],
        sourceURL: null,
      },
    ],
  });

  it('活动期命中与边界', () => {
    expect(table.phaseForItemKey('buildings:103000000', 1_500_000)?.phaseID).toBe('p');
    expect(table.phaseForItemKey('buildings:999', 1_500_000)).toBeUndefined();
    expect(table.availability('buildings:103000000', null, 999_999).kind).toBe('seasonal');
    expect(table.availability('buildings:103000000', null, 1_000_000).kind).toBe('seasonal');
    expect(table.availability('buildings:103000000', null, 1_999_999).kind).toBe('seasonal');
  });

  it('permanent 与阶段冲突 fail-closed', () => {
    const availability = table.availability('buildings:103000000', 'permanent', 1_500_000);
    expect(availability.kind).toBe('conflict');
    expect(catalogAvailabilityLabel(availability)).toContain('声明冲突');
  });

  it('bucket 在边界内稳定', () => {
    const bucket = table.bucket(1_500_000);
    expect(bucket.startMs).toBe(1_000_000);
    expect(bucket.endMs).toBe(2_000_000);
  });
});
