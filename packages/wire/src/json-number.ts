import { JsonParseError } from './json-value';

/** Swift `Int64.min`。 */
export const INT64_MIN = -9223372036854775808n;
/** Swift `Int64.max`。 */
export const INT64_MAX = 9223372036854775807n;
/** Swift `UInt64.max`：JSONSerialization 对超 Int64 的无符号整数走 `Q`。 */
export const UINT64_MAX = 18446744073709551615n;

const INTEGER_TOKEN = /^-?(0|[1-9]\d*)$/;

/**
 * 把 JSON 数字 token 规范化为 `NSNumber.stringValue` 形态（WA-1.2）。
 * 整数 token 走 BigInt，避免 `JSON.parse` 丢掉 Int64；带小数/指数的走 double + `%.16g`。
 */
export function normalizeJsonNumberToken(raw: string): string {
  if (INTEGER_TOKEN.test(raw)) {
    if (raw === '-0') {
      return '0';
    }
    return BigInt(raw).toString();
  }

  if (!hasExponent(raw) && significantDigitCount(raw) >= 18) {
    return raw;
  }

  const value = Number(raw);
  if (!Number.isFinite(value)) {
    throw new JsonParseError('数字必须是有限值。');
  }
  return formatAppleDouble(value);
}

export function formatAppleDouble(value: number): string {
  if (!Number.isFinite(value)) {
    throw new JsonParseError('数字必须是有限值。');
  }
  if (Object.is(value, -0)) {
    return '-0';
  }
  if (value === 0) {
    return '0';
  }

  const sign = value < 0 ? '-' : '';
  const exponential = Math.abs(value).toExponential(15);
  const match = /^(\d)\.(\d+)e([+-]\d+)$/.exec(exponential);
  if (!match) {
    throw new JsonParseError(`无法格式化数字: ${exponential}`);
  }
  const lead = match[1]!;
  const frac = match[2]!;
  const exp = Number(match[3]);

  if (exp < -4 || exp >= 16) {
    const mantissa = stripTrailingFractionZeros(`${lead}.${frac}`);
    const expSign = exp >= 0 ? '+' : '-';
    const expDigits = String(Math.abs(exp)).padStart(2, '0');
    return `${sign}${mantissa}e${expSign}${expDigits}`;
  }

  const digits = `${lead}${frac}`;
  let fixed: string;
  if (exp >= 0) {
    if (exp + 1 >= digits.length) {
      fixed = digits + '0'.repeat(exp + 1 - digits.length);
    } else {
      const intPart = digits.slice(0, exp + 1);
      const fracPart = digits.slice(exp + 1);
      fixed = `${intPart}.${fracPart}`;
    }
  } else {
    fixed = `0.${'0'.repeat(-exp - 1)}${digits}`;
  }
  return sign + stripTrailingFractionZeros(fixed);
}

function hasExponent(raw: string): boolean {
  return /e/i.test(raw);
}

function significantDigitCount(raw: string): number {
  const unsigned = raw.startsWith('-') ? raw.slice(1) : raw;
  const [intRaw, fracRaw = ''] = unsigned.split('.');
  const intDigits = (intRaw ?? '0').replace(/^0+/, '') || (fracRaw.length > 0 ? '' : '0');
  const fracDigits = fracRaw.replace(/0+$/, '');
  return `${intDigits}${fracDigits}`.length;
}

function stripTrailingFractionZeros(value: string): string {
  if (!value.includes('.')) {
    return value;
  }
  return value.replace(/\.?0+$/, '');
}
