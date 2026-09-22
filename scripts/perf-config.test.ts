import { describe, expect, it } from 'vitest';

import { FROZEN_RELEASE_BASELINE, validatePerfProfile } from './perf-config.mjs';

describe('performance profile contract', () => {
  it('accepts the frozen independent baseline profile', () => {
    expect(
      validatePerfProfile({
        profile: 'baseline',
        scenario: 'village-detail',
        repetitions: FROZEN_RELEASE_BASELINE.repetitions,
        warmup: FROZEN_RELEASE_BASELINE.warmup,
        scrollMs: FROZEN_RELEASE_BASELINE.scrollMs,
      }),
    ).toEqual({ profile: 'baseline', acceptanceEligible: false });
  });

  it('rejects all scenarios in the baseline profile', () => {
    expect(() =>
      validatePerfProfile({
        profile: 'baseline',
        scenario: 'all',
        repetitions: 3,
        warmup: 1,
        scrollMs: 10_000,
      }),
    ).toThrow(/一次只运行一个独立 scenario/);
  });

  it('rejects a baseline run with non-frozen sampling parameters', () => {
    expect(() =>
      validatePerfProfile({
        profile: 'baseline',
        scenario: 'overview',
        repetitions: 1,
        warmup: 0,
        scrollMs: 1_000,
      }),
    ).toThrow(/repetitions=3/);
  });

  it('keeps all diagnostic profiles explicitly non-gating', () => {
    expect(
      validatePerfProfile({
        profile: 'diagnostic',
        scenario: 'all',
        repetitions: 1,
        warmup: 0,
        scrollMs: 1_000,
      }),
    ).toEqual({ profile: 'diagnostic', acceptanceEligible: false });
  });

  it('keeps a single-scenario diagnostic profile non-gating', () => {
    expect(
      validatePerfProfile({
        profile: 'diagnostic',
        scenario: 'history-24',
        repetitions: 3,
        warmup: 1,
        scrollMs: 10_000,
      }),
    ).toEqual({ profile: 'diagnostic', acceptanceEligible: false });
  });
});
