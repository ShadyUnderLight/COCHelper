import type { UuidString } from '@coc-helper/wire';

import type { LocalQueueKind } from './local-queue-kind';

export type LocalQueueCapacitySource = 'userConfigured';

export type LocalQueueCapacityUpdate =
  { readonly kind: 'set'; readonly capacity: number } | { readonly kind: 'clear' };

export type LocalQueueCapacityConfigError =
  | { readonly kind: 'invalidCapacity'; readonly capacity: number }
  | { readonly kind: 'invalidTimestamp' };

export const LOCAL_QUEUE_CAPACITY_MAXIMUM = 10_000;

export type LocalQueueCapacityConfig = {
  readonly villageID: UuidString;
  readonly queueKind: LocalQueueKind;
  readonly capacity: number;
  readonly updatedAtMs: number;
  readonly source: LocalQueueCapacitySource;
};

export function createLocalQueueCapacityConfig(input: {
  readonly villageID: UuidString;
  readonly queueKind: LocalQueueKind;
  readonly capacity: number;
  readonly updatedAtMs: number;
  readonly source?: LocalQueueCapacitySource;
}): LocalQueueCapacityConfig {
  const capacityError = validateLocalQueueCapacityValue(input.capacity);
  if (capacityError !== null) {
    throw capacityError;
  }
  if (!Number.isFinite(input.updatedAtMs)) {
    throw { kind: 'invalidTimestamp' } satisfies LocalQueueCapacityConfigError;
  }
  return {
    villageID: input.villageID,
    queueKind: input.queueKind,
    capacity: input.capacity,
    updatedAtMs: input.updatedAtMs,
    source: input.source ?? 'userConfigured',
  };
}

export function validateLocalQueueCapacityValue(
  capacity: number,
): LocalQueueCapacityConfigError | null {
  if (!Number.isInteger(capacity) || capacity < 0 || capacity > LOCAL_QUEUE_CAPACITY_MAXIMUM) {
    return { kind: 'invalidCapacity', capacity };
  }
  return null;
}

export function localQueueCapacityConfigErrorsEqual(
  left: LocalQueueCapacityConfigError,
  right: LocalQueueCapacityConfigError,
): boolean {
  if (left.kind !== right.kind) {
    return false;
  }
  if (left.kind === 'invalidCapacity' && right.kind === 'invalidCapacity') {
    return left.capacity === right.capacity;
  }
  return true;
}
