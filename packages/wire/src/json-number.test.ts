import { describe, expect, it } from 'vitest';

import { formatAppleDouble } from './json-number';

describe('NSNumber.stringValue 非 fixture 路径', () => {
  it('double 路径对齐 Darwin %.16g', () => {
    expect(formatAppleDouble(1)).toBe('1');
    expect(formatAppleDouble(1e20)).toBe('1e+20');
    expect(formatAppleDouble(1e-6)).toBe('1e-06');
    expect(formatAppleDouble(1234567890123456.5)).toBe('1234567890123456');
  });
});
