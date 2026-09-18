/** @vitest-environment jsdom */

import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { IDLE_OFFICIAL_CLAN_WAR_VIEW } from '../official-war-session';
import type { OfficialClanWarApi } from '../use-official-clan-war';
import { ClanWarCard } from './ClanWarCard';

describe('ClanWarCard（#277-E2）', () => {
  it('notInWar 展示空态文案', () => {
    const api: OfficialClanWarApi = {
      view: {
        ...IDLE_OFFICIAL_CLAN_WAR_VIEW,
        clanTag: '#CLAN',
        queryStatus: 'ready',
        refreshStatus: 'success',
        phase: 'notInWar',
        war: { state: 'notInWar', unrecognizedKeys: [] },
        canRefresh: true,
      },
      refresh: async () => undefined,
      refreshing: false,
    };
    render(<ClanWarCard api={api} />);
    expect(screen.getByText('当前没有进行中的部落对战')).toBeTruthy();
  });

  it('inWar 展示规模与成员进攻明细入口', () => {
    const api: OfficialClanWarApi = {
      view: {
        ...IDLE_OFFICIAL_CLAN_WAR_VIEW,
        clanTag: '#CLAN',
        queryStatus: 'ready',
        refreshStatus: 'success',
        phase: 'inWar',
        war: {
          state: 'inWar',
          teamSize: 15,
          attacksPerMember: 2,
          unrecognizedKeys: [],
          clan: {
            name: '我方',
            stars: 10,
            destructionPercentage: 80,
            members: [
              {
                name: '玩家A',
                townhallLevel: 16,
                mapPosition: 1,
                attacks: [{ stars: 3, destructionPercentage: 100 }],
              },
            ],
          },
          opponent: { name: '对方', stars: 8, destructionPercentage: 70 },
        },
        canRefresh: true,
      },
      refresh: async () => undefined,
      refreshing: false,
    };
    render(<ClanWarCard api={api} />);
    expect(screen.getByText(/15v15/)).toBeTruthy();
    expect(screen.getByText('我方成员进攻（1）')).toBeTruthy();
  });
});
