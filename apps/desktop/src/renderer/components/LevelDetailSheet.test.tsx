/** @vitest-environment jsdom */

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { recordFixture } from '../overview-session';
import { LevelDetailSheet } from './LevelDetailSheet';

afterEach(() => {
  cleanup();
});

function itemWith(overrides: Partial<ReturnType<typeof recordFixture>['item']> = {}) {
  return { ...recordFixture().item, ...overrides };
}

describe('LevelDetailSheet（#277-C2）', () => {
  it('渲染名称/等级跃迁/状态（权威单状态：importedActive → 正在升级）', () => {
    render(
      <LevelDetailSheet item={itemWith()} catalogVersion="18.400.13" onClose={() => undefined} />,
    );
    expect(screen.getByRole('dialog', { name: '加农炮等级详情' })).toBeTruthy();
    expect(screen.getByText('加农炮')).toBeTruthy();
    expect(screen.getByText(/5 → 6 级/)).toBeTruthy();
    expect(screen.getAllByText(/正在升级/).length).toBeGreaterThan(0);
    expect(screen.queryByText(/进行中/)).toBeNull();
  });

  it('upgrading + manualCompleted 显示已记录且无进行中（权威状态）', () => {
    const item = itemWith({ status: 'upgrading', effectiveStatus: 'manualCompleted' });
    render(<LevelDetailSheet item={item} catalogVersion="18.400.13" onClose={() => undefined} />);
    expect(screen.getAllByText(/已记录/).length).toBeGreaterThan(0);
    expect(screen.queryByText(/进行中/)).toBeNull();
  });

  it('conflict 显示本地状态冲突 + 说明', () => {
    const item = itemWith({ effectiveStatus: 'conflict' });
    render(<LevelDetailSheet item={item} catalogVersion="18.400.13" onClose={() => undefined} />);
    expect(screen.getAllByText(/本地状态冲突/).length).toBeGreaterThan(0);
    expect(screen.getByText(/本地手动状态冲突/)).toBeTruthy();
  });

  it('requires 升级显示解锁条件（home 大本营 + 实验室）', () => {
    const item = itemWith({
      nextUpgrade: {
        kind: 'requires',
        nextLevel: 11,
        requirements: [
          { kind: 'townHall', level: 10 },
          { kind: 'laboratory', level: 8 },
        ],
        referenceDurationSeconds: null,
      },
    });
    render(<LevelDetailSheet item={item} catalogVersion="18.400.13" onClose={() => undefined} />);
    expect(screen.getByText(/所需大本营等级 10级 · 所需实验室等级 8级/)).toBeTruthy();
  });

  it('requires 空数组时不渲染解锁条件行', () => {
    const item = itemWith({
      nextUpgrade: {
        kind: 'requires',
        nextLevel: 11,
        requirements: [],
        referenceDurationSeconds: null,
      },
    });
    render(<LevelDetailSheet item={item} catalogVersion="18.400.13" onClose={() => undefined} />);
    expect(screen.getByText(/下一级 11 级/)).toBeTruthy();
    expect(screen.queryByText(/解锁条件/)).toBeNull();
  });

  it('globalMaxed 显示已满级', () => {
    const item = itemWith({ nextUpgrade: { kind: 'globalMaxed' } });
    render(<LevelDetailSheet item={item} catalogVersion="18.400.13" onClose={() => undefined} />);
    expect(screen.getByText(/已满级/)).toBeTruthy();
  });

  it('timed 时长显示 1天 1小时', () => {
    const item = itemWith({ nextLevelDurationState: { kind: 'timed', seconds: 90061 } });
    render(<LevelDetailSheet item={item} catalogVersion="18.400.13" onClose={() => undefined} />);
    expect(screen.getByText(/1天 1小时/)).toBeTruthy();
  });

  it('instant 时长显示即时', () => {
    const item = itemWith({ nextLevelDurationState: { kind: 'instant' } });
    render(<LevelDetailSheet item={item} catalogVersion="18.400.13" onClose={() => undefined} />);
    expect(screen.getByText(/即时/)).toBeTruthy();
  });

  it('sourceMissing 时长显示目录缺失', () => {
    const item = itemWith({ nextLevelDurationState: { kind: 'sourceMissing' } });
    render(<LevelDetailSheet item={item} catalogVersion="18.400.13" onClose={() => undefined} />);
    expect(screen.getByText(/目录缺失/)).toBeTruthy();
  });

  it('图标 src 正确，加载失败后显示图标缺失', () => {
    const item = itemWith({
      icon: {
        container: 'sc',
        exportName: 'x',
        renderedPath: 'icons/ui/icon_x.png',
        missingReason: null,
      },
    });
    render(<LevelDetailSheet item={item} catalogVersion="18.400.13" onClose={() => undefined} />);
    const img = document.querySelector('.level-sheet img.item-icon') as HTMLImageElement | null;
    expect(img?.getAttribute('src')).toBe('cochelper://catalog/18.400.13/icons/ui/icon_x.png');
    fireEvent.error(img!);
    expect(screen.getByText('图标缺失')).toBeTruthy();
  });

  it('图标全空显示图标缺失', () => {
    render(
      <LevelDetailSheet item={itemWith()} catalogVersion="18.400.13" onClose={() => undefined} />,
    );
    expect(screen.getByText('图标缺失')).toBeTruthy();
  });

  it('Esc 关闭', () => {
    const onClose = vi.fn();
    render(<LevelDetailSheet item={itemWith()} catalogVersion="18.400.13" onClose={onClose} />);
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('点击遮罩关闭', () => {
    const onClose = vi.fn();
    const { container } = render(
      <LevelDetailSheet item={itemWith()} catalogVersion="18.400.13" onClose={onClose} />,
    );
    const overlay = container.querySelector('.sheet-overlay');
    expect(overlay).not.toBeNull();
    fireEvent.click(overlay!);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('关闭按钮关闭', () => {
    const onClose = vi.fn();
    render(<LevelDetailSheet item={itemWith()} catalogVersion="18.400.13" onClose={onClose} />);
    fireEvent.click(screen.getByText('关闭'));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('Tab 陷阱：单可聚焦关闭按钮时 Tab 留在 dialog', () => {
    render(
      <LevelDetailSheet item={itemWith()} catalogVersion="18.400.13" onClose={() => undefined} />,
    );
    const closeButton = screen.getByText('关闭');
    closeButton.focus();
    expect(document.activeElement).toBe(closeButton);
    fireEvent.keyDown(document, { key: 'Tab' });
    expect(document.activeElement).toBe(closeButton);
  });

  it('Tab 陷阱：Shift+Tab 在首元素回绕到末元素（单按钮即自身）', () => {
    render(
      <LevelDetailSheet item={itemWith()} catalogVersion="18.400.13" onClose={() => undefined} />,
    );
    const closeButton = screen.getByText('关闭');
    closeButton.focus();
    fireEvent.keyDown(document, { key: 'Tab', shiftKey: true });
    expect(document.activeElement).toBe(closeButton);
  });
});
