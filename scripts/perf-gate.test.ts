import { describe, expect, it } from 'vitest';

import {
  comparePerfReports,
  RELEASE_GATE_PROTOCOL,
  requiredGateMetricPaths,
  validatePerfReport,
} from './perf-gate.mjs';

function makeReport(node: string, scenario = 'history-24') {
  const summary: Record<string, unknown> = {};
  for (const metric of requiredGateMetricPaths(scenario)) {
    setPath(summary, metric, 100);
  }
  return {
    protocol: 'electron-release-perf-v1',
    status: 'observed',
    failures: [],
    commitSha: 'commit-1',
    sourceProvenance: { commitSha: 'commit-1', dirty: false, untrackedInputs: [] },
    binaryProvenance: { commitSha: 'commit-1', dirty: false },
    environment: { platform: 'darwin', arch: 'arm64', node },
    options: { scenario, profile: 'baseline', repetitions: 3, warmup: 1, scrollMs: 10_000 },
    sampling: { processSampleIntervalMs: 250, footprintSampleEvery: 16 },
    manifest: { schemaVersion: 1, protocol: 'electron-release-perf-v1' },
    runs: [1, 2, 3].map((repetition) => ({
      scenario,
      repetition,
      runtime: { node: 'v22.15.0', electron: '44.0.0', platform: 'darwin', arch: 'arm64' },
      finalProcess: { raw: { rssBytes: [100], rootFootprintBytes: [100] } },
    })),
    summary: { [scenario]: summary },
  };
}

function makePolicy(scenario = 'history-24') {
  return {
    schemaVersion: 1,
    protocol: RELEASE_GATE_PROTOCOL,
    referenceRole: 'node24-ci',
    candidateRole: 'node26-local',
    metrics: Object.fromEntries(
      requiredGateMetricPaths(scenario).map((metric) => [
        metric,
        { maxAbsoluteIncrease: 10, maxRelativeIncrease: 0.1 },
      ]),
    ),
  };
}

function setPath(target: Record<string, unknown>, path: string, value: number): void {
  const parts = path.split('.');
  let current = target;
  for (const part of parts.slice(0, -1)) {
    const existing = current[part];
    if (existing !== null && typeof existing === 'object' && !Array.isArray(existing)) {
      current = existing as Record<string, unknown>;
    } else {
      const next = {} as Record<string, unknown>;
      current[part] = next;
      current = next;
    }
  }
  current[parts.at(-1)!] = value;
}

describe('cross-environment release performance gate', () => {
  it('requires the frozen baseline protocol and runtime role', () => {
    const report = makeReport('v24.18.1');
    expect(validatePerfReport(report, { role: 'node24-ci', scenario: 'history-24' })).toEqual({
      ok: true,
      errors: [],
    });
    expect(validatePerfReport(report, { role: 'node26-local', scenario: 'history-24' }).ok).toBe(
      false,
    );
  });

  it('passes only when every required metric is within the supplied policy', () => {
    const reference = makeReport('v24.18.1');
    const candidate = makeReport('v26.0.0');
    const result = comparePerfReports({
      reference,
      candidate,
      policy: makePolicy(),
      scenario: 'history-24',
    });

    expect(result.status).toBe('passed');
    expect(result.acceptanceEligible).toBe(true);
    expect(result.comparisons).toHaveLength(requiredGateMetricPaths('history-24').length);
  });

  it('fails closed when a required tolerance is missing', () => {
    const policy = makePolicy();
    delete policy.metrics['peakRssBytes.max'];
    const result = comparePerfReports({
      reference: makeReport('v24.18.1'),
      candidate: makeReport('v26.0.0'),
      policy,
      scenario: 'history-24',
    });

    expect(result.status).toBe('failed');
    expect(result.acceptanceEligible).toBe(false);
    expect(result.failures.some((message) => message.includes('peakRssBytes.max'))).toBe(true);
  });

  it('fails closed when a candidate metric is unknown or exceeds tolerance', () => {
    const candidate = makeReport('v26.0.0');
    setPath(candidate.summary['history-24'] as Record<string, unknown>, 'peakRssBytes.max', 111);
    const result = comparePerfReports({
      reference: makeReport('v24.18.1'),
      candidate,
      policy: makePolicy(),
      scenario: 'history-24',
    });

    expect(result.status).toBe('failed');
    expect(result.failures.some((message) => message.includes('peakRssBytes.max'))).toBe(true);

    setPath(candidate.summary['history-24'] as Record<string, unknown>, 'peakFootprintBytes.max', NaN);
    const unknown = comparePerfReports({
      reference: makeReport('v24.18.1'),
      candidate,
      policy: makePolicy(),
      scenario: 'history-24',
    });
    expect(unknown.status).toBe('failed');
    expect(unknown.failures.some((message) => message.includes('peakFootprintBytes.max'))).toBe(
      true,
    );
  });

  it('rejects different provenance before comparing numbers', () => {
    const candidate = makeReport('v26.0.0');
    candidate.commitSha = 'other-commit';
    const result = comparePerfReports({
      reference: makeReport('v24.18.1'),
      candidate,
      policy: makePolicy(),
      scenario: 'history-24',
    });

    expect(result.status).toBe('failed');
    expect(result.failures).toContain('reference/candidate commit 不一致。');
    expect(result.comparisons).toHaveLength(0);
  });

  it('requires the top-level commit to bind both provenance records', () => {
    const report = makeReport('v24.18.1');
    report.commitSha = 'other-commit';
    const result = validatePerfReport(report, { role: 'node24-ci', scenario: 'history-24' });

    expect(result.ok).toBe(false);
    expect(result.errors).toContain('source provenance commit 与 report 顶层 commit 不一致。');
    expect(result.errors).toContain('binary provenance commit 与 report 顶层 commit 不一致。');
  });

  it('requires every repetition to provide RSS and footprint samples', () => {
    const report = makeReport('v24.18.1');
    report.runs[1].finalProcess.raw.rootFootprintBytes = [];
    const result = validatePerfReport(report, { role: 'node24-ci', scenario: 'history-24' });

    expect(result.ok).toBe(false);
    expect(result.errors).toContain(
      'scenario history-24 repetition=2 缺少 rootFootprintBytes workload sample。',
    );
  });

  it('requires a present and valid manifest even when both reports omit it', () => {
    const reference = makeReport('v24.18.1');
    const candidate = makeReport('v26.0.0');
    delete reference.manifest;
    delete candidate.manifest;
    const result = comparePerfReports({
      reference,
      candidate,
      policy: makePolicy(),
      scenario: 'history-24',
    });

    expect(result.status).toBe('failed');
    expect(result.failures.some((message) => message.includes('manifest 缺失'))).toBe(true);
  });

  it('requires unique repetition identities [1,2,3]', () => {
    const report = makeReport('v24.18.1');
    report.runs[1].repetition = 1;
    const result = validatePerfReport(report, { role: 'node24-ci', scenario: 'history-24' });

    expect(result.ok).toBe(false);
    expect(result.errors).toContain('scenario history-24 repetition identity 必须恰好是 [1,2,3]。');
  });
});
