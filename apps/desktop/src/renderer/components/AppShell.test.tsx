/** @vitest-environment jsdom */

import { useState } from 'react';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { ApiRefreshPayload, AppSnapshotPayload, Result } from '@coc-helper/contracts';

import { AppShell } from './AppShell';
import { INITIAL_APP_SESSION, type AppSessionState } from '../app-session';
import { clockStore, resetClockStoreForTests } from '../clock-store';
import { INITIAL_OVERVIEW_STATE, applyOverviewSuccess, recordFixture } from '../overview-session';
import { playerFixture } from '../official-session.fixtures';
import type { AppRoute } from '../navigation';
import {
  INITIAL_VILLAGE_DETAIL_STATE,
  applyVillageDetailSuccess,
  villageDetailFixture,
  type VillageDetailState,
} from '../village-detail-session';
import type { AppSessionApi } from '../use-app-session';
import type { OverviewApi } from '../use-upgrade-overview';
import type { VillageDetailApi } from '../use-village-detail';
import type { BridgeOfficialVillageClient } from '../use-official-clan-war-bundle';

function snapshot(overrides: Partial<AppSnapshotPayload> = {}): AppSnapshotPayload {
  return {
    sessionId: '11111111-2222-3333-4444-555555555555',
    generation: 1,
    availability: 'available',
    villageStatus: 'available',
    villageError: null,
    canWrite: true,
    hasPendingJournal: false,
    recoveryNotice: null,
    selectedVillageId: 'v1',
    villages: [
      { id: 'v1', name: '主村', tag: '#AAA', hasImportedData: true },
      { id: 'v2', name: '分村', tag: null, hasImportedData: false },
    ],
    pendingImport: null,
    ...overrides,
  };
}

function sessionApi(state: AppSessionState): AppSessionApi {
  return {
    state,
    recoveryStatus: null,
    setPasteText: () => undefined,
    refresh: async () => undefined,
    selectVillage: async () => true,
    prepareImport: async () => undefined,
    commitImport: async () => undefined,
    discardImport: async () => undefined,
    refreshRecovery: async () => undefined,
    recoveryReset: async () => undefined,
    recoveryRestoreSaved: async () => undefined,
    recoveryRecoverJournal: async () => undefined,
  };
}

function overviewApi(
  state = INITIAL_OVERVIEW_STATE,
  select: OverviewApi['select'] = () => undefined,
): OverviewApi {
  return {
    state,
    selectedId: null,
    select,
    refresh: async () => undefined,
  };
}

function detailApi(state: VillageDetailState = INITIAL_VILLAGE_DETAIL_STATE): VillageDetailApi {
  return {
    state,
    refresh: async () => undefined,
  };
}

afterEach(() => {
  cleanup();
  resetClockStoreForTests();
  vi.useRealTimers();
});

