/**
 * Official IPC zod schema：Main 入参与 preload 出参/event 共用。
 */

import { z } from 'zod';

import {
  OFFICIAL_API_REQUEST_STATUSES,
  OFFICIAL_ENDPOINT_FAILURE_KINDS,
} from './official-wire';
import type {
  ApiRefreshPayload,
  CapitalRaidLoadMorePayload,
  CapitalRaidStatePayload,
  CapitalRaidStateRequest,
  ClanStatePayload,
  ClanStateRequest,
  ClanWarStatePayload,
  ClanWarStateRequest,
  OfficialEndpointKind,
  OfficialEndpointStateDto,
  OperationProgressPayload,
  PlayerStatePayload,
  PlayerStateRequest,
  WarLogLoadMorePayload,
  WarLogStatePayload,
  WarLogStateRequest,
} from './official-ipc';
import { OFFICIAL_ENDPOINT_KINDS } from './official-ipc';
import { REQUEST_ID_MAX_LENGTH } from './ipc';

const generationSchema = z.number().int().nonnegative().safe();
const villageIdSchema = z.string().min(1).max(128);
const clanTagSchema = z.string().min(1).max(32);
const requestIdSchema = z
  .string()
  .min(1)
  .max(REQUEST_ID_MAX_LENGTH)
  .regex(/^[\x21-\x7e]+$/);

const endpointKindSchema = z.enum(OFFICIAL_ENDPOINT_KINDS);

const officialEndpointStateDtoSchema: z.ZodType<OfficialEndpointStateDto> = z
  .object({
    status: z.enum(OFFICIAL_API_REQUEST_STATUSES),
    clanTag: z.string().max(32).optional(),
    playerTag: z.string().max(32).optional(),
    fetchedAt: z.number().finite().optional(),
    lastAttemptAt: z.number().finite().optional(),
    lastErrorReason: z.string().max(500).optional(),
    lastHTTPStatus: z.number().int().safe().optional(),
    failureKind: z.enum(OFFICIAL_ENDPOINT_FAILURE_KINDS).optional(),
    parserVersion: z.string().min(1).max(64),
    lastGood: z.unknown().optional(),
    unrecognizedKeys: z.array(z.string().max(256)).max(500),
    hasMore: z.boolean().optional(),
  })
  .strict();

export const playerStateRequestSchema: z.ZodType<PlayerStateRequest> = z
  .object({
    villageId: villageIdSchema,
  })
  .strict();

export const playerStatePayloadSchema: z.ZodType<PlayerStatePayload> = z
  .object({
    generation: generationSchema,
    villageId: villageIdSchema,
    playerTag: z.string().max(32).nullable(),
    state: officialEndpointStateDtoSchema.nullable(),
  })
  .strict();

export const clanStateRequestSchema: z.ZodType<ClanStateRequest> = z
  .object({
    clanTag: clanTagSchema,
  })
  .strict();

export const clanStatePayloadSchema: z.ZodType<ClanStatePayload> = z
  .object({
    generation: generationSchema,
    clanTag: clanTagSchema,
    state: officialEndpointStateDtoSchema.nullable(),
  })
  .strict();

export const clanWarStateRequestSchema: z.ZodType<ClanWarStateRequest> = z
  .object({
    clanTag: clanTagSchema,
  })
  .strict();

export const clanWarStatePayloadSchema: z.ZodType<ClanWarStatePayload> = z
  .object({
    generation: generationSchema,
    clanTag: clanTagSchema,
    state: officialEndpointStateDtoSchema.nullable(),
  })
  .strict();

export const warLogStateRequestSchema: z.ZodType<WarLogStateRequest> = z
  .object({
    clanTag: clanTagSchema,
  })
  .strict();

export const warLogStatePayloadSchema: z.ZodType<WarLogStatePayload> = z
  .object({
    generation: generationSchema,
    clanTag: clanTagSchema,
    state: officialEndpointStateDtoSchema.nullable(),
  })
  .strict();

export const capitalRaidStateRequestSchema: z.ZodType<CapitalRaidStateRequest> = z
  .object({
    clanTag: clanTagSchema,
  })
  .strict();

