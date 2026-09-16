/** @vitest-environment jsdom */

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { resetClockStoreForTests } from '../clock-store';
import { LOADING_RESOURCE, resourceFailure, resourceSuccess } from '../resource-state';
import { playerFixture } from '../official-session.fixtures';
import { toOfficialPlayerView } from '../official-session';
import { OfficialPlayerCard } from './OfficialPlayerCard';

afterEach(() => {
  cleanup();
  resetClockStoreForTests();
  vi.useRealTimers();
});

describe('OfficialPlayerCard（#277-E1）', () => {
  it('成功态渲染摘要与刷新按钮', () => {
    resetClockStoreForTests(1_700_000_000_000);
    const onRefresh = vi.fn();
    const view = toOfficialPlayerView(resourceSuccess(playerFixture()), 1_700_000_000_000);
    render(<OfficialPlayerCard view={view} refreshing={false} onRefresh={onRefresh} />);
    expect(screen.getByLabelText('官方玩家数据')).toBeTruthy();
    expect(screen.getByText('官方 API 数据', { exact: false })).toBeTruthy();
    expect(screen.getByText('Hero')).toBeTruthy();
    expect(screen.getByText('#AAA')).toBeTruthy();
    expect(screen.getByText('16级')).toBeTruthy();
    expect(screen.getByText('测试部落')).toBeTruthy();
    fireEvent.click(screen.getByText('刷新官方数据'));
    expect(onRefresh).toHaveBeenCalledTimes(1);
  });

  it('无玩家 tag 禁用刷新并提示导入', () => {
    const view = toOfficialPlayerView(
      resourceSuccess(
        playerFixture({ playerTag: null, state: null, summary: null, currentClanTag: null }),
      ),
      0,
    );
    render(<OfficialPlayerCard view={view} refreshing={false} onRefresh={() => undefined} />);
    expect(screen.getByText('请先在账号数据页导入该村庄的账号 JSON')).toBeTruthy();
    expect((screen.getByText('刷新官方数据') as HTMLButtonElement).disabled).toBe(true);
  });

  it('failed-with-last-good 仍显示摘要', () => {
    const view = toOfficialPlayerView(
      resourceSuccess(
        playerFixture({
          state: {
            status: 'failed',
            parserVersion: 'player-snapshot-0.2',
            fetchedAt: 1_700_000_000_000,
            lastErrorReason: '服务器错误（500）',
            unrecognizedKeys: [],
          },
        }),
      ),
      1_700_000_000_000,
    );
    render(<OfficialPlayerCard view={view} refreshing={false} onRefresh={() => undefined} />);
    expect(screen.getByText('缓存的官方 API 数据', { exact: false })).toBeTruthy();
    expect(screen.getByText('16级')).toBeTruthy();
    expect(screen.getByText('已保留上次成功数据')).toBeTruthy();
  });

  it('刷新命令错误单独展示', () => {
    const view = {
      ...toOfficialPlayerView(resourceSuccess(playerFixture()), 1_700_000_000_000),
      commandError: '提交官方缓存失败',
    };
    render(<OfficialPlayerCard view={view} refreshing={false} onRefresh={() => undefined} />);
    expect(screen.getByRole('alert').textContent).toMatch(/提交官方缓存失败/);
  });

  it('query 失败显示查询失败，不说缺少标签', () => {
    const view = toOfficialPlayerView(resourceFailure(LOADING_RESOURCE, '查询失败'), 0);
    render(<OfficialPlayerCard view={view} refreshing={false} onRefresh={() => undefined} />);
    expect(screen.getByRole('alert').textContent).toMatch(/查询失败/);
    expect(screen.queryByText(/缺少有效标签/)).toBeNull();
  });
});
