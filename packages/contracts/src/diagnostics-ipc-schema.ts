import { z } from 'zod';

import {
  TOKEN_MAX_LENGTH,
  type DiagnosticsSnapshotPayload,
  type TokenSaveRequest,
  type TokenStatusPayload,
} from './diagnostics-ipc';
import { appAvailabilitySchema, villageStoreStatusDtoSchema } from './app-ipc-schema';
import { manualTrackerStatusSchema } from './manual-ipc-schema';
import { isSafeIpcDiagnosticText } from './safe-text';

const versionSchema = z.string().min(1).max(64);
const identifierSchema = z.string().min(1).max(128);
const generationSchema = z.number().int().nonnegative().safe();

export const tokenStorageStatusSchema = z.enum(['available', 'unavailable', 'decryptFailed']);

export const tokenStatusPayloadSchema: z.ZodType<TokenStatusPayload> = z
  .object({
    configured: z.boolean(),
    storage: tokenStorageStatusSchema,
    message: z
      .string()
      .max(200)
      .nullable()
      .refine((value) => value === null || isSafeIpcDiagnosticText(value), {
        message: 'Token 状态文案不安全',
      }),
  })
  .strict();

export const tokenSaveRequestSchema: z.ZodType<TokenSaveRequest> = z
  .object({
    token: z.string().min(1).max(TOKEN_MAX_LENGTH),
  })
  .strict();

export const tokenStatusRequestSchema = z.object({}).strict().optional();
export const tokenClearRequestSchema = z.object({}).strict().optional();
export const diagnosticsSnapshotRequestSchema = z.object({}).strict().optional();

const diagnosticsAppSchema = z
  .object({
    name: z.string().min(1).max(128),
    version: versionSchema,
  })
  .strict();

const diagnosticsRuntimeSchema = z
  .object({
    electron: versionSchema,
    node: versionSchema,
    chrome: versionSchema,
    platform: z.string().min(1).max(32),
    arch: z.string().min(1).max(32),
  })
  .strict();

const diagnosticsApplicationSchema = z
  .object({
    availability: appAvailabilitySchema,
    villageStatus: villageStoreStatusDtoSchema,
    generation: generationSchema,
    selectedVillageId: identifierSchema.nullable(),
    selectedVillageName: z.string().min(1).max(256).nullable(),
    canWrite: z.boolean(),
    hasPendingJournal: z.boolean(),
  })
  .strict();

const diagnosticsCatalogSchema = z
  .object({
    status: z.enum(['available', 'unavailable']),
    version: versionSchema.nullable(),
  })
  .strict();

const diagnosticsOfficialSchema = z
  .object({
    endpointAccess: z.literal('mainOnly'),
    authorization: z.literal('mainOnly'),
    credentialStorage: tokenStorageStatusSchema,
    rawResponseExposure: z.literal('notExposed'),
  })
  .strict();

const diagnosticsManualSchema = z
  .object({
    status: manualTrackerStatusSchema,
  })
  .strict();

export const diagnosticsSnapshotPayloadSchema: z.ZodType<DiagnosticsSnapshotPayload> = z
  .object({
    sessionId: identifierSchema,
    app: diagnosticsAppSchema,
    runtime: diagnosticsRuntimeSchema,
    application: diagnosticsApplicationSchema,
    catalog: diagnosticsCatalogSchema,
    official: diagnosticsOfficialSchema,
    manual: diagnosticsManualSchema,
    token: tokenStatusPayloadSchema,
  })
  .strict();

export function isDiagnosticsSnapshotPayload(value: unknown): value is DiagnosticsSnapshotPayload {
  return diagnosticsSnapshotPayloadSchema.safeParse(value).success;
}

export function isTokenStatusPayload(value: unknown): value is TokenStatusPayload {
  return tokenStatusPayloadSchema.safeParse(value).success;
}
