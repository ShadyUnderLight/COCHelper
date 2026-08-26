import { describe, expect, it } from 'vitest';

import {
  APP_HEALTH_CHANNEL,
  DESKTOP_BRIDGE_KEYS,
  REQUEST_CANCEL_CHANNEL,
  REQUEST_ID_MAX_LENGTH,
  isCancelRequest,
  isRequestId,
} from './ipc';

describe('@coc-helper/contracts IPC', () => {
  it('登记 health 与 cancel 通道，并保持 requestId 长度上限', () => {
    expect(APP_HEALTH_CHANNEL).toBe('app.health');
    expect(REQUEST_CANCEL_CHANNEL).toBe('request.cancel');
    expect(REQUEST_ID_MAX_LENGTH).toBe(128);
    expect(DESKTOP_BRIDGE_KEYS).toEqual(['health', 'cancel']);
  });

  it('只接受可打印、有限长度的 requestId DTO', () => {
    expect(isRequestId('request-1')).toBe(true);
    expect(isRequestId('')).toBe(false);
    expect(isRequestId('x'.repeat(REQUEST_ID_MAX_LENGTH + 1))).toBe(false);
    expect(isRequestId('request\n1')).toBe(false);
    expect(isCancelRequest({ requestId: 'request-1' })).toBe(true);
    expect(isCancelRequest({ requestId: 'request-1', extra: true })).toBe(false);
    expect(isCancelRequest(Object.create(null))).toBe(false);
  });
});
