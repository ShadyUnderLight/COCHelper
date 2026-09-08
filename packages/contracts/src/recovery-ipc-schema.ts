/**
 * #276-S5 Recovery IPC 共享 zod schema。
 */

import { z } from 'zod';

import { villageStoreStatusDtoSchema } from './app-ipc-schema';
import type {
  RecoveryExportPayload,
  RecoveryRecoverJournalPayload,
  RecoveryRecoverJournalRequest,
  RecoveryResetPayload,
  RecoveryResetRequest,
  RecoveryRestorePayload,
  RecoveryRestoreRequest,
  RecoveryRestoreSavedRequest,
  RecoveryStatusPayload,
} from './recovery-ipc';

/** 精确对应 PERSISTENCE_MAX_FILE_BYTES=32MiB 的标准 base64 字符上限：ceil(n/3)*4。 */
export const RECOVERY_DATA_BASE64_MAX_LENGTH = 44_739_244;

const generationSchema = z.number().int().nonnegative().safe();
const sessionIdSchema = z.string().min(1).max(128);
const noticeSchema = z.string().min(1).max(500);

export const recoveryStatusPayloadSchema: z.ZodType<RecoveryStatusPayload> = z
  .object({
    generation: generationSchema,
    sessionId: sessionIdSchema,
    recoveryRequired: z.boolean(),
    villageStatus: villageStoreStatusDtoSchema,
    villageError: z.string().max(500).nullable(),
    canWrite: z.boolean(),
    hasPendingJournal: z.boolean(),
    canExport: z.boolean(),
    canRestoreSavedCopy: z.boolean(),
    notice: z.string().max(500).nullable(),
  })
  .strict();

export const recoveryExportPayloadSchema: z.ZodType<RecoveryExportPayload> = z
  .object({
    generation: generationSchema,
    sessionId: sessionIdSchema,
    dataBase64: z.string().max(RECOVERY_DATA_BASE64_MAX_LENGTH).nullable(),
  })
  .strict();

export const recoveryRestoreRequestSchema: z.ZodType<RecoveryRestoreRequest> = z
  .object({
    expectedGeneration: generationSchema,
    dataBase64: z.string().min(1).max(RECOVERY_DATA_BASE64_MAX_LENGTH),
  })
  .strict();

export const recoveryRestoreSavedRequestSchema: z.ZodType<RecoveryRestoreSavedRequest> = z
  .object({
    expectedGeneration: generationSchema,
  })
  .strict();

export const recoveryResetRequestSchema: z.ZodType<RecoveryResetRequest> = z
  .object({
    expectedGeneration: generationSchema,
  })
  .strict();

export const recoveryRecoverJournalRequestSchema: z.ZodType<RecoveryRecoverJournalRequest> = z
  .object({
    expectedGeneration: generationSchema,
  })
  .strict();

const recoveryActionPayloadBase = {
  generation: generationSchema,
  sessionId: sessionIdSchema,
  villageStatus: villageStoreStatusDtoSchema,
  canWrite: z.boolean(),
  notice: noticeSchema,
} as const;

export const recoveryRestorePayloadSchema: z.ZodType<RecoveryRestorePayload> = z
  .object(recoveryActionPayloadBase)
  .strict();

export const recoveryResetPayloadSchema: z.ZodType<RecoveryResetPayload> = z
  .object(recoveryActionPayloadBase)
  .strict();

export const recoveryRecoverJournalPayloadSchema: z.ZodType<RecoveryRecoverJournalPayload> = z
  .object(recoveryActionPayloadBase)
  .strict();

export function isRecoveryStatusPayload(value: unknown): value is RecoveryStatusPayload {
  return recoveryStatusPayloadSchema.safeParse(value).success;
}

export function isRecoveryExportPayload(value: unknown): value is RecoveryExportPayload {
  return recoveryExportPayloadSchema.safeParse(value).success;
}

export function isRecoveryRestorePayload(value: unknown): value is RecoveryRestorePayload {
  return recoveryRestorePayloadSchema.safeParse(value).success;
}

export function isRecoveryResetPayload(value: unknown): value is RecoveryResetPayload {
  return recoveryResetPayloadSchema.safeParse(value).success;
}

export function isRecoveryRecoverJournalPayload(
  value: unknown,
): value is RecoveryRecoverJournalPayload {
  return recoveryRecoverJournalPayloadSchema.safeParse(value).success;
}
