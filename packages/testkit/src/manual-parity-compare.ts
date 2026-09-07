import type { ParityReport } from './compare';
import type { ParityCategory } from './manifest';
import type { SwiftOracleResponse } from './oracle';

export function compareManualOutcomeParity(input: {
  readonly caseId: string;
  readonly typescriptHex: string;
  readonly swift: SwiftOracleResponse;
  readonly expectedCanonicalHex?: string;
  readonly category?: ParityCategory;
}): ParityReport {
  const category = input.category ?? 'projection';
  const differences: ParityReport['differences'][number][] = [];
  const expectedCanonicalHex = input.expectedCanonicalHex ?? input.typescriptHex;

  if (!input.swift.ok) {
    differences.push({
      category: 'error',
      path: '$.ok',
      expected: 'true',
      actual: 'false',
    });
  } else {
    if (input.typescriptHex !== expectedCanonicalHex) {
      differences.push({
        category: 'fixture',
        path: '$.expected.canonicalHex',
        expected: expectedCanonicalHex,
        actual: input.typescriptHex,
      });
    }
    if (input.swift.value.canonicalHex !== expectedCanonicalHex) {
      differences.push({
        category: 'fixture',
        path: '$.expected.canonicalHex',
        expected: expectedCanonicalHex,
        actual: input.swift.value.canonicalHex,
      });
    }
    if (input.typescriptHex !== input.swift.value.canonicalHex) {
      differences.push({
        category,
        path: '$.value.canonicalHex',
        expected: input.typescriptHex,
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
