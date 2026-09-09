/** @vitest-environment jsdom */

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
  BuildingGroupDto,
  VillageCategoryCompletionDto,
  VillageDetailFlatRowDto,
  VillageDetailGroupDto,
} from '@coc-helper/contracts';

import { recordFixture } from '../overview-session';
import {
  applyVillageDetailSuccess,
  idleVillageDetailState,
  villageDetailFixture,
} from '../village-detail-session';
import { VillageDetail } from './VillageDetail';

afterEach(() => {
  cleanup();
});

function baseProps() {
  return {
    base: 'home' as const,
    onBaseChange: () => undefined,
    onRetry: () => undefined,
  };
}

describe('VillageDetail', () => {
  it('idle 显示选择提示', () => {
    render(<VillageDetail state={idleVillageDetailState()} {...baseProps()} />);
    expect(screen.getByText('先选择村庄查看详情')).toBeTruthy();
  });

  it('loading 显示加载文案', () => {
    render(
      <VillageDetail
        state={{ status: 'loading', payload: null, lastError: null }}
        {...baseProps()}
      />,
    );
    expect(screen.getByText('正在加载村庄详情…')).toBeTruthy();
  });

  it('error 无 last-good 显示错误与重试', () => {
    const onRetry = vi.fn();
    render(
      <VillageDetail
        state={{ status: 'error', payload: null, lastError: '加载失败' }}
        {...baseProps()}
        onRetry={onRetry}
      />,
    );
    expect(screen.getByRole('alert').textContent).toMatch(/加载失败/);
    fireEvent.click(screen.getByText('重试'));
    expect(onRetry).toHaveBeenCalledTimes(1);
  });

  it('空详情显示空态而非告警', () => {
    render(
      <VillageDetail state={applyVillageDetailSuccess(villageDetailFixture())} {...baseProps()} />,
    );
    expect(screen.getByText('该村庄暂无详情数据')).toBeTruthy();
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('sectionHeader 渲染分组标题与统计行', () => {
    const group: VillageDetailGroupDto = {
      id: 'g-def',
      category: 'buildings',
      displayCategory: 'defense',
      itemIds: [],
    };
    const stats: VillageCategoryCompletionDto = {
      id: 'g-def',
      category: 'buildings',
      displayCategory: 'defense',
      knownCount: 3,
      completedCount: 1,
      unknownCount: 2,
      saturated: false,
      completionRatio: 0.5,
      isFullyMaxed: false,
    };
    const flatRows: readonly VillageDetailFlatRowDto[] = [
      { kind: 'sectionHeader', groupID: 'g-def', stats },
    ];
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(
          villageDetailFixture({ groups: [group], completion: [stats], flatRows }),
        )}
        {...baseProps()}
      />,
    );
    expect(screen.getByText('防御建筑')).toBeTruthy();
    expect(screen.getByText(/已知 3 · 完成 1 · 未知 2/)).toBeTruthy();
    expect(screen.getByText(/50%/)).toBeTruthy();
  });

  it('instance 行渲染分组摘要，点击可解析实例打开等级底片，Esc 关闭', () => {
    const buildingGroup: BuildingGroupDto = {
      id: 'bg1',
      base: 'home',
      section: 'buildings',
      dataID: 1000010,
      name: '城墙',
      category: 'buildings',
      displayCategory: 'walls',
      instanceIds: ['inst-1'],
      summary: {
        instanceCount: 5,
        remainingLevelCount: 2,
        totalDurationSeconds: 7200,
        costByResource: [{ resource: '金币', totalCost: 1000 }],
        saturated: false,
        completeness: 'partialMissing',
      },
      trackerStatus: 'observed',
    };
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(
          villageDetailFixture({
            items: [{ ...recordFixture().item, id: 'inst-1', name: '城墙实例' }],
            buildingGroups: [buildingGroup],
            flatRows: [
              { kind: 'instance', groupID: 'bg1', instanceID: 'inst-1', leadingDivider: true },
            ],
          }),
        )}
        {...baseProps()}
      />,
    );
    expect(screen.getByText('城墙')).toBeTruthy();
    expect(screen.getByText(/5 实例/)).toBeTruthy();
    expect(screen.getByText(/金币 1000/)).toBeTruthy();
    expect(screen.getByText(/部分缺失/)).toBeTruthy();
    expect(screen.getByText(/已同步/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /城墙/ }));
    expect(screen.getByRole('dialog', { name: '城墙实例等级详情' })).toBeTruthy();
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('instance 行 id 无法解析时点击不打开底片', () => {
    const buildingGroup: BuildingGroupDto = {
      id: 'bg1',
      base: 'home',
      section: 'buildings',
      dataID: 1000010,
      name: '城墙',
      category: 'buildings',
      displayCategory: 'walls',
      instanceIds: ['inst-unknown'],
      summary: {
        instanceCount: 5,
        remainingLevelCount: 2,
        totalDurationSeconds: 7200,
        costByResource: [],
        saturated: false,
        completeness: 'complete',
      },
      trackerStatus: 'observed',
    };
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(
          villageDetailFixture({
            buildingGroups: [buildingGroup],
            flatRows: [
              {
                kind: 'instance',
                groupID: 'bg1',
                instanceID: 'inst-unknown',
                leadingDivider: false,
              },
            ],
          }),
        )}
        {...baseProps()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: /城墙/ }));
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('instance 行 id 带 # 后缀时剥离后解析打开底片', () => {
    const buildingGroup: BuildingGroupDto = {
      id: 'bg1',
      base: 'home',
      section: 'buildings',
      dataID: 1000010,
      name: '城墙',
      category: 'buildings',
      displayCategory: 'walls',
      instanceIds: ['inst-9#7'],
      summary: {
        instanceCount: 5,
        remainingLevelCount: 2,
        totalDurationSeconds: 7200,
        costByResource: [],
        saturated: false,
        completeness: 'complete',
      },
      trackerStatus: 'observed',
    };
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(
          villageDetailFixture({
            items: [{ ...recordFixture().item, id: 'inst-9', name: '城墙实例' }],
            buildingGroups: [buildingGroup],
            flatRows: [
              {
                kind: 'instance',
                groupID: 'bg1',
                instanceID: 'inst-9#7',
                leadingDivider: false,
              },
            ],
          }),
        )}
        {...baseProps()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: /城墙/ }));
    expect(screen.getByRole('dialog', { name: '城墙实例等级详情' })).toBeTruthy();
  });

  it('legacy 行渲染条目与等级跃迁，点击打开等级底片', () => {
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(
          villageDetailFixture({
            items: [recordFixture().item],
            flatRows: [
              {
                kind: 'legacy',
                itemID: 'item-1',
                groupID: 'g',
                indented: true,
                leadingDivider: false,
              },
            ],
          }),
        )}
        {...baseProps()}
      />,
    );
    expect(screen.getByText('加农炮')).toBeTruthy();
    expect(screen.getByText(/5 → 6 级/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /加农炮/ }));
    expect(screen.getByRole('dialog', { name: '加农炮等级详情' })).toBeTruthy();
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('缺失 legacy 条目显示未知条目且无详情按钮（不崩溃）', () => {
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(
          villageDetailFixture({
            flatRows: [
              {
                kind: 'legacy',
                itemID: 'nope',
                groupID: 'g',
                indented: false,
                leadingDivider: false,
              },
            ],
          }),
        )}
        {...baseProps()}
      />,
    );
    expect(screen.getByText(/未知条目/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: /打开等级详情/ })).toBeNull();
  });

  it('mismatch 显示目录版本不一致告警', () => {
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(
          villageDetailFixture({
            compatibility: {
              kind: 'mismatch',
              catalogVersion: '18.400.12',
              expectedVersion: '18.400.13',
            },
          }),
        )}
        {...baseProps()}
      />,
    );
    expect(screen.getByRole('alert').textContent).toMatch(/目录版本不一致/);
  });

  it('unavailable 显示游戏目录不可用告警', () => {
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(
          villageDetailFixture({ compatibility: { kind: 'unavailable' } }),
        )}
        {...baseProps()}
      />,
    );
    expect(screen.getByRole('alert').textContent).toMatch(/游戏目录不可用/);
  });

  it('unverified 版本行包含未验证', () => {
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(
          villageDetailFixture({ compatibility: { kind: 'unverified', gameVersion: '18.400.13' } }),
        )}
        {...baseProps()}
      />,
    );
    expect(screen.getByText(/未验证/)).toBeTruthy();
  });

  it('指标降级原因与部分状态可见', () => {
    const metric = {
      kind: 'test',
      numerator: 1,
      denominator: 2,
      state: 'partial' as const,
      saturated: false,
      units: 'items',
      degradedReason: '缺口径',
      ratio: 0.5,
    };
    const { container } = render(
      <VillageDetail
        state={applyVillageDetailSuccess(
          villageDetailFixture({
            metrics: {
              currentStageProgress: metric,
              globalProgress: metric,
              snapshotCoverage: metric,
              instanceProgress: metric,
              effectiveTrackerProgress: metric,
            },
          }),
        )}
        {...baseProps()}
      />,
    );
    expect(container.textContent).toMatch(/缺口径/);
    expect(container.textContent).toMatch(/部分/);
  });

  it('基地切换点击夜世界触发 onBaseChange 并反映 aria-pressed', () => {
    const onBaseChange = vi.fn();
    render(
      <VillageDetail
        state={applyVillageDetailSuccess(villageDetailFixture())}
        {...baseProps()}
        onBaseChange={onBaseChange}
      />,
    );
    const homeButton = screen.getByRole('button', { name: '主村' });
    const builderButton = screen.getByRole('button', { name: '夜世界' });
    expect(homeButton.getAttribute('aria-pressed')).toBe('true');
    expect(builderButton.getAttribute('aria-pressed')).toBe('false');
    fireEvent.click(builderButton);
    expect(onBaseChange).toHaveBeenCalledWith('builder');
  });

  it('长中文名称完整渲染（换行由 CSS 承担）', () => {
    const longName = '超级无敌加农炮之究极进化完全体形态最终决战兵器加长加长加长版名称测试';
    const { container } = render(
      <VillageDetail
        state={applyVillageDetailSuccess(
          villageDetailFixture({
            items: [{ ...recordFixture().item, id: 'item-long', name: longName }],
            flatRows: [
              {
                kind: 'legacy',
                itemID: 'item-long',
                groupID: 'g',
                indented: false,
                leadingDivider: false,
              },
            ],
          }),
        )}
        {...baseProps()}
      />,
    );
    expect(screen.getByText(longName)).toBeTruthy();
    expect(container.querySelector('.detail-item-name')).toBeTruthy();
  });

  it('payload 切换时自动关闭已开底片', () => {
    const { rerender } = render(
      <VillageDetail
        state={applyVillageDetailSuccess(
          villageDetailFixture({
            villageId: 'vA',
            items: [{ ...recordFixture().item, id: 'item-1' }],
            flatRows: [
              {
                kind: 'legacy',
                itemID: 'item-1',
                groupID: 'g',
                indented: false,
                leadingDivider: false,
              },
            ],
          }),
        )}
        {...baseProps()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: /加农炮/ }));
    expect(screen.getByRole('dialog', { name: '加农炮等级详情' })).toBeTruthy();
    rerender(
      <VillageDetail
        state={applyVillageDetailSuccess(
          villageDetailFixture({
            villageId: 'vB',
            generation: 2,
            items: [{ ...recordFixture().item, id: 'item-1' }],
            flatRows: [
              {
                kind: 'legacy',
                itemID: 'item-1',
                groupID: 'g',
                indented: false,
                leadingDivider: false,
              },
            ],
          }),
        )}
        {...baseProps()}
      />,
    );
    expect(screen.queryByRole('dialog')).toBeNull();
  });
});
