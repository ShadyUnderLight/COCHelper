import { describe, expect, it } from 'vitest';

import { createPerformanceTraceSink, PERFORMANCE_TRACE_PREFIX } from './performance-trace';

describe('performance trace sink', () => {
  it('records a successful phase without changing its return value', () => {
    const lines: string[] = [];
    const trace = createPerformanceTraceSink((line) => lines.push(line));

    expect(trace.measure('history', 'canonicalization', () => 42)).toBe(42);
    expect(lines).toHaveLength(1);
    expect(lines[0]?.startsWith(PERFORMANCE_TRACE_PREFIX)).toBe(true);
    expect(JSON.parse(lines[0]!.slice(PERFORMANCE_TRACE_PREFIX.length))).toMatchObject({
      sequence: 1,
      scope: 'history',
      phase: 'canonicalization',
    });
  });

  it('records a failed phase while preserving the original error', () => {
    const lines: string[] = [];
    const trace = createPerformanceTraceSink((line) => lines.push(line));
    const error = new Error('phase failed');

    expect(() =>
      trace.measure('storage', 'write', () => {
        throw error;
      }),
    ).toThrow(error);
    expect(lines).toHaveLength(1);
    expect(JSON.parse(lines[0]!.slice(PERFORMANCE_TRACE_PREFIX.length))).toMatchObject({
      sequence: 1,
      scope: 'storage',
      phase: 'write',
    });
  });
});
