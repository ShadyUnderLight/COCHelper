import { OFFICIAL_PARSER_VERSIONS } from '../types';
import {
  asRecord,
  collectUnrecognizedKeys,
  optionalBool,
  optionalInt,
  optionalString,
  type JsonRecord,
} from '../json-decode';
import { decodePlayerClan } from './player-nested';

const KNOWN_KEYS = new Set([
  'tag',
  'name',
  'townHallLevel',
  'townHallWeaponLevel',
  'townHallWeaponLevelKeyPresent',
  'builderHallLevel',
  'expLevel',
  'trophies',
  'bestTrophies',
  'warStars',
  'attackWins',
  'defenseWins',
  'builderBaseTrophies',
  'versusBattleWins',
  'legendStatistics',
  'clan',
  'role',
  'warPreference',
  'donations',
  'donationsReceived',
  'clanCapitalContributions',
  'league',
  'builderBaseLeague',
  'leagueTier',
  'achievements',
  'labels',
  'playerHouse',
  'troops',
  'heroes',
  'spells',
  'heroEquipment',
  'unrecognizedKeys',
]);

export type PlayerLeague = {
  readonly id: number | undefined;
  readonly name: string | undefined;
  readonly iconUrls: Readonly<Record<string, string>> | undefined;
};

export type PlayerItemLevel = {
  readonly name: string | undefined;
  readonly level: number | undefined;
  readonly maxLevel: number | undefined;
  readonly village: string | undefined;
};

export type OfficialPlayerSnapshot = {
  readonly tag: string | undefined;
  readonly name: string | undefined;
  readonly townHallLevel: number | undefined;
  readonly townHallWeaponLevel: number | undefined;
  readonly townHallWeaponLevelKeyPresent: boolean;
  readonly builderHallLevel: number | undefined;
  readonly expLevel: number | undefined;
  readonly trophies: number | undefined;
  readonly bestTrophies: number | undefined;
  readonly warStars: number | undefined;
  readonly attackWins: number | undefined;
  readonly defenseWins: number | undefined;
  readonly builderBaseTrophies: number | undefined;
  readonly versusBattleWins: number | undefined;
  readonly legendStatistics: Readonly<Record<string, unknown>> | undefined;
  readonly clan: ReturnType<typeof decodePlayerClan>;
  readonly role: string | undefined;
  readonly warPreference: string | undefined;
  readonly donations: number | undefined;
  readonly donationsReceived: number | undefined;
  readonly clanCapitalContributions: number | undefined;
  readonly league: PlayerLeague | undefined;
  readonly builderBaseLeague: PlayerLeague | undefined;
  readonly leagueTier: PlayerLeague | undefined;
  readonly achievements: readonly Readonly<Record<string, unknown>>[] | undefined;
  readonly labels: readonly Readonly<Record<string, unknown>>[] | undefined;
  readonly playerHouse: Readonly<Record<string, unknown>> | undefined;
  readonly troops: readonly PlayerItemLevel[] | undefined;
  readonly heroes: readonly PlayerItemLevel[] | undefined;
  readonly spells: readonly PlayerItemLevel[] | undefined;
  readonly heroEquipment: readonly PlayerItemLevel[] | undefined;
  readonly unrecognizedKeys: readonly string[];
};

export const PLAYER_SNAPSHOT_PARSER_VERSION = OFFICIAL_PARSER_VERSIONS.playerSnapshot;

function decodePlayerLeague(value: unknown): PlayerLeague | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  const record = asRecord(value, 'PlayerLeague');
  const iconRaw = record.iconUrls;
  let iconUrls: Readonly<Record<string, string>> | undefined;
  if (iconRaw !== undefined && iconRaw !== null) {
    iconUrls = Object.fromEntries(
      Object.entries(asRecord(iconRaw, 'iconUrls')).map(([key, entry]) => {
        if (typeof entry !== 'string') {
          throw new TypeError(`iconUrls.${key} 必须是 string。`);
        }
        return [key, entry];
      }),
    );
  }
  return {
    id: optionalInt(record.id),
    name: optionalString(record.name),
    iconUrls,
  };
}

