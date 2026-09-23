import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { maskDiagnosticIdsInWireHex, parseAccountSnapshot, wireHex } from '@coc-helper/domain';
import { refSecondsToUnixSeconds } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { FakeClock } from './fake-clock';

const GOLDEN_IMPORTED_AT_MS = refSecondsToUnixSeconds(807_529_133) * 1000;

describe('account parser golden contract', () => {
  it('account_snapshot_golden 与 parser_golden_expected 一致', () => {
    const root = process.cwd();
    const goldenText = readFileSync(
      resolve(root, 'fixtures/golden/account_snapshot_golden.json'),
      'utf8',
    );
    const expected = JSON.parse(
      readFileSync(resolve(root, 'fixtures/golden/parser_golden_expected.json'), 'utf8'),
    ) as {
      accountSnapshot: {
        encodedJSONHex: string;
      };
    };

    const parsed = parseAccountSnapshot(goldenText, {
      clock: new FakeClock(GOLDEN_IMPORTED_AT_MS),
    });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }

    expect(maskDiagnosticIdsInWireHex(wireHex(parsed.value))).toBe(
      expected.accountSnapshot.encodedJSONHex,
    );
  });
});
