/** @vitest-environment jsdom */

import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type {
  UpgradeOverviewManualActiveRecordDto,
  UpgradeRecentCompletionDto,
  VillageSummaryDto,
} from '@coc-helper/contracts';

import {
  applyOverviewError,
  applyOverviewSuccess,
  recordFixture,
  type OverviewState,
} from '../overview-session';
import { advanceClockStoreForTests, resetClockStoreForTests } from '../clock-store';
import { UpgradeOverview } from './UpgradeOverview';

afterEach(() => {
  cleanup();
  resetClockStoreForTests();
  vi.useRealTimers();
});

type Props = {
  readonly state: OverviewState;
  readonly selectedId: string | null;
  readonly villages: readonly VillageSummaryDto[];
  readonly onSelect: (id: string) => void;
  readonly onRetry: () => void;
};

function propsOf(state: OverviewState): Props {
  return {
    state,
    selectedId: null,
    villages: [],
    onSelect: () => undefined,
    onRetry: () => undefined,
  };
}

function stateShape(
  overrides: Partial<{
    readonly generation: number;
    readonly catalogVersion: string | null;
    readonly catalogIsUsable: boolean;
    readonly active: ReturnType<typeof recordFixture>[];
    readonly completedRecently: UpgradeRecentCompletionDto[];
    readonly manualActiveRecords: UpgradeOverviewManualActiveRecordDto[];
  }> = {},
) {
  const { completedRecently = [], manualActiveRecords = [], ...payloadOverrides } = overrides;
  return {
    generation: 1,
    nowMs: 1,
    catalogVersion: '18.400.13' as string | null,
    catalogIsUsable: true,
    active: [] as ReturnType<typeof recordFixture>[],
    pending: [] as ReturnType<typeof recordFixture>[],
    state: {
      manualActiveCount: 0,
      manualActiveRecords,
      importedActiveCount: 0,
      deduplicatedDisplayCount: 0,
      manualCompletedCount: 0,
      completedRecently,
      activeRecords: [],
      attentionRecords: [],
      needsReimportRecords: [],
    },
    ...payloadOverrides,
  };
}

