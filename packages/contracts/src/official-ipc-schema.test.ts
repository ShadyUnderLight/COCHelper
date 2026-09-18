import { describe, expect, it } from 'vitest';

import {
  capitalRaidStatePayloadSchema,
  clanWarStatePayloadSchema,
  isCapitalRaidStatePayload,
  isClanWarStatePayload,
  isWarLogStatePayload,
  warLogStatePayloadSchema,
} from './official-ipc-schema';

const baseEndpointState = {
  status: 'success' as const,
  parserVersion: 'test-0.1',
  unrecognizedKeys: [] as string[],
};

describe('official-ipc-schema war payloads', () => {
  it('接受结构正确的 ClanWar / WarLog / CapitalRaid lastGood', () => {
    expect(
      isClanWarStatePayload({
        generation: 1,
        clanTag: '#CLAN01',
        state: {
          ...baseEndpointState,
          lastGood: {
            state: 'inWar',
            unrecognizedKeys: [],
          },
        },
      }),
    ).toBe(true);

    expect(
      isWarLogStatePayload({
        generation: 1,
        clanTag: '#CLAN01',
        state: {
          ...baseEndpointState,
          lastGood: {
            page: {
              items: [{ result: 'win', endTime: '2024-01-01' }],
            },
            unrecognizedKeys: [],
          },
        },
      }),
    ).toBe(true);

    expect(
      isCapitalRaidStatePayload({
        generation: 1,
        clanTag: '#CLAN01',
        state: {
          ...baseEndpointState,
          lastGood: {
            page: {
              items: [{ state: 'ended', startTime: '2024-01-01' }],
            },
            unrecognizedKeys: [],
          },
        },
      }),
    ).toBe(true);
  });

  it('拒绝空对象或错误嵌套结构的 lastGood', () => {
    expect(
      clanWarStatePayloadSchema.safeParse({
        generation: 1,
        clanTag: '#CLAN01',
        state: {
          ...baseEndpointState,
          lastGood: {},
        },
      }).success,
    ).toBe(false);

    expect(
      warLogStatePayloadSchema.safeParse({
        generation: 1,
        clanTag: '#CLAN01',
        state: {
          ...baseEndpointState,
          lastGood: {
            page: {
              items: 'not-an-array',
            },
          },
        },
      }).success,
    ).toBe(false);

    expect(
      warLogStatePayloadSchema.safeParse({
        generation: 1,
        clanTag: '#CLAN01',
        state: {
          ...baseEndpointState,
          lastGood: {
            page: {
              items: [{ clan: { stars: 'bad' } }],
            },
          },
        },
      }).success,
    ).toBe(false);

    expect(
      capitalRaidStatePayloadSchema.safeParse({
        generation: 1,
        clanTag: '#CLAN01',
        state: {
          ...baseEndpointState,
          lastGood: {
            page: {},
          },
        },
      }).success,
    ).toBe(false);
  });
});
