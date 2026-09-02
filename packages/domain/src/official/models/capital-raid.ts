import { OFFICIAL_PARSER_VERSIONS } from '../types';
import {
  asRecord,
  optionalDouble,
  optionalInt,
  optionalString,
  stableEqual,
} from '../json-decode';
import {
  decodeOfficialPaginatedPage,
  type OfficialPaginatedPage,
} from './paginated-page';

export type CapitalRaidSeasonMember = {
  readonly tag: string | undefined;
  readonly name: string | undefined;
  readonly capitalResourcesLooted: number | undefined;
  readonly attacks: number | undefined;
};

export type CapitalRaidClanInfo = {
  readonly tag: string | undefined;
  readonly name: string | undefined;
  readonly level: number | undefined;
  readonly badgeUrls: Readonly<Record<string, string>> | undefined;
};

export type CapitalRaidDistrict = {
  readonly name: string | undefined;
  readonly id: number | undefined;
  readonly districtHallLevel: number | undefined;
  readonly stars: number | undefined;
  readonly destructionPercent: number | undefined;
  readonly attackCount: number | undefined;
  readonly totalLooted: number | undefined;
};

export type CapitalRaidAttackLogEntry = {
  readonly defender: CapitalRaidClanInfo | undefined;
  readonly attackCount: number | undefined;
  readonly districtCount: number | undefined;
  readonly districtsDestroyed: number | undefined;
  readonly districts: readonly CapitalRaidDistrict[] | undefined;
};

export type CapitalRaidDefenseLogEntry = {
  readonly attacker: CapitalRaidClanInfo | undefined;
  readonly attackCount: number | undefined;
  readonly districtCount: number | undefined;
  readonly districtsDestroyed: number | undefined;
  readonly districts: readonly CapitalRaidDistrict[] | undefined;
};

export type OfficialCapitalRaidSeason = {
  readonly state: string | undefined;
  readonly startTime: string | undefined;
  readonly endTime: string | undefined;
  readonly capitalTotalLoot: number | undefined;
  readonly raidsCompleted: number | undefined;
  readonly totalAttacks: number | undefined;
  readonly enemyDistrictsDestroyed: number | undefined;
  readonly offensiveReward: number | undefined;
  readonly defensiveReward: number | undefined;
  readonly members: readonly CapitalRaidSeasonMember[] | undefined;
  readonly attackLog: readonly CapitalRaidAttackLogEntry[] | undefined;
  readonly defenseLog: readonly CapitalRaidDefenseLogEntry[] | undefined;
};

export const CAPITAL_RAID_PARSER_VERSION = OFFICIAL_PARSER_VERSIONS.clanCapital;

export type OfficialCapitalRaidPage = {
  readonly page: OfficialPaginatedPage<OfficialCapitalRaidSeason>;
  readonly unrecognizedKeys: readonly string[];
};

function decodeBadgeUrls(value: unknown): Readonly<Record<string, string>> | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  return Object.fromEntries(
    Object.entries(asRecord(value, 'badgeUrls')).map(([key, entry]) => {
      if (typeof entry !== 'string') {
        throw new TypeError(`badgeUrls.${key} 必须是 string。`);
      }
      return [key, entry];
    }),
  );
}

function decodeCapitalRaidClanInfo(value: unknown): CapitalRaidClanInfo | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  const record = asRecord(value, 'CapitalRaidClanInfo');
  return {
    tag: optionalString(record.tag),
    name: optionalString(record.name),
    level: optionalInt(record.level),
    badgeUrls: decodeBadgeUrls(record.badgeUrls),
  };
}

function decodeCapitalRaidDistrict(value: unknown): CapitalRaidDistrict {
  const record = asRecord(value, 'CapitalRaidDistrict');
  return {
    name: optionalString(record.name),
    id: optionalInt(record.id),
    districtHallLevel: optionalInt(record.districtHallLevel),
    stars: optionalInt(record.stars),
    destructionPercent: optionalDouble(record.destructionPercent),
    attackCount: optionalInt(record.attackCount),
    totalLooted: optionalInt(record.totalLooted),
  };
}

function decodeCapitalRaidAttackLogEntry(value: unknown): CapitalRaidAttackLogEntry {
  const record = asRecord(value, 'CapitalRaidAttackLogEntry');
  const districtsRaw = record.districts;
  let districts: readonly CapitalRaidDistrict[] | undefined;
  if (districtsRaw !== undefined && districtsRaw !== null) {
    if (!Array.isArray(districtsRaw)) {
      throw new TypeError('districts 必须是 array 或 null。');
    }
    districts = districtsRaw.map(decodeCapitalRaidDistrict);
  }
  return {
    defender: decodeCapitalRaidClanInfo(record.defender),
    attackCount: optionalInt(record.attackCount),
    districtCount: optionalInt(record.districtCount),
    districtsDestroyed: optionalInt(record.districtsDestroyed),
    districts,
  };
}

