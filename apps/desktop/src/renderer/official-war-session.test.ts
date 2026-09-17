import { describe, expect, it } from 'vitest';

import type { ClanWarStatePayload, WarLogStatePayload } from '@coc-helper/contracts';

import { resourceSuccess } from './resource-state';
import {
  clanWarPhase,
  clanWarScoreLine,
  toOfficialClanWarView,
  toOfficialWarLogView,
  warLogMoreState,
  WAR_LOG_DEFAULT_VISIBLE_COUNT,
} from './official-war-session';

describe('official-war-session（#277-E2）', () => {
  it('clanWarPhase 精确匹配官方 state', () => {
    expect(clanWarPhase({ state: 'notInWar', unrecognizedKeys: [] })).toBe('notInWar');
    expect(clanWarPhase({ state: ' inWar ', unrecognizedKeys: [] })).toBe('inWar');
    expect(clanWarPhase({ state: 'unknownPhase', unrecognizedKeys: [] })).toBe('unknown');
  });

  it('warLogMoreState 本地隐藏优先于服务端更多', () => {
    expect(warLogMoreState(12, 10, true)).toBe('localHidden');
    expect(warLogMoreState(10, 10, true)).toBe('serverMore');
    expect(warLogMoreState(0, 10, true)).toBe('none');
  });

  it('knownNotPublic 时不查询且展示固定文案', () => {
    const view = toOfficialWarLogView('#CLAN', resourceSuccess(warLogPayload()), 10, true);
    expect(view.knownNotPublic).toBe(true);
    expect(view.canRefresh).toBe(false);
    expect(view.entries).toEqual([]);
  });

  it('clanWarScoreLine 缺失星数时不伪造 0★', () => {
    const line = clanWarScoreLine({
      state: 'inWar',
      unrecognizedKeys: [],
      clan: { name: '我方' },
      opponent: { name: '对方', stars: 10, destructionPercentage: 80 },
    });
    expect(line).toBe('我方 vs 对方 10★ 80%');
  });

  it('toOfficialClanWarView 投影 last-good 战争', () => {
    const view = toOfficialClanWarView('#CLAN', resourceSuccess(clanWarPayload()));
    expect(view.phase).toBe('inWar');
    expect(view.war?.clan?.name).toBe('我方');
  });
});

function clanWarPayload(): ClanWarStatePayload {
  return {
    generation: 1,
    clanTag: '#CLAN',
    state: {
      status: 'success',
      parserVersion: 'clan-war-0.1',
      fetchedAt: 1_700_000_000_000,
      unrecognizedKeys: [],
      lastGood: {
        state: 'inWar',
        unrecognizedKeys: [],
        clan: { name: '我方', stars: 10, destructionPercentage: 80 },
        opponent: { name: '对方', stars: 8, destructionPercentage: 70 },
      },
    },
  };
}

function warLogPayload(): WarLogStatePayload {
  return {
    generation: 1,
    clanTag: '#CLAN',
    state: {
      status: 'success',
      parserVersion: 'war-log-0.1',
      fetchedAt: 1_700_000_000_000,
      unrecognizedKeys: [],
      hasMore: true,
      lastGood: {
        page: {
          items: Array.from({ length: 12 }, (_, index) => ({
            endTime: `2024-01-${String(index + 1).padStart(2, '0')}`,
            result: 'win',
          })),
        },
      },
    },
  };
}

describe('warLog visible count', () => {
  it('默认可见条数与 E1 分页预算一致', () => {
    const view = toOfficialWarLogView(
      '#CLAN',
      resourceSuccess(warLogPayload()),
      WAR_LOG_DEFAULT_VISIBLE_COUNT,
      false,
    );
    expect(view.visibleEntries).toHaveLength(10);
    expect(view.moreState).toBe('localHidden');
  });
});
