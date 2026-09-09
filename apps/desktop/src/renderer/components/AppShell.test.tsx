/** @vitest-environment jsdom */

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';

import type { AppSnapshotPayload } from '@coc-helper/contracts';

import { AppShell } from './AppShell';
import { INITIAL_APP_SESSION, type AppSessionState } from '../app-session';
import { INITIAL_OVERVIEW_STATE } from '../overview-session';
import type { AppSessionApi } from '../use-app-session';
import type { OverviewApi } from '../use-upgrade-overview';

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
    selectVillage: async () => undefined,
    prepareImport: async () => undefined,
    commitImport: async () => undefined,
    discardImport: async () => undefined,
    refreshRecovery: async () => undefined,
    recoveryReset: async () => undefined,
    recoveryRestoreSaved: async () => undefined,
    recoveryRecoverJournal: async () => undefined,
  };
}

function overviewApi(): OverviewApi {
  return {
    state: INITIAL_OVERVIEW_STATE,
    selectedId: null,
    select: () => undefined,
    refresh: async () => undefined,
  };
}

afterEach(() => {
  cleanup();
});

describe('AppShell', () => {
  it('booting 显示加载文案', () => {
    render(<AppShell session={sessionApi(INITIAL_APP_SESSION)} overview={overviewApi()} />);
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
      />,
    );
    expect(screen.getByLabelText('数据恢复')).toBeTruthy();
    expect(screen.queryByLabelText('账号导入')).toBeNull();
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
      />,
    );
    expect(screen.getByText(/只读模式/)).toBeTruthy();
  });

  it('总览 tab 切换显示升级总览', () => {
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot(),
        })}
        overview={overviewApi()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '升级总览' }));
    expect(screen.getByLabelText('升级总览')).toBeTruthy();
    expect(screen.queryByLabelText('账号 JSON')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: '导入' }));
    expect(screen.getByLabelText('账号 JSON')).toBeTruthy();
    expect(screen.queryByLabelText('升级总览')).toBeNull();
  });
});
