function sortedNumbers(values) {
  return values.filter((value) => Number.isFinite(value)).sort((left, right) => left - right);
}

function percentile(values, ratio) {
  const sorted = sortedNumbers(values);
  if (sorted.length === 0) return null;
  const index = Math.min(sorted.length - 1, Math.ceil(sorted.length * ratio) - 1);
  return sorted[index];
}

export function summarizeNumbers(values) {
  const sorted = sortedNumbers(values);
  if (sorted.length === 0) {
    return { count: 0, min: null, p50: null, p95: null, max: null, mean: null };
  }
  return {
    count: sorted.length,
    min: sorted[0],
    p50: percentile(sorted, 0.5),
    p95: percentile(sorted, 0.95),
    max: sorted[sorted.length - 1],
    mean: sorted.reduce((total, value) => total + value, 0) / sorted.length,
  };
}

export function summarizeProcessSamples(samples) {
  const processCounts = samples
    .map((sample) => sample.pids?.length)
    .filter((value) => typeof value === 'number');
  const rssBytes = samples
    .map((sample) => sample.rssBytes)
    .filter((value) => typeof value === 'number');
  const cpuPercent = samples
    .map((sample) => sample.cpuPercent)
    .filter((value) => typeof value === 'number');
  const rootFootprintBytes = samples
    .map((sample) => sample.rootFootprintBytes)
    .filter((value) => typeof value === 'number');
  const samplingDurationMs = samples
    .map((sample) => sample.samplingDurationMs)
    .filter((value) => typeof value === 'number');
  return {
    sampleCount: samples.length,
    rssBytes: summarizeNumbers(rssBytes),
    cpuPercent: summarizeNumbers(cpuPercent),
    rootFootprintBytes: summarizeNumbers(rootFootprintBytes),
    raw: { rssBytes, cpuPercent, rootFootprintBytes },
    samplingDurationMs: summarizeNumbers(samplingDurationMs),
    footprintAvailable: rootFootprintBytes.length > 0,
    processCount: processCounts.length === 0 ? null : Math.max(...processCounts),
  };
}

export function workloadProcessSummariesForRun(run) {
  const summaries = [];
  if (run.preparation?.process !== null && run.preparation?.process !== undefined) {
    summaries.push(run.preparation.process);
  }
  if (run.finalProcess !== null && run.finalProcess !== undefined) {
    summaries.push(run.finalProcess);
  }
  if (summaries.length === 0) {
    summaries.push(run.startup?.process, run.restartStartup?.process);
  }
  return summaries.filter((value) => value !== null && value !== undefined);
}

export function collectProcessMetric(runs, metric) {
  const values = [];
  for (const run of runs) {
    for (const process of workloadProcessSummariesForRun(run)) {
      values.push(...(process.raw?.[metric] ?? []));
    }
  }
  return summarizeNumbers(values);
}
