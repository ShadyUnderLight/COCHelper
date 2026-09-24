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
    expect(screen.getByText('正在整理营地数据…')).toBeTruthy();
    expect(screen.getByLabelText('升级总览').getAttribute('data-perf-state')).toBe('loading');
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
    expect(screen.getByLabelText('升级总览').getAttribute('data-perf-state')).toBe('error');
    fireEvent.click(screen.getByText('重试'));
    expect(onRetry).toHaveBeenCalledTimes(1);
  });

  it('空 Overview 显示空态而非错误', () => {
    render(<UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape()))} />);
    expect(screen.getByText('暂无进行中的升级')).toBeTruthy();
    expect(
      screen.getByText('导入游戏账号数据后，正在进行与待安排的升级会汇集在这里。'),
    ).toBeTruthy();
    expect(screen.queryByRole('alert')).toBeNull();
    expect(screen.getByLabelText('升级总览').getAttribute('data-perf-state')).toBe('ready');
  });

  it('只有近期窗口外的手动完成记录时显示无待处理文案', () => {
    const payload = stateShape();
    payload.state.manualCompletedCount = 3;
    render(<UpgradeOverview {...propsOf(applyOverviewSuccess(payload))} />);
    expect(screen.getByText('当前没有进行中或待处理的升级，已记录 3 项手动完成。')).toBeTruthy();
    expect(
      screen.queryByText('导入游戏账号数据后，正在进行与待安排的升级会汇集在这里。'),
    ).toBeNull();
  });

  it('列表使用 effective 等级和权威状态，不并列展示 raw 状态', () => {
    const base = recordFixture();
    const rec = recordFixture({
      id: 'r-effective',
      item: {
        ...base.item,
        currentLevel: 5,
        nextLevel: 6,
        status: 'complete',
        effectiveStatus: 'manualCompleted',
        effectiveCurrentLevel: 6,
        effectiveTargetLevel: 7,
        effectiveNextUpgrade: { kind: 'available', level: 7, durationSeconds: 7200 },
        effectiveNextLevelDurationState: { kind: 'timed', seconds: 7200 },
        effectiveIsMaxed: false,
      },
    });
    render(<UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape({ active: [rec] })))} />);
    const row = screen.getByRole('button', { name: /加农炮/ });
    expect(row.textContent).toContain('6 → 7 级');
    expect(row.textContent).toContain('已记录');
    expect(row.textContent).not.toContain('5 → 6 级');
    expect(row.textContent).not.toContain('已完成');
  });

  it('升级记录行保持四个内容节点，将箭头作为 CSS 装饰绘制', () => {
    const rec = recordFixture({ id: 'r-flat-row' });
    render(<UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape({ active: [rec] })))} />);
    const row = screen.getByRole('button', { name: /加农炮/ });
    expect(row.children).toHaveLength(4);
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

  it('有图标时行内渲染 36px 图标且 src 正确（#277-C2）', () => {
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
    expect(img?.getAttribute('width')).toBe('36');
    expect(img?.getAttribute('height')).toBe('36');
  });

  it('图标全空时显示分类 glyph 而非消失（#277-C2 review）', () => {
    const rec = recordFixture({ id: 'r-noicon' });
    const { container } = render(
      <UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape({ active: [rec] })))} />,
    );
    expect(container.querySelector('img.overview-item-icon')).toBeNull();
    expect(container.querySelector('.overview-item-glyph')?.textContent).toBe('防');
  });

  it('图标加载失败且无候选时显示分类 glyph（#277-C2 review）', () => {
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
    expect(container.querySelector('.overview-item-glyph')?.textContent).toBe('防');
  });

  it('effective 等级变化时不使用 raw current-level 图标', () => {
    const rec = recordFixture({
      id: 'r-effective-asset',
      item: {
        ...recordFixture().item,
        currentLevel: 5,
        effectiveCurrentLevel: 6,
        currentLevelVisual: {
          container: 'sc',
          exportName: 'cannon_lvl5',
          renderedPath: 'icons/buildings/cannon_lvl5.png',
          missingReason: null,
        },
        levelVisual: {
          container: 'sc',
          exportName: 'cannon',
          renderedPath: 'icons/buildings/cannon.png',
          missingReason: null,
        },
      },
    });
    const { container } = render(
      <UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape({ active: [rec] })))} />,
    );
    expect(container.querySelector('img.overview-item-icon')?.getAttribute('src')).toBe(
      'cochelper://catalog/18.400.13/icons/buildings/cannon.png',
    );
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
