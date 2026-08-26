import { describe, expect, it } from 'vitest';

import { APP_HEALTH_CHANNEL } from '@coc-helper/contracts';

import {
  IpcValidationError,
  REGISTERED_IPC_CHANNELS,
  appHealthResponse,
  parseAppHealthRequest,
} from './ipc-schema';

describe('app.health schema', () => {
  it('接受空对象或缺省参数', () => {
    expect(() => parseAppHealthRequest(undefined)).not.toThrow();
    expect(() => parseAppHealthRequest({})).not.toThrow();
  });

  it('拒绝多余字段与非对象', () => {
    expect(() => parseAppHealthRequest({ extra: true })).toThrow(IpcValidationError);
    expect(() => parseAppHealthRequest([])).toThrow(IpcValidationError);
    expect(() => parseAppHealthRequest('ping')).toThrow(IpcValidationError);
    expect(() => parseAppHealthRequest(1)).toThrow(IpcValidationError);
  });

  it('只登记 stub 通道', () => {
    expect(REGISTERED_IPC_CHANNELS).toEqual([APP_HEALTH_CHANNEL]);
    expect(appHealthResponse()).toEqual({ ok: true, app: 'coc-helper' });
  });
});
