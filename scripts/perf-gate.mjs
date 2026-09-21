#!/usr/bin/env node

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { FROZEN_RELEASE_BASELINE } from './perf-config.mjs';
import { workloadMetricSampleCountForRun } from './perf-metrics.mjs';

export const RELEASE_GATE_PROTOCOL = 'electron-release-perf-gate-v1';
export const RELEASE_PERF_PROTOCOL = 'electron-release-perf-v1';

const COMMON_METRICS = Object.freeze([
  'startupMs.p50',
  'ttiMs.p50',
  'overviewColdMs.p50',
  'detailColdMs.p50',
  'overviewHotMs.p50',
  'overviewColdRendererCommitMs.p50',
  'detailColdRendererCommitMs.p50',
  'overviewHotRendererCommitMs.p50',
  'overviewPayloadBytes.p95',
  'detailPayloadBytes.p95',
  'detailScrollFrameP95.p50',
  'detailScrollFrameMax.p50',
  'detailScrollLongFrames.p50',
  'detailScrollHitches.p50',
  'peakRssBytes.max',
  'peakFootprintBytes.max',
]);

export const REQUIRED_GATE_METRICS = Object.freeze({
  overview: COMMON_METRICS,
  'village-detail': Object.freeze([
    ...COMMON_METRICS,
    'restartStartupMs.p50',
    'restartTtiMs.p50',
    'wallBeforeImportMs.p50',
    'wallAfterImportMs.p50',
  ]),
  'history-24': Object.freeze([
    ...COMMON_METRICS,
    'restartStartupMs.p50',
    'restartTtiMs.p50',
    'historyImportTotalMs.p50',
    'phaseDurations.historyLoad.p50',
    'phaseDurations.historyCanonicalization.p50',
    'phaseDurations.historyValidatePrevious.p50',
    'phaseDurations.historyValidateWire.p50',
    'phaseDurations.storageCommit.p50',
  ]),
  'official-lists': Object.freeze([
    ...COMMON_METRICS,
    'warLogPayloadBytes.p95',
    'capitalRaidPayloadBytes.p95',
    'officialScrollFrameP95.p50',
    'officialScrollFrameMax.p50',
    'officialScrollLongFrames.p50',
    'officialScrollHitches.p50',
  ]),
});

const ROLE_NODE_MAJORS = Object.freeze({
  'node24-ci': 24,
  'node26-local': 26,
});

export function requiredGateMetricPaths(scenario) {
  const metrics = REQUIRED_GATE_METRICS[scenario];
  if (metrics === undefined) {
    throw new Error(`未知性能 gate scenario：${String(scenario)}`);
  }
  return metrics;
}

