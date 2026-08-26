import { JsonParseError } from './json-value';

/** Swift `Int64.min`。 */
export const INT64_MIN = -9223372036854775808n;
/** Swift `Int64.max`。 */
export const INT64_MAX = 9223372036854775807n;
/** Swift `UInt64.max`：JSONSerialization 对超 Int64 的无符号整数走 `Q`。 */
export const UINT64_MAX = 18446744073709551615n;

const INTEGER_TOKEN = /^-?(0|[1-9]\d*)$/;
/** NSDecimal 尾数是 8×UInt16 = 128 bit。 */
const NSDECIMAL_MAX_MANTISSA = (1n << 128n) - 1n;
const NSDECIMAL_EXPONENT_MIN = -128;
const NSDECIMAL_EXPONENT_MAX = 127;

/**
 * 把 JSON 数字 token 规范化为 `JSONSerialization` → `NSNumber.stringValue`（WA-1.2）。
 *
 * - 落入 Int64/UInt64 的整数 token：对应 `q`/`Q`，十进制整数串（`-0` → `0`）。
 * - 更大的整数，或有效数字 ≥ 18 的小数/指数：`NSDecimalNumber`
 *   （128-bit 尾数截断、未压缩指数 ∈ [-128, 127]）。
 * - 其余：IEEE 754 double，再按 Darwin `%.16g`（round-ties-to-even）。
 */
export function normalizeJsonNumberToken(raw: string): string {
  if (INTEGER_TOKEN.test(raw)) {
    if (raw === '-0') {
      return '0';
    }
    const integer = BigInt(raw);
    if (integer >= INT64_MIN && integer <= UINT64_MAX) {
      return integer.toString();
    }
    return formatNSDecimalNumber(raw);
  }

  if (significandDigitCount(raw) >= 18) {
    return formatNSDecimalNumber(raw);
  }

  const value = Number(raw);
  if (!Number.isFinite(value)) {
    throw new JsonParseError('数字必须是有限值。');
  }
  return formatAppleDouble(value);
}

/** Darwin `NSNumber(double).stringValue` / `%.16g`。 */
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
  const { digits, exponent } = roundDoubleToSignificantDigits(Math.abs(value), 16);
  return sign + formatSignificantDigits(digits, exponent);
}

function significandDigitCount(raw: string): number {
  const body = mantissaBody(raw);
  const dot = body.indexOf('.');
  const intRaw = dot === -1 ? body : body.slice(0, dot);
  const fracRaw = dot === -1 ? '' : body.slice(dot + 1);
  const integerDigits = intRaw.replace(/^0+/, '');
  return integerDigits.length + fracRaw.length;
}

function mantissaBody(raw: string): string {
  const unsigned = raw.startsWith('-') ? raw.slice(1) : raw;
  return unsigned.split(/[eE]/)[0]!;
}

function parseDecimalToken(raw: string): {
  negative: boolean;
  significand: bigint;
  scale: number;
} {
  const negative = raw.startsWith('-');
  const unsigned = negative ? raw.slice(1) : raw;
  const expMatch = unsigned.match(/[eE]([+-]?\d+)$/);
  const exp = expMatch ? Number(expMatch[1]) : 0;
  const body = expMatch ? unsigned.slice(0, unsigned.length - expMatch[0].length) : unsigned;
  const dot = body.indexOf('.');
  const intRaw = (dot === -1 ? body : body.slice(0, dot)).replace(/^0+/, '') || '0';
  const fracRaw = dot === -1 ? '' : body.slice(dot + 1);
  const digits = (intRaw + fracRaw).replace(/^0+/, '') || '0';
  return {
    negative,
    significand: BigInt(digits),
    scale: fracRaw.length - exp,
  };
}

/**
 * 对齐 `NSDecimalNumber`：尾数按 128-bit 向零截断；指数用未去掉尾零的 scale 校验；
 * 零值写出 `0`（不保留负号）。
 */
