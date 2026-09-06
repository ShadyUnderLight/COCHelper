import type { ParityCategory } from './manifest';
import type { SwiftOracleResponse } from './oracle';

export type CanonicalOutcome =
  | { readonly ok: true; readonly canonicalHex: string }
  | {
      readonly ok: false;
      readonly error: { readonly kind: string; readonly code: string };
    };

export type ParityDifference = {
  readonly category: ParityCategory;
  readonly path: string;
  readonly expected: string;
  readonly actual: string;
};

export type ParityReport = {
  readonly caseId: string;
  readonly ok: boolean;
  readonly differences: readonly ParityDifference[];
};

export class ParityMismatchError extends Error {
  override readonly name = 'ParityMismatchError';
  readonly report: ParityReport;

  constructor(report: ParityReport) {
    super(formatParityReport(report));
    this.report = report;
  }
}

export function compareCanonicalParity(input: {
  readonly caseId: string;
  readonly expectedAccepted: boolean;
  readonly expectedCanonicalHex?: string;
  readonly typescript: CanonicalOutcome;
  readonly swift: SwiftOracleResponse;
  readonly category?: ParityCategory;
}): ParityReport {
  const category = input.category ?? 'wire';
  const differences: ParityDifference[] = [];

  if (input.typescript.ok !== input.expectedAccepted) {
    differences.push({
      category: 'fixture',
      path: '$.expectedAccepted',
      expected: String(input.expectedAccepted),
      actual: String(input.typescript.ok),
    });
  }
  if (input.swift.ok !== input.expectedAccepted) {
    differences.push({
      category: 'fixture',
      path: '$.expectedAccepted',
      expected: String(input.expectedAccepted),
      actual: String(input.swift.ok),
    });
  }

  if (input.typescript.ok !== input.swift.ok) {
    differences.push({
      category: 'parser',
      path: '$.ok',
      expected: String(input.typescript.ok),
      actual: String(input.swift.ok),
    });
  } else if (!input.typescript.ok && !input.swift.ok) {
    if (input.typescript.error.kind !== input.swift.error.kind) {
      differences.push({
        category: 'error',
        path: '$.error.kind',
        expected: input.typescript.error.kind,
        actual: input.swift.error.kind,
      });
    }
    if (input.typescript.error.code !== input.swift.error.code) {
      differences.push({
        category: 'error',
        path: '$.error.code',
        expected: input.typescript.error.code,
        actual: input.swift.error.code,
      });
    }
  } else if (input.typescript.ok && input.swift.ok) {
    if (input.expectedCanonicalHex !== undefined) {
      if (input.typescript.canonicalHex !== input.expectedCanonicalHex) {
        differences.push({
          category: 'fixture',
          path: '$.value.canonicalHex',
          expected: input.expectedCanonicalHex,
          actual: input.typescript.canonicalHex,
        });
      }
      if (input.swift.value.canonicalHex !== input.expectedCanonicalHex) {
        differences.push({
          category: 'fixture',
          path: '$.value.canonicalHex',
          expected: input.expectedCanonicalHex,
          actual: input.swift.value.canonicalHex,
        });
      }
    }
    if (input.typescript.canonicalHex !== input.swift.value.canonicalHex) {
      differences.push({
        category,
        path: '$.value.canonicalHex',
        expected: input.typescript.canonicalHex,
        actual: input.swift.value.canonicalHex,
      });
    }
  }

  return {
    caseId: input.caseId,
    ok: differences.length === 0,
    differences,
  };
}

export function assertParity(report: ParityReport): void {
  if (!report.ok) {
    throw new ParityMismatchError(report);
  }
}

export function firstDifference(
  expected: unknown,
  actual: unknown,
  category: ParityCategory = 'wire',
  path = '$',
): ParityDifference | undefined {
  if (typeof expected !== typeof actual || (expected === null) !== (actual === null)) {
    return difference(category, path, expected, actual);
  }
  if (expected === null || actual === null) {
    return Object.is(expected, actual) ? undefined : difference(category, path, expected, actual);
  }
  if (Array.isArray(expected) || Array.isArray(actual)) {
    if (!Array.isArray(expected) || !Array.isArray(actual)) {
      return difference(category, path, expected, actual);
    }
    if (expected.length !== actual.length) {
      return difference(category, `${path}.length`, expected.length, actual.length);
    }
    for (let index = 0; index < expected.length; index += 1) {
      const found = firstDifference(expected[index], actual[index], category, `${path}[${index}]`);
      if (found !== undefined) {
        return found;
      }
    }
    return undefined;
  }
  if (typeof expected === 'object' && typeof actual === 'object') {
    const expectedObject = expected as Record<string, unknown>;
    const actualObject = actual as Record<string, unknown>;
    const keys = [
      ...new Set([...Object.keys(expectedObject), ...Object.keys(actualObject)]),
    ].sort();
    for (const key of keys) {
      if (!Object.hasOwn(expectedObject, key) || !Object.hasOwn(actualObject, key)) {
        return difference(category, `${path}.${key}`, expectedObject[key], actualObject[key]);
      }
      const found = firstDifference(
        expectedObject[key],
        actualObject[key],
        category,
        `${path}.${key}`,
      );
      if (found !== undefined) {
        return found;
      }
    }
    return undefined;
  }
  return Object.is(expected, actual) ? undefined : difference(category, path, expected, actual);
}

function difference(
  category: ParityCategory,
  path: string,
  expected: unknown,
  actual: unknown,
): ParityDifference {
  return {
    category,
    path,
    expected: summarize(expected),
    actual: summarize(actual),
  };
}

function formatParityReport(report: ParityReport): string {
  const details = report.differences
    .map((item) => `${item.category} ${item.path} expected=${item.expected} actual=${item.actual}`)
    .join('; ');
  return `parity 失败（caseId=${report.caseId}）：${details}`;
}

function summarize(value: unknown): string {
  if (typeof value === 'string') {
    return `<string length=${value.length}>`;
  }
  if (typeof value === 'bigint') {
    return `<bigint ${value.toString()}>`;
  }
  if (Array.isArray(value)) {
    return `<array length=${value.length}>`;
  }
  if (typeof value === 'object' && value !== null) {
    return `<object keys=${Object.keys(value).length}>`;
  }
  return String(value);
}
