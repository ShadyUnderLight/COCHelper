/** @vitest-environment jsdom */

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import {
  applyOverviewError,
  applyOverviewSuccess,
  recordFixture,
  type OverviewState,
} from '../overview-session';
import { UpgradeOverview } from './UpgradeOverview';

afterEach(() => {
  cleanup();
});

type Props = {
  readonly state: OverviewState;
  readonly selectedId: string | null;
  readonly onSelect: (id: string) => void;
  readonly onRetry: () => void;
};

function propsOf(state: OverviewState): Props {
  return { state, selectedId: null, onSelect: () => undefined, onRetry: () => undefined };
}

function stateShape(
  overrides: Partial<{
    readonly generation: number;
    readonly catalogVersion: string | null;
    readonly catalogIsUsable: boolean;
    readonly active: ReturnType<typeof recordFixture>[];
  }> = {},
) {
  return {
    generation: 1,
    nowMs: 1,
    catalogVersion: '18.400.13' as string | null,
    catalogIsUsable: true,
    active: [] as ReturnType<typeof recordFixture>[],
    pending: [] as ReturnType<typeof recordFixture>[],
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
    ...overrides,
  };
}

describe('UpgradeOverview', () => {
  it('loading 显示加载文案', () => {
    render(<UpgradeOverview {...propsOf({ status: 'loading', payload: null, lastError: null })} />);
    expect(screen.getByText('正在加载升级总览…')).toBeTruthy();
  });

  it('error 无 last-good 显示错误与重试', () => {
    const onRetry = vi.fn();
    render(
      <UpgradeOverview
        {...propsOf({
          status: 'error',
          payload: null,
          lastError: '目录未就绪',
        })}
        onRetry={onRetry}
      />,
    );
    expect(screen.getByRole('alert')).toBeTruthy();
    fireEvent.click(screen.getByText('重试'));
    expect(onRetry).toHaveBeenCalledTimes(1);
  });

  it('空 Overview 显示空态而非错误', () => {
    render(<UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape()))} />);
    expect(screen.getByText('暂无进行中的升级')).toBeTruthy();
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('catalogIsUsable=false 显示不可用横幅且仍列出记录', () => {
    const rec = recordFixture({ id: 'r1' });
    render(
      <UpgradeOverview
        {...propsOf(
          applyOverviewSuccess(
            stateShape({
              generation: 2,
              catalogVersion: null,
              catalogIsUsable: false,
              active: [rec],
            }),
          ),
        )}
      />,
    );
    expect(screen.getByRole('alert').textContent).toMatch(/目录不可用/);
    expect(screen.getByText('加农炮')).toBeTruthy();
  });

  it('failed-with-last-good 显示过期提示且保留旧数据', () => {
    const rec = recordFixture({ id: 'r2' });
    const good = applyOverviewSuccess(stateShape({ active: [rec] }));
    render(<UpgradeOverview {...propsOf(applyOverviewError(good, '查询失败'))} />);
    expect(screen.getByRole('alert').textContent).toMatch(/可能过期/);
    expect(screen.getByText('加农炮')).toBeTruthy();
  });

  it('点击条目触发 onSelect 并携带记录 id', () => {
    const onSelect = vi.fn();
    const rec = recordFixture({ id: 'rec-9' });
    render(
      <UpgradeOverview
        {...propsOf(applyOverviewSuccess(stateShape({ active: [rec] })))}
        onSelect={onSelect}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: /加农炮/ }));
    expect(onSelect).toHaveBeenCalledWith('rec-9');
  });

  it('长中文名称完整渲染（换行由 CSS 承担）', () => {
    const longName = '超级无敌加农炮之究极进化完全体形态最终决战兵器加长加长加长版名称测试';
    const rec = recordFixture({
      id: 'r-long',
      item: { ...recordFixture().item, name: longName },
    });
    const { container } = render(
      <UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape({ active: [rec] })))} />,
    );
    expect(screen.getByText(longName)).toBeTruthy();
    expect(container.querySelector('.overview-item-name')).toBeTruthy();
  });
});
