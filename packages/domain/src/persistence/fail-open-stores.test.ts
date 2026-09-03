import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  createOfficialEndpointState,
  createOfficialStateStore,
  createTrackedClanProfile,
  createTrackedClanStore,
  upsertTrackedClan,
  type ClanAPIState,
} from '../official';
import { CLAN_SNAPSHOT_PARSER_VERSION } from '../official/models/clan';
import { createClanStateFileStore, createPlayerStateFileStore } from './official-state-file-store';
import { TrackedClanFileStore } from './tracked-clan-file-store';
import { SelectionFileStore, resolveSelectedVillageId } from './selection-file-store';
import { decodeTrackedClanStoreWire, encodeTrackedClanStoreWire } from '../official/tracked-clan';

describe('OfficialStateFileStore', () => {
  it('往返保存、按 tag 排序，坏条保留好条，顶层坏归空', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-official-'));
    const fileURL = join(directory, 'clans-v1.json');
    const store = createClanStateFileStore(fileURL);

    const stateZ: ClanAPIState = createOfficialEndpointState({
      status: 'never',
      parserVersion: CLAN_SNAPSHOT_PARSER_VERSION,
    });
    const stateA: ClanAPIState = createOfficialEndpointState({
      status: 'success',
      clanTag: '#AAA',
      fetchedAtMs: 1_700_000_000_000,
      parserVersion: CLAN_SNAPSHOT_PARSER_VERSION,
      lastGood: {
        tag: '#AAA',
        name: 'Alpha',
        type: undefined,
        description: undefined,
        clanLevel: 10,
        badgeUrls: undefined,
        members: 40,
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
        unrecognizedKeys: ['x'],
      },
    });
    store.save(
      createOfficialStateStore({
        '#ZZZ': stateZ,
        '#AAA': stateA,
      }),
    );

    const text = readFileSync(fileURL, 'utf8');
    const wire = JSON.parse(text) as unknown[];
    expect(Object.keys(wire[0] as object)[0]).toBe('#AAA');
    expect(Object.keys(wire[1] as object)[0]).toBe('#ZZZ');

    const loaded = store.load();
    expect(loaded.states['#AAA']?.clanTag).toBe('#AAA');
    expect(loaded.states['#AAA']?.fetchedAtMs).toBe(1_700_000_000_000);
    expect(loaded.states['#AAA']?.lastGood?.name).toBe('Alpha');
    expect(loaded.states['#AAA']?.lastGood?.unrecognizedKeys).toEqual(['x']);
    expect(loaded.states['#ZZZ']?.status).toBe('never');

    writeFileSync(
      fileURL,
      JSON.stringify([
        { '#BAD': { status: 1 } },
        {},
        {
          '#BBB': {
            status: 'success',
            parserVersion: CLAN_SNAPSHOT_PARSER_VERSION,
            unrecognizedKeys: [],
          },
        },
      ]),
    );
    const partial = store.load();
    expect(partial.states['#BBB']?.status).toBe('success');
    expect(partial.states['#BAD']).toBeUndefined();

    writeFileSync(fileURL, '{');
    expect(store.load().states).toEqual({});

    rmSync(directory, { recursive: true, force: true });
  });

  it('player-states 按 villageId 往返', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-player-'));
    const store = createPlayerStateFileStore(join(directory, 'player-states-v1.json'));
    store.save(
      createOfficialStateStore({
        'village-1': {
          status: 'failed',
          playerTag: '#P1',
          fetchedAtMs: undefined,
          lastAttemptAtMs: 100,
          lastErrorReason: 'boom',
          lastHTTPStatus: 500,
          parserVersion: '1',
          lastGood: undefined,
          unrecognizedKeys: [],
        },
      }),
    );
    const loaded = store.load();
    expect(loaded.states['village-1']?.playerTag).toBe('#P1');
    expect(loaded.states['village-1']?.lastHTTPStatus).toBe(500);
    rmSync(directory, { recursive: true, force: true });
  });
});

describe('TrackedClanFileStore', () => {
  it('保持添加顺序、upsert 原位、顶层坏归空', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-tracked-'));
    const fileURL = join(directory, 'tracked-clans-v1.json');
    const store = new TrackedClanFileStore(fileURL);

    let profiles = createTrackedClanStore();
    profiles = upsertTrackedClan(
      profiles,
      createTrackedClanProfile({
        clanTag: '  #abc123  ',
        displayName: '甲',
        createdAtMs: 1,
      }),
    );
    profiles = upsertTrackedClan(
      profiles,
      createTrackedClanProfile({
        clanTag: '#BBB222',
        displayName: null,
        createdAtMs: 2,
      }),
    );
    profiles = upsertTrackedClan(
      profiles,
      createTrackedClanProfile({
        clanTag: '#ABC123',
        displayName: '甲改',
        createdAtMs: 3,
      }),
    );
    store.save(profiles);

    const loaded = store.load();
    expect(loaded.profiles.map((entry) => entry.clanTag)).toEqual(['#ABC123', '#BBB222']);
    expect(loaded.profiles[0]?.displayName).toBe('甲改');

    const wire = encodeTrackedClanStoreWire(loaded);
    expect(
      decodeTrackedClanStoreWire([{ clanTag: '#OK1', createdAt: 1 }, 'bad', wire[1]]).profiles,
    ).toHaveLength(2);

    writeFileSync(fileURL, '{');
    expect(store.load().profiles).toEqual([]);
    rmSync(directory, { recursive: true, force: true });
  });
});

describe('SelectionFileStore', () => {
  it('非法 selection 回落第一项', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-selection-'));
    const store = new SelectionFileStore(join(directory, 'selection-v1.json'));
    expect(store.load()).toBeNull();
    store.save('v-2');
    expect(store.load()).toBe('v-2');
    expect(resolveSelectedVillageId(['v-1', 'v-2'], 'v-2')).toBe('v-2');
    expect(resolveSelectedVillageId(['v-1', 'v-2'], 'missing')).toBe('v-1');
    expect(resolveSelectedVillageId(['v-1', 'v-2'], null)).toBe('v-1');
    writeFileSync(join(directory, 'selection-v1.json'), '{');
    expect(store.load()).toBeNull();
    rmSync(directory, { recursive: true, force: true });
  });
});
