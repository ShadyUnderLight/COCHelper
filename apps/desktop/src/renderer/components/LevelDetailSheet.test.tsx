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
  it('渲染名称/等级跃迁/状态', () => {
    render(
      <LevelDetailSheet item={itemWith()} catalogVersion="18.400.13" onClose={() => undefined} />,
    );
    expect(screen.getByRole('dialog', { name: '加农炮等级详情' })).toBeTruthy();
    expect(screen.getByText('加农炮')).toBeTruthy();
    expect(screen.getByText(/5 → 6 级/)).toBeTruthy();
    expect(screen.getAllByText(/进行中/).length).toBeGreaterThan(0);
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
});
