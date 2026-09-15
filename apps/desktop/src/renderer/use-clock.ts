import { useSyncExternalStore } from 'react';

import { clockStore } from './clock-store';

/** 订阅全应用唯一显示时钟（默认每秒 tick，无订阅者时停止）。 */
export function useClock(): number {
  return useSyncExternalStore(clockStore.subscribe, clockStore.getSnapshot, clockStore.getSnapshot);
}
