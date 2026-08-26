import { describe, expect, it } from 'vitest';

import {
  UNIX_TO_REF_EPOCH_SECONDS,
  finiteOrReferenceZero,
  officialUtcDisplay,
  parseOfficialUtcMs,
  refSecondsToUnixSeconds,
  unixSecondsToRefSeconds,
} from './time';

describe('时间纪元（WA-4 T1/T2）', () => {
  it('Unix 与 Swift reference-date 偏移 978307200 秒', () => {
    expect(UNIX_TO_REF_EPOCH_SECONDS).toBe(978307200);
    expect(unixSecondsToRefSeconds(1_785_836_333)).toBe(807_529_133);
    expect(refSecondsToUnixSeconds(807_529_133)).toBe(1_785_836_333);
    expect(unixSecondsToRefSeconds(978307200)).toBe(0);
  });

  it('非有限值回落到 reference-date 0', () => {
    expect(finiteOrReferenceZero(Number.NaN)).toBe(0);
    expect(finiteOrReferenceZero(Number.POSITIVE_INFINITY)).toBe(0);
    expect(finiteOrReferenceZero(-12.5)).toBe(-12.5);
  });
});

describe('官方 UTC 紧凑时间（WA-4 T3）', () => {
  it('转换为固定 Asia/Shanghai，不使用本机时区', () => {
    expect(officialUtcDisplay('20260809T110738.000Z')).toEqual({
      kind: 'beijing',
      text: '2026年8月9日 19:07:38',
    });
    expect(officialUtcDisplay(null)).toEqual({ kind: 'hidden' });
  });

  it('跨日 / 跨月 / 跨年边界', () => {
    expect(officialUtcDisplay('20260809T160000.000Z')).toEqual({
      kind: 'beijing',
      text: '2026年8月10日 00:00:00',
    });
    expect(officialUtcDisplay('20260809T155959.000Z')).toEqual({
      kind: 'beijing',
      text: '2026年8月9日 23:59:59',
    });
    expect(officialUtcDisplay('20260731T160000.000Z')).toEqual({
      kind: 'beijing',
      text: '2026年8月1日 00:00:00',
    });
    expect(officialUtcDisplay('20251231T160000.000Z')).toEqual({
      kind: 'beijing',
      text: '2026年1月1日 00:00:00',
    });
  });

  it('毫秒变体不影响秒级展示', () => {
    expect(officialUtcDisplay('20260809T110738Z')).toEqual({
      kind: 'beijing',
      text: '2026年8月9日 19:07:38',
    });
    expect(officialUtcDisplay('20260809T110738.5Z')).toEqual({
      kind: 'beijing',
      text: '2026年8月9日 19:07:38',
    });
    expect(officialUtcDisplay('20260809T110738.50Z')).toEqual({
      kind: 'beijing',
      text: '2026年8月9日 19:07:38',
    });
  });

  it('越界组件、非法格式与年份下限拒绝', () => {
    const bad = [
      '',
      '20260809',
      '2026-08-09T11:07:38.000Z',
      '20260809T110738',
      '20260809T110738.000',
      '20260809T110738.000+00:00',
      '20260809T110738.000z',
      'abc',
      '20261309T110738.000Z',
      '20260809T246000.000Z',
      '20260230T110738.000Z',
      '20230229T110738.000Z',
      '20260809T111160.000Z',
      '20260809T110760.000Z',
      '19911231T235959.000Z',
      '20260809T110738.000Z ',
      '20260809T110738.0000Z',
      '21000229T000000.000Z',
    ];
    for (const raw of bad) {
      expect(officialUtcDisplay(raw), raw).toEqual({ kind: 'unparsable', raw });
    }
    expect(parseOfficialUtcMs('20260230T110738.000Z')).toBeUndefined();
  });

  it('闰年、1992 边界、世纪闰年与 9999 进位', () => {
    expect(officialUtcDisplay('20240229T110738.000Z')).toEqual({
      kind: 'beijing',
      text: '2024年2月29日 19:07:38',
    });
    expect(officialUtcDisplay('19920101T000000.000Z')).toEqual({
      kind: 'beijing',
      text: '1992年1月1日 08:00:00',
    });
    expect(officialUtcDisplay('20000229T000000.000Z')).toEqual({
      kind: 'beijing',
      text: '2000年2月29日 08:00:00',
    });
    expect(officialUtcDisplay('99991231T235959Z')).toEqual({
      kind: 'beijing',
      text: '10000年1月1日 07:59:59',
    });
  });

  it('确定性抽样：UTC 小时 × 分钟 × 秒', () => {
    for (let hour = 0; hour <= 23; hour += 1) {
      for (const minute of [0, 30, 59]) {
        for (const second of [0, 7, 59]) {
          const raw = `20260809T${pad2(hour)}${pad2(minute)}${pad2(second)}.000Z`;
          expect(officialUtcDisplay(raw)).toEqual({
            kind: 'beijing',
            text: referenceBeijing(2026, 8, 9, hour, minute, second),
          });
        }
      }
    }
  });
});

function pad2(value: number): string {
  return String(value).padStart(2, '0');
}

function referenceBeijing(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  second: number,
): string {
  const utcMinutes = daysFromCivil(year, month, day) * 1440 + hour * 60 + minute;
  const beijingMinutes = utcMinutes + 480;
  const [by, bm, bd] = civilFromDays(Math.floor(beijingMinutes / 1440));
  const remainder = ((beijingMinutes % 1440) + 1440) % 1440;
  const bh = Math.floor(remainder / 60);
  const bmi = remainder % 60;
  return `${by}年${bm}月${bd}日 ${pad2(bh)}:${pad2(bmi)}:${pad2(second)}`;
}

function daysFromCivil(y: number, m: number, d: number): number {
  const y2 = m <= 2 ? y - 1 : y;
  const era = Math.floor((y2 >= 0 ? y2 : y2 - 399) / 400);
  const yoe = y2 - era * 400;
  const doy = Math.floor((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe - 719468;
}

function civilFromDays(z: number): [number, number, number] {
  const z2 = z + 719468;
  const era = Math.floor((z2 >= 0 ? z2 : z2 - 146096) / 146097);
  const doe = z2 - era * 146097;
  const yoe = Math.floor(
    (doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365,
  );
  const y = yoe + era * 400;
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const m = mp + (mp < 10 ? 3 : -9);
  return [m <= 2 ? y + 1 : y, m, d];
}
