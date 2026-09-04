import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { isValidTag } from '../tag/validator';
import type { AccountItem, AccountSnapshot } from './types';
import { isBuilderBaseSection } from './types';
import { parseAccountSnapshot } from './parser';

const FIXTURE_DIR = resolve(process.cwd(), 'Tests/COCHelperCoreTests/Fixtures');
const PERF_FIXTURE_TIMESTAMP_SEC = 1_785_736_933;
const PERF_NOW_MS = PERF_FIXTURE_TIMESTAMP_SEC * 1000;
const SAMPLE_NOW_MS = 1_700_000_600_000;

class FakeClock {
  constructor(private readonly fixedMs: number) {}

  nowMs(): number {
    return this.fixedMs;
  }
}

function readFixture(name: string): string {
  return readFileSync(resolve(FIXTURE_DIR, `${name}.json`), 'utf8');
}

function collectObjectItems(snapshot: AccountSnapshot): AccountItem[] {
  const items: AccountItem[] = [];
  const visit = (item: AccountItem): void => {
    items.push(item);
    for (const nested of [...item.types, ...item.modules]) {
      visit(nested);
    }
  };
  for (const sectionItems of Object.values(snapshot.objectSections)) {
    for (const item of sectionItems) {
      visit(item);
    }
  }
  return items;
}

function wallSegmentCount(walls: readonly AccountItem[]): number {
  return walls.reduce((total, item) => total + (item.count ?? 1), 0);
}

function wallHistogramByLevel(walls: readonly AccountItem[]): Map<number | null, number> {
  const histogram = new Map<number | null, number>();
  for (const item of walls) {
    histogram.set(item.level, (histogram.get(item.level) ?? 0) + (item.count ?? 1));
  }
  return histogram;
}

function hasUnrecognizedFieldWarning(snapshot: AccountSnapshot, field: string): boolean {
  return snapshot.diagnostics.some(
    (diagnostic) =>
      diagnostic.path === '顶层' &&
      diagnostic.severity === 'warning' &&
      diagnostic.message.includes('未识别字段') &&
      diagnostic.message.includes(field),
  );
}

function assertAnonymized(text: string): void {
  const lower = text.toLowerCase();
  for (const forbidden of ['token', 'cookie', 'secret', 'api_key', 'bearer']) {
    expect(lower.includes(forbidden)).toBe(false);
  }
}

function countTopLevelObjectItems(snapshot: AccountSnapshot, builderBase: boolean): number {
  let count = 0;
  for (const [section, items] of Object.entries(snapshot.objectSections)) {
    if (isBuilderBaseSection(section) === builderBase) {
      count += items.length;
    }
  }
  return count;
}

function activeItems(snapshot: AccountSnapshot, builderBase: boolean): AccountItem[] {
  return collectObjectItems(snapshot).filter(
    (item) => item.timerSeconds !== null && isBuilderBaseSection(item.section) === builderBase,
  );
}

