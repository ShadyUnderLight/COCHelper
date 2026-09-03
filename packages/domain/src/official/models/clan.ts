import { OFFICIAL_PARSER_VERSIONS } from '../types';
import {
  asRecord,
  collectUnrecognizedKeys,
  optionalBool,
  optionalInt,
  optionalString,
  type JsonRecord,
} from '../json-decode';

const KNOWN_KEYS = new Set([
  'tag',
  'name',
  'type',
  'description',
  'clanLevel',
  'clanPoints',
  'clanVersusPoints',
  'requiredTrophies',
  'requiredTownhallLevel',
  'requiredTownHallLevel',
  'requiredBuilderBaseTrophies',
  'requiredLeagueTier',
  'clanBuilderBasePoints',
  'clanCapitalPoints',
  'capitalLeague',
  'warFrequency',
  'warWinStreak',
  'warWins',
  'warTies',
  'warLosses',
  'isWarLogPublic',
  'warLeague',
  'members',
  'memberList',
  'labels',
  'requiredVersusTrophies',
  'chatLanguage',
  'clanCapital',
  'badgeUrls',
  'location',
  'isFamilyFriendly',
  'unrecognizedKeys',
]);

export type ClanCapital = {
  readonly capitalHallLevel: number | undefined;
};

export type ClanLeague = {
  readonly id: number | undefined;
  readonly name: string | undefined;
};

export type ClanLeagueTier = {
  readonly id: number | undefined;
  readonly name: string | undefined;
  readonly iconUrls: Readonly<Record<string, string>> | undefined;
};

export type ClanLabel = {
  readonly id: number | undefined;
  readonly name: string | undefined;
};

export type OfficialClanSnapshot = {
  readonly tag: string | undefined;
  readonly name: string | undefined;
  readonly type: string | undefined;
  readonly description: string | undefined;
  readonly clanLevel: number | undefined;
  readonly badgeUrls: Readonly<Record<string, string>> | undefined;
  readonly members: number | undefined;
  readonly requiredTrophies: number | undefined;
  readonly requiredTownHallLevel: number | undefined;
  readonly requiredBuilderBaseTrophies: number | undefined;
  readonly requiredLeagueTier: ClanLeagueTier | undefined;
  readonly clanBuilderBasePoints: number | undefined;
  readonly clanCapitalPoints: number | undefined;
  readonly capitalLeague: ClanLeague | undefined;
  readonly warLeague: ClanLeague | undefined;
  readonly warWins: number | undefined;
  readonly warLosses: number | undefined;
  readonly warTies: number | undefined;
  readonly warWinStreak: number | undefined;
  readonly isWarLogPublic: boolean | undefined;
  readonly labels: readonly ClanLabel[] | undefined;
  readonly clanCapital: ClanCapital | undefined;
  readonly unrecognizedKeys: readonly string[];
};

export const CLAN_SNAPSHOT_PARSER_VERSION = OFFICIAL_PARSER_VERSIONS.clanSnapshot;

function decodeClanLeague(value: unknown): ClanLeague | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  const record = asRecord(value, 'ClanLeague');
  return {
    id: optionalInt(record.id),
    name: optionalString(record.name),
  };
}

function decodeClanLeagueTier(value: unknown): ClanLeagueTier | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value === 'number' && Number.isInteger(value)) {
    return { id: value, name: undefined, iconUrls: undefined };
  }
  const record = asRecord(value, 'ClanLeagueTier');
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

function decodeClanLabels(value: unknown): readonly ClanLabel[] | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (!Array.isArray(value)) {
    throw new TypeError('labels 必须是 array 或 null。');
  }
  return value.map((entry) => {
    const record = asRecord(entry, 'ClanLabel');
    return {
      id: optionalInt(record.id),
      name: optionalString(record.name),
    };
  });
}

function decodeClanCapital(value: unknown): ClanCapital | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  const record = asRecord(value, 'ClanCapital');
  return {
    capitalHallLevel: optionalInt(record.capitalHallLevel),
  };
}

function decodeRequiredTownHallLevel(record: JsonRecord): number | undefined {
  return optionalInt(record.requiredTownhallLevel) ?? optionalInt(record.requiredTownHallLevel);
}

export function decodeOfficialClanSnapshot(value: unknown): OfficialClanSnapshot {
  const record = asRecord(value, 'OfficialClanSnapshot');
  const badgeRaw = record.badgeUrls;
  let badgeUrls: Readonly<Record<string, string>> | undefined;
  if (badgeRaw !== undefined && badgeRaw !== null) {
    badgeUrls = Object.fromEntries(
      Object.entries(asRecord(badgeRaw, 'badgeUrls')).map(([key, entry]) => {
        if (typeof entry !== 'string') {
          throw new TypeError(`badgeUrls.${key} 必须是 string。`);
        }
        return [key, entry];
      }),
    );
  }
  return {
    tag: optionalString(record.tag),
    name: optionalString(record.name),
    type: optionalString(record.type),
    description: optionalString(record.description),
    clanLevel: optionalInt(record.clanLevel),
    badgeUrls,
    members: optionalInt(record.members),
    requiredTrophies: optionalInt(record.requiredTrophies),
    requiredTownHallLevel: decodeRequiredTownHallLevel(record),
    requiredBuilderBaseTrophies: optionalInt(record.requiredBuilderBaseTrophies),
    requiredLeagueTier: decodeClanLeagueTier(record.requiredLeagueTier),
    clanBuilderBasePoints: optionalInt(record.clanBuilderBasePoints),
    clanCapitalPoints: optionalInt(record.clanCapitalPoints),
    capitalLeague: decodeClanLeague(record.capitalLeague),
    warLeague: decodeClanLeague(record.warLeague),
    warWins: optionalInt(record.warWins),
    warLosses: optionalInt(record.warLosses),
    warTies: optionalInt(record.warTies),
    warWinStreak: optionalInt(record.warWinStreak),
    isWarLogPublic: optionalBool(record.isWarLogPublic),
    labels: decodeClanLabels(record.labels),
    clanCapital: decodeClanCapital(record.clanCapital),
    unrecognizedKeys: collectUnrecognizedKeys(record, KNOWN_KEYS),
  };
}

export function decodeOfficialClanSnapshotJson(text: string): OfficialClanSnapshot {
  return decodeOfficialClanSnapshot(JSON.parse(text) as unknown);
}
