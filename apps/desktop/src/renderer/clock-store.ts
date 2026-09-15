/**
 * 全 Renderer 唯一显示时钟：只格式化 Main 已提供的时间事实，不触发 IPC。
 */
type ClockListener = () => void;

const TICK_MS = 1000;

let nowMs = Date.now();
let subscriberCount = 0;
let timer: ReturnType<typeof setInterval> | null = null;
const listeners = new Set<ClockListener>();

function notify(): void {
  for (const listener of listeners) {
    listener();
  }
}

function startTicker(): void {
  if (timer !== null) {
    return;
  }
  timer = setInterval(() => {
    nowMs = Date.now();
    notify();
  }, TICK_MS);
}

function stopTicker(): void {
  if (timer === null) {
    return;
  }
  clearInterval(timer);
  timer = null;
}

export type ClockStore = {
  readonly getSnapshot: () => number;
  readonly subscribe: (listener: ClockListener) => () => void;
};

export const clockStore: ClockStore = {
  getSnapshot(): number {
    return nowMs;
  },
  subscribe(listener: ClockListener): () => void {
    listeners.add(listener);
    subscriberCount += 1;
    if (subscriberCount === 1) {
      startTicker();
    }
    return () => {
      if (!listeners.has(listener)) {
        return;
      }
      listeners.delete(listener);
      subscriberCount -= 1;
      if (subscriberCount === 0) {
        stopTicker();
      }
    };
  },
};

/** 将 Main 提供的绝对结束时刻格式化为剩余毫秒（可为负，不在 Renderer 推断完成）。 */
export function remainingMs(expectedEndAtMs: number, atMs: number): number {
  return expectedEndAtMs - atMs;
}

/** 测试专用：重置单例状态。 */
export function resetClockStoreForTests(atMs = 0): void {
  stopTicker();
  listeners.clear();
  subscriberCount = 0;
  nowMs = atMs;
}

/** 测试专用：手动推进显示时间。 */
export function advanceClockStoreForTests(deltaMs: number): void {
  nowMs += deltaMs;
  notify();
}
