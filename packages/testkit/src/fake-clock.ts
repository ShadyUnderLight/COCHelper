import type { Clock } from '@coc-helper/domain';

/** 可复现测试用的 Unix epoch 毫秒时钟。 */
export class FakeClock implements Clock {
  private currentMs: number;

  constructor(initialMs: number) {
    this.currentMs = requireSafeInteger(initialMs, 'initialMs');
  }

  nowMs(): number {
    return this.currentMs;
  }

  setMs(value: number): void {
    this.currentMs = requireSafeInteger(value, 'value');
  }

  advanceBy(deltaMs: number): number {
    const delta = requireSafeInteger(deltaMs, 'deltaMs');
    this.currentMs = requireSafeInteger(this.currentMs + delta, 'result');
    return this.currentMs;
  }
}

function requireSafeInteger(value: number, name: string): number {
  if (!Number.isSafeInteger(value)) {
    throw new RangeError(`FakeClock ${name} 必须是安全整数毫秒。`);
  }
  return value;
}