describe('AppShell', () => {
  it('booting 显示加载文案', () => {
    render(
      <AppShell
        session={sessionApi(INITIAL_APP_SESSION)}
        overview={overviewApi()}
        detail={detailApi()}
      />,
    );
    expect(screen.getByText('正在加载应用快照…')).toBeTruthy();
    expect(document.querySelector('[data-smoke="loading"]')).toBeTruthy();
  });

  it('fatal 且 snapshot 为 null 时显示 fatal 而非 loading', () => {
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'fatal',
          snapshot: null,
          lastError: '启动快照失败',
        })}
        overview={overviewApi()}
        detail={detailApi()}
      />,
    );
    expect(document.querySelector('[data-smoke="fatal"]')).toBeTruthy();
    expect(document.querySelector('[data-smoke="loading"]')).toBeNull();
    expect(screen.getByText('启动快照失败')).toBeTruthy();
  });

  it('available 渲染村庄列表与导入区，并标记 smoke ready', () => {
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot(),
        })}
        overview={overviewApi()}
        detail={detailApi()}
      />,
    );
    expect(screen.getByText('主村')).toBeTruthy();
    expect(screen.getByLabelText('账号 JSON')).toBeTruthy();
    expect(document.querySelector('[data-smoke="ready"]')).toBeTruthy();
    expect(screen.getByText('Electron 宿主已就绪')).toBeTruthy();
  });

  it('empty 显示暂无村庄提示', () => {
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot({
            villages: [],
            villageStatus: 'empty',
            selectedVillageId: null,
          }),
        })}
        overview={overviewApi()}
        detail={detailApi()}
      />,
    );
    expect(screen.getByText(/暂无村庄/)).toBeTruthy();
  });

  it('recovery 显示恢复面板而非导入区', () => {
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot({
            availability: 'recovery',
            villageStatus: 'corrupt',
            canWrite: false,
          }),
        })}
        overview={overviewApi()}
        detail={detailApi()}
      />,
    );
    expect(screen.getByLabelText('数据恢复')).toBeTruthy();
    expect(screen.queryByLabelText('账号导入')).toBeNull();
  });

  it('Info 路由渲染 Diagnostics 页面而不是 overview 占位', () => {
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot(),
        })}
        overview={overviewApi()}
        detail={detailApi()}
        route={{ kind: 'info', section: 'diagnostics' }}
      />,
    );
    expect(screen.getByLabelText('诊断')).toBeTruthy();
    expect(screen.getByText('诊断服务不可用。')).toBeTruthy();
    expect(screen.queryByLabelText('升级追踪')).toBeNull();
  });

  it('Token 变更成功后刷新 Diagnostics', async () => {
    const refreshDiagnostics = vi.fn(async () => undefined);
    const tokenBridge = {
      tokenStatus: vi.fn(async () => ({
        ok: true as const,
        value: { configured: false, storage: 'available' as const, message: null },
      })),
      tokenSave: vi.fn(async () => ({
        ok: true as const,
        value: { configured: true, storage: 'available' as const, message: null },
      })),
      tokenClear: vi.fn(async () => ({
        ok: true as const,
        value: { configured: false, storage: 'available' as const, message: null },
      })),
    };

    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot(),
        })}
        overview={overviewApi()}
        detail={detailApi()}
        diagnostics={{
          state: { kind: 'loading', data: null },
          refresh: refreshDiagnostics,
        }}
        tokenBridge={tokenBridge}
        route={{ kind: 'info', section: 'tokenSettings' }}
      />,
    );

    await waitFor(() => expect(screen.getByText('当前未配置 Token。')).toBeTruthy());
    fireEvent.change(screen.getByLabelText('CoC API Token'), {
      target: { value: 'secret-token' },
    });
    fireEvent.click(screen.getByRole('button', { name: '保存 Token' }));

    await waitFor(() => expect(tokenBridge.tokenSave).toHaveBeenCalled());
    expect(refreshDiagnostics).toHaveBeenCalledTimes(1);
  });

  it('Token Settings 路由的顶部刷新会重新读取 Token 状态', async () => {
    const tokenStatus = vi.fn(async () => ({
      ok: true as const,
      value: { configured: false, storage: 'available' as const, message: null },
    }));
    const tokenBridge = {
      tokenStatus,
      tokenSave: vi.fn(async () => ({
        ok: true as const,
        value: { configured: true, storage: 'available' as const, message: null },
      })),
      tokenClear: vi.fn(async () => ({
        ok: true as const,
        value: { configured: false, storage: 'available' as const, message: null },
      })),
    };

    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot(),
        })}
        overview={overviewApi()}
        detail={detailApi()}
        tokenBridge={tokenBridge}
        route={{ kind: 'info', section: 'tokenSettings' }}
      />,
    );

    await waitFor(() => expect(tokenStatus).toHaveBeenCalledTimes(1));
    fireEvent.click(screen.getByRole('button', { name: '刷新数据' }));
    await waitFor(() => expect(tokenStatus).toHaveBeenCalledTimes(2));
  });

  it('recovery 状态仍保留 Info 入口', () => {
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot({
            availability: 'recovery',
            villageStatus: 'corrupt',
            canWrite: false,
          }),
        })}
        overview={overviewApi()}
        detail={detailApi()}
      />,
    );
    expect(screen.getByRole('button', { name: 'Info' })).toBeTruthy();
    expect(screen.getByLabelText('数据恢复')).toBeTruthy();
  });

  it('read-only 提示且禁用写入入口文案可见', () => {
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot({ canWrite: false, villageStatus: 'readOnly' }),
        })}
        overview={overviewApi()}
        detail={detailApi()}
      />,
    );
    expect(screen.getByText(/只读模式/)).toBeTruthy();
  });

  it('总览 tab 切换显示升级追踪', () => {
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot(),
        })}
        overview={overviewApi()}
        detail={detailApi()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '升级追踪' }));
    expect(screen.getByLabelText('升级追踪')).toBeTruthy();
    expect(screen.queryByLabelText('账号 JSON')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: '导入' }));
    expect(screen.getByLabelText('账号 JSON')).toBeTruthy();
    expect(screen.queryByLabelText('升级追踪')).toBeNull();
  });

  it('无选中村庄时详情 tab 禁用', () => {
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot({ selectedVillageId: null }),
        })}
        overview={overviewApi()}
        detail={detailApi()}
      />,
    );
    const tab = screen.getByRole('button', { name: '村庄详情' });
    expect(tab.hasAttribute('disabled')).toBe(true);
  });

  it('有选中村庄可切详情', () => {
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot(),
        })}
        overview={overviewApi()}
        detail={detailApi()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '村庄详情' }));
    expect(screen.getByLabelText('村庄详情')).toBeTruthy();
    expect(screen.getByRole('heading', { level: 1, name: '村庄详情' })).toBeTruthy();
  });

  it('详情 route 点击当前村庄可进入升级追踪而不重复切换档案', () => {
    const selectVillage = vi.fn(async () => true);
    function Shell() {
      const [route, setRoute] = useState<AppRoute>({
        kind: 'villageDetail',
        villageId: 'v1',
        base: 'home',
      });
      return (
        <AppShell
          session={{ ...readySession(), selectVillage }}
          overview={overviewApi()}
          detail={detailApi()}
          route={route}
          onRouteChange={setRoute}
        />
      );
    }
    render(<Shell />);

    fireEvent.click(screen.getByRole('button', { name: /主村/ }));

    expect(selectVillage).not.toHaveBeenCalled();
    expect(screen.getByLabelText('升级追踪')).toBeTruthy();
  });

  it('总览行点击切到详情', () => {
    const overviewState = applyOverviewSuccess({
      generation: 1,
      nowMs: 1,
      catalogVersion: '18.400.13',
      catalogIsUsable: true,
      active: [recordFixture({ id: 'r1' })],
      pending: [],
      state: {
        manualActiveCount: 0,
        manualActiveRecords: [],
        importedActiveCount: 0,
        deduplicatedDisplayCount: 0,
        manualCompletedCount: 0,
        completedRecently: [],
        activeRecords: [],
        attentionRecords: [],
        needsReimportRecords: [],
      },
    });
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot(),
        })}
        overview={overviewApi(overviewState)}
        detail={detailApi()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '升级追踪' }));
    fireEvent.click(screen.getByRole('button', { name: /加农炮/ }));
    expect(screen.getByLabelText('村庄详情')).toBeTruthy();
  });

  it('详情 route 下 sidebar 选村成功时同步更新 route', async () => {
    const onRouteChange = vi.fn();
    const selectVillage = vi.fn(async () => true);
    render(
      <AppShell
        session={{
          ...sessionApi({
            ...INITIAL_APP_SESSION,
            status: 'ready',
            snapshot: snapshot({ selectedVillageId: 'v1' }),
          }),
          selectVillage,
        }}
        overview={overviewApi()}
        detail={detailApi(applyVillageDetailSuccess(villageDetailFixture()))}
        route={{ kind: 'villageDetail', villageId: 'v1', base: 'home' }}
        onRouteChange={onRouteChange}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: /分村/ }));
    await waitFor(() => {
      expect(selectVillage).toHaveBeenCalledWith('v2');
    });
    await waitFor(() => {
      expect(onRouteChange).toHaveBeenCalledWith({
        kind: 'villageDetail',
        villageId: 'v2',
        base: 'home',
      });
    });
  });

  it('导入 route 下 sidebar 切换目标村庄时保留导入页面', async () => {
    const onRouteChange = vi.fn();
    const selectVillage = vi.fn(async () => true);
    render(
      <AppShell
        session={{
          ...sessionApi({
            ...INITIAL_APP_SESSION,
            status: 'ready',
            snapshot: snapshot({ selectedVillageId: 'v1' }),
          }),
          selectVillage,
        }}
        overview={overviewApi()}
        detail={detailApi()}
        route={{ kind: 'import' }}
        onRouteChange={onRouteChange}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: /分村/ }));

    await waitFor(() => expect(selectVillage).toHaveBeenCalledWith('v2'));
    expect(screen.getByLabelText('账号 JSON')).toBeTruthy();
    expect(screen.queryByLabelText('升级追踪')).toBeNull();
    expect(onRouteChange).not.toHaveBeenCalled();
  });

  it('详情 route 下 sidebar 选村失败时 route 不变', async () => {
    const onRouteChange = vi.fn();
    const selectVillage = vi.fn(async () => false);
    render(
      <AppShell
        session={{
          ...sessionApi({
            ...INITIAL_APP_SESSION,
            status: 'ready',
            snapshot: snapshot({ selectedVillageId: 'v1' }),
          }),
          selectVillage,
        }}
        overview={overviewApi()}
        detail={detailApi(applyVillageDetailSuccess(villageDetailFixture()))}
        route={{ kind: 'villageDetail', villageId: 'v1', base: 'home' }}
        onRouteChange={onRouteChange}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: /分村/ }));
    await waitFor(() => {
      expect(selectVillage).toHaveBeenCalledWith('v2');
    });
    expect(onRouteChange).not.toHaveBeenCalled();
  });

  it('sidebar 选村 pending 期间切到总览后不应被旧 callback 拉回详情', async () => {
    let resolveSelect!: (ok: boolean) => void;
    const selectVillage = vi.fn(
      () =>
        new Promise<boolean>((resolve) => {
          resolveSelect = resolve;
        }),
    );
    const detailState = applyVillageDetailSuccess(villageDetailFixture());
    render(
      <AppShell
        session={{
          ...sessionApi({
            ...INITIAL_APP_SESSION,
            status: 'ready',
            snapshot: snapshot({ selectedVillageId: 'v1' }),
          }),
          selectVillage,
        }}
        overview={overviewApi()}
        detail={detailApi(detailState)}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '村庄详情' }));
    expect(screen.getByLabelText('村庄详情')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /分村/ }));
    expect(selectVillage).toHaveBeenCalledWith('v2');
    fireEvent.click(screen.getByRole('button', { name: '升级追踪' }));
    expect(screen.getByLabelText('升级追踪')).toBeTruthy();
    act(() => {
      resolveSelect(true);
    });
    await act(async () => {});
    expect(screen.getByLabelText('升级追踪')).toBeTruthy();
    expect(screen.queryByLabelText('村庄详情')).toBeNull();
  });

  it('sidebar 选村 pending 期间切 base，成功后应同步 v2/builder', async () => {
    let resolveSelect!: (ok: boolean) => void;
    const selectVillage = vi.fn(
      () =>
        new Promise<boolean>((resolve) => {
          resolveSelect = resolve;
        }),
    );
    const onRouteChange = vi.fn();
    const detailState = applyVillageDetailSuccess(villageDetailFixture());
    const shellProps = {
      session: {
        ...sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot({ selectedVillageId: 'v1' }),
        }),
        selectVillage,
      },
      overview: overviewApi(),
      detail: detailApi(detailState),
      onRouteChange,
    };
    const { rerender } = render(
      <AppShell {...shellProps} route={{ kind: 'villageDetail', villageId: 'v1', base: 'home' }} />,
    );
    fireEvent.click(screen.getByRole('button', { name: /分村/ }));
    rerender(
      <AppShell
        {...shellProps}
        route={{ kind: 'villageDetail', villageId: 'v1', base: 'builder' }}
      />,
    );
    act(() => {
      resolveSelect(true);
    });
    await waitFor(() => {
      expect(onRouteChange).toHaveBeenCalledWith({
        kind: 'villageDetail',
        villageId: 'v2',
        base: 'builder',
      });
    });
  });

  it('详情 base 切换透传（初始主村按下）', () => {
    const detailState = applyVillageDetailSuccess(villageDetailFixture());
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot(),
        })}
        overview={overviewApi()}
        detail={detailApi(detailState)}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '村庄详情' }));
    const homeTab = screen.getByRole('button', { name: '主村' });
    expect(homeTab.getAttribute('aria-pressed')).toBe('true');
  });

  it('总览中点击他村记录时同步切换选中村庄再进详情', async () => {
    const selectVillage = vi.fn(async () => true);
    const bRecord = recordFixture({ id: 'rec-b', villageID: 'v2', villageName: '分村' });
    const overviewState = applyOverviewSuccess({
      generation: 1,
      nowMs: 1,
      catalogVersion: '18.400.13',
      catalogIsUsable: true,
      active: [bRecord],
      pending: [],
      state: {
        manualActiveCount: 0,
        manualActiveRecords: [],
        importedActiveCount: 0,
        deduplicatedDisplayCount: 0,
        manualCompletedCount: 0,
        completedRecently: [],
        activeRecords: [],
        attentionRecords: [],
        needsReimportRecords: [],
      },
    });
    render(
      <AppShell
        session={{
          ...sessionApi({
            ...INITIAL_APP_SESSION,
            status: 'ready',
            snapshot: snapshot({ selectedVillageId: 'v1' }),
          }),
          selectVillage,
        }}
        overview={overviewApi(overviewState)}
        detail={detailApi()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '升级追踪' }));
    fireEvent.click(screen.getByRole('button', { name: /加农炮/ }));
    expect(selectVillage).toHaveBeenCalledWith('v2');
    await waitFor(() => {
      expect(screen.getByLabelText('村庄详情')).toBeTruthy();
    });
  });

  it('总览中点击本村记录时不重复切换村庄', () => {
    const selectVillage = vi.fn(async () => true);
    const aRecord = recordFixture({ id: 'rec-a', villageID: 'v1', villageName: '主村' });
    const overviewState = applyOverviewSuccess({
      generation: 1,
      nowMs: 1,
      catalogVersion: '18.400.13',
      catalogIsUsable: true,
      active: [aRecord],
      pending: [],
      state: {
        manualActiveCount: 0,
        manualActiveRecords: [],
        importedActiveCount: 0,
        deduplicatedDisplayCount: 0,
        manualCompletedCount: 0,
        completedRecently: [],
        activeRecords: [],
        attentionRecords: [],
        needsReimportRecords: [],
      },
    });
    render(
      <AppShell
        session={{
          ...sessionApi({
            ...INITIAL_APP_SESSION,
            status: 'ready',
            snapshot: snapshot({ selectedVillageId: 'v1' }),
          }),
          selectVillage,
        }}
        overview={overviewApi(overviewState)}
        detail={detailApi()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '升级追踪' }));
    fireEvent.click(screen.getByRole('button', { name: /加农炮/ }));
    expect(selectVillage).not.toHaveBeenCalled();
    expect(screen.getByLabelText('村庄详情')).toBeTruthy();
  });

  it('总览点击他村记录 pending 期间切到导入后，成功时不应被拉回详情', async () => {
    let resolveSelect!: (ok: boolean) => void;
    const selectVillage = vi.fn(
      () =>
        new Promise<boolean>((resolve) => {
          resolveSelect = resolve;
        }),
    );
    const bRecord = recordFixture({ id: 'rec-b', villageID: 'v2', villageName: '分村' });
    const overviewState = applyOverviewSuccess({
      generation: 1,
      nowMs: 1,
      catalogVersion: '18.400.13',
      catalogIsUsable: true,
      active: [bRecord],
      pending: [],
      state: {
        manualActiveCount: 0,
        manualActiveRecords: [],
        importedActiveCount: 0,
        deduplicatedDisplayCount: 0,
        manualCompletedCount: 0,
        completedRecently: [],
        activeRecords: [],
        attentionRecords: [],
        needsReimportRecords: [],
      },
    });
    render(
      <AppShell
        session={{
          ...sessionApi({
            ...INITIAL_APP_SESSION,
            status: 'ready',
            snapshot: snapshot({ selectedVillageId: 'v1' }),
          }),
          selectVillage,
        }}
        overview={overviewApi(overviewState)}
        detail={detailApi()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '升级追踪' }));
    fireEvent.click(screen.getByRole('button', { name: /加农炮/ }));
    expect(selectVillage).toHaveBeenCalledWith('v2');
    fireEvent.click(screen.getByRole('button', { name: '导入' }));
    expect(screen.getByLabelText('账号 JSON')).toBeTruthy();
    act(() => {
      resolveSelect(true);
    });
    await act(async () => {});
    expect(screen.getByLabelText('账号 JSON')).toBeTruthy();
    expect(screen.queryByLabelText('村庄详情')).toBeNull();
  });

  it('切换村庄 pending 时仍停留在总览，成功后才进详情', async () => {
    let resolveSelect!: (ok: boolean) => void;
    const selectVillage = vi.fn(
      () =>
        new Promise<boolean>((resolve) => {
          resolveSelect = resolve;
        }),
    );
    const bRecord = recordFixture({ id: 'rec-b', villageID: 'v2', villageName: '分村' });
    const overviewState = applyOverviewSuccess({
      generation: 1,
      nowMs: 1,
      catalogVersion: '18.400.13',
      catalogIsUsable: true,
      active: [bRecord],
      pending: [],
      state: {
        manualActiveCount: 0,
        manualActiveRecords: [],
        importedActiveCount: 0,
        deduplicatedDisplayCount: 0,
        manualCompletedCount: 0,
        completedRecently: [],
        activeRecords: [],
        attentionRecords: [],
        needsReimportRecords: [],
      },
    });
    render(
      <AppShell
        session={{
          ...sessionApi({
            ...INITIAL_APP_SESSION,
            status: 'ready',
            snapshot: snapshot({ selectedVillageId: 'v1' }),
          }),
          selectVillage,
        }}
        overview={overviewApi(overviewState)}
        detail={detailApi()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '升级追踪' }));
    fireEvent.click(screen.getByRole('button', { name: /加农炮/ }));
    expect(selectVillage).toHaveBeenCalledWith('v2');
    await act(async () => {});
    // 切换未完成：仍在总览，不进详情。
    expect(screen.queryByLabelText('村庄详情')).toBeNull();
    expect(screen.getByLabelText('升级追踪')).toBeTruthy();
    act(() => {
      resolveSelect(true);
    });
    await waitFor(() => {
      expect(screen.getByLabelText('村庄详情')).toBeTruthy();
    });
  });

  it('切换村庄失败时不进详情，留在总览', async () => {
    let resolveSelect!: (ok: boolean) => void;
    const selectVillage = vi.fn(
      () =>
        new Promise<boolean>((resolve) => {
          resolveSelect = resolve;
        }),
    );
    const bRecord = recordFixture({ id: 'rec-b', villageID: 'v2', villageName: '分村' });
    const overviewState = applyOverviewSuccess({
      generation: 1,
      nowMs: 1,
      catalogVersion: '18.400.13',
      catalogIsUsable: true,
      active: [bRecord],
      pending: [],
      state: {
        manualActiveCount: 0,
        manualActiveRecords: [],
        importedActiveCount: 0,
        deduplicatedDisplayCount: 0,
        manualCompletedCount: 0,
        completedRecently: [],
        activeRecords: [],
        attentionRecords: [],
        needsReimportRecords: [],
      },
    });
    render(
      <AppShell
        session={{
          ...sessionApi({
            ...INITIAL_APP_SESSION,
            status: 'ready',
            snapshot: snapshot({ selectedVillageId: 'v1' }),
          }),
          selectVillage,
        }}
        overview={overviewApi(overviewState)}
        detail={detailApi()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '升级追踪' }));
    fireEvent.click(screen.getByRole('button', { name: /加农炮/ }));
    act(() => {
      resolveSelect(false);
    });
    await act(async () => {});
    expect(screen.queryByLabelText('村庄详情')).toBeNull();
    expect(screen.getByLabelText('升级追踪')).toBeTruthy();
  });
});