describe('UpgradeOverview', () => {
  it('loading 显示加载文案', () => {
    render(<UpgradeOverview {...propsOf({ status: 'loading', payload: null, lastError: null })} />);
    expect(screen.getByText('正在整理营地数据…')).toBeTruthy();
    expect(screen.getByLabelText('升级追踪').getAttribute('data-perf-state')).toBe('loading');
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
    expect(screen.getByLabelText('升级追踪').getAttribute('data-perf-state')).toBe('error');
    fireEvent.click(screen.getByText('重试'));
    expect(onRetry).toHaveBeenCalledTimes(1);
  });

  it('空 Overview 显示空态而非错误', () => {
    render(<UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape()))} />);
    expect(screen.getByText('暂无进行中的升级')).toBeTruthy();
    expect(
      screen.getByText('导入游戏账号后，这里会汇总所有村庄正在进行和待安排的升级。'),
    ).toBeTruthy();
    expect(screen.queryByRole('alert')).toBeNull();
    expect(screen.getByLabelText('升级追踪').getAttribute('data-perf-state')).toBe('ready');
  });

  it('只有近期窗口外的手动完成记录时显示无待处理文案', () => {
    const payload = stateShape();
    payload.state.manualCompletedCount = 3;
    render(<UpgradeOverview {...propsOf(applyOverviewSuccess(payload))} />);
    expect(screen.getByText('当前没有进行中或待处理的升级，已记录 3 项手动完成。')).toBeTruthy();
    expect(
      screen.queryByText('导入游戏账号后，这里会汇总所有村庄正在进行和待安排的升级。'),
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

  it('跨村庄升级记录显示村庄标签以区分账号', () => {
    const record = recordFixture({
      id: 'r-tagged',
      villageName: '分村',
      villageTag: '#BBB',
    });
    render(
      <UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape({ active: [record] })))} />,
    );
    expect(screen.getByRole('button', { name: /加农炮/ }).textContent).toContain('分村（#BBB）');
  });

  it('正在升级的记录显示会随显示时钟递减的剩余时间', () => {
    resetClockStoreForTests(1);
    const record = recordFixture({
      id: 'r-timer',
      effectiveRemainingSeconds: 3_600,
      item: {
        ...recordFixture().item,
        timerSeconds: 7_200,
        remainingSeconds: null,
      },
    });
    render(
      <UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape({ active: [record] })))} />,
    );
    const row = screen.getByRole('button', { name: /加农炮/ });
    expect(row.textContent).toContain('剩余 1小时 0分钟');

    act(() => advanceClockStoreForTests(60_000));

    expect(row.textContent).toContain('剩余 59分钟');
  });

  it('计时归零后将记录移入待处理状态并停止时钟订阅', () => {
    vi.useFakeTimers();
    vi.setSystemTime(1);
    resetClockStoreForTests(1);

    const baseItem = recordFixture().item;
    const manualTimerRecord = recordFixture({
      id: 'manual-timer-due',
      effectiveRemainingSeconds: 2,
      item: {
        ...baseItem,
        timerSeconds: 2,
        remainingSeconds: null,
        effectiveStatus: 'manualActive',
      },
    });
    const manualIdleRecord = recordFixture({
      id: 'manual-idle-due',
      effectiveRemainingSeconds: 2,
      item: {
        ...baseItem,
        timerSeconds: null,
        remainingSeconds: null,
        effectiveStatus: 'manualActive',
      },
    });
    const importedRecord = recordFixture({
      id: 'imported-due',
      villageID: 'v2',
      effectiveRemainingSeconds: 2,
      item: {
        ...baseItem,
        timerSeconds: 2,
        remainingSeconds: 2,
        effectiveStatus: 'importedActive',
      },
    });
    const payload = stateShape({
      active: [manualTimerRecord, manualIdleRecord, importedRecord],
      manualActiveRecords: [
        {
          villageID: 'v1',
          recordID: '00000000-0000-0000-0000-000000000001',
          itemKey: baseItem.trackerItemKey,
          expectedEndAtMs: 2_001,
        },
      ],
    });
    payload.state.manualActiveCount = 1;
    payload.state.importedActiveCount = 1;

    render(<UpgradeOverview {...propsOf(applyOverviewSuccess(payload))} />);
    expect(vi.getTimerCount()).toBe(1);

    act(() => {
      vi.advanceTimersByTime(2_000);
    });

    const activeCount = screen
      .getByLabelText('升级记录概况')
      .querySelector('.stat-card.active .stat-value');
    expect(activeCount?.textContent).toContain('0');
    expect(screen.getByText('手动进行中 0')).toBeTruthy();
    expect(screen.getByText('手动待结算 1')).toBeTruthy();
    const settlementList = screen.getByLabelText('待结算');
    expect(settlementList.querySelectorAll('button')).toHaveLength(1);
    expect(settlementList.querySelector('.record-badge')?.textContent).toBe('1');
    expect(settlementList.querySelector('button')?.textContent).toContain('待结算');
    expect(screen.getByLabelText('待重新导入').querySelector('button')?.textContent).toContain(
      '待重新导入确认',
    );
    expect(screen.queryByText(/正在升级/)).toBeNull();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('同 tracker key 的并行手动记录按底层记录数计数并合并展示行', () => {
    vi.useFakeTimers();
    vi.setSystemTime(1);
    resetClockStoreForTests(1);

    const item = recordFixture().item;
    const record = recordFixture({
      id: 'manual-parallel',
      effectiveRemainingSeconds: null,
      item: {
        ...item,
        timerSeconds: null,
        remainingSeconds: null,
        effectiveStatus: 'manualActive',
      },
    });
    const payload = stateShape({
      active: [record],
      manualActiveRecords: [
        {
          villageID: 'v1',
          recordID: '00000000-0000-0000-0000-000000000001',
          itemKey: item.trackerItemKey,
          expectedEndAtMs: 1_001,
        },
        {
          villageID: 'v1',
          recordID: '00000000-0000-0000-0000-000000000002',
          itemKey: item.trackerItemKey,
          expectedEndAtMs: 2_001,
        },
      ],
    });
    payload.state.manualActiveCount = 2;

    render(<UpgradeOverview {...propsOf(applyOverviewSuccess(payload))} />);
    act(() => {
      vi.advanceTimersByTime(2_000);
    });

    const settlementList = screen.getByLabelText('待结算');
    expect(settlementList.querySelectorAll('button')).toHaveLength(1);
    expect(settlementList.querySelector('.record-badge')?.textContent).toBe('2');
    expect(settlementList.querySelector('button')?.textContent).toContain('待结算 2 条');
    expect(screen.getByText('手动进行中 0')).toBeTruthy();
    expect(screen.getByText('手动待结算 2')).toBeTruthy();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('近期完成记录显示所属村庄和标签', () => {
    const completion: UpgradeRecentCompletionDto = {
      id: 'completed-cannon',
      villageID: 'v2',
      itemKey: recordFixture().item.trackerItemKey,
      itemName: '加农炮',
      targetLevel: 6,
      quantity: 1,
      completedAtMs: Date.UTC(2026, 8, 23),
    };
    const villages: VillageSummaryDto[] = [
      { id: 'v2', name: '分村', tag: '#BBB', hasImportedData: true },
    ];
    const props = propsOf(applyOverviewSuccess(stateShape({ completedRecently: [completion] })));
    render(<UpgradeOverview {...props} villages={villages} />);
    expect(screen.getByLabelText('近期完成').textContent).toContain('分村（#BBB）');
  });

  it('升级记录行保持四个元素的完整子树，将箭头作为 CSS 装饰绘制', () => {
    const rec = recordFixture({ id: 'r-flat-row' });
    render(<UpgradeOverview {...propsOf(applyOverviewSuccess(stateShape({ active: [rec] })))} />);
    const row = screen.getByRole('button', { name: /加农炮/ });
    expect(row.querySelectorAll('*')).toHaveLength(4);
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
