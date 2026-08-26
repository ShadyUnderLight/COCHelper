import type { UuidString } from '@coc-helper/wire';

/** 可注入的 Unix epoch 毫秒时钟。 */
export interface Clock {
  nowMs(): number;
}

/** 可注入的 UUID 来源，用于需要可复现身份的领域操作。 */
export interface UuidSource {
  next(): UuidString;
}