function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

function readySession(overrides: Partial<AppSnapshotPayload> = {}) {
  return sessionApi({
    ...INITIAL_APP_SESSION,
    status: 'ready',
    snapshot: snapshot(overrides),
  });
}

function createOfficialBridge() {
  const playerResolvers: Array<(value: Result<ReturnType<typeof playerFixture>>) => void> = [];
  const refreshResolvers: Array<(value: Result<ApiRefreshPayload>) => void> = [];
  const bridge: BridgeOfficialVillageClient = {
    playerState: vi.fn(
      async () =>
        await new Promise<Result<ReturnType<typeof playerFixture>>>((resolve) => {
          playerResolvers.push(resolve);
        }),
    ),
    clanState: vi.fn(async () => ({
      ok: true as const,
      value: {
        generation: 1,
        clanTag: '#CLAN01',
        summary: {
          name: '测试部落',
          tag: '#CLAN01',
          clanLevel: 12,
          members: 40,
          type: 'open',
          isWarLogPublic: true,
          warWins: 0,
        },
        state: null,
      },
    })),
    clanWarState: vi.fn(async () => ({
      ok: true as const,
      value: { generation: 1, clanTag: '#CLAN01', state: null },
    })),
    warLogState: vi.fn(async () => ({
      ok: true as const,
      value: { generation: 1, clanTag: '#CLAN01', state: null },
    })),
    capitalRaidState: vi.fn(async () => ({
      ok: true as const,
      value: { generation: 1, clanTag: '#CLAN01', state: null },
    })),
    apiRefresh: vi.fn(
      async () =>
        await new Promise<Result<ApiRefreshPayload>>((resolve) => {
          refreshResolvers.push(resolve);
        }),
    ),
    warLogLoadMore: vi.fn(async () => ({
      ok: true as const,
      value: {
        generation: 1,
        clanTag: '#CLAN01',
        state: {
          status: 'success' as const,
          parserVersion: 'war-log-0.1',
          unrecognizedKeys: [] as const,
        },
      },
    })),
    capitalRaidLoadMore: vi.fn(async () => ({
      ok: true as const,
      value: {
        generation: 1,
        clanTag: '#CLAN01',
        state: {
          status: 'success' as const,
          parserVersion: 'capital-raid-0.1',
          unrecognizedKeys: [] as const,
        },
      },
    })),
    onOperationProgress: () => () => undefined,
    cancel: vi.fn(),
  };
  return {
    bridge,
    resolvePlayer(value: Result<ReturnType<typeof playerFixture>>) {
      playerResolvers.shift()?.(value);
    },
    refreshPending() {
      return refreshResolvers.length;
    },
  };
}

