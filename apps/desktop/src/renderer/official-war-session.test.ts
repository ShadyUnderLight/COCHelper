import { describe, expect, it } from 'vitest';

import type { ClanWarStatePayload, WarLogStatePayload } from '@coc-helper/contracts';

import { IDLE_RESOURCE, resourceSuccess } from './resource-state';
import {
  capitalRaidAttackLogRows,
  capitalRaidDistrictRowLabel,
  OFFICIAL_DETAIL_ROW_LIMIT,
  clanWarMemberRowLabel,
  clanWarMetaLine,
  clanWarPhase,
  clanWarScoreLine,
  capitalRaidShowsEmptyHistory,
  clanWarRefreshStatusLine,
  formatMemberAttackSummary,
  toOfficialCapitalRaidView,
  toOfficialClanWarView,
  toOfficialWarLogView,
  warLogRefreshStatusLine,
  warLogEntryLabel,
  warLogMoreState,
  warLogShowsEmptyHistory,
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

  it('warLog 不公开时不查询且展示固定文案', () => {
    const view = toOfficialWarLogView(
      'tagged',
      '#CLAN',
      resourceSuccess(warLogPayload()),
      10,
      'private',
    );
    expect(view.warLogPublicity).toBe('private');
    expect(view.canRefresh).toBe(false);
    expect(view.entries).toEqual([]);
  });

  it('归属未知时不应显示不在部落中', () => {
    const view = toOfficialClanWarView('unknown', null, IDLE_RESOURCE);
    expect(view.affiliation).toBe('unknown');
    expect(clanWarRefreshStatusLine(view)).toBe('尚未确认部落归属');
  });

  it('warLog 公开性未知时禁用远程刷新', () => {
    const view = toOfficialWarLogView(
      'tagged',
      '#CLAN',
      resourceSuccess(warLogPayload()),
      10,
      'unknown',
    );
    expect(view.warLogPublicity).toBe('unknown');
    expect(view.canRefresh).toBe(false);
    expect(warLogRefreshStatusLine(view)).toBe('尚未确认部落对战日志是否公开');
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
    const view = toOfficialClanWarView('tagged', '#CLAN', resourceSuccess(clanWarPayload()));
    expect(view.phase).toBe('inWar');
    expect(view.war?.clan?.name).toBe('我方');
  });

  it('clanWarMetaLine 展示规模与进攻次数', () => {
    const line = clanWarMetaLine({
      state: 'inWar',
      teamSize: 15,
      attacksPerMember: 2,
      unrecognizedKeys: [],
      clan: { attacks: 20 },
      opponent: { attacks: 18 },
    });
    expect(line).toContain('15v15');
    expect(line).toContain('每人 2 次进攻');
  });

  it('warLogEntryLabel 包含比分摘要', () => {
    const label = warLogEntryLabel({
      endTime: '2024-01-01',
      result: 'win',
      clan: { stars: 45, destructionPercentage: 95 },
      opponent: { stars: 40, destructionPercentage: 90 },
    });
    expect(label).toContain('45★');
    expect(label).toContain('40★');
  });

  it('成员进攻摘要不累加摧毁率，且区分空数组与缺失', () => {
    expect(
      formatMemberAttackSummary([
        { stars: 3, destructionPercentage: 100 },
        { stars: 2, destructionPercentage: 75 },
      ]),
    ).toBe('2 次进攻 · 5★ · 摧毁 100%/75%');
    expect(
      formatMemberAttackSummary([
        { stars: 1, destructionPercentage: 100 },
        { destructionPercentage: 50 },
        { stars: 3, destructionPercentage: 80 },
      ]),
    ).toBe('3 次进攻 · 已知 4★ · 1 次星数未知 · 摧毁 100%/50%/80%');
    expect(
      formatMemberAttackSummary([{ destructionPercentage: 100 }, { destructionPercentage: undefined }]),
    ).toBe('2 次进攻 · 星数未知 · 摧毁 100%/—');
    expect(formatMemberAttackSummary([{ stars: 0 }, { stars: 0 }])).toBe('2 次进攻 · 0★ · 摧毁 —/—');
    expect(formatMemberAttackSummary([])).toBe('0 次进攻');
    expect(formatMemberAttackSummary(undefined)).toBeNull();
    expect(
      clanWarMemberRowLabel({
        name: '玩家A',
        attacks: [],
      }),
    ).toContain('0 次进攻');
  });

  it('Capital Raid 日志不把 districtCount 当作摧毁数，并展示城区明细', () => {
    const rows = capitalRaidAttackLogRows({
      attackLog: [
        {
          defender: { name: '防守部落' },
          districtCount: 5,
          districtsDestroyed: 1,
          districts: [
            {
              name: 'Capital Peak',
              stars: 3,
              destructionPercent: 80,
              totalLooted: 1200,
            },
          ],
        },
      ],
    });
    expect(rows.entryCount).toBe(1);
    expect(rows.rows[0]?.label).toBe('防守方 防守部落 · 城区 5 · 摧毁 1');
    expect(rows.rows[0]?.label).not.toContain('摧毁 5');
    expect(rows.rows[1]?.label).toBe(
      capitalRaidDistrictRowLabel({
        name: 'Capital Peak',
        stars: 3,
        destructionPercent: 80,
        totalLooted: 1200,
      }),
    );
  });

  it('never 或 null 状态不展示空历史文案', () => {
    const neverWarLogView = toOfficialWarLogView(
      'tagged',
      '#CLAN',
      resourceSuccess({
        generation: 1,
        clanTag: '#CLAN',
        state: {
          status: 'never',
          parserVersion: 'war-log-0.1',
          unrecognizedKeys: [],
        },
      }),
      10,
      'public',
    );
    expect(warLogShowsEmptyHistory(neverWarLogView)).toBe(false);

    const neverCapitalView = toOfficialCapitalRaidView(
      'tagged',
      '#CLAN',
      resourceSuccess({
        generation: 1,
        clanTag: '#CLAN',
        state: {
          status: 'never',
          parserVersion: 'capital-raid-0.1',
          unrecognizedKeys: [],
        },
      }),
    );
    expect(capitalRaidShowsEmptyHistory(neverCapitalView)).toBe(false);
  });

  it('Capital Raid 日志在达到行数上限后停止物化', () => {
    const rows = capitalRaidAttackLogRows({
      attackLog: Array.from({ length: 40 }, (_, index) => ({
        defender: { name: `防守${index}` },
        districts: [{ name: `城区${index}`, stars: 3 }],
      })),
    });
    expect(rows.entryCount).toBe(40);
    expect(rows.rows.length).toBe(OFFICIAL_DETAIL_ROW_LIMIT);
    expect(rows.truncated).toBe(true);
  });

  it('failedWithoutLastGood 时不展示空历史文案', () => {
    const warLogView = toOfficialWarLogView(
      'tagged',
      '#CLAN',
      resourceSuccess({
        generation: 1,
        clanTag: '#CLAN',
        state: {
          status: 'failed',
          parserVersion: 'war-log-0.1',
          unrecognizedKeys: [],
          lastErrorReason: '网络错误',
        },
      }),
      10,
      'public',
    );
    expect(warLogShowsEmptyHistory(warLogView)).toBe(false);

    const capitalView = toOfficialCapitalRaidView(
      'tagged',
      '#CLAN',
      resourceSuccess({
        generation: 1,
        clanTag: '#CLAN',
        state: {
          status: 'failed',
          parserVersion: 'capital-raid-0.1',
          unrecognizedKeys: [],
          lastErrorReason: '网络错误',
        },
      }),
    );
    expect(capitalRaidShowsEmptyHistory(capitalView)).toBe(false);
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
        unrecognizedKeys: [],
      },
    },
  };
}

describe('warLog visible count', () => {
  it('默认可见条数与 E1 分页预算一致', () => {
    const view = toOfficialWarLogView(
      'tagged',
      '#CLAN',
      resourceSuccess(warLogPayload()),
      WAR_LOG_DEFAULT_VISIBLE_COUNT,
      'public',
    );
    expect(view.visibleEntries).toHaveLength(10);
    expect(view.moreState).toBe('localHidden');
  });
});