export function metricValue(summary, metricPath) {
  let value = summary;
  for (const part of metricPath.split('.')) {
    value = value?.[part];
  }
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

export function validatePerfReport(report, { role, scenario } = {}) {
  const errors = [];
  if (report === null || typeof report !== 'object') {
    return { ok: false, errors: ['report 必须是对象。'] };
  }

  const options = report.options;
  const expectedScenario = scenario ?? options?.scenario;
  const requiredMetrics = REQUIRED_GATE_METRICS[expectedScenario];
  if (requiredMetrics === undefined) {
    errors.push(`report scenario 无法用于 gate：${String(expectedScenario)}`);
    return { ok: false, errors };
  }
  if (report.protocol !== RELEASE_PERF_PROTOCOL) {
    errors.push(`report protocol 不匹配：${String(report.protocol)}`);
  }
  if (report.status !== 'observed') {
    errors.push(`report status 必须是 observed：${String(report.status)}`);
  }
  if (!Array.isArray(report.failures) || report.failures.length !== 0) {
    errors.push('report 存在失败 run，不能进入性能 gate。');
  }
  if (options?.profile !== 'baseline') {
    errors.push(`report profile 必须是 baseline：${String(options?.profile)}`);
  }
  if (options?.scenario !== expectedScenario) {
    errors.push(`report scenario 不匹配：期望 ${expectedScenario}，实际 ${String(options?.scenario)}`);
  }
  if (options?.repetitions !== FROZEN_RELEASE_BASELINE.repetitions) {
    errors.push(`repetitions 不匹配：${String(options?.repetitions)}`);
  }
  if (options?.warmup !== FROZEN_RELEASE_BASELINE.warmup) {
    errors.push(`warmup 不匹配：${String(options?.warmup)}`);
  }
  if (options?.scrollMs !== FROZEN_RELEASE_BASELINE.scrollMs) {
    errors.push(`scrollMs 不匹配：${String(options?.scrollMs)}`);
  }
  if (report.sampling?.processSampleIntervalMs !== FROZEN_RELEASE_BASELINE.processSampleIntervalMs) {
    errors.push(
      `processSampleIntervalMs 不匹配：${String(report.sampling?.processSampleIntervalMs)}`,
    );
  }
  if (report.sampling?.footprintSampleEvery !== FROZEN_RELEASE_BASELINE.footprintSampleEvery) {
    errors.push(`footprintSampleEvery 不匹配：${String(report.sampling?.footprintSampleEvery)}`);
  }

  const source = report.sourceProvenance;
  const binary = report.binaryProvenance;
  if (typeof report.commitSha !== 'string' || report.commitSha.length === 0) {
    errors.push('report 缺少顶层 commitSha。');
  }
  if (
    typeof source?.commitSha !== 'string' ||
    source.commitSha.length === 0 ||
    source.dirty !== false ||
    !Array.isArray(source.untrackedInputs) ||
    source.untrackedInputs.length !== 0
  ) {
    errors.push('source provenance 不完整或 worktree 非 clean。');
  }
  if (
    typeof binary?.commitSha !== 'string' ||
    binary.commitSha.length === 0 ||
    binary.dirty !== false
  ) {
    errors.push('binary provenance 不完整或 packaged binary 非 clean。');
  }
  if (source?.commitSha !== binary?.commitSha) {
    errors.push('source commit 与 binary commit 不一致。');
  }
  if (source?.commitSha !== report.commitSha) {
    errors.push('source provenance commit 与 report 顶层 commit 不一致。');
  }
  if (binary?.commitSha !== report.commitSha) {
    errors.push('binary provenance commit 与 report 顶层 commit 不一致。');
  }

  const manifest = report.manifest;
  if (
    manifest === null ||
    typeof manifest !== 'object' ||
    manifest.schemaVersion !== 1 ||
    manifest.protocol !== RELEASE_PERF_PROTOCOL
  ) {
    errors.push('report manifest 缺失或 schema/protocol 不匹配。');
  }

  const environment = report.environment;
  if (!nonEmptyString(environment?.platform) || !nonEmptyString(environment?.arch)) {
    errors.push('report 缺少 platform/arch 环境身份。');
  }
  const nodeVersion = typeof environment?.node === 'string' ? environment.node : '';
  if (!nonEmptyString(nodeVersion) || nodeMajor(nodeVersion) === null) {
    errors.push('report 缺少 runner Node 版本。');
  }
  const hasKnownRole = Object.hasOwn(ROLE_NODE_MAJORS, role);
  const expectedNodeMajor = hasKnownRole ? ROLE_NODE_MAJORS[role] : undefined;
  if (!hasKnownRole) {
    errors.push(`不支持的 gate role：${String(role)}`);
  } else if (nodeMajor(nodeVersion) !== expectedNodeMajor) {
    errors.push(`${role} 期望 Node ${expectedNodeMajor}，实际 ${nodeVersion || 'unknown'}。`);
  }

  const runs = Array.isArray(report.runs)
    ? report.runs.filter((run) => run?.scenario === expectedScenario)
    : [];
  if (runs.length !== FROZEN_RELEASE_BASELINE.repetitions) {
    errors.push(`scenario ${expectedScenario} run 数量不是 3：${runs.length}`);
  }
  const repetitionIds = runs.map((run) => run.repetition).sort((left, right) => left - right);
  const expectedRepetitionIds = [1, 2, 3];
  if (
    repetitionIds.length !== expectedRepetitionIds.length ||
    repetitionIds.some((value, index) => value !== expectedRepetitionIds[index])
  ) {
    errors.push(`scenario ${expectedScenario} repetition identity 必须恰好是 [1,2,3]。`);
  }
  for (const [index, run] of runs.entries()) {
    if (
      !nonEmptyString(run.runtime?.node) ||
      nodeMajor(run.runtime.node) === null ||
      !nonEmptyString(run.runtime?.platform) ||
      !nonEmptyString(run.runtime?.arch)
    ) {
      errors.push(`scenario ${expectedScenario} repetition=${index + 1} 缺少 Electron runtime Node。`);
    }
    for (const metric of ['rssBytes', 'rootFootprintBytes']) {
      if (workloadMetricSampleCountForRun(run, metric) === 0) {
        errors.push(
          `scenario ${expectedScenario} repetition=${index + 1} 缺少 ${metric} workload sample。`,
        );
      }
    }
  }

  const summary = report.summary?.[expectedScenario];
  for (const metricPath of requiredMetrics) {
    if (metricValue(summary, metricPath) === null) {
      errors.push(`scenario ${expectedScenario} 缺少可用 metric：${metricPath}`);
    }
  }

  return { ok: errors.length === 0, errors };
}

export function comparePerfReports({ reference, candidate, policy, scenario }) {
  const referenceCheck = validatePerfReport(reference, {
    role: policy?.referenceRole,
    scenario,
  });
  const candidateCheck = validatePerfReport(candidate, {
    role: policy?.candidateRole,
    scenario,
  });
  const failures = [
    ...referenceCheck.errors.map((message) => `reference: ${message}`),
    ...candidateCheck.errors.map((message) => `candidate: ${message}`),
  ];

  if (reference?.commitSha !== candidate?.commitSha) {
    failures.push('reference/candidate commit 不一致。');
  }
  if (reference?.binaryProvenance?.commitSha !== candidate?.binaryProvenance?.commitSha) {
    failures.push('reference/candidate binary commit 不一致。');
  }
  if (stableJson(reference?.manifest) !== stableJson(candidate?.manifest)) {
    failures.push('reference/candidate fixture manifest 不一致。');
  }
  if (reference?.environment?.platform !== candidate?.environment?.platform) {
    failures.push('reference/candidate platform 不一致。');
  }
  if (reference?.environment?.arch !== candidate?.environment?.arch) {
    failures.push('reference/candidate arch 不一致。');
  }

  const policyCheck = validateGatePolicy(policy, scenario);
  failures.push(...policyCheck.errors.map((message) => `policy: ${message}`));

  const comparisons = [];
  if (failures.length === 0 && referenceCheck.ok && candidateCheck.ok && policyCheck.ok) {
    const referenceSummary = reference.summary[scenario];
    const candidateSummary = candidate.summary[scenario];
    for (const metricPath of requiredGateMetricPaths(scenario)) {
      const rule = policy.metrics[metricPath];
      const referenceValue = metricValue(referenceSummary, metricPath);
      const candidateValue = metricValue(candidateSummary, metricPath);
      const allowedIncrease = Math.max(
        rule.maxAbsoluteIncrease ?? 0,
        Math.abs(referenceValue) * (rule.maxRelativeIncrease ?? 0),
      );
      const delta = candidateValue - referenceValue;
      comparisons.push({
        metric: metricPath,
        reference: referenceValue,
        candidate: candidateValue,
        delta,
        allowedIncrease,
        status: delta <= allowedIncrease ? 'passed' : 'failed',
      });
      if (delta > allowedIncrease) {
        failures.push(
          `${metricPath} 超出容差：delta=${formatNumber(delta)} > allowed=${formatNumber(allowedIncrease)}`,
        );
      }
    }
  }

  return {
    protocol: RELEASE_GATE_PROTOCOL,
    scenario,
    status: failures.length === 0 ? 'passed' : 'failed',
    acceptanceEligible: failures.length === 0,
    reference: reportIdentity(reference),
    candidate: reportIdentity(candidate),
    comparisons,
    failures,
  };
}

export function validatePerfReportContract(report, { role, scenario }) {
  const check = validatePerfReport(report, { role, scenario });
  return {
    protocol: RELEASE_GATE_PROTOCOL,
    scenario,
    role,
    status: check.ok ? 'passed' : 'failed',
    contractPassed: check.ok,
    acceptanceEligible: false,
    report: reportIdentity(report),
    failures: check.errors,
  };
}

export function validateGatePolicy(policy, scenario) {
  const errors = [];
  if (policy === null || typeof policy !== 'object') {
    return { ok: false, errors: ['policy 必须是对象。'] };
  }
  if (policy.schemaVersion !== 1) {
    errors.push(`policy schemaVersion 不支持：${String(policy.schemaVersion)}`);
  }
  if (policy.protocol !== RELEASE_GATE_PROTOCOL) {
    errors.push(`policy protocol 不匹配：${String(policy.protocol)}`);
  }
  if (!Object.hasOwn(ROLE_NODE_MAJORS, policy.referenceRole)) {
    errors.push(`policy referenceRole 不支持：${String(policy.referenceRole)}`);
  }
  if (!Object.hasOwn(ROLE_NODE_MAJORS, policy.candidateRole)) {
    errors.push(`policy candidateRole 不支持：${String(policy.candidateRole)}`);
  }
  if (policy.referenceRole === policy.candidateRole) {
    errors.push('referenceRole 与 candidateRole 必须不同。');
  }
  const requiredMetrics = REQUIRED_GATE_METRICS[scenario];
  if (requiredMetrics === undefined) {
    errors.push(`policy scenario 无法用于 gate：${String(scenario)}`);
    return { ok: false, errors };
  }
  if (typeof policy.metrics !== 'object' || policy.metrics === null) {
    errors.push('policy 缺少 metrics。');
    return { ok: false, errors };
  }
  for (const metricPath of requiredMetrics) {
    const rule = policy.metrics[metricPath];
    if (rule === undefined || rule === null || typeof rule !== 'object') {
      errors.push(`policy 缺少 metric tolerance：${metricPath}`);
      continue;
    }
    const absolute = rule.maxAbsoluteIncrease;
    const relative = rule.maxRelativeIncrease;
    const provided = [
      ['maxAbsoluteIncrease', absolute],
      ['maxRelativeIncrease', relative],
    ];
    let validCount = 0;
    for (const [field, value] of provided) {
      if (value === undefined) {
        continue;
      }
      if (!Number.isFinite(value) || value < 0) {
        errors.push(`policy metric tolerance 无效：${metricPath}.${field}`);
      } else {
        validCount += 1;
      }
    }
    if (validCount === 0) {
      errors.push(`policy metric tolerance 至少提供一个合法字段：${metricPath}`);
    }
  }
  return { ok: errors.length === 0, errors };
}

function reportIdentity(report) {
  return {
    commitSha: report?.commitSha ?? null,
    binaryCommitSha: report?.binaryProvenance?.commitSha ?? null,
    platform: report?.environment?.platform ?? null,
    arch: report?.environment?.arch ?? null,
    node: report?.environment?.node ?? null,
  };
}

function nodeMajor(version) {
  if (!nonEmptyString(version)) {
    return null;
  }
  const match = /^v?(\d+)/.exec(version);
  return match === null ? null : Number(match[1]);
}

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function stableJson(value) {
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableJson(item)).join(',')}]`;
  }
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

function formatNumber(value) {
  return Number.isFinite(value) ? String(Math.round(value)) : 'unknown';
}

function readJson(file) {
  return JSON.parse(readFileSync(file, 'utf8'));
}

function optionValue(name) {
  const prefix = `${name}=`;
  const argument = process.argv.find((value) => value.startsWith(prefix));
  return argument === undefined ? undefined : argument.slice(prefix.length);
}

function requireOption(name) {
  const value = optionValue(name);
  if (value === undefined || value.length === 0) {
    throw new Error(`缺少参数 ${name}=...`);
  }
  return value;
}

async function runCli() {
  const reportFile = optionValue('--report');
  if (reportFile !== undefined) {
    const scenario = requireOption('--scenario');
    const role = requireOption('--role');
    const outputFile = optionValue('--output');
    const result = validatePerfReportContract(readJson(reportFile), { role, scenario });
    if (outputFile !== undefined) {
      writeFileSync(outputFile, `${JSON.stringify(result, null, 2)}\n`);
    }
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (result.status !== 'passed') {
      process.exitCode = 1;
    }
    return;
  }
  const referenceFile = requireOption('--reference');
  const candidateFile = requireOption('--candidate');
  const policyFile = requireOption('--policy');
  const scenario = requireOption('--scenario');
  const outputFile = optionValue('--output');
  const result = comparePerfReports({
    reference: readJson(referenceFile),
    candidate: readJson(candidateFile),
    policy: readJson(policyFile),
    scenario,
  });
  if (outputFile !== undefined) {
    writeFileSync(outputFile, `${JSON.stringify(result, null, 2)}\n`);
  }
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (result.status !== 'passed') {
    process.exitCode = 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  runCli().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
