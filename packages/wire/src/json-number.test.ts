import { describe, expect, it } from 'vitest';

import { formatAppleDouble, normalizeJsonNumberToken } from './json-number';

describe('NSNumber.stringValue 数字规范化', () => {
  it('对齐 JSONSerialization 实测 token', () => {
    const cases: Array<[string, string]> = [
      ['0', '0'],
      ['-0', '0'],
      ['1', '1'],
      ['1.0', '1'],
      ['-2.5', '-2.5'],
      ['1e2', '100'],
      ['1E2', '100'],
      ['1e+2', '100'],
      ['1e-2', '0.01'],
      ['9007199254740993', '9007199254740993'],
      ['9223372036854775807', '9223372036854775807'],
      ['-9223372036854775808', '-9223372036854775808'],
      ['9223372036854775808', '9223372036854775808'],
      ['0.1', '0.1'],
      ['0.10', '0.1'],
      ['1.00', '1'],
      ['1.5e1', '15'],
      ['2.5e-1', '0.25'],
      ['1e20', '1e+20'],
      ['1e6', '1000000'],
      ['1e-6', '1e-06'],
      ['1e-20', '9.999999999999999e-21'],
      ['18446744073709551615', '18446744073709551615'],
      ['18446744073709551616', '18446744073709551616'],
      ['-9223372036854775809', '-9223372036854775809'],
    ];
    for (const [raw, expected] of cases) {
      expect(normalizeJsonNumberToken(raw), raw).toBe(expected);
    }
  });

  it('double 路径对齐 %.16g', () => {
    expect(formatAppleDouble(1)).toBe('1');
    expect(formatAppleDouble(1e20)).toBe('1e+20');
    expect(formatAppleDouble(1e-6)).toBe('1e-06');
  });
});
