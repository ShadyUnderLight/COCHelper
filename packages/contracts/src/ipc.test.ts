import { describe, expect, it } from 'vitest';

import {
  APP_HEALTH_CHANNEL,
  APP_IPC_BRIDGE_KEYS,
  APP_IPC_CHANNELS,
  APP_SNAPSHOT_CHANNEL,
  DESKTOP_BRIDGE_KEYS,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  REQUEST_CANCEL_CHANNEL,
  REQUEST_ID_MAX_LENGTH,
  STATE_CHANGED_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  isCancelRequest,
  isRequestId,
} from './ipc';

describe('@coc-helper/contracts IPC', () => {
  it('登记 health、cancel 与 E3-02 业务通道', () => {
    expect(APP_HEALTH_CHANNEL).toBe('app.health');
    expect(REQUEST_CANCEL_CHANNEL).toBe('request.cancel');
    expect(APP_SNAPSHOT_CHANNEL).toBe('app.snapshot');
    expect(VILLAGE_SELECT_CHANNEL).toBe('village.select');
    expect(IMPORT_PREPARE_CHANNEL).toBe('import.prepare');
    expect(IMPORT_COMMIT_CHANNEL).toBe('import.commit');
    expect(IMPORT_DISCARD_CHANNEL).toBe('import.discard');
    expect(STATE_CHANGED_CHANNEL).toBe('state.changed');
    expect(REQUEST_ID_MAX_LENGTH).toBe(128);
    expect(APP_IPC_CHANNELS).toEqual([
      APP_SNAPSHOT_CHANNEL,
      VILLAGE_SELECT_CHANNEL,
      IMPORT_PREPARE_CHANNEL,
      IMPORT_COMMIT_CHANNEL,
      IMPORT_DISCARD_CHANNEL,
      STATE_CHANGED_CHANNEL,
    ]);
    expect(DESKTOP_BRIDGE_KEYS).toEqual(['health', 'cancel', ...APP_IPC_BRIDGE_KEYS]);
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
