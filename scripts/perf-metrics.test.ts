import { describe, expect, it } from 'vitest';

import {
  collectProcessMetric,
  collectTracePhase,
  summarizeNumbers,
  summarizeProcessSamples,
} from './perf-metrics.mjs';

describe('perf metrics', () => {
  it('缺失进程样本保持 unknown，不产生 0', () => {
    const summary = summarizeProcessSamples([
      { pids: null, rssBytes: null, cpuPercent: null, rootFootprintBytes: null },
    ]);
    expect(summary.rssBytes).toMatchObject({ count: 0, p95: null, max: null });
    expect(summary.cpuPercent).toMatchObject({ count: 0, p95: null, max: null });
    expect(summary.footprintAvailable).toBe(false);
  });

  it('跨 workload 聚合原始样本且不重复 preparation/import/navigation phase', () => {
    const run = {
      preparation: {
        process: { raw: { cpuPercent: [1, 2, 3] } },
        imports: [{ process: { raw: { cpuPercent: [99] } } }],
      },
      finalProcess: { raw: { cpuPercent: [4, 5, 6] } },
      startup: { process: { raw: { cpuPercent: [88] } } },
      views: { process: { navigation: { overview: { raw: { cpuPercent: [77] } } } } },
    };
    expect(collectProcessMetric([run], 'cpuPercent')).toMatchObject({
      count: 6,
      p95: 6,
      max: 6,
    });
  });

  it('数值汇总在空输入时返回可识别的 unknown 结构', () => {
    expect(summarizeNumbers([])).toEqual({
      count: 0,
      min: null,
      p50: null,
      p95: null,
      max: null,
      mean: null,
    });
  });

  it('只聚合匹配 scope/phase 的主进程阶段事件', () => {
    expect(
      collectTracePhase(
        [
          {
            phaseEvents: [
              { scope: 'history', phase: 'validate-wire-history', durationMs: 8 },
              { scope: 'history', phase: 'validate-wire-history', durationMs: 12 },
              { scope: 'storage', phase: 'write', durationMs: 99 },
            ],
          },
        ],
        'history',
        'validate-wire-history',
      ),
    ).toMatchObject({ count: 2, p50: 8, p95: 12, max: 12 });
  });
});
