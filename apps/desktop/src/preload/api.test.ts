import { describe, expect, it } from 'vitest';

import { DESKTOP_BRIDGE_KEYS, type RequestId } from '@coc-helper/contracts';

import { createDesktopBridge, isAppHealthResponse, isQuickPrepareResponse } from './api';

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

  it('quick 通道透传并校验 preview 形状，拒绝伪造', async () => {
    const preview = {
      snapshot: {
        tag: '#A',
        diagnostics: [],
        unknownTopLevelKeys: [],
      },
      targetVillageId: 'v-1',
      targetVillageName: 'A',
      targetVillageTag: null,
      targetVillageHasSnapshot: false,
      replacesSameTag: false,
      destinationDescription: '将建立「A」的账号快照并导入',
    };
    const seen: string[] = [];
    const bridge = createDesktopBridge(
      async (channel) => {
        seen.push(channel);
        if (channel === 'import.quickPrepare') {
          return { ok: true, value: { generation: 4, preview } };
        }
        if (channel === 'import.quickCommit') {
          return { ok: true, value: { generation: 5, selectedVillageId: 'v-1' } };
        }
        return { ok: true, value: { generation: 5 } };
      },
      () => {},
      () => () => undefined,
    );
    await expect(bridge.quickPrepare({ targetVillageId: 'v-1' })).resolves.toEqual({
      ok: true,
      value: { generation: 4, preview },
    });
    await expect(bridge.quickCommit({ expectedGeneration: 4 })).resolves.toEqual({
      ok: true,
      value: { generation: 5, selectedVillageId: 'v-1' },
    });
    await expect(bridge.quickDiscard({ expectedGeneration: 4 })).resolves.toEqual({
      ok: true,
      value: { generation: 5 },
    });
    expect(seen).toEqual(['import.quickPrepare', 'import.quickCommit', 'import.quickDiscard']);
    expect(isQuickPrepareResponse({ ok: true, value: { generation: 4, preview } })).toBe(true);
    expect(isQuickPrepareResponse({ ok: true, value: { generation: 4 } })).toBe(false);
    await expect(
      createDesktopBridge(
        async () => ({ ok: true, value: { generation: 4, preview: {} } }),
        () => {},
        () => () => undefined,
      ).quickPrepare({ targetVillageId: 'v-1' }),
    ).rejects.toThrow('import.quickPrepare 返回值不合法');
  });

  it('校验 app.snapshot 与 state.changed 订阅，并拒绝伪造 payload', async () => {
    const snapshot = {
      sessionId: 'session-test',
      generation: 0,
      availability: 'available',
      villageStatus: 'missing',
      villageError: null,
      canWrite: true,
      hasPendingJournal: false,
      recoveryNotice: null,
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

    await expect(
      createDesktopBridge(
        async () => ({
          ok: true,
          value: { ...snapshot, availability: 'garbage', villages: [123] },
        }),
        () => {},
        () => () => undefined,
      ).snapshot(),
    ).rejects.toThrow('app.snapshot 返回值不合法');

    const seen: unknown[] = [];
    const unsubscribe = bridge.onStateChanged((payload) => {
      seen.push(payload);
    });
    holder.listener?.(snapshot);
    holder.listener?.({ forged: true });
    holder.listener?.({ ...snapshot, availability: 'garbage' });
    expect(seen).toEqual([snapshot]);
    unsubscribe();
  });
});
