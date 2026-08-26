import { existsSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  assertFixtureFingerprints,
  assertGoldenPayloadSafe,
  compareParity,
  findFixtureSecretHits,
  findRepoRoot,
  isSwiftOracleEnabled,
  loadGoldenJson,
  loadGoldenManifest,
  loadGoldenText,
  loadTestRegistry,
  ParityMismatchError,
  resolveGoldenFixture,
  runSwiftOracle,
  SWIFT_ORACLE_ENV,
  TEST_CATEGORIES,
} from './index';

describe('golden fixture loader', () => {
  it('拒绝绝对路径和 .. 逃逸', () => {
    expect(() => resolveGoldenFixture('../Package.swift')).toThrow('非法 golden 相对路径');
    expect(() => resolveGoldenFixture('/etc/passwd')).toThrow('禁止绝对 golden 路径');
    expect(() => resolveGoldenFixture('..\\Package.swift')).toThrow('非法 golden 相对路径');
  });

  it('能加载匿名 canonical 期望值', () => {
    const expected = loadGoldenJson<{ expectations: Record<string, string> }>(
      'canonical-json-expected.json',
    );
    expect(Object.keys(expected.expectations).length).toBeGreaterThan(0);
    expect(loadGoldenText('account_snapshot_golden.json')).toContain('#GOLDEN01');
  });
});

describe('fixture 脱敏', () => {
  it('允许匿名 Tag，拒绝真实 Tag / JWT / Cookie', () => {
    expect(findFixtureSecretHits('{"tag":"#GOLDEN01"}', 'ok.json')).toEqual([]);
    expect(findFixtureSecretHits('{"tag":"#8G9P0Q2L"}', 'bad.json')).toEqual([
      'bad.json → 真实 Tag #8G9P0Q2L',
    ]);
    expect(() =>
      assertGoldenPayloadSafe('Authorization: Bearer super-secret-value', 'hdr.txt'),
    ).toThrow('Authorization Bearer');
    expect(() =>
      assertGoldenPayloadSafe(
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghij',
        'jwt.txt',
      ),
    ).toThrow('JWT');
    expect(() => assertGoldenPayloadSafe('Cookie: session=abc', 'cookie.txt')).toThrow('Cookie');
  });
});

describe('golden manifest', () => {
  it('登记项 fingerprint 与文件一致，且含未消费的 parser golden', () => {
    const manifest = loadGoldenManifest();
    expect(manifest.schemaVersion).toBe(1);
    expect(manifest.fixtures.map((entry) => entry.id)).toContain('account-snapshot-parser');
    for (const fixture of manifest.fixtures) {
      assertFixtureFingerprints(fixture);
    }
    const parser = manifest.fixtures.find((entry) => entry.id === 'account-snapshot-parser');
    expect(parser?.status).toBe('unported');
    expect(parser?.ownerIssue).toBe(269);
  });
});

describe('test registry', () => {
  it('覆盖八类 load-bearing 测试，ported 项有 tsOwner，unported 项为空', () => {
    const registry = loadTestRegistry();
    const categories = new Set(registry.tests.map((entry) => entry.category));
    expect([...TEST_CATEGORIES].every((category) => categories.has(category))).toBe(true);

    const repoRoot = findRepoRoot();
    for (const entry of registry.tests) {
      expect(existsSync(path.join(repoRoot, entry.swift)), entry.swift).toBe(true);
      expect(entry.loadBearing).toBe(true);
      if (entry.status === 'ported') {
        expect(entry.tsOwner).not.toBeNull();
        expect(existsSync(path.join(repoRoot, entry.tsOwner ?? '')), entry.tsOwner ?? '').toBe(
          true,
        );
      } else {
        expect(entry.tsOwner).toBeNull();
      }
    }

    const parserGolden = registry.tests.find((entry) => entry.id === 'ParserGoldenTests');
    expect(parserGolden?.status).toBe('unported');
    expect(
      registry.tests.some((entry) => entry.status === 'ported' && entry.category === 'wire'),
    ).toBe(true);
  });
});

describe('parity 差异分类', () => {
  it('canonical hex 差异归为 wire', () => {
    expect(() => compareParity({ expected: 'aabbccdd', actual: 'aabbccde' })).toThrowError(
      ParityMismatchError,
    );
    try {
      compareParity({ expected: 'aabbccdd', actual: 'aabbccde' });
    } catch (error) {
      expect(error).toBeInstanceOf(ParityMismatchError);
      expect((error as ParityMismatchError).diffs[0]?.kind).toBe('wire');
    }
  });

  it('键序/数组序差异归为 ordering', () => {
    expect(() =>
      compareParity({
        expected: JSON.parse('{"a":1,"b":2}'),
        actual: JSON.parse('{"b":2,"a":1}'),
      }),
    ).toThrow(/ordering/);
    expect(() => compareParity({ expected: [1, 2], actual: [2, 1] })).toThrow(/ordering/);
  });

  it('时间字段与 failureKind 分别归为 time / error', () => {
    expect(() => compareParity({ expected: { capturedAt: 1 }, actual: { capturedAt: 2 } })).toThrow(
      /time @ \$\.capturedAt/,
    );
    expect(() =>
      compareParity({
        expected: { failureKind: 'timeout' },
        actual: { failureKind: 'network' },
      }),
    ).toThrow(/error @ \$\.failureKind/);
  });

  it('调用方可声明 projection 默认层', () => {
    expect(() =>
      compareParity({
        expected: { rows: 1 },
        actual: { rows: 2 },
        defaultKind: 'projection',
      }),
    ).toThrow(/projection @ \$\.rows/);
  });

  it('一致则通过', () => {
    compareParity({ expected: { a: 1 }, actual: { a: 1 } });
  });
});

describe('Swift oracle', () => {
  it('默认关闭，不会 spawn Swift', () => {
    expect(isSwiftOracleEnabled({})).toBe(false);
    expect(isSwiftOracleEnabled({ [SWIFT_ORACLE_ENV]: '1' })).toBe(true);
    expect(() => runSwiftOracle(['dump-canonical'], findRepoRoot(), {})).toThrow('默认关闭');
  });
});
