import { performance } from 'node:perf_hooks';

import type { PerformanceTraceSink } from '@coc-helper/domain';

export const PERFORMANCE_TRACE_PREFIX = 'COCHELPER_PERF_PHASE ';

export function createPerformanceTraceSink(write: (line: string) => void): PerformanceTraceSink {
  let sequence = 0;
  return {
    measure<T>(scope: string, phase: string, task: () => T): T {
      const startedAt = performance.now();
      try {
        return task();
      } finally {
        const event = {
          sequence: ++sequence,
          scope,
          phase,
          durationMs: performance.now() - startedAt,
        };
        try {
          write(`${PERFORMANCE_TRACE_PREFIX}${JSON.stringify(event)}\n`);
        } catch {
          // Profiling must never change the product result or hide the primary error.
        }
      }
    },
  };
}
