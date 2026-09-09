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

  it('点击条目同时触发 onOpenDetail 并携带记录 id 与村庄 id', () => {
    const onOpenDetail = vi.fn();
    const rec = recordFixture({ id: 'rec-open', villageID: 'vB', villageName: '分村' });
    render(
      <UpgradeOverview
        {...propsOf(applyOverviewSuccess(stateShape({ active: [rec] })))}
        onOpenDetail={onOpenDetail}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: /加农炮/ }));
    expect(onOpenDetail).toHaveBeenCalledWith('rec-open', 'vB');
  });

  it('有图标时行内渲染 28px 图标且 src 正确（#277-C2）', () => {
    const rec = recordFixture({
      id: 'r-icon',
      item: {
        ...recordFixture().item,
        icon: {
          container: 'sc',
          exportName: 'x',
          renderedPath: 'icons/ui/icon_x.png',
          missingReason: null,
        },
      },
    });
    const { container } = render(
      <UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape({ active: [rec] })))} />,
    );
    const img = container.querySelector('img.overview-item-icon') as HTMLImageElement | null;
    expect(img?.getAttribute('src')).toBe('cochelper://catalog/18.400.13/icons/ui/icon_x.png');
    expect(img?.getAttribute('width')).toBe('28');
    expect(img?.getAttribute('height')).toBe('28');
  });

  it('图标全空时行内无 img（#277-C2）', () => {
    const rec = recordFixture({ id: 'r-noicon' });
    const { container } = render(
      <UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape({ active: [rec] })))} />,
    );
    expect(container.querySelector('img.overview-item-icon')).toBeNull();
  });

  it('图标加载失败后隐藏 img（#277-C2）', () => {
    const rec = recordFixture({
      id: 'r-icon-err',
      item: {
        ...recordFixture().item,
        icon: {
          container: 'sc',
          exportName: 'x',
          renderedPath: 'icons/ui/icon_x.png',
          missingReason: null,
        },
      },
    });
    const { container } = render(
      <UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape({ active: [rec] })))} />,
    );
    const img = container.querySelector('img.overview-item-icon') as HTMLImageElement | null;
    expect(img).not.toBeNull();
    fireEvent.error(img!);
    expect(container.querySelector('img.overview-item-icon')).toBeNull();
  });

  it('双候选首个失败回退到第二个（#277-C2 review 候选链）', () => {
    const rec = recordFixture({
      id: 'r-icon-fallback',
      item: {
        ...recordFixture().item,
        currentLevelVisual: {
          container: 'sc',
          exportName: 'a',
          renderedPath: 'icons/a.png',
          missingReason: null,
        },
        currentLevelIcon: null,
        levelVisual: null,
        icon: {
          container: 'sc',
          exportName: 'b',
          renderedPath: 'icons/b.png',
          missingReason: null,
        },
      },
    });
    const { container } = render(
      <UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape({ active: [rec] })))} />,
    );
    const first = container.querySelector('img.overview-item-icon') as HTMLImageElement | null;
    expect(first?.getAttribute('src')).toBe('cochelper://catalog/18.400.13/icons/a.png');
    fireEvent.error(first!);
    expect(container.querySelector('img.overview-item-icon')?.getAttribute('src')).toBe(
      'cochelper://catalog/18.400.13/icons/b.png',
    );
  });
});
