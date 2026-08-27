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
  isVitestExecutedOwner,
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
  it('允许匿名 Tag，拒绝真实 Tag / JWT / header Cookie', () => {
    const bearer = ['Authorization', ': ', 'Bearer', ' ', 'super-secret-value'].join('');
    const jwt = [
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9',
      'eyJzdWIiOiIxMjM0NTY3ODkwIn0',
      'abcdefghij',
    ].join('.');
    expect(findFixtureSecretHits('{"tag":"#GOLDEN01"}', 'ok.json')).toEqual([]);
    expect(findFixtureSecretHits('{"tag":"#8G9P0Q2L"}', 'bad.json')).toEqual([
      'bad.json → 真实 Tag #8G9P0Q2L',
    ]);
    expect(() => assertGoldenPayloadSafe(bearer, 'hdr.txt')).toThrow('Authorization Bearer');
    expect(() => assertGoldenPayloadSafe(jwt, 'jwt.txt')).toThrow('JWT');
    expect(() => assertGoldenPayloadSafe('Cookie: session=abc', 'cookie.txt')).toThrow('Cookie');
  });

  it('拒绝 JSON 字段里的 cookie / token，不依赖 header 形态', () => {
    const payload = JSON.stringify({
      cookie: 'session=real-secret',
      token: 'real-api-token',
      authorization: 'Bearer real-secret',
      nested: { accessToken: 'abc', refreshToken: 'def', apiToken: 'ghi' },
      list: [{ 'set-cookie': 'sid=1' }],
    });
    expect(() => assertGoldenPayloadSafe(payload, 'api.json')).toThrow('JSON 敏感键 $.cookie');
    expect(() => assertGoldenPayloadSafe(payload, 'api.json')).toThrow('JSON 敏感键 $.token');
    expect(() => assertGoldenPayloadSafe(payload, 'api.json')).toThrow(
      'JSON 敏感键 $.authorization',
    );
    expect(() => assertGoldenPayloadSafe(payload, 'api.json')).toThrow(
      'JSON 敏感键 $.nested.accessToken',
    );
    expect(() => assertGoldenPayloadSafe(payload, 'api.json')).toThrow(
      'JSON 敏感键 $.nested.refreshToken',
    );
    expect(() => assertGoldenPayloadSafe(payload, 'api.json')).toThrow(
      'JSON 敏感键 $.nested.apiToken',
    );
    expect(() => assertGoldenPayloadSafe(payload, 'api.json')).toThrow(
      'JSON 敏感键 $.list[0].set-cookie',
    );
    expect(() =>
      assertGoldenPayloadSafe(JSON.stringify({ apiKey: 'real-secret' }), 'api.json'),
    ).toThrow('JSON 敏感键 $.apiKey');
    expect(() =>
      assertGoldenPayloadSafe(
        JSON.stringify({ source: JSON.stringify({ token: 'real-secret' }) }),
        'raw.json',
      ),
    ).toThrow('JSON 敏感键 $.source.token');
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
        expect(isVitestExecutedOwner(entry.tsOwner ?? '')).toBe(true);
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
  it('未声明 defaultKind 的标量差异归为 wire', () => {
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
    expect(() => compareParity({ expected: [1n, 2n], actual: [2n, 1n] })).toThrow(/ordering/);
  });

  it('类型碰撞与 __proto__ / bigint 不得误报 ordering 或抛 TypeError', () => {
    const assertNotOrdering = (expected: unknown, actual: unknown): void => {
      try {
        compareParity({ expected, actual, defaultKind: 'wire' });
        throw new Error('应当失败');
      } catch (error) {
        expect(error).toBeInstanceOf(ParityMismatchError);
        expect((error as ParityMismatchError).diffs.map((item) => item.kind)).not.toContain(
          'ordering',
        );
      }
    };
    assertNotOrdering([1], ['1']);
    assertNotOrdering([true], ['true']);
    assertNotOrdering(JSON.parse('{"__proto__":1}'), JSON.parse('{"__proto__":2}'));
    assertNotOrdering({ x: 1n }, { x: 2n });
    compareParity({ expected: [1n], actual: [1n] });
  });

  it('capturedAt / createdAt 归为 time，failureKind 归为 error', () => {
    expect(() => compareParity({ expected: { capturedAt: 1 }, actual: { capturedAt: 2 } })).toThrow(
      /time @ \$\.capturedAt/,
    );
    expect(() => compareParity({ expected: { createdAt: 1 }, actual: { createdAt: 2 } })).toThrow(
      /time @ \$\.createdAt/,
    );
    expect(() =>
      compareParity({
        expected: { failureKind: 'timeout' },
        actual: { failureKind: 'network' },
      }),
    ).toThrow(/error @ \$\.failureKind/);
  });

  it('kind / format / 看起来像 hex 的 id 尊重 defaultKind，不被误报为 error 或 time', () => {
    expect(() =>
      compareParity({
        expected: { kind: 'number' },
        actual: { kind: 'string' },
        defaultKind: 'wire',
      }),
    ).toThrow(/wire @ \$\.kind/);
    expect(() =>
      compareParity({
        expected: { kind: 'number' },
        actual: { kind: 'string' },
        defaultKind: 'projection',
      }),
    ).toThrow(/projection @ \$\.kind/);
    expect(() =>
      compareParity({
        expected: { format: 'A' },
        actual: { format: 'B' },
        defaultKind: 'projection',
      }),
    ).toThrow(/projection @ \$\.format/);
    expect(() =>
      compareParity({
        expected: { stat: 1 },
        actual: { stat: 2 },
        defaultKind: 'wire',
      }),
    ).toThrow(/wire @ \$\.stat/);
    expect(() =>
      compareParity({
        expected: { message: 'a', code: 1, reason: 'x' },
        actual: { message: 'b', code: 2, reason: 'y' },
        defaultKind: 'wire',
      }),
    ).toThrow(/wire @ \$\.(?:message|code|reason)/);
    expect(() =>
      compareParity({
        expected: 'deadbeef',
        actual: 'cafebabe',
        defaultKind: 'projection',
      }),
    ).toThrow(/projection @ \$/);
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
    compareParity({ expected: new Date(1), actual: new Date(1) });
  });

  it('Date 与缺失字段不得静默通过', () => {
    expect(() => compareParity({ expected: new Date(1), actual: new Date(2) })).toThrow(
      ParityMismatchError,
    );
    expect(() =>
      compareParity({
        expected: { a: 1 },
        actual: { a: 1, b: undefined },
      }),
    ).toThrow(/wire @ \$\.b/);
    expect(() =>
      compareParity({
        expected: { a: undefined },
        actual: {},
      }),
    ).toThrow(/wire @ \$\.a/);
  });
});

describe('Swift oracle', () => {
  it('默认关闭，不会 spawn Swift', () => {
    expect(isSwiftOracleEnabled({})).toBe(false);
    expect(isSwiftOracleEnabled({ [SWIFT_ORACLE_ENV]: '1' })).toBe(true);
    expect(() => runSwiftOracle(['dump-canonical'], findRepoRoot(), {})).toThrow('默认关闭');
  });
});
