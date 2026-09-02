/** 官方 API 状态族 wire DTO（dto-mapping.md M-5）。 */

export const OFFICIAL_ENDPOINT_FAILURE_KINDS = [
  'missingCredentials',
  'unauthorized',
  'accessDenied',
  'notFound',
  'rateLimited',
  'serverError',
  'timeout',
  'network',
  'malformedResponse',
  'cancelled',
] as const;

export type OfficialEndpointFailureKindWire =
  (typeof OFFICIAL_ENDPOINT_FAILURE_KINDS)[number];

export const OFFICIAL_API_REQUEST_STATUSES = [
  'never',
  'loading',
  'success',
  'failed',
  'skipped',
] as const;

export type OfficialAPIRequestStatusWire = (typeof OFFICIAL_API_REQUEST_STATUSES)[number];

export type EndpointStateWire<Snapshot> = {
  readonly status: OfficialAPIRequestStatusWire;
  readonly clanTag?: string;
  readonly playerTag?: string;
  readonly fetchedAt?: number;
  readonly lastAttemptAt?: number;
  readonly lastErrorReason?: string;
  readonly lastHTTPStatus?: number;
  readonly failureKind?: OfficialEndpointFailureKindWire;
  readonly parserVersion: string;
  readonly lastGood?: Snapshot;
  readonly unrecognizedKeys: readonly string[];
};

export type OfficialPaginatedPageWire<Item> = {
  readonly items: readonly Item[];
  readonly before?: string;
  readonly after?: string;
};

export type WarLogPageWire = {
  readonly page: OfficialPaginatedPageWire<WarLogEntryWire>;
};

export type CapitalRaidPageWire = {
  readonly page: OfficialPaginatedPageWire<CapitalRaidSeasonWire>;
};

export type WarLogEntryWire = {
  readonly result?: string;
  readonly endTime?: string;
  readonly teamSize?: number;
  readonly attacksPerMember?: number;
  readonly battleModifier?: string;
  readonly clan?: ClanWarParticipantWire;
  readonly opponent?: ClanWarParticipantWire;
};

export type ClanWarParticipantWire = {
  readonly tag?: string;
  readonly name?: string;
  readonly badgeUrls?: Readonly<Record<string, string>>;
  readonly clanLevel?: number;
  readonly attacks?: number;
  readonly stars?: number;
  readonly destructionPercentage?: number;
  readonly members?: readonly ClanWarMemberWire[];
};

export type ClanWarMemberWire = {
  readonly tag?: string;
  readonly name?: string;
  readonly mapPosition?: number;
  readonly townhallLevel?: number;
  readonly attacks?: readonly ClanWarAttackWire[];
  readonly opponentAttacks?: number;
  readonly bestOpponentAttack?: ClanWarAttackWire;
};

export type ClanWarAttackWire = {
  readonly order?: number;
  readonly attackerTag?: string;
  readonly defenderTag?: string;
  readonly stars?: number;
  readonly destructionPercentage?: number;
  readonly duration?: number;
};

export type CapitalRaidSeasonWire = {
  readonly state?: string;
  readonly startTime?: string;
  readonly endTime?: string;
  readonly capitalTotalLoot?: number;
  readonly raidsCompleted?: number;
  readonly totalAttacks?: number;
  readonly enemyDistrictsDestroyed?: number;
  readonly offensiveReward?: number;
  readonly defensiveReward?: number;
  readonly members?: readonly CapitalRaidSeasonMemberWire[];
  readonly attackLog?: readonly CapitalRaidAttackLogEntryWire[];
  readonly defenseLog?: readonly CapitalRaidDefenseLogEntryWire[];
};

export type CapitalRaidSeasonMemberWire = {
  readonly tag?: string;
  readonly name?: string;
  readonly capitalResourcesLooted?: number;
  readonly attacks?: number;
};

export type CapitalRaidClanInfoWire = {
  readonly tag?: string;
  readonly name?: string;
  readonly level?: number;
  readonly badgeUrls?: Readonly<Record<string, string>>;
};

export type CapitalRaidDistrictWire = {
  readonly name?: string;
  readonly id?: number;
  readonly districtHallLevel?: number;
  readonly stars?: number;
  readonly destructionPercent?: number;
  readonly attackCount?: number;
  readonly totalLooted?: number;
};

export type CapitalRaidAttackLogEntryWire = {
  readonly defender?: CapitalRaidClanInfoWire;
  readonly attackCount?: number;
  readonly districtCount?: number;
  readonly districtsDestroyed?: number;
  readonly districts?: readonly CapitalRaidDistrictWire[];
};

export type CapitalRaidDefenseLogEntryWire = {
  readonly attacker?: CapitalRaidClanInfoWire;
  readonly attackCount?: number;
  readonly districtCount?: number;
  readonly districtsDestroyed?: number;
  readonly districts?: readonly CapitalRaidDistrictWire[];
};

export type ClanWire = {
  readonly tag?: string;
  readonly name?: string;
  readonly type?: string;
  readonly description?: string;
  readonly clanLevel?: number;
  readonly badgeUrls?: Readonly<Record<string, string>>;
  readonly members?: number;
  readonly requiredTrophies?: number;
  readonly requiredTownHallLevel?: number;
  readonly requiredBuilderBaseTrophies?: number;
  readonly requiredLeagueTier?: ClanLeagueTierWire;
  readonly clanBuilderBasePoints?: number;
  readonly clanCapitalPoints?: number;
  readonly capitalLeague?: ClanLeagueWire;
  readonly warLeague?: ClanLeagueWire;
  readonly warWins?: number;
  readonly warLosses?: number;
  readonly warTies?: number;
  readonly warWinStreak?: number;
  readonly isWarLogPublic?: boolean;
  readonly labels?: readonly ClanLabelWire[];
  readonly clanCapital?: ClanCapitalWire;
  readonly unrecognizedKeys: readonly string[];
};

export type ClanCapitalWire = {
  readonly capitalHallLevel?: number;
};

export type ClanLeagueWire = {
  readonly id?: number;
  readonly name?: string;
};

export type ClanLeagueTierWire = {
  readonly id?: number;
  readonly name?: string;
  readonly iconUrls?: Readonly<Record<string, string>>;
};

export type ClanLabelWire = {
  readonly id?: number;
  readonly name?: string;
};

export type ClanWarWire = {
  readonly state?: string;
  readonly teamSize?: number;
  readonly attacksPerMember?: number;
  readonly preparationStartTime?: string;
  readonly startTime?: string;
  readonly endTime?: string;
  readonly warStartTime?: string;
  readonly battleModifier?: string;
  readonly clan?: ClanWarParticipantWire;
  readonly opponent?: ClanWarParticipantWire;
  readonly unrecognizedKeys: readonly string[];
};

export type StateStoreFileV1<State> = readonly Record<string, State>[];
