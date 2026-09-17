/**
 * Official war / war-log / capital-raid wire Zod schema：preload IPC 边界运行时校验。
 */

import { z } from 'zod';

import type { CapitalRaidPageWire, ClanWarWire, WarLogPageWire } from './official-wire';

const wireString = z.string().max(256);
const optionalWireString = wireString.optional();
const optionalInt = z.number().int().safe().optional();
const optionalFinite = z.number().finite().optional();
const unrecognizedKeysSchema = z.array(z.string().max(256)).max(500);

const badgeUrlsSchema = z.record(z.string().max(64), wireString);

const clanWarAttackWireSchema = z
  .object({
    order: optionalInt,
    attackerTag: z.string().max(32).optional(),
    defenderTag: z.string().max(32).optional(),
    stars: optionalInt,
    destructionPercentage: optionalFinite,
    duration: optionalInt,
  })
  .strict();

const clanWarMemberWireSchema = z
  .object({
    tag: z.string().max(32).optional(),
    name: z.string().max(128).optional(),
    mapPosition: optionalInt,
    townhallLevel: optionalInt,
    attacks: z.array(clanWarAttackWireSchema).max(100).optional(),
    opponentAttacks: optionalInt,
    bestOpponentAttack: clanWarAttackWireSchema.optional(),
  })
  .strict();

export const clanWarParticipantWireSchema = z
  .object({
    tag: z.string().max(32).optional(),
    name: z.string().max(128).optional(),
    badgeUrls: badgeUrlsSchema.optional(),
    clanLevel: optionalInt,
    attacks: optionalInt,
    stars: optionalInt,
    destructionPercentage: optionalFinite,
    members: z.array(clanWarMemberWireSchema).max(100).optional(),
  })
  .strict();

export const clanWarWireSchema: z.ZodType<ClanWarWire> = z
  .object({
    state: z.string().max(64).optional(),
    teamSize: optionalInt,
    attacksPerMember: optionalInt,
    preparationStartTime: optionalWireString,
    startTime: optionalWireString,
    endTime: optionalWireString,
    warStartTime: optionalWireString,
    battleModifier: z.string().max(64).optional(),
    clan: clanWarParticipantWireSchema.optional(),
    opponent: clanWarParticipantWireSchema.optional(),
    unrecognizedKeys: unrecognizedKeysSchema,
  })
  .strict();

function officialPaginatedPageSchema<Item extends z.ZodTypeAny>(itemSchema: Item) {
  return z
    .object({
      items: z.array(itemSchema).max(500),
      before: optionalWireString,
      after: optionalWireString,
    })
    .strict();
}

export const warLogEntryWireSchema = z
  .object({
    result: z.string().max(64).optional(),
    endTime: optionalWireString,
    teamSize: optionalInt,
    attacksPerMember: optionalInt,
    battleModifier: z.string().max(64).optional(),
    clan: clanWarParticipantWireSchema.optional(),
    opponent: clanWarParticipantWireSchema.optional(),
  })
  .strict();

export const warLogPageWireSchema: z.ZodType<WarLogPageWire> = z
  .object({
    page: officialPaginatedPageSchema(warLogEntryWireSchema),
    unrecognizedKeys: unrecognizedKeysSchema,
  })
  .strict();

const capitalRaidSeasonMemberWireSchema = z
  .object({
    tag: z.string().max(32).optional(),
    name: z.string().max(128).optional(),
    capitalResourcesLooted: optionalInt,
    attacks: optionalInt,
  })
  .strict();

const capitalRaidClanInfoWireSchema = z
  .object({
    tag: z.string().max(32).optional(),
    name: z.string().max(128).optional(),
    level: optionalInt,
    badgeUrls: badgeUrlsSchema.optional(),
  })
  .strict();

const capitalRaidDistrictWireSchema = z
  .object({
    name: z.string().max(128).optional(),
    id: optionalInt,
    districtHallLevel: optionalInt,
    stars: optionalInt,
    destructionPercent: optionalFinite,
    attackCount: optionalInt,
    totalLooted: optionalInt,
  })
  .strict();

const capitalRaidAttackLogEntryWireSchema = z
  .object({
    defender: capitalRaidClanInfoWireSchema.optional(),
    attackCount: optionalInt,
    districtCount: optionalInt,
    districtsDestroyed: optionalInt,
    districts: z.array(capitalRaidDistrictWireSchema).max(100).optional(),
  })
  .strict();

const capitalRaidDefenseLogEntryWireSchema = z
  .object({
    attacker: capitalRaidClanInfoWireSchema.optional(),
    attackCount: optionalInt,
    districtCount: optionalInt,
    districtsDestroyed: optionalInt,
    districts: z.array(capitalRaidDistrictWireSchema).max(100).optional(),
  })
  .strict();

export const capitalRaidSeasonWireSchema = z
  .object({
    state: z.string().max(64).optional(),
    startTime: optionalWireString,
    endTime: optionalWireString,
    capitalTotalLoot: optionalInt,
    raidsCompleted: optionalInt,
    totalAttacks: optionalInt,
    enemyDistrictsDestroyed: optionalInt,
    offensiveReward: optionalInt,
    defensiveReward: optionalInt,
    members: z.array(capitalRaidSeasonMemberWireSchema).max(100).optional(),
    attackLog: z.array(capitalRaidAttackLogEntryWireSchema).max(500).optional(),
    defenseLog: z.array(capitalRaidDefenseLogEntryWireSchema).max(500).optional(),
  })
  .strict();

export const capitalRaidPageWireSchema: z.ZodType<CapitalRaidPageWire> = z
  .object({
    page: officialPaginatedPageSchema(capitalRaidSeasonWireSchema),
    unrecognizedKeys: unrecognizedKeysSchema,
  })
  .strict();