describe('AppShell Official 接线（#277-E1）', () => {
  it('导入页只按 selectedVillageId 查玩家，不自动 apiRefresh', async () => {
    const harness = createOfficialBridge();
    render(
      <AppShell
        session={readySession({ selectedVillageId: 'v1' })}
        overview={overviewApi()}
        detail={detailApi()}
        officialBridge={harness.bridge}
        route={{ kind: 'import' }}
      />,
    );
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledWith({ villageId: 'v1' });
    });
    expect(harness.bridge.apiRefresh).not.toHaveBeenCalled();
  });

  it('详情页用 route.villageId，而不是 snapshot.selectedVillageId', async () => {
    const harness = createOfficialBridge();
    render(
      <AppShell
        session={readySession({ selectedVillageId: 'v1' })}
        overview={overviewApi()}
        detail={detailApi(applyVillageDetailSuccess(villageDetailFixture({ villageId: 'v2' })))}
        officialBridge={harness.bridge}
        route={{ kind: 'villageDetail', villageId: 'v2', base: 'home' }}
      />,
    );
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledWith({ villageId: 'v2' });
    });
    expect(harness.bridge.playerState).not.toHaveBeenCalledWith({ villageId: 'v1' });
  });

  it('overview 不挂 Official query，也不订阅秒级 clock', () => {
    vi.useFakeTimers();
    resetClockStoreForTests(1000);
    const harness = createOfficialBridge();
    render(
      <AppShell
        session={readySession()}
        overview={overviewApi()}
        detail={detailApi()}
        officialBridge={harness.bridge}
        route={{ kind: 'overview' }}
      />,
    );
    expect(harness.bridge.playerState).not.toHaveBeenCalled();
    vi.advanceTimersByTime(3000);
    expect(clockStore.getSnapshot()).toBe(1000);
  });

  it('详情页玩家查询未完成时不显示不在部落中', async () => {
    const harness = createOfficialBridge();
    render(
      <AppShell
        session={readySession()}
        overview={overviewApi()}
        detail={detailApi(applyVillageDetailSuccess(villageDetailFixture()))}
        officialBridge={harness.bridge}
        route={{ kind: 'villageDetail', villageId: 'v1', base: 'home' }}
      />,
    );
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalled();
    });
    expect(screen.queryByText('该玩家当前不在部落中')).toBeNull();
    expect(screen.getAllByText('尚未确认部落归属').length).toBeGreaterThan(0);
  });

  it('详情页玩家确认无部落时显示不在部落中', async () => {
    const harness = createOfficialBridge();
    render(
      <AppShell
        session={readySession()}
        overview={overviewApi()}
        detail={detailApi(applyVillageDetailSuccess(villageDetailFixture()))}
        officialBridge={harness.bridge}
        route={{ kind: 'villageDetail', villageId: 'v1', base: 'home' }}
      />,
    );
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalled();
    });
    act(() => {
      harness.resolvePlayer(
        ok(
          playerFixture({
            currentClanTag: null,
            summary: {
              name: 'Hero',
              tag: '#AAA',
              townHallLevel: 16,
              builderHallLevel: 10,
              expLevel: 200,
              trophies: 5000,
              bestTrophies: 5200,
              clanName: null,
              clanTag: null,
            },
          }),
        ),
      );
    });
    await waitFor(() => {
      expect(screen.getAllByText('该玩家当前不在部落中').length).toBeGreaterThan(0);
    });
  });

  it('详情页 War Log never 状态不显示没有历史记录', async () => {
    const harness = createOfficialBridge();
    render(
      <AppShell
        session={readySession()}
        overview={overviewApi()}
        detail={detailApi(applyVillageDetailSuccess(villageDetailFixture()))}
        officialBridge={harness.bridge}
        route={{ kind: 'villageDetail', villageId: 'v1', base: 'home' }}
      />,
    );
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalled();
    });
    act(() => {
      harness.resolvePlayer(ok(playerFixture({ generation: 1 })));
    });
    await waitFor(() => {
      expect(harness.bridge.clanState).toHaveBeenCalled();
    });
    await waitFor(() => {
      expect(screen.getByText('尚未获取部落对战日志')).toBeTruthy();
    });
    expect(screen.queryByText('没有历史部落对战记录')).toBeNull();
  });

  it('pending refresh 时切走 Official 页会 cancel', async () => {
    const harness = createOfficialBridge();
    function Shell() {
      const [route, setRoute] = useState<AppRoute>({ kind: 'import' });
      return (
        <AppShell
          session={readySession()}
          overview={overviewApi()}
          detail={detailApi()}
          officialBridge={harness.bridge}
          route={route}
          onRouteChange={setRoute}
        />
      );
    }
    render(<Shell />);
    await waitFor(() => {
      expect(harness.bridge.playerState).toHaveBeenCalledTimes(1);
    });
    act(() => {
      harness.resolvePlayer(ok(playerFixture({ generation: 1 })));
    });
    await waitFor(() => {
      expect(screen.getByText('刷新官方数据')).toBeTruthy();
    });
    fireEvent.click(screen.getByText('刷新官方数据'));
    await waitFor(() => {
      expect(harness.refreshPending()).toBe(1);
    });
    const requestId = vi.mocked(harness.bridge.apiRefresh).mock.calls[0]?.[0]?.requestId;
    fireEvent.click(screen.getByRole('button', { name: '升级追踪' }));
    expect(harness.bridge.cancel).toHaveBeenCalledWith({ requestId });
  });
});
