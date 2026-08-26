import { INT64_MAX, INT64_MIN, UINT64_MAX } from './json-number';

/** 饱和算术的闭区间边界。 */
export type SaturatingBounds = {
  readonly min: bigint;
  readonly max: bigint;
};

/** 精确结果与是否发生过界。 */
export type SaturatingResult = {
  readonly value: bigint;
  readonly overflowed: boolean;
};

export const INT64_BOUNDS: SaturatingBounds = {
  min: INT64_MIN,
  max: INT64_MAX,
};

export const UINT64_BOUNDS: SaturatingBounds = {
  min: 0n,
  max: UINT64_MAX,
};

/** 加法溢出时钳制到显式边界，而不是回绕。 */
export function saturatingAdd(
  left: bigint,
  right: bigint,
  bounds: SaturatingBounds = INT64_BOUNDS,
): SaturatingResult {
  return saturate(left + right, bounds);
}

/** 减法溢出时钳制到显式边界，而不是回绕。 */
export function saturatingSubtract(
  left: bigint,
  right: bigint,
  bounds: SaturatingBounds = INT64_BOUNDS,
): SaturatingResult {
  return saturate(left - right, bounds);
}

/** 乘法溢出时钳制到显式边界，而不是回绕。 */
export function saturatingMultiply(
  left: bigint,
  right: bigint,
  bounds: SaturatingBounds = INT64_BOUNDS,
): SaturatingResult {
  return saturate(left * right, bounds);
}

function saturate(exact: bigint, bounds: SaturatingBounds): SaturatingResult {
  validateBounds(bounds);
  if (exact < bounds.min) {
    return { value: bounds.min, overflowed: true };
  }
  if (exact > bounds.max) {
    return { value: bounds.max, overflowed: true };
  }
  return { value: exact, overflowed: false };
}

function validateBounds(bounds: SaturatingBounds): void {
  if (bounds.min > bounds.max) {
    throw new RangeError('饱和算术边界必须满足 min <= max。');
  }
}
