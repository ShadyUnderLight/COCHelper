import { describe, expect, it } from 'vitest';

import { compareCanonicalParity, firstDifference } from './compare';
import type { SwiftOracleResponse } from './oracle';

function swiftSuccess(canonicalHex: string): SwiftOracleResponse {
  return {
    protocolVersion: 2,
    caseId: 'test/case',
    ok: true,
    value: { canonicalHex },
  };
}

describe('parity comparator', () => {
  it('同时检查 fixture 与两侧 canonical bytes', () => {
    const report = compareCanonicalParity({
      caseId: 'test/case',
      expectedAccepted: true,
      expectedCanonicalHex: '31',
      typescript: { ok: true, canonicalHex: '31' },
      swift: swiftSuccess('31'),
    });
    expect(report.ok).toBe(true);
    expect(report.differences).toEqual([]);
  });

  it('把两侧输出差异归类为 wire，并给出稳定路径', () => {
    const report = compareCanonicalParity({
      caseId: 'test/case',
      expectedAccepted: true,
      expectedCanonicalHex: '31',
      typescript: { ok: true, canonicalHex: '31' },
      swift: swiftSuccess('32'),
    });
    expect(report.ok).toBe(false);
    expect(report.differences).toContainEqual({
      category: 'wire',
      path: '$.value.canonicalHex',
      expected: '31',
      actual: '32',
    });
  });

  it('把一侧接受、一侧拒绝归类为 parser', () => {
    const report = compareCanonicalParity({
      caseId: 'test/reject',
      expectedAccepted: false,
      typescript: { ok: false, error: { kind: 'rejected', code: 'invalidJson' } },
      swift: swiftSuccess('31'),
    });
    expect(report.differences).toContainEqual(
      expect.objectContaining({ category: 'parser', path: '$.ok' }),
    );
  });

  it('错误 kind 变化不能被相同 code 掩盖', () => {
    const report = compareCanonicalParity({
      caseId: 'test/reject-kind',
      expectedAccepted: false,
      typescript: { ok: false, error: { kind: 'rejected', code: 'invalidJson' } },
      swift: {
        protocolVersion: 2,
        caseId: 'test/reject-kind',
        ok: false,
        error: { kind: 'not-rejected', code: 'invalidJson' },
      },
    });
    expect(report.ok).toBe(false);
    expect(report.differences).toContainEqual({
      category: 'error',
      path: '$.error.kind',
      expected: 'rejected',
      actual: 'not-rejected',
    });
  });

  it('不会让两侧同时接受 fixture 标记为 reject 的输入', () => {
    const report = compareCanonicalParity({
      caseId: 'test/reject',
      expectedAccepted: false,
      typescript: { ok: true, canonicalHex: '7b226e223a317d' },
      swift: swiftSuccess('7b226e223a317d'),
    });
    expect(report.ok).toBe(false);
    expect(report.differences).toContainEqual(
      expect.objectContaining({ category: 'fixture', path: '$.expectedAccepted' }),
    );
  });

  it('递归比较结构时保留数组顺序并定位首个差异', () => {
    expect(firstDifference({ items: [1, 2] }, { items: [1, 3] }, 'ordering')).toEqual({
      category: 'ordering',
      path: '$.items[1]',
      expected: '2',
      actual: '3',
    });
  });
});
