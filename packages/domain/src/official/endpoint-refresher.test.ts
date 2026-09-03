import {
  clanSnapshotParserVersion,
  createOfficialEndpointState,
  type ClanAPIState,
} from './endpoint-state';
import { fetchSingleOfficialEndpoint, refreshOfficialEndpoints } from './endpoint-refresher';
import { describe, expect, it } from 'vitest';

const NOW = 1_700_000_000_000;

function sampleClanState(tag: string, name: string): ClanAPIState {
  return createOfficialEndpointState({
    status: 'success',
    clanTag: tag,
    fetchedAtMs: NOW,
    parserVersion: clanSnapshotParserVersion,
    lastGood: {
      tag,
      name,
      type: undefined,
      description: undefined,
      clanLevel: 5,
      badgeUrls: undefined,
      members: 10,
      requiredTrophies: undefined,
      requiredTownHallLevel: undefined,
      requiredBuilderBaseTrophies: undefined,
      requiredLeagueTier: undefined,
      clanBuilderBasePoints: undefined,
      clanCapitalPoints: undefined,
      capitalLeague: undefined,
      warLeague: undefined,
      warWins: undefined,
      warLosses: undefined,
      warTies: undefined,
      warWinStreak: undefined,
      isWarLogPublic: undefined,
      labels: undefined,
      clanCapital: undefined,
      unrecognizedKeys: [],
    },
  });
}

describe('EndpointRefresher', () => {
  it('重复 tag 只请求一次', async () => {
    let count = 0;
    const result = await refreshOfficialEndpoints({
      tags: ['#AAA', '#AAA', '#BBB', '#AAA'],
      previous: {},
      parserVersion: clanSnapshotParserVersion,
      nowMs: NOW,
      fetch: async (tag) => {
        count += 1;
        return { tag, name: tag, unrecognizedKeys: [] } as never;
      },
    });
    expect(count).toBe(2);
    expect(Object.keys(result).sort()).toEqual(['#AAA', '#BBB']);
  });

  it('失败保留 last-good 与 parserVersion', async () => {
    const previous = {
      '#CLAN': sampleClanState('#CLAN', 'previous-good'),
    };
    const result = await refreshOfficialEndpoints({
      tags: ['#CLAN'],
      previous,
      parserVersion: 'clan-snapshot-0.9',
      nowMs: NOW,
      fetch: async () => {
        throw { kind: 'rateLimited', retryAfterSeconds: undefined };
      },
    });
    const state = result['#CLAN'];
    expect(state?.status).toBe('failed');
    expect(state?.lastGood?.name).toBe('previous-good');
    expect(state?.parserVersion).toBe(clanSnapshotParserVersion);
    expect(state?.fetchedAtMs).toBe(NOW);
  });

  it('取消写入 cancelled failureKind', async () => {
    const result = await fetchSingleOfficialEndpoint({
      tag: '#CLAN',
      previous: undefined,
      parserVersion: clanSnapshotParserVersion,
      nowMs: NOW,
      fetch: async () => {
        throw new DOMException('aborted', 'AbortError');
      },
    });
    expect(result.failureKind).toBe('cancelled');
    expect(result.lastErrorReason).toBe('已取消');
  });

  it('无效 tag 被忽略', async () => {
    let count = 0;
    const result = await refreshOfficialEndpoints({
      tags: [null, '', '   ', '#', '#lowercase', 'NOHASH'],
      previous: {},
      parserVersion: clanSnapshotParserVersion,
      fetch: async () => {
        count += 1;
        return { unrecognizedKeys: [] } as never;
      },
    });
    expect(count).toBe(0);
    expect(result).toEqual({});
  });
});