function formatNSDecimalNumber(raw: string): string {
  const parsed = parseDecimalToken(raw);
  let significand = parsed.significand;
  let scale = parsed.scale;

  if (significand === 0n) {
    return '0';
  }

  while (significand > NSDECIMAL_MAX_MANTISSA) {
    significand /= 10n;
    scale -= 1;
  }

  const exponent = -scale;
  if (exponent < NSDECIMAL_EXPONENT_MIN || exponent > NSDECIMAL_EXPONENT_MAX) {
    throw new JsonParseError('数字超出 NSDecimal 指数范围。');
  }

  const sign = parsed.negative ? '-' : '';
  if (scale <= 0) {
    return `${sign}${significand.toString()}${'0'.repeat(-scale)}`;
  }

  const digits = significand.toString().padStart(scale + 1, '0');
  const split = digits.length - scale;
  const intPart = digits.slice(0, split);
  const fracPart = digits.slice(split);
  return sign + stripTrailingFractionZeros(`${intPart}.${fracPart}`);
}

function roundDoubleToSignificantDigits(
  abs: number,
  precision: number,
): { digits: string; exponent: number } {
  const { significand, exp2 } = decodeFloat64(abs);
  let sig: bigint;
  let exp10: number;
  if (exp2 >= 0) {
    sig = significand << BigInt(exp2);
    exp10 = 0;
  } else {
    sig = significand * 5n ** BigInt(-exp2);
    exp10 = exp2;
  }

  const raw = sig.toString();
  const scientificExp = raw.length - 1 + exp10;
  if (raw.length <= precision) {
    return { digits: raw, exponent: scientificExp };
  }

  let head = BigInt(raw.slice(0, precision));
  const rest = raw.slice(precision);
  const first = rest[0]!;
  const exactHalf =
    first === '5' &&
    rest
      .slice(1)
      .split('')
      .every((digit) => digit === '0');
  const roundUp = first > '5' || (first === '5' && !exactHalf) || (exactHalf && head % 2n === 1n);
  if (roundUp) {
    head += 1n;
  }

  let digits = head.toString();
  let exponent = scientificExp;
  if (digits.length > precision) {
    digits = digits.slice(0, precision);
    exponent += 1;
  }
  return { digits, exponent };
}

function decodeFloat64(abs: number): { significand: bigint; exp2: number } {
  const view = new DataView(new ArrayBuffer(8));
  view.setFloat64(0, abs, false);
  const bits = (BigInt(view.getUint32(0, false)) << 32n) | BigInt(view.getUint32(4, false));
  const biased = Number((bits >> 52n) & 0x7ffn);
  const fraction = bits & ((1n << 52n) - 1n);
  if (biased === 0) {
    return { significand: fraction, exp2: 1 - 1023 - 52 };
  }
  return { significand: fraction + (1n << 52n), exp2: biased - 1023 - 52 };
}

function formatSignificantDigits(digits: string, exponent: number): string {
  if (exponent < -4 || exponent >= 16) {
    const mantissa =
      digits.length === 1 ? digits : stripTrailingFractionZeros(`${digits[0]}.${digits.slice(1)}`);
    const expSign = exponent >= 0 ? '+' : '-';
    const expDigits = String(Math.abs(exponent)).padStart(2, '0');
    return `${mantissa}e${expSign}${expDigits}`;
  }

  let fixed: string;
  if (exponent >= 0) {
    if (exponent + 1 >= digits.length) {
      fixed = digits + '0'.repeat(exponent + 1 - digits.length);
    } else {
      fixed = `${digits.slice(0, exponent + 1)}.${digits.slice(exponent + 1)}`;
    }
  } else {
    fixed = `0.${'0'.repeat(-exponent - 1)}${digits}`;
  }
  return stripTrailingFractionZeros(fixed);
}

function stripTrailingFractionZeros(value: string): string {
  if (!value.includes('.')) {
    return value;
  }
  return value.replace(/\.?0+$/, '');
}
