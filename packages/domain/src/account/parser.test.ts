import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { refSecondsToUnixSeconds } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { maskDiagnosticIdsInWireHex, parseAccountSnapshot, wireHex } from './index';

const GOLDEN_IMPORTED_AT_MS = refSecondsToUnixSeconds(807_529_133) * 1000;
const SAMPLE_NOW_MS = 1_700_000_600_000;

const sampleJson = `
{
  "tag": "#TESTTAG",
  "timestamp": 1700000000,
  "helpers": [{"data": 93000000, "lvl": 8, "helper_cooldown": 2312}],
  "buildings": [
    {"data": 1000013, "lvl": 17, "timer": 3600},
    {"data": 1000097, "types": [{"data": 103000011, "modules": [{"data": 102000033, "lvl": 1}]}]}
  ],
  "units": [{"data": 4000123, "lvl": 5, "timer": 7200}],
  "house_parts": [82000000, 82000001],
  "buildings2": [{"data": 1000050, "lvl": 7, "timer": 900}],
  "boosts": {"clocktower_cooldown": 25274}
}
`;

class FakeClock {
  constructor(private readonly fixedMs: number) {}

  nowMs(): number {
    return this.fixedMs;
  }
}

describe('AccountSnapshotImporter', () => {
  it('解析 section、嵌套 items 与 timer 扣减', () => {
    const parsed = parseAccountSnapshot(sampleJson, { clock: new FakeClock(SAMPLE_NOW_MS) });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }
    const snapshot = parsed.value;
    expect(snapshot.tag).toBe('#TESTTAG');
    expect(snapshot.objectSections.buildings?.length).toBe(2);
    expect(snapshot.objectSections.buildings2?.length).toBe(1);
    expect(snapshot.numericSections.house_parts).toEqual([82000000n, 82000001n]);
    expect(snapshot.boosts.clocktower_cooldown).toBe(24674n);
    expect(snapshot.objectSections.helpers?.[0]?.remainingHelperCooldownSeconds).toBe(1712n);
    expect(snapshot.objectSections.buildings?.[0]?.remainingSeconds).toBe(3000n);
    expect(snapshot.objectSections.buildings?.[1]?.types[0]?.modules[0]?.dataID).toBe(102000033n);
  });

  it('重复记录保留 multiplicity，未知字段进入诊断', () => {
    const parsed = parseAccountSnapshot(
      `{
        "tag": "#TESTTAG",
        "timestamp": 1700000000,
        "buildings": [
          {"data": 1000000, "lvl": 10, "cnt": 2},
          {"data": 1000000, "lvl": 11, "cnt": 1}
        ],
        "future_field": {"value": true}
      }`,
      { clock: new FakeClock(1_700_000_000_000) },
    );
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }
    expect(parsed.value.objectSections.buildings?.length).toBe(2);
    expect(parsed.value.unknownTopLevelKeys).toEqual(['future_field']);
    expect(parsed.value.diagnostics.some((item) => item.path === '顶层')).toBe(true);
  });

  it('coverage 是已知 metadata，不得进入 unknownTopLevelKeys', () => {
    const parsed = parseAccountSnapshot(
      `{
        "buildings": [],
        "coverage": {
          "buildings": {
            "kind": "authoritative",
            "source": "trusted-adapter",
            "version": "1"
          }
        }
      }`,
      { clock: new FakeClock(1_700_000_000_000) },
    );
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }
    expect(parsed.value.unknownTopLevelKeys).toEqual([]);
  });

  it('malformed、非 object 顶层、空输入 fail-closed', () => {
    expect(parseAccountSnapshot('   ', { clock: new FakeClock(0) }).ok).toBe(false);
    expect(parseAccountSnapshot('[1,2,3]', { clock: new FakeClock(0) })).toMatchObject({
      ok: false,
      error: { kind: 'topLevelMustBeObject' },
    });
    expect(parseAccountSnapshot('{', { clock: new FakeClock(0) }).ok).toBe(false);
    expect(
      parseAccountSnapshot('{"timestamp":1e30,"buildings":[]}', { clock: new FakeClock(0) }).ok,
    ).toBe(false);
  });

  it('golden fixture 指纹与 wire 形状 parity', () => {
    const root = resolve(process.cwd());
    const goldenText = readFileSync(
      resolve(root, 'Tests/Golden/Fixtures/account_snapshot_golden.json'),
      'utf8',
    );
    const expected = JSON.parse(
      readFileSync(resolve(root, 'Tests/Golden/Fixtures/parser_golden_expected.json'), 'utf8'),
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

    expect(parsed.value.tag).toBe('#GOLDEN01');
    expect(parsed.value.ageSeconds).toBe(100000n);
    expect(parsed.value.unknownTopLevelKeys).toEqual(['golden_unknown_field']);
    expect(maskDiagnosticIdsInWireHex(wireHex(parsed.value))).toBe(
      expected.accountSnapshot.encodedJSONHex,
    );
  });

  it('同一输入解析业务内容稳定、内容变化可区分（Issue #304 无 fingerprint）', () => {
    const clock = new FakeClock(SAMPLE_NOW_MS);
    const first = parseAccountSnapshot(sampleJson, { clock });
    const second = parseAccountSnapshot(sampleJson, { clock });
    expect(first.ok && second.ok).toBe(true);
    if (!first.ok || !second.ok) {
      return;
    }
    // 诊断随机 id 不属于业务身份：业务字段一致即视为同一内容。
    expect(first.value.tag).toBe(second.value.tag);
    expect(first.value.objectSections).toEqual(second.value.objectSections);
    expect(first.value.numericSections).toEqual(second.value.numericSections);
    expect(first.value.boosts).toEqual(second.value.boosts);
    const mutated = {
      ...first.value,
      objectSections: {
        ...first.value.objectSections,
        buildings: [
          {
            ...first.value.objectSections.buildings![0]!,
            level: 18,
          },
          ...first.value.objectSections.buildings!.slice(1),
        ],
      },
    };
    expect(mutated.objectSections.buildings?.[0]?.level).not.toBe(
      first.value.objectSections.buildings?.[0]?.level,
    );
  });
});
