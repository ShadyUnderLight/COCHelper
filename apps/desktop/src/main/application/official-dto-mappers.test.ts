import { describe, expect, it } from 'vitest';

import {
  createOfficialAPIState,
  createOfficialEndpointState,
  type OfficialClanSnapshot,
  type OfficialPlayerSnapshot,
} from '@coc-helper/domain';

import { toClanSummaryDto, toPlayerSummaryDto } from './official-dto-mappers';

describe('official DTO mappers', () => {
  it('0 / false 与未知 type 不被 || 吞掉', () => {
    const player = toPlayerSummaryDto(
      createOfficialAPIState({
        status: 'success',
        lastGood: {
          tag: '#P',
          name: 'Zero',
          trophies: 0,
          unrecognizedKeys: [],
        } as unknown as OfficialPlayerSnapshot,
      }),
    );
    expect(player?.trophies).toBe(0);
    expect(player?.tag).toBe('#P');

    const clan = toClanSummaryDto(
      createOfficialEndpointState({
        status: 'success',
        parserVersion: 'clan-snapshot-0.4',
        lastGood: {
          tag: '#C',
          name: 'Empty',
          type: 'weird',
          members: 0,
          warWins: 0,
          isWarLogPublic: false,
          unrecognizedKeys: [],
        } as unknown as OfficialClanSnapshot,
      }),
    );
    expect(clan?.members).toBe(0);
    expect(clan?.warWins).toBe(0);
    expect(clan?.isWarLogPublic).toBe(false);
    expect(clan?.type).toBe('weird');
    expect(clan?.tag).toBe('#C');
  });
});