export const capitalRaidStatePayloadSchema: z.ZodType<CapitalRaidStatePayload> = z
  .object({
    generation: generationSchema,
    clanTag: clanTagSchema,
    state: officialEndpointStateDtoSchema.nullable(),
  })
  .strict();

export const apiRefreshRequestSchema = z
  .object({
    requestId: requestIdSchema,
    endpoints: z.array(endpointKindSchema).min(1).max(OFFICIAL_ENDPOINT_KINDS.length),
    villageId: villageIdSchema.nullable().optional(),
    clanTag: clanTagSchema.nullable().optional(),
  })
  .strict();

export const apiRefreshPayloadSchema: z.ZodType<ApiRefreshPayload> = z
  .object({
    generation: generationSchema,
    results: z.array(
      z
        .object({
          endpoint: endpointKindSchema,
          tag: z.string().max(32).nullable(),
          status: z.enum(OFFICIAL_API_REQUEST_STATUSES),
          failureKind: z.enum(OFFICIAL_ENDPOINT_FAILURE_KINDS).optional(),
          skippedOverwrite: z.boolean().optional(),
        })
        .strict(),
    ),
  })
  .strict();

export const warLogLoadMoreRequestSchema = z
  .object({
    requestId: requestIdSchema,
    clanTag: clanTagSchema,
  })
  .strict();

export const warLogLoadMorePayloadSchema: z.ZodType<WarLogLoadMorePayload> = z
  .object({
    generation: generationSchema,
    clanTag: clanTagSchema,
    state: officialEndpointStateDtoSchema,
  })
  .strict();

export const capitalRaidLoadMoreRequestSchema = z
  .object({
    requestId: requestIdSchema,
    clanTag: clanTagSchema,
  })
  .strict();

export const capitalRaidLoadMorePayloadSchema: z.ZodType<CapitalRaidLoadMorePayload> = z
  .object({
    generation: generationSchema,
    clanTag: clanTagSchema,
    state: officialEndpointStateDtoSchema,
  })
  .strict();

export const operationProgressPayloadSchema: z.ZodType<OperationProgressPayload> = z
  .object({
    operationId: z.string().min(1).max(REQUEST_ID_MAX_LENGTH),
    phase: z.enum([
      'started',
      'endpointStarted',
      'endpointFinished',
      'completed',
      'cancelled',
      'failed',
    ]),
    generation: generationSchema,
    endpoint: endpointKindSchema.optional(),
    tag: z.string().max(32).nullable().optional(),
    status: z.enum(OFFICIAL_API_REQUEST_STATUSES).optional(),
    message: z.string().max(500).nullable().optional(),
  })
  .strict();

export function isPlayerStatePayload(value: unknown): value is PlayerStatePayload {
  return playerStatePayloadSchema.safeParse(value).success;
}

export function isClanStatePayload(value: unknown): value is ClanStatePayload {
  return clanStatePayloadSchema.safeParse(value).success;
}

export function isClanWarStatePayload(value: unknown): value is ClanWarStatePayload {
  return clanWarStatePayloadSchema.safeParse(value).success;
}

export function isWarLogStatePayload(value: unknown): value is WarLogStatePayload {
  return warLogStatePayloadSchema.safeParse(value).success;
}

export function isCapitalRaidStatePayload(value: unknown): value is CapitalRaidStatePayload {
  return capitalRaidStatePayloadSchema.safeParse(value).success;
}

export function isApiRefreshPayload(value: unknown): value is ApiRefreshPayload {
  return apiRefreshPayloadSchema.safeParse(value).success;
}

export function isWarLogLoadMorePayload(value: unknown): value is WarLogLoadMorePayload {
  return warLogLoadMorePayloadSchema.safeParse(value).success;
}

export function isCapitalRaidLoadMorePayload(value: unknown): value is CapitalRaidLoadMorePayload {
  return capitalRaidLoadMorePayloadSchema.safeParse(value).success;
}

export function isOperationProgressPayload(value: unknown): value is OperationProgressPayload {
  return operationProgressPayloadSchema.safeParse(value).success;
}

export type { OfficialEndpointKind };