function decodeCapitalRaidDefenseLogEntry(value: unknown): CapitalRaidDefenseLogEntry {
  const record = asRecord(value, 'CapitalRaidDefenseLogEntry');
  const districtsRaw = record.districts;
  let districts: readonly CapitalRaidDistrict[] | undefined;
  if (districtsRaw !== undefined && districtsRaw !== null) {
    if (!Array.isArray(districtsRaw)) {
      throw new TypeError('districts 必须是 array 或 null。');
    }
    districts = districtsRaw.map(decodeCapitalRaidDistrict);
  }
  return {
    attacker: decodeCapitalRaidClanInfo(record.attacker),
    attackCount: optionalInt(record.attackCount),
    districtCount: optionalInt(record.districtCount),
    districtsDestroyed: optionalInt(record.districtsDestroyed),
    districts,
  };
}

function decodeCapitalRaidSeasonMember(value: unknown): CapitalRaidSeasonMember {
  const record = asRecord(value, 'CapitalRaidSeasonMember');
  return {
    tag: optionalString(record.tag),
    name: optionalString(record.name),
    capitalResourcesLooted: optionalInt(record.capitalResourcesLooted),
    attacks: optionalInt(record.attacks),
  };
}

export function decodeOfficialCapitalRaidSeason(value: unknown): OfficialCapitalRaidSeason {
  const record = asRecord(value, 'OfficialCapitalRaidSeason');
  const decodeArray = <T>(
    raw: unknown,
    decode: (entry: unknown) => T,
    label: string,
  ): readonly T[] | undefined => {
    if (raw === undefined || raw === null) {
      return undefined;
    }
    if (!Array.isArray(raw)) {
      throw new TypeError(`${label} 必须是 array 或 null。`);
    }
    return raw.map(decode);
  };
  return {
    state: optionalString(record.state),
    startTime: optionalString(record.startTime),
    endTime: optionalString(record.endTime),
    capitalTotalLoot: optionalInt(record.capitalTotalLoot),
    raidsCompleted: optionalInt(record.raidsCompleted),
    totalAttacks: optionalInt(record.totalAttacks),
    enemyDistrictsDestroyed: optionalInt(record.enemyDistrictsDestroyed),
    offensiveReward: optionalInt(record.offensiveReward),
    defensiveReward: optionalInt(record.defensiveReward),
    members: decodeArray(record.members, decodeCapitalRaidSeasonMember, 'members'),
    attackLog: decodeArray(record.attackLog, decodeCapitalRaidAttackLogEntry, 'attackLog'),
    defenseLog: decodeArray(record.defenseLog, decodeCapitalRaidDefenseLogEntry, 'defenseLog'),
  };
}

export function decodeOfficialCapitalRaidPage(value: unknown): OfficialCapitalRaidPage {
  return {
    page: decodeOfficialPaginatedPage(value, decodeOfficialCapitalRaidSeason),
    unrecognizedKeys: [],
  };
}

export function decodeOfficialCapitalRaidPageJson(text: string): OfficialCapitalRaidPage {
  return decodeOfficialCapitalRaidPage(JSON.parse(text) as unknown);
}

export function capitalRaidPageItems(
  page: OfficialCapitalRaidPage,
): readonly OfficialCapitalRaidSeason[] {
  return page.page.items;
}

export function capitalRaidPageAfter(page: OfficialCapitalRaidPage): string | undefined {
  return page.page.after;
}

export function capitalRaidPageBefore(page: OfficialCapitalRaidPage): string | undefined {
  return page.page.before;
}

export function capitalRaidPageUnrecognizedKeys(_page: OfficialCapitalRaidPage): readonly string[] {
  return [];
}

/** 旧版完整内容身份键（#199，迁移参照）。 */
export function capitalRaidSeasonStableIdentityKey(season: OfficialCapitalRaidSeason): string {
  const sorted = stableStringifySorted(season);
  return `season:${bytesToBase64(new TextEncoder().encode(sorted))}`;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function stableStringifySorted(value: unknown): string {
  if (value === null || typeof value !== 'object') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((entry) => stableStringifySorted(entry)).join(',')}]`;
  }
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record).sort();
  return `{${keys.map((key) => `${JSON.stringify(key)}:${stableStringifySorted(record[key])}`).join(',')}}`;
}

export function capitalRaidSeasonsEqual(
  left: OfficialCapitalRaidSeason,
  right: OfficialCapitalRaidSeason,
): boolean {
  return stableEqual(left, right);
}