function decodePlayerItemLevels(value: unknown): readonly PlayerItemLevel[] | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (!Array.isArray(value)) {
    throw new TypeError('item levels 必须是 array 或 null。');
  }
  return value.map((entry) => {
    const record = asRecord(entry, 'PlayerItemLevel');
    return {
      name: optionalString(record.name),
      level: optionalInt(record.level),
      maxLevel: optionalInt(record.maxLevel),
      village: optionalString(record.village),
    };
  });
}

function decodeObjectArray(value: unknown): readonly Readonly<Record<string, unknown>>[] | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (!Array.isArray(value)) {
    throw new TypeError('array 字段必须是 array 或 null。');
  }
  return value.map((entry) => asRecord(entry, 'object array item'));
}

function decodeTownHallWeaponLevelKeyPresent(record: JsonRecord): boolean {
  if ('townHallWeaponLevelKeyPresent' in record) {
    const marker = optionalBool(record.townHallWeaponLevelKeyPresent);
    if (marker === undefined) {
      throw new TypeError('townHallWeaponLevelKeyPresent 必须是布尔值');
    }
    const hasWeaponKey = 'townHallWeaponLevel' in record;
    if (marker !== hasWeaponKey) {
      throw new TypeError('townHallWeaponLevelKeyPresent 与 townHallWeaponLevel 键存在性矛盾');
    }
    return marker;
  }
  return 'townHallWeaponLevel' in record;
}

export function decodeOfficialPlayerSnapshot(value: unknown): OfficialPlayerSnapshot {
  const record = asRecord(value, 'OfficialPlayerSnapshot');
  const legendRaw = record.legendStatistics;
  return {
    tag: optionalString(record.tag),
    name: optionalString(record.name),
    townHallLevel: optionalInt(record.townHallLevel),
    townHallWeaponLevel: optionalInt(record.townHallWeaponLevel),
    townHallWeaponLevelKeyPresent: decodeTownHallWeaponLevelKeyPresent(record),
    builderHallLevel: optionalInt(record.builderHallLevel),
    expLevel: optionalInt(record.expLevel),
    trophies: optionalInt(record.trophies),
    bestTrophies: optionalInt(record.bestTrophies),
    warStars: optionalInt(record.warStars),
    attackWins: optionalInt(record.attackWins),
    defenseWins: optionalInt(record.defenseWins),
    builderBaseTrophies: optionalInt(record.builderBaseTrophies),
    versusBattleWins: optionalInt(record.versusBattleWins),
    legendStatistics:
      legendRaw === undefined || legendRaw === null ? undefined : asRecord(legendRaw, 'legendStatistics'),
    clan: decodePlayerClan(record.clan),
    role: optionalString(record.role),
    warPreference: optionalString(record.warPreference),
    donations: optionalInt(record.donations),
    donationsReceived: optionalInt(record.donationsReceived),
    clanCapitalContributions: optionalInt(record.clanCapitalContributions),
    league: decodePlayerLeague(record.league),
    builderBaseLeague: decodePlayerLeague(record.builderBaseLeague),
    leagueTier: decodePlayerLeague(record.leagueTier),
    achievements: decodeObjectArray(record.achievements),
    labels: decodeObjectArray(record.labels),
    playerHouse:
      record.playerHouse === undefined || record.playerHouse === null
        ? undefined
        : asRecord(record.playerHouse, 'playerHouse'),
    troops: decodePlayerItemLevels(record.troops),
    heroes: decodePlayerItemLevels(record.heroes),
    spells: decodePlayerItemLevels(record.spells),
    heroEquipment: decodePlayerItemLevels(record.heroEquipment),
    unrecognizedKeys: collectUnrecognizedKeys(record, KNOWN_KEYS),
  };
}

export function decodeOfficialPlayerSnapshotJson(text: string): OfficialPlayerSnapshot {
  return decodeOfficialPlayerSnapshot(JSON.parse(text) as unknown);
}
