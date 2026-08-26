import { describe, expect, it } from 'vitest';

import { normalizeJsonNumberToken } from '@coc-helper/wire';

import { compareParity, loadGoldenJson } from './index';

describe('NSNumber.stringValue golden（WA-1.2）', () => {
  it('逐 token 对齐 JSONSerialization → NSNumber.stringValue', () => {
    const fixture = loadGoldenJson<{ stringValues: Record<string, string>; rejects: string[] }>(
      'nsnumber-stringvalue.json',
    );
    for (const [raw, expected] of Object.entries(fixture.stringValues)) {
      compareParity({
        expected,
        actual: normalizeJsonNumberToken(raw),
        path: `$.${raw}`,
      });
    }
  });

  it('NSDecimal 指数越界必须拒绝', () => {
    const fixture = loadGoldenJson<{ rejects: string[] }>('nsnumber-stringvalue.json');
    expect(fixture.rejects.length).toBeGreaterThan(0);
    for (const raw of fixture.rejects) {
      expect(() => normalizeJsonNumberToken(raw), raw).toThrow();
    }
  });
});
