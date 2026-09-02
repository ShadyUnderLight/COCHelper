import { OFFICIAL_PARSER_VERSIONS } from '../types';
import {
  asRecord,
  collectUnrecognizedKeys,
  optionalInt,
  optionalString,
} from '../json-decode';
import { decodeOptionalParticipant } from './war-shared';

const KNOWN_KEYS = new Set([
  'state',
  'teamSize',
  'attacksPerMember',
  'preparationStartTime',
  'startTime',
  'endTime',
  'warStartTime',
  'battleModifier',
  'clan',
  'opponent',
  'unrecognizedKeys',
]);

export type OfficialClanWarSnapshot = {
  readonly state: string | undefined;
  readonly teamSize: number | undefined;
  readonly attacksPerMember: number | undefined;
  readonly preparationStartTime: string | undefined;
  readonly startTime: string | undefined;
  readonly endTime: string | undefined;
  readonly warStartTime: string | undefined;
  readonly battleModifier: string | undefined;
  readonly clan: ReturnType<typeof decodeOptionalParticipant>;
  readonly opponent: ReturnType<typeof decodeOptionalParticipant>;
  readonly unrecognizedKeys: readonly string[];
};

export const CLAN_WAR_PARSER_VERSION = OFFICIAL_PARSER_VERSIONS.clanWar;

export function decodeOfficialClanWarSnapshot(value: unknown): OfficialClanWarSnapshot {
  const record = asRecord(value, 'OfficialClanWarSnapshot');
  return {
    state: optionalString(record.state),
    teamSize: optionalInt(record.teamSize),
    attacksPerMember: optionalInt(record.attacksPerMember),
    preparationStartTime: optionalString(record.preparationStartTime),
    startTime: optionalString(record.startTime),
    endTime: optionalString(record.endTime),
    warStartTime: optionalString(record.warStartTime),
    battleModifier: optionalString(record.battleModifier),
    clan: decodeOptionalParticipant(record.clan),
    opponent: decodeOptionalParticipant(record.opponent),
    unrecognizedKeys: collectUnrecognizedKeys(record, KNOWN_KEYS),
  };
}

export function decodeOfficialClanWarSnapshotJson(text: string): OfficialClanWarSnapshot {
  return decodeOfficialClanWarSnapshot(JSON.parse(text) as unknown);
}

/** battleModifier 的稳定中文映射（对齐 BattleModifierText.swift）。 */
export function battleModifierLocalizedText(raw: string | undefined): string | undefined {
  if (raw === undefined) {
    return undefined;
  }
  const normalized = raw.trim();
  if (normalized.length === 0) {
    return undefined;
  }
  switch (normalized) {
    case 'none':
      return undefined;
    case 'hardMode':
      return '锦标赛模式';
    case 'minusOne':
      return '传奇杯1';
    case 'minusTwo':
      return '传奇杯2';
    case 'minusThree':
      return '传奇杯3';
    default:
      return normalized;
  }
}
