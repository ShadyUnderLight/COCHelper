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
});
