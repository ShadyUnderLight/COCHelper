import type {
  ClanStatePayload,
  OfficialEndpointStateDto,
  PlayerStatePayload,
} from '@coc-helper/contracts';

export function playerFixture(overrides: Partial<PlayerStatePayload> = {}): PlayerStatePayload {
  return {
    generation: 1,
    villageId: 'v1',
    playerTag: '#AAA',
    currentClanTag: '#CLAN01',
    summary: {
      name: 'Hero',
      tag: '#AAA',
      townHallLevel: 16,
      builderHallLevel: 10,
      expLevel: 200,
      trophies: 5000,
      bestTrophies: 5200,
      clanName: '测试部落',
      clanTag: '#CLAN01',
    },
    state: successState(),
    ...overrides,
  };
}

export function clanFixture(overrides: Partial<ClanStatePayload> = {}): ClanStatePayload {
  return {
    generation: 1,
    clanTag: '#CLAN01',
    summary: {
      name: '测试部落',
      tag: '#CLAN01',
      clanLevel: 12,
      members: 40,
      type: 'open',
      isWarLogPublic: true,
      warWins: 100,
    },
    state: successState(),
    ...overrides,
  };
}

function successState(): OfficialEndpointStateDto {
  return {
    status: 'success',
    parserVersion: 'player-snapshot-0.2',
    fetchedAt: 1_700_000_000_000,
    unrecognizedKeys: [],
  };
}
