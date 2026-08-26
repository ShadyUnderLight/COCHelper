/** 只接受 JS number 中可参与确定性计算的有限值。 */
export function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

export function requireFiniteNumber(value: unknown, name = 'number'): number {
  if (!isFiniteNumber(value)) {
    throw new RangeError(`${name} 必须是有限数字。`);
  }
  return value;
}
