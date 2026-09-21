/**
 * Optional performance instrumentation used by the packaged Release benchmark.
 *
 * The domain remains unaware of the output destination. Production callers may
 * omit the sink entirely, while the Electron perf fixture can collect timings
 * without adding timing fields to business DTOs or changing business results.
 */
export interface PerformanceTraceSink {
  measure<T>(scope: string, phase: string, task: () => T): T;
}
