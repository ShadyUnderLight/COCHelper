import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { formatAppleDouble, normalizeJsonNumberToken } from './json-number';

const fixturePath = join(process.cwd(), 'Tests/Golden/Fixtures/nsnumber-stringvalue.json');

describe('NSNumber.stringValue golden（WA-1.2）', () => {
  it('逐 token 对齐 JSONSerialization → NSNumber.stringValue', () => {
    const fixture = JSON.parse(readFileSync(fixturePath, 'utf8')) as {
      stringValues: Record<string, string>;
    };
    for (const [raw, expected] of Object.entries(fixture.stringValues)) {
      expect(normalizeJsonNumberToken(raw), raw).toBe(expected);
    }
  });

  it('double 路径对齐 Darwin %.16g', () => {
    expect(formatAppleDouble(1)).toBe('1');
    expect(formatAppleDouble(1e20)).toBe('1e+20');
    expect(formatAppleDouble(1e-6)).toBe('1e-06');
    expect(formatAppleDouble(1234567890123456.5)).toBe('1234567890123456');
  });
});
