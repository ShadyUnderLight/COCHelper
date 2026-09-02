import { sha256Fingerprint, type Sha256Fingerprint } from '@coc-helper/wire';

import type { ParityReport } from './compare';
import type { ParityCategory } from './manifest';
import type { SwiftOracleResponse } from './oracle';

export function compareManualOutcomeParity(input: {
  readonly caseId: string;
  readonly source: string;
  readonly typescriptHex: string;
  readonly swift: SwiftOracleResponse;
  readonly expectedCanonicalHex?: string;
  readonly expectedOutputFingerprint?: Sha256Fingerprint;
  readonly category?: ParityCategory;
}): ParityReport {
  const category = input.category ?? 'projection';
  const inputFingerprint = sha256Fingerprint(input.source);
  const differences: ParityReport['differences'][number][] = [];
  const expectedCanonicalHex = input.expectedCanonicalHex ?? input.typescriptHex;

  if (input.swift.inputFingerprint !== inputFingerprint) {
    differences.push({
      category: 'fixture',
      path: '$.inputFingerprint',
      expected: inputFingerprint,
      actual: input.swift.inputFingerprint,
    });
  }
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
    const outputFingerprint = sha256Fingerprint(hexToBytes(input.swift.value.canonicalHex));
    if (input.expectedOutputFingerprint !== undefined) {
      if (outputFingerprint !== input.expectedOutputFingerprint) {
        differences.push({
          category: 'fixture',
          path: '$.expected.outputFingerprint',
          expected: input.expectedOutputFingerprint,
          actual: outputFingerprint,
        });
      }
      if (input.swift.outputFingerprint !== input.expectedOutputFingerprint) {
        differences.push({
          category: 'fixture',
          path: '$.expected.outputFingerprint',
          expected: input.expectedOutputFingerprint,
          actual: input.swift.outputFingerprint,
        });
      }
    }
  }

  const outputFingerprint =
    input.swift.ok && input.typescriptHex === expectedCanonicalHex
      ? sha256Fingerprint(hexToBytes(expectedCanonicalHex))
      : undefined;

  return {
    caseId: input.caseId,
    ok: differences.length === 0,
    inputFingerprint,
    outputFingerprint,
    differences,
  };
}

function hexToBytes(value: string): Uint8Array {
  if (!/^[0-9a-f]+$/.test(value) || value.length % 2 !== 0) {
    throw new Error('canonical hex 格式无效。');
  }
  const bytes = new Uint8Array(value.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}
