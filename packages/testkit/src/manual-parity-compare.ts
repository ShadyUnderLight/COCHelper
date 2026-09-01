import { sha256Fingerprint } from '@coc-helper/wire';

import type { ParityReport } from './compare';
import type { ParityCategory } from './manifest';
import type { SwiftOracleResponse } from './oracle';

export function compareManualOutcomeParity(input: {
  readonly caseId: string;
  readonly source: string;
  readonly typescriptHex: string;
  readonly swift: SwiftOracleResponse;
  readonly category?: ParityCategory;
}): ParityReport {
  const category = input.category ?? 'projection';
  const inputFingerprint = sha256Fingerprint(input.source);
  const differences: ParityReport['differences'][number][] = [];

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
  } else if (input.swift.value.canonicalHex !== input.typescriptHex) {
    differences.push({
      category,
      path: '$.value.canonicalHex',
      expected: input.typescriptHex,
      actual: input.swift.value.canonicalHex,
    });
  }

  const outputFingerprint = input.swift.ok
    ? sha256Fingerprint(hexToBytes(input.swift.value.canonicalHex))
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
