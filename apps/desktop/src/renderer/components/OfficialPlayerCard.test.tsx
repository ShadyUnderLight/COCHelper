/** @vitest-environment jsdom */

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { resourceSuccess } from '../resource-state';
import { playerFixture, toOfficialPlayerView } from '../official-session';
import { OfficialPlayerCard } from './OfficialPlayerCard';

afterEach(() => {
  cleanup();
});

describe('OfficialPlayerCard（#277-E1）', () => {
  it('成功态渲染摘要与刷新按钮', () => {
    const onRefresh = vi.fn();
    const view = toOfficialPlayerView(resourceSuccess(playerFixture()), 1_700_000_000_000);
    render(<OfficialPlayerCard view={view} refreshing={false} onRefresh={onRefresh} />);
    expect(screen.getByLabelText('官方玩家数据')).toBeTruthy();
    expect(screen.getByText('官方 API 数据', { exact: false })).toBeTruthy();
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
});
