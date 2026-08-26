import { describe, expect, it } from 'vitest';

import { APP_HEALTH_CHANNEL, REQUEST_CANCEL_CHANNEL, type RequestId } from '@coc-helper/contracts';

import {
  IpcValidationError,
  REGISTERED_IPC_CHANNELS,
  appHealthResponse,
  parseCancelRequest,
  parseAppHealthRequest,
  toIpcError,
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

  it('登记 health 与 cancel 通道，并返回 Result envelope', () => {
    expect(REGISTERED_IPC_CHANNELS).toEqual([APP_HEALTH_CHANNEL, REQUEST_CANCEL_CHANNEL]);
    expect(appHealthResponse()).toEqual({ ok: true, value: { app: 'coc-helper' } });
  });
});

describe('request.cancel schema', () => {
  it('接受可打印 requestId 并拒绝空值、超长值和额外字段', () => {
    expect(parseCancelRequest({ requestId: 'request-1' })).toEqual({
      requestId: 'request-1' as RequestId,
    });
    expect(() => parseCancelRequest({ requestId: '' })).toThrow(IpcValidationError);
    expect(() => parseCancelRequest({ requestId: 'x'.repeat(129) })).toThrow(IpcValidationError);
    expect(() => parseCancelRequest({ requestId: 'request-1', extra: true })).toThrow(
      IpcValidationError,
    );
    expect(() => parseCancelRequest({ requestId: 'line\nbreak' })).toThrow(IpcValidationError);
    expect(() => parseCancelRequest('request-1')).toThrow(IpcValidationError);
  });
});

describe('toIpcError', () => {
  it('保留静态 validation 信息并将未知 Error 收敛为安全 internal', () => {
    const bearerMessage = ['Authorization', ': ', 'Bearer', ' ', 'secret-token'].join('');
    expect(toIpcError(new IpcValidationError('请求参数不合法'))).toEqual({
      kind: 'validation',
      code: 'invalidRequest',
      messageKey: 'ipc.invalidRequest',
      message: '请求参数不合法',
    });
    expect(toIpcError(new Error(bearerMessage))).toEqual({
      kind: 'internal',
      code: 'internalError',
      messageKey: 'ipc.internalError',
      message: '宿主内部错误。',
    });
    expect(
      toIpcError(new IpcValidationError(`${bearerMessage} https://example.test/body`)).message,
    ).not.toContain('secret-token');
  });

  it('将 AbortError 映射为 cancelled，不传播原始消息', () => {
    const error = new Error('request body secret');
    error.name = 'AbortError';
    expect(toIpcError(error)).toEqual({
      kind: 'cancelled',
      code: 'requestCancelled',
      messageKey: 'ipc.requestCancelled',
      message: '请求已取消。',
    });
  });
});
