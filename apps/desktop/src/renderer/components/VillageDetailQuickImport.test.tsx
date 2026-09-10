/** @vitest-environment jsdom */

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { QuickPreparePreviewWire } from '@coc-helper/contracts';

import type { QuickImportApi, QuickImportState } from '../use-quick-import';
import { applyVillageDetailSuccess, villageDetailFixture } from '../village-detail-session';
import { VillageDetail } from './VillageDetail';

afterEach(() => {
  cleanup();
});

function quickState(overrides: Partial<QuickImportState> = {}): QuickImportState {
  return {
    status: 'idle',
    targetVillageId: null,
    preview: null,
    preparedGeneration: null,
    stale: false,
    lastError: null,
    ...overrides,
  };
}

function quickApi(state: QuickImportState, open = vi.fn()): QuickImportApi {
  return {
    state,
    open,
    confirm: async () => true,
    cancel: async () => undefined,
    retry: async () => undefined,
    close: () => undefined,
  };
}

function preview(): QuickPreparePreviewWire {
  return {
    snapshot: {
      tag: '#QA',
      unknownTopLevelKeys: [],
      diagnostics: [],
    },
    targetVillageId: 'v-detail',
    targetVillageName: 'Detail',
    targetVillageTag: '#QA',
    targetVillageHasSnapshot: true,
    replacesSameTag: true,
    destinationDescription: '导入目标：按当前详情页更新「Detail」',
  };
}

describe('VillageDetail quick import entry', () => {
  it('无 quick 时不渲染入口（旧嵌入兼容）', () => {
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(villageDetailFixture())}
        base="home"
        onBaseChange={() => undefined}
        onRetry={() => undefined}
      />,
    );
    expect(screen.queryByRole('button', { name: '粘贴并更新' })).toBeNull();
  });

  it('点击“粘贴并更新”以详情页村庄为固定目标打开', () => {
    const open = vi.fn();
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(villageDetailFixture({ villageId: 'v-detail' }))}
        base="home"
        onBaseChange={() => undefined}
        onRetry={() => undefined}
        quick={quickApi(quickState(), open)}
        canQuick
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: '粘贴并更新' }));
    expect(open).toHaveBeenCalledTimes(1);
    expect(open).toHaveBeenCalledWith('v-detail');
  });

  it('只读时按钮禁用', () => {
    const open = vi.fn();
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(villageDetailFixture({ villageId: 'v-detail' }))}
        base="home"
        onBaseChange={() => undefined}
        onRetry={() => undefined}
        quick={quickApi(quickState(), open)}
        canQuick={false}
      />,
    );
    expect((screen.getByRole('button', { name: '粘贴并更新' }) as HTMLButtonElement).disabled).toBe(
      true,
    );
    fireEvent.click(screen.getByRole('button', { name: '粘贴并更新' }));
    expect(open).not.toHaveBeenCalled();
  });

  it('ready 时展示确认 Sheet', () => {
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(villageDetailFixture({ villageId: 'v-detail' }))}
        base="home"
        onBaseChange={() => undefined}
        onRetry={() => undefined}
        quick={quickApi(
          quickState({
            status: 'ready',
            targetVillageId: 'v-detail',
            preview: preview(),
            preparedGeneration: 8,
          }),
        )}
        canQuick
      />,
    );
    expect(screen.getByRole('dialog', { name: '快捷导入' })).toBeTruthy();
    expect(screen.getByRole('button', { name: '确认导入' })).toBeTruthy();
  });

  it('idle 无错误时不展示 Sheet', () => {
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(villageDetailFixture({ villageId: 'v-detail' }))}
        base="home"
        onBaseChange={() => undefined}
        onRetry={() => undefined}
        quick={quickApi(quickState())}
        canQuick
      />,
    );
    expect(screen.queryByRole('dialog', { name: '快捷导入' })).toBeNull();
  });
});
