import { OFFICIAL_PARSER_VERSIONS } from '../types';
import { optionalInt, optionalString } from '../json-decode';
import { decodeOptionalParticipant } from './war-shared';
import {
  decodeOfficialPaginatedPage,
  type OfficialPaginatedPage,
} from './paginated-page';

export type OfficialWarLogEntry = {
  readonly result: string | undefined;
  readonly endTime: string | undefined;
  readonly teamSize: number | undefined;
  readonly attacksPerMember: number | undefined;
  readonly battleModifier: string | undefined;
  readonly clan: ReturnType<typeof decodeOptionalParticipant>;
  readonly opponent: ReturnType<typeof decodeOptionalParticipant>;
};

export const WAR_LOG_PARSER_VERSION = OFFICIAL_PARSER_VERSIONS.clanWarLog;

export type OfficialWarLogPage = {
  readonly page: OfficialPaginatedPage<OfficialWarLogEntry>;
  readonly unrecognizedKeys: readonly string[];
};

export function decodeOfficialWarLogEntry(value: unknown): OfficialWarLogEntry {
  const record = value as Record<string, unknown>;
  return {
    result: optionalString(record.result),
    endTime: optionalString(record.endTime),
    teamSize: optionalInt(record.teamSize),
    attacksPerMember: optionalInt(record.attacksPerMember),
    battleModifier: optionalString(record.battleModifier),
    clan: decodeOptionalParticipant(record.clan),
    opponent: decodeOptionalParticipant(record.opponent),
  };
}

export function decodeOfficialWarLogPage(value: unknown): OfficialWarLogPage {
  return {
    page: decodeOfficialPaginatedPage(value, decodeOfficialWarLogEntry),
    unrecognizedKeys: [],
  };
}

export function decodeOfficialWarLogPageJson(text: string): OfficialWarLogPage {
  return decodeOfficialWarLogPage(JSON.parse(text) as unknown);
}

export function warLogPageItems(page: OfficialWarLogPage): readonly OfficialWarLogEntry[] {
  return page.page.items;
}

export function warLogPageAfter(page: OfficialWarLogPage): string | undefined {
  return page.page.after;
}

export function warLogPageBefore(page: OfficialWarLogPage): string | undefined {
  return page.page.before;
}

export function warLogPageUnrecognizedKeys(_page: OfficialWarLogPage): readonly string[] {
  return [];
}
