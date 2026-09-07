export const BASELINE_SUITE_IDS = Object.freeze([
  'unit',
  'parity',
  'fault-replay',
  'oracle-isolation',
]);

/**
 * @param {string | undefined} rawEnv
 * @param {readonly string[]} [knownIds=BASELINE_SUITE_IDS]
 * @returns {readonly string[]}
 */
export function resolveBaselineSuiteSelection(rawEnv, knownIds = BASELINE_SUITE_IDS) {
  const known = new Set(knownIds);

  if (rawEnv === undefined) {
    return [...knownIds];
  }

  const requested = rawEnv
    .split(',')
    .map((name) => name.trim())
    .filter(Boolean);

  if (requested.length === 0) {
    throw new Error('No E1-02 baseline suites selected');
  }

  const unknown = requested.filter((name) => !known.has(name));
  if (unknown.length > 0) {
    throw new Error(`Unknown E1-02 baseline suite(s): ${unknown.join(', ')}`);
  }

  // 保序去重，顺序跟随 knownIds 以便报告稳定。
  return knownIds.filter((id) => requested.includes(id));
}
