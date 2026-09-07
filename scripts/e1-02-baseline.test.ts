import { describe, expect, it } from 'vitest';

import {
  BASELINE_SUITE_IDS,
  resolveBaselineSuiteSelection,
} from './e1-02-baseline-selection.mjs';

describe('resolveBaselineSuiteSelection', () => {
  it('未设置 env 时选择全部 suite', () => {
    expect(resolveBaselineSuiteSelection(undefined)).toEqual([...BASELINE_SUITE_IDS]);
  });

  it('单个合法 suite', () => {
    expect(resolveBaselineSuiteSelection('parity')).toEqual(['parity']);
  });

  it('多个合法 suites（按 known 顺序去重）', () => {
    expect(resolveBaselineSuiteSelection('oracle-isolation,parity,parity')).toEqual([
      'parity',
      'oracle-isolation',
    ]);
  });

  it('合法 + 未知 suite → 抛错', () => {
    expect(() => resolveBaselineSuiteSelection('parity,registraton')).toThrow(
      /Unknown E1-02 baseline suite\(s\): registraton/,
    );
  });

  it('全部都是未知 suite → 抛错', () => {
    expect(() => resolveBaselineSuiteSelection('registraton,baseline')).toThrow(
      /Unknown E1-02 baseline suite\(s\): registraton, baseline/,
    );
  });

  it('显式提供但最终为空的 selection → 抛错', () => {
    expect(() => resolveBaselineSuiteSelection('')).toThrow(/No E1-02 baseline suites selected/);
    expect(() => resolveBaselineSuiteSelection(' , , ')).toThrow(/No E1-02 baseline suites selected/);
  });
});
