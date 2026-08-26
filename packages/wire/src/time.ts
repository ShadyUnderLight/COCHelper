/** Unix epoch（1970-01-01）到 Swift reference date（2001-01-01）的秒差。 */
export const UNIX_TO_REF_EPOCH_SECONDS = 978307200;

export type OfficialUtcDisplay =
  | { readonly kind: 'hidden' }
  | { readonly kind: 'beijing'; readonly text: string }
  | { readonly kind: 'unparsable'; readonly raw: string };

const OFFICIAL_UTC = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(\.\d{1,3})?Z$/;

export function unixSecondsToRefSeconds(unixSeconds: number): number {
  return finiteOrReferenceZero(unixSeconds - UNIX_TO_REF_EPOCH_SECONDS);
}

export function refSecondsToUnixSeconds(refSeconds: number): number {
  return finiteOrReferenceZero(refSeconds + UNIX_TO_REF_EPOCH_SECONDS);
}

/** 非有限时间兜底为 reference-date 0（WA-4）。 */
export function finiteOrReferenceZero(seconds: number): number {
  return Number.isFinite(seconds) ? seconds : 0;
}

export function isFiniteNumber(value: number): boolean {
  return Number.isFinite(value);
}

/**
 * 官方 UTC 紧凑串 → UTC 毫秒。失败返回 undefined。
 * 越界组件拒绝（不走 Date 溢出归一化）；年份下限 1992。
 */
export function parseOfficialUtcMs(raw: string): number | undefined {
  const match = OFFICIAL_UTC.exec(raw);
  if (!match) {
    return undefined;
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const maxDay = daysInMonth(year, month);
  if (
    year < 1992 ||
    maxDay === undefined ||
    day < 1 ||
    day > maxDay ||
    hour > 23 ||
    minute > 59 ||
    second > 59
  ) {
    return undefined;
  }
  return Date.UTC(year, month - 1, day, hour, minute, second);
}

export function formatBeijing(utcMs: number): string {
  const shifted = utcMs + 8 * 3600 * 1000;
  const date = new Date(shifted);
  const year = date.getUTCFullYear();
  const month = date.getUTCMonth() + 1;
  const day = date.getUTCDate();
  const hour = pad2(date.getUTCHours());
  const minute = pad2(date.getUTCMinutes());
  const second = pad2(date.getUTCSeconds());
  return `${year}年${month}月${day}日 ${hour}:${minute}:${second}`;
}

export function officialUtcDisplay(raw: string | null | undefined): OfficialUtcDisplay {
  if (raw === null || raw === undefined) {
    return { kind: 'hidden' };
  }
  const utcMs = parseOfficialUtcMs(raw);
  if (utcMs === undefined) {
    return { kind: 'unparsable', raw };
  }
  return { kind: 'beijing', text: formatBeijing(utcMs) };
}

function daysInMonth(year: number, month: number): number | undefined {
  const table = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month < 1 || month > 12) {
    return undefined;
  }
  if (month === 2 && isLeapYear(year)) {
    return 29;
  }
  return table[month - 1];
}

function isLeapYear(year: number): boolean {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

function pad2(value: number): string {
  return String(value).padStart(2, '0');
}
