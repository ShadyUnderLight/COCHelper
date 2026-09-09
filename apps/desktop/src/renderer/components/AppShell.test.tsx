/** @vitest-environment jsdom */

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';

import type { AppSnapshotPayload } from '@coc-helper/contracts';

import { AppShell } from './AppShell';
import { INITIAL_APP_SESSION, type AppSessionState } from '../app-session';
import { INITIAL_OVERVIEW_STATE, applyOverviewSuccess, recordFixture } from '../overview-session';
import {
  INITIAL_VILLAGE_DETAIL_STATE,
  applyVillageDetailSuccess,
  villageDetailFixture,
  type VillageDetailState,
} from '../village-detail-session';
import type { AppSessionApi } from '../use-app-session';
import type { OverviewApi } from '../use-upgrade-overview';
import type { VillageDetailApi } from '../use-village-detail';

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

function detailProps(): { readonly detailBase: 'home'; readonly onDetailBaseChange: () => void } {
  return { detailBase: 'home' as const, onDetailBaseChange: () => undefined };
}

afterEach(() => {
  cleanup();
});

describe('AppShell', () => {
  it('booting 显示加载文案', () => {
    render(
      <AppShell
        session={sessionApi(INITIAL_APP_SESSION)}
        overview={overviewApi()}
        detail={detailApi()}
        detailBase="home"
        onDetailBaseChange={() => undefined}
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
        detailBase="home"
        onDetailBaseChange={() => undefined}
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
        detailBase="home"
        onDetailBaseChange={() => undefined}
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
        detailBase="home"
        onDetailBaseChange={() => undefined}
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
        detailBase="home"
        onDetailBaseChange={() => undefined}
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
        detail={detailApi()}
        detailBase="home"
        onDetailBaseChange={() => undefined}
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
        detail={detailApi()}
        detailBase="home"
        onDetailBaseChange={() => undefined}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '升级总览' }));
    expect(screen.getByLabelText('升级总览')).toBeTruthy();
    expect(screen.queryByLabelText('账号 JSON')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: '导入' }));
    expect(screen.getByLabelText('账号 JSON')).toBeTruthy();
    expect(screen.queryByLabelText('升级总览')).toBeNull();
  });

  it('无选中村庄时详情 tab 禁用', () => {
    const dp = detailProps();
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot({ selectedVillageId: null }),
        })}
        overview={overviewApi()}
        detail={detailApi()}
        detailBase={dp.detailBase}
        onDetailBaseChange={dp.onDetailBaseChange}
      />,
    );
    const tab = screen.getByRole('button', { name: '村庄详情' });
    expect(tab.hasAttribute('disabled')).toBe(true);
  });

  it('有选中村庄可切详情', () => {
    const dp = detailProps();
    render(
      <AppShell
        session={sessionApi({
          ...INITIAL_APP_SESSION,
          status: 'ready',
          snapshot: snapshot(),
        })}
        overview={overviewApi()}
        detail={detailApi()}
        detailBase={dp.detailBase}
        onDetailBaseChange={dp.onDetailBaseChange}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '村庄详情' }));
    expect(screen.getByLabelText('村庄详情')).toBeTruthy();
  });

  it('总览行点击切到详情', () => {
    const dp = detailProps();
    const overviewState = applyOverviewSuccess({
      generation: 1,
      nowMs: 1,
      catalogVersion: '18.400.13',
      catalogIsUsable: true,
      active: [recordFixture({ id: 'r1' })],
      pending: [],
      state: {
        manualActiveCount: 0,
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
        detailBase={dp.detailBase}
        onDetailBaseChange={dp.onDetailBaseChange}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '升级总览' }));
    fireEvent.click(screen.getByRole('button', { name: /加农炮/ }));
    expect(screen.getByLabelText('村庄详情')).toBeTruthy();
  });

  it('详情 base 切换透传（初始主村按下）', () => {
    const dp = detailProps();
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
        detailBase={dp.detailBase}
        onDetailBaseChange={dp.onDetailBaseChange}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '村庄详情' }));
    const homeTab = screen.getByRole('button', { name: '主村' });
    expect(homeTab.getAttribute('aria-pressed')).toBe('true');
  });
});