describe('AccountSnapshot fixture regression', () => {
  it('perf_account_snapshot_large_walls_before/after 精确保留 1005 段城墙 histogram', () => {
    const beforeText = readFixture('perf_account_snapshot_large_walls_before');
    const afterText = readFixture('perf_account_snapshot_large_walls_after');
    assertAnonymized(beforeText);
    assertAnonymized(afterText);

    const beforeParsed = parseAccountSnapshot(beforeText, { clock: new FakeClock(PERF_NOW_MS) });
    const afterParsed = parseAccountSnapshot(afterText, {
      clock: new FakeClock(PERF_NOW_MS + 1_000),
    });
    expect(beforeParsed.ok && afterParsed.ok).toBe(true);
    if (!beforeParsed.ok || !afterParsed.ok) {
      return;
    }

    expect(beforeParsed.value.tag).toBe('#LARGEWALL01');
    expect(afterParsed.value.tag).toBe('#LARGEWALL01');
    expect(isValidTag(beforeParsed.value.tag ?? '')).toBe(true);

    const beforeWalls = (beforeParsed.value.objectSections.buildings ?? []).filter(
      (item) => item.dataID === 1_000_008n,
    );
    const afterWalls = (afterParsed.value.objectSections.buildings ?? []).filter(
      (item) => item.dataID === 1_000_008n,
    );
    expect(wallSegmentCount(beforeWalls)).toBe(1_005);
    expect(wallSegmentCount(afterWalls)).toBe(1_005);

    const beforeByLevel = wallHistogramByLevel(beforeWalls);
    const afterByLevel = wallHistogramByLevel(afterWalls);
    expect(beforeByLevel.get(1)).toBe(1_005);
    expect(afterByLevel.get(12)).toBe(1_005);

    const positiveDelta = [...new Set([...beforeByLevel.keys(), ...afterByLevel.keys()])].reduce(
      (total: number, level) =>
        total + Math.max(0, (afterByLevel.get(level) ?? 0) - (beforeByLevel.get(level) ?? 0)),
      0,
    );
    expect(positiveDelta).toBeGreaterThanOrEqual(1_000);
    expect(beforeText).not.toBe(afterText);
    expect(beforeWalls).not.toEqual(afterWalls);
  });

  it('perf_account_snapshot_large_walls 解析大体积城墙 fixture 且不误报 coverage', () => {
    const text = readFixture('perf_account_snapshot_large_walls');
    assertAnonymized(text);
    const parsed = parseAccountSnapshot(text, { clock: new FakeClock(PERF_NOW_MS) });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }

    const walls = (parsed.value.objectSections.buildings ?? []).filter(
      (item) => item.dataID === 1_000_008n,
    );
    const segmentCount = walls.reduce((total, item) => total + (item.count ?? 1), 0);
    expect(parsed.value.tag).toBe('#PERF-LARGE-WALLS');
    expect(segmentCount).toBeGreaterThanOrEqual(1_000);
    expect(parsed.value.unknownTopLevelKeys).not.toContain('coverage');
    expect(parsed.value.objectSections.coverage).toBeUndefined();
  });

  it('perf_account_snapshot_home 解析大体积主村快照并保留墙体/重复建筑语义', () => {
    const text = readFixture('perf_account_snapshot_home');
    assertAnonymized(text);
    const parsed = parseAccountSnapshot(text, { clock: new FakeClock(PERF_NOW_MS) });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }

    const buildings = parsed.value.objectSections.buildings ?? [];
    expect(parsed.value.tag).toBe('#ANONYMIZED');
    expect(buildings.length).toBeGreaterThanOrEqual(100);

    const walls = buildings.filter((item) => item.dataID === 1_000_010n);
    expect(walls.length).toBeGreaterThan(0);
    expect(walls.reduce((total, item) => total + (item.count ?? 0), 0)).toBeGreaterThanOrEqual(300);

    const countsById = new Map<bigint, number>();
    for (const item of buildings) {
      countsById.set(item.dataID, (countsById.get(item.dataID) ?? 0) + 1);
    }
    const multiLevel = [...countsById.values()].filter((count) => count >= 2);
    expect(multiLevel.length).toBeGreaterThanOrEqual(2);

    const activeTimers = collectObjectItems(parsed.value).filter(
      (item) => (item.remainingSeconds ?? 0n) > 0n,
    );
    expect(activeTimers.length).toBeGreaterThanOrEqual(5);

    const endedTimers = collectObjectItems(parsed.value).filter(
      (item) => item.timerSeconds !== null && (item.remainingSeconds ?? 0n) === 0n,
    );
    expect(endedTimers.length).toBeGreaterThanOrEqual(2);
    expect(parsed.value.unknownTopLevelKeys).not.toContain('coverage');
  });

  it('code fence 与缺失 timestamp 产生有用诊断', () => {
    const parsed = parseAccountSnapshot(
      '```json\n{"buildings": [{"data": 1000000, "timer": 90}]}\n```',
      { clock: new FakeClock(1_700_000_000_000) },
    );
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }
    expect(parsed.value.objectSections.buildings?.[0]?.remainingSeconds).toBe(90n);
    expect(
      parsed.value.diagnostics.some((item) => item.path === '文本' && item.severity === 'info'),
    ).toBe(true);
    expect(
      parsed.value.diagnostics.some(
        (item) => item.path === 'timestamp' && item.severity === 'warning',
      ),
    ).toBe(true);
  });

  it('过期 cooldown 归一化为 0', () => {
    const parsed = parseAccountSnapshot(
      `{
        "timestamp": 1700000000,
        "helpers": [{"data": 93000000, "helper_cooldown": 60}],
        "boosts": {"clocktower_cooldown": 60}
      }`,
      { clock: new FakeClock(1_700_000_060_000) },
    );
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }
    expect(parsed.value.objectSections.helpers?.[0]?.remainingHelperCooldownSeconds).toBe(0n);
    expect(parsed.value.boosts.clocktower_cooldown).toBe(0n);
  });

  it('无效 coverage 类型 fail-closed 且不误报未知字段', () => {
    for (const text of [
      '{"buildings":[],"coverage":"full"}',
      '{"buildings":[],"coverage":[1,2]}',
      '{"buildings":[],"coverage":true}',
    ]) {
      const parsed = parseAccountSnapshot(text, { clock: new FakeClock(1_700_000_000_000) });
      expect(parsed.ok).toBe(true);
      if (!parsed.ok) {
        return;
      }
      expect(parsed.value.unknownTopLevelKeys).toEqual([]);
      expect(parsed.value.objectSections.coverage).toBeUndefined();
      expect(hasUnrecognizedFieldWarning(parsed.value, 'coverage')).toBe(false);
    }
  });

  it('coverage 与其他 unknown 顶层字段可并存', () => {
    const parsed = parseAccountSnapshot(
      `{
        "buildings": [],
        "coverage": {
          "buildings": {
            "kind": "authoritative",
            "source": "trusted-adapter",
            "version": "1"
          }
        },
        "future_field": {"value": true}
      }`,
      { clock: new FakeClock(1_700_000_000_000) },
    );
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }
    expect(parsed.value.unknownTopLevelKeys).toEqual(['future_field']);
    expect(hasUnrecognizedFieldWarning(parsed.value, 'future_field')).toBe(true);
    expect(hasUnrecognizedFieldWarning(parsed.value, 'coverage')).toBe(false);
  });

  it('未知 dataID 保留原始 dataID 值', () => {
    const parsed = parseAccountSnapshot(
      `{
        "timestamp": 1700000000,
        "buildings": [{"data": 9999999, "lvl": 1}]
      }`,
      { clock: new FakeClock(1_700_000_000_000) },
    );
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }
    expect(parsed.value.objectSections.buildings?.[0]?.dataID).toBe(9_999_999n);
    expect(parsed.value.objectSections.buildings?.[0]?.level).toBe(1);
  });

  it('主村与建筑工人基地记录分区统计', () => {
    const parsed = parseAccountSnapshot(
      `{
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
      }`,
      { clock: new FakeClock(SAMPLE_NOW_MS) },
    );
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }

    const allItems = collectObjectItems(parsed.value);
    const mainItems = countTopLevelObjectItems(parsed.value, false);
    const builderItems = countTopLevelObjectItems(parsed.value, true);
    const mainActive = activeItems(parsed.value, false);
    const builderActive = activeItems(parsed.value, true);

    expect(mainItems).toBe(4);
    expect(builderItems).toBe(1);
    expect(mainActive.length).toBe(2);
    expect(builderActive.length).toBe(1);
    expect(allItems.some((item) => item.dataID === 102_000_033n)).toBe(true);
  });

  it('同一文本不同导入时间 importedAt 不同（Issue #304 无 fingerprint）', () => {
    const text = `{
      "tag": "#TESTTAG",
      "timestamp": 1700000000,
      "buildings": [{"data": 1000013, "lvl": 17, "timer": 3600}]
    }`;
    const first = parseAccountSnapshot(text, { clock: new FakeClock(SAMPLE_NOW_MS) });
    const second = parseAccountSnapshot(text, { clock: new FakeClock(SAMPLE_NOW_MS + 10_000) });
    expect(first.ok && second.ok).toBe(true);
    if (!first.ok || !second.ok) {
      return;
    }
    expect(first.value.importedAtMs).not.toBe(second.value.importedAtMs);
  });
});
