import { describe, expect, it } from 'vitest';

import { DESKTOP_BRIDGE_KEYS } from '@coc-helper/contracts';

import { createDesktopBridge, isAppHealthResponse } from './api';

describe('preload API surface', () => {
  it('只暴露 health，且不把 ipcRenderer 交给 renderer', () => {
    const invokeCalls: string[] = [];
    const bridge = createDesktopBridge(async (channel) => {
      invokeCalls.push(channel);
      return { ok: true, app: 'coc-helper' };
    });
    expect(Object.keys(bridge)).toEqual([...DESKTOP_BRIDGE_KEYS]);
    expect(bridge).not.toHaveProperty('ipcRenderer');
  });

  it('拒绝伪造的 health 返回', async () => {
    const bridge = createDesktopBridge(async () => ({ ok: true }));
    await expect(bridge.health()).rejects.toThrow('app.health 返回值不合法');
    expect(isAppHealthResponse({ ok: true, app: 'coc-helper' })).toBe(true);
    expect(isAppHealthResponse({ ok: true, app: 'other' })).toBe(false);
  });
});
