import { describe, expect, it } from 'vitest';

import { DESKTOP_BRIDGE_KEYS, type RequestId } from '@coc-helper/contracts';

import { createDesktopBridge, isAppHealthResponse } from './api';

describe('preload API surface', () => {
  it('只暴露受限 API，且不把 ipcRenderer 交给 renderer', () => {
    const invokeCalls: string[] = [];
    const sendCalls: string[] = [];
    const bridge = createDesktopBridge(
      async (channel) => {
        invokeCalls.push(channel);
        return { ok: true, value: { app: 'coc-helper' } };
      },
      (channel) => {
        sendCalls.push(channel);
      },
    );
    expect(Object.keys(bridge)).toEqual([...DESKTOP_BRIDGE_KEYS]);
    expect(bridge).not.toHaveProperty('ipcRenderer');
    bridge.cancel({ requestId: 'request-1' as RequestId });
    expect(invokeCalls).toEqual([]);
    expect(sendCalls).toEqual(['request.cancel']);
  });

  it('拒绝伪造的 health 返回', async () => {
    const bridge = createDesktopBridge(
      async () => ({ ok: true }),
      () => {},
    );
    await expect(bridge.health()).rejects.toThrow('app.health 返回值不合法');
    expect(isAppHealthResponse({ ok: true, value: { app: 'coc-helper' } })).toBe(true);
    expect(isAppHealthResponse({ ok: true, value: { app: 'other' } })).toBe(false);
  });

  it('拒绝不合法的 cancel request', () => {
    const bridge = createDesktopBridge(
      async () => ({ ok: true, value: { app: 'coc-helper' } }),
      () => {
        throw new Error('不应发送');
      },
    );
    expect(() => bridge.cancel({ requestId: '' as RequestId })).toThrow(
      'request.cancel 参数不合法',
    );
  });
});
