/** @vitest-environment jsdom */

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { LOADING_RESOURCE, resourceSuccess } from '../resource-state';
import { clanFixture } from '../official-session.fixtures';
import { toOfficialClanView } from '../official-session';
import { ClanCard } from './ClanCard';

afterEach(() => {
  cleanup();
});

describe('ClanCard（#277-E1）', () => {
  it('unknown 不显示刷新，并提示先拉玩家数据', () => {
    const view = toOfficialClanView('unknown', null, LOADING_RESOURCE, 0);
    render(<ClanCard view={view} refreshing={false} onRefresh={() => undefined} />);
    expect(screen.getByText('尚未获取玩家数据，无法确认部落归属')).toBeTruthy();
    expect(screen.queryByText('刷新部落数据')).toBeNull();
  });

  it('none 显示不在部落，不出现刷新', () => {
    const view = toOfficialClanView('none', null, LOADING_RESOURCE, 0);
    render(<ClanCard view={view} refreshing={false} onRefresh={() => undefined} />);
    expect(screen.getByText('该玩家当前不在部落中')).toBeTruthy();
    expect(screen.queryByText('刷新部落数据')).toBeNull();
  });

  it('tagged 成功态显示摘要并可刷新', () => {
    const onRefresh = vi.fn();
    const view = toOfficialClanView(
      'tagged',
      '#CLAN01',
      resourceSuccess(clanFixture()),
      1_700_000_000_000,
    );
    render(<ClanCard view={view} refreshing={false} onRefresh={onRefresh} />);
    expect(screen.getByText('测试部落')).toBeTruthy();
    expect(screen.getByText('任何人都可加入')).toBeTruthy();
    expect(screen.getByText('公开')).toBeTruthy();
    fireEvent.click(screen.getByText('刷新部落数据'));
    expect(onRefresh).toHaveBeenCalledTimes(1);
  });
});
