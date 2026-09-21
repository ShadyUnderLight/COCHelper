export const FROZEN_RELEASE_BASELINE = Object.freeze({
  profile: 'baseline-v1',
  repetitions: 3,
  warmup: 1,
  scrollMs: 10_000,
  processSampleIntervalMs: 250,
  footprintSampleEvery: 16,
});

export function validatePerfProfile({ profile, scenario, repetitions, warmup, scrollMs }) {
  if (profile !== 'diagnostic' && profile !== 'baseline') {
    throw new Error(`未知性能 profile：${String(profile)}；可选值：diagnostic、baseline`);
  }

  if (profile === 'diagnostic') {
    return { profile, acceptanceEligible: scenario !== 'all' };
  }

  const selectedScenarioCount =
    scenario === 'all' ? Number.POSITIVE_INFINITY : scenario.split(',').filter(Boolean).length;
  if (selectedScenarioCount !== 1) {
    throw new Error('baseline profile 必须一次只运行一个独立 scenario；all 仅用于 diagnostic');
  }

  const mismatches = [];
  if (repetitions !== FROZEN_RELEASE_BASELINE.repetitions) {
    mismatches.push(`repetitions=${FROZEN_RELEASE_BASELINE.repetitions}`);
  }
  if (warmup !== FROZEN_RELEASE_BASELINE.warmup) {
    mismatches.push(`warmup=${FROZEN_RELEASE_BASELINE.warmup}`);
  }
  if (scrollMs !== FROZEN_RELEASE_BASELINE.scrollMs) {
    mismatches.push(`scroll-ms=${FROZEN_RELEASE_BASELINE.scrollMs}`);
  }
  if (mismatches.length > 0) {
    throw new Error(`baseline profile 参数未按冻结协议设置：${mismatches.join('、')}`);
  }

  // Frozen parameters make the artifact comparable; they do not create a
  // numeric performance pass/fail gate until a cross-environment tolerance is
  // separately approved.
  return { profile, acceptanceEligible: false };
}
