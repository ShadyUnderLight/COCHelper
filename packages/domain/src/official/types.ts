import { parserVersions } from '@coc-helper/wire';

export type OfficialAPIRequestStatus = 'never' | 'loading' | 'success' | 'failed' | 'skipped';

export type OfficialAPIDisplayStatus =
  'never' | 'loading' | 'success' | 'stale' | 'failed' | 'skipped';

export type OfficialEndpointFailureKind =
  | 'missingCredentials'
  | 'unauthorized'
  | 'accessDenied'
  | 'notFound'
  | 'rateLimited'
  | 'serverError'
  | 'timeout'
  | 'network'
  | 'malformedResponse'
  | 'cancelled';

export const OFFICIAL_PARSER_VERSIONS = {
  playerSnapshot: parserVersions.playerSnapshot,
  clanSnapshot: parserVersions.clanSnapshot,
  clanWar: parserVersions.clanWar,
  clanWarLog: parserVersions.clanWarLog,
  clanCapital: parserVersions.clanCapital,
} as const;

export const OFFICIAL_STALE_THRESHOLD_MS = 24 * 3600 * 1000;

export type UnrecognizedKeysProviding = {
  readonly unrecognizedKeys: readonly string[];
};

export type EndpointParserVersioning = {
  readonly currentParserVersion: string;
};
