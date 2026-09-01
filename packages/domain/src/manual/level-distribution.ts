import { INT64_MAX, saturatingAdd } from '@coc-helper/wire';

import type { ManualUpgradeError } from './errors';
import type { ManualLevelDistribution, ManualLevelQuantity } from './types';

export function assertValidManualQuantity(quantity: bigint): ManualUpgradeError | null {
  if (quantity <= 0n || quantity > INT64_MAX) {
    return { kind: 'invalidQuantity' };
  }
  return null;
}

export function assertValidManualLevel(level: number): ManualUpgradeError | null {
  if (!Number.isInteger(level) || level < 0) {
    return { kind: 'invalidLevel' };
  }
  return null;
}

export function createManualLevelQuantity(
  level: number,
  quantity: bigint,
): ManualLevelQuantity {
  const levelError = assertValidManualLevel(level);
  if (levelError !== null) {
    throw levelError;
  }
  const quantityError = assertValidManualQuantity(quantity);
  if (quantityError !== null) {
    throw quantityError;
  }
  return { level, quantity };
}

export function createManualLevelDistribution(
  levels: readonly ManualLevelQuantity[],
): ManualLevelDistribution {
  const sorted = levels.slice().sort((left, right) => left.level - right.level);
  for (let index = 1; index < sorted.length; index += 1) {
    if (sorted[index - 1]!.level === sorted[index]!.level) {
      throw { kind: 'invalidRecord' } satisfies ManualUpgradeError;
    }
  }
  let total = 0n;
  for (const entry of sorted) {
    const next = saturatingAdd(total, entry.quantity);
    if (next.overflowed) {
      throw { kind: 'arithmeticOverflow' } satisfies ManualUpgradeError;
    }
    total = next.value;
  }
  return buildManualLevelDistribution(sorted);
}

export function manualLevelDistributionAddChecked(
  distribution: ManualLevelDistribution,
  level: number,
  quantity: bigint,
): ManualLevelDistribution {
  if (assertValidManualQuantity(quantity) !== null || assertValidManualLevel(level) !== null) {
    throw { kind: 'invalidQuantity' } satisfies ManualUpgradeError;
  }
  const updated = [...distribution.levels];
  const index = updated.findIndex((entry) => entry.level === level);
  if (index >= 0) {
    const sum = saturatingAdd(updated[index]!.quantity, quantity);
    if (sum.overflowed) {
      throw { kind: 'arithmeticOverflow' } satisfies ManualUpgradeError;
    }
    updated[index] = createManualLevelQuantity(level, sum.value);
  } else {
    updated.push(createManualLevelQuantity(level, quantity));
  }
  return createManualLevelDistribution(updated);
}

export function manualLevelDistributionSubtractChecked(
  distribution: ManualLevelDistribution,
  level: number,
  quantity: bigint,
): ManualLevelDistribution {
  if (assertValidManualQuantity(quantity) !== null) {
    throw { kind: 'invalidQuantity' } satisfies ManualUpgradeError;
  }
  const available = distribution.quantityAt(level);
  if (available < quantity) {
    throw {
      kind: 'insufficientQuantity',
      level,
      requested: quantity,
      available,
    } satisfies ManualUpgradeError;
  }
  const updated = [...distribution.levels];
  const index = updated.findIndex((entry) => entry.level === level);
  if (index < 0) {
    throw {
      kind: 'insufficientQuantity',
      level,
      requested: quantity,
      available: 0n,
    } satisfies ManualUpgradeError;
  }
  const remaining = available - quantity;
  if (remaining === 0n) {
    updated.splice(index, 1);
  } else {
    updated[index] = createManualLevelQuantity(level, remaining);
  }
  return createManualLevelDistribution(updated);
}

export function buildManualLevelDistribution(
  sorted: readonly ManualLevelQuantity[],
): ManualLevelDistribution {
  const levels = sorted.slice();
  return {
    levels,
    quantityAt(level: number) {
      return levels.find((entry) => entry.level === level)?.quantity ?? 0n;
    },
    get totalQuantity() {
      return levels.reduce((total, entry) => total + entry.quantity, 0n);
    },
    get isEmpty() {
      return levels.length === 0;
    },
  };
}

export const MANUAL_LEVEL_DISTRIBUTION_EMPTY = buildManualLevelDistribution([]);

function checkedAddQuantities(left: bigint, right: bigint): bigint | undefined {
  const sum = saturatingAdd(left, right);
  if (sum.overflowed) {
    return undefined;
  }
  return sum.value;
}

export function manualLevelDistributionFromQuantities(
  levelQuantities: ReadonlyMap<number, bigint>,
): ManualLevelDistribution | undefined {
  const levels: ManualLevelQuantity[] = [];
  for (const level of [...levelQuantities.keys()].sort((left, right) => left - right)) {
    const quantity = levelQuantities.get(level);
    if (
      quantity === undefined ||
      assertValidManualQuantity(quantity) !== null ||
      assertValidManualLevel(level) !== null
    ) {
      return undefined;
    }
    let total = 0n;
    for (const entry of levels) {
      total += entry.quantity;
    }
    const nextTotal = checkedAddQuantities(total, quantity);
    if (nextTotal === undefined) {
      return undefined;
    }
    levels.push({ level, quantity });
  }
  return buildManualLevelDistribution(levels);
}

export function manualLevelDistributionAdd(
  distribution: ManualLevelDistribution,
  level: number,
  quantity: bigint,
): ManualLevelDistribution | undefined {
  if (assertValidManualQuantity(quantity) !== null || assertValidManualLevel(level) !== null) {
    return undefined;
  }
  const quantities = new Map<number, bigint>();
  for (const entry of distribution.levels) {
    quantities.set(entry.level, entry.quantity);
  }
  const existing = quantities.get(level) ?? 0n;
  const sum = checkedAddQuantities(existing, quantity);
  if (sum === undefined) {
    return undefined;
  }
  quantities.set(level, sum);
  return manualLevelDistributionFromQuantities(quantities);
}

export function manualLevelDistributionSubtract(
  distribution: ManualLevelDistribution,
  level: number,
  quantity: bigint,
): ManualLevelDistribution | undefined {
  if (assertValidManualQuantity(quantity) !== null) {
    return undefined;
  }
  const available = distribution.quantityAt(level);
  if (available < quantity) {
    return undefined;
  }
  const quantities = new Map<number, bigint>();
  for (const entry of distribution.levels) {
    quantities.set(entry.level, entry.quantity);
  }
  const remaining = available - quantity;
  if (remaining === 0n) {
    quantities.delete(level);
  } else {
    quantities.set(level, remaining);
  }
  return manualLevelDistributionFromQuantities(quantities);
}

export function manualLevelDistributionTotalQuantity(
  distribution: ManualLevelDistribution,
): bigint {
  return distribution.totalQuantity;
}

export function manualLevelDistributionIsEmpty(distribution: ManualLevelDistribution): boolean {
  return distribution.isEmpty;
}

export function manualLevelDistributionQuantityAt(
  distribution: ManualLevelDistribution,
  level: number,
): bigint {
  return distribution.quantityAt(level);
}

export function manualLevelDistributionsEqual(
  left: ManualLevelDistribution,
  right: ManualLevelDistribution,
): boolean {
  if (left.levels.length !== right.levels.length) {
    return false;
  }
  for (let index = 0; index < left.levels.length; index += 1) {
    const leftEntry = left.levels[index]!;
    const rightEntry = right.levels[index]!;
    if (leftEntry.level !== rightEntry.level || leftEntry.quantity !== rightEntry.quantity) {
      return false;
    }
  }
  return true;
}
