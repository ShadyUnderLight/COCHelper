import { useSyncExternalStore } from 'react';

import { clockStore } from './clock-store';

const subscribeDisabled = (): (() => void) => () => undefined;

/** 订阅全应用唯一显示时钟（默认每秒 tick，无订阅者时停止）。 */
export function useClock(enabled = true): number {
  return useSyncExternalStore(
    enabled ? clockStore.subscribe : subscribeDisabled,
    clockStore.getSnapshot,
    clockStore.getSnapshot,
  );
}
