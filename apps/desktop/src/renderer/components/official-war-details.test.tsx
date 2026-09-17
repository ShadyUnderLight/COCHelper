/** @vitest-environment jsdom */

import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { OfficialCapitalRaidSeasonDetails } from './official-war-details';

describe('OfficialCapitalRaidSeasonDetails（#277-E2）', () => {
  it('进攻日志标题只统计日志条数，不含城区子行', () => {
    render(
      <OfficialCapitalRaidSeasonDetails
        season={{
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
        }}
      />,
    );
    expect(screen.getByText('进攻日志（1）')).toBeTruthy();
  });
});
