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
      () => () => undefined,
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
      () => () => undefined,
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
      () => () => undefined,
    );
    expect(() => bridge.cancel({ requestId: '' as RequestId })).toThrow(
      'request.cancel 参数不合法',
    );
  });

  it('校验 app.snapshot 与 state.changed 订阅', async () => {
    const snapshot = {
      generation: 0,
      availability: 'available',
      villageStatus: 'missing',
      villageError: null,
      canWrite: true,
      selectedVillageId: null,
      villages: [],
      pendingImport: null,
    };
    const holder: { listener: ((payload: unknown) => void) | null } = { listener: null };
    const bridge = createDesktopBridge(
      async (channel) => {
        if (channel === 'app.snapshot') {
          return { ok: true, value: snapshot };
        }
        throw new Error(`unexpected ${channel}`);
      },
      () => {},
      (_channel, listener) => {
        holder.listener = listener;
        return () => {
          holder.listener = null;
        };
      },
    );
    const result = await bridge.snapshot();
    expect(result).toEqual({ ok: true, value: snapshot });

    const seen: unknown[] = [];
    const unsubscribe = bridge.onStateChanged((payload) => {
      seen.push(payload);
    });
    holder.listener?.(snapshot);
    holder.listener?.({ forged: true });
    expect(seen).toEqual([snapshot]);
    unsubscribe();
  });
});
