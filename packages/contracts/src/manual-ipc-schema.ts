/**
 * Manual IPC zod schema：Main 入参与 preload 出参共用。
 */

import { z } from 'zod';

import type {
  ManualAdjustPayload,
  ManualAdjustRequest,
  ManualCancelPayload,
  ManualCancelRequest,
  ManualReconcilePayload,
  ManualReconcileRequest,
  ManualSettlePayload,
  ManualSettleRequest,
  ManualStartPayload,
  ManualStartRequest,
  ManualStatePayload,
  ManualStateRequest,
  ManualUpgradeRecordDto,
} from './manual-ipc';
import type { TrackerItemKeyDto } from './projection-ipc';

const generationSchema = z.number().int().nonnegative().safe();
const villageIdSchema = z.string().min(1).max(128);
const safeIntSchema = z.number().int().safe();
const trackerBaseSchema = z.enum(['home', 'builder']);

const trackerNestedKindSchema = z.enum(['root', 'type', 'module']);

const trackerItemKeySchema: z.ZodType<TrackerItemKeyDto> = z
  .object({
    base: trackerBaseSchema,
    rawSection: z.string().min(1).max(64),
    dataID: safeIntSchema,
    nestedKind: trackerNestedKindSchema,
    nestedRootIdentity: z
      .object({
        base: trackerBaseSchema,
        rawSection: z.string().min(1).max(64),
        dataID: safeIntSchema,
      })
      .strict()
      .nullable(),
    nestedPath: z.array(
      z
        .object({
          kind: trackerNestedKindSchema,
          dataID: safeIntSchema,
        })
        .strict(),
    ),
    stableId: z.string().min(1).max(512),
  })
  .strict();

const manualUpgradeRecordDtoSchema: z.ZodType<ManualUpgradeRecordDto> = z
  .object({
    recordId: z.string().uuid(),
    status: z.enum(['active', 'completed', 'cancelled']),
    fromLevel: safeIntSchema,
    targetLevel: safeIntSchema,
    quantity: safeIntSchema,
    startedAtMs: z.number().finite(),
    expectedEndAtMs: z.number().finite(),
  })
  .strict();

export const manualStateRequestSchema: z.ZodType<ManualStateRequest> = z
  .object({
    villageId: villageIdSchema,
  })
  .strict();

export const manualStatePayloadSchema: z.ZodType<ManualStatePayload> = z
  .object({
    generation: generationSchema,
    villageId: villageIdSchema,
    status: z.enum(['missing', 'available', 'empty', 'unavailable', 'migrationRequired']),
    error: z.string().max(500).nullable(),
    baselineRevision: z.string().max(256).nullable(),
    baselineLineageId: z.string().max(128).nullable(),
    activeRecordCount: z.number().int().nonnegative().safe(),
    itemStateCount: z.number().int().nonnegative().safe(),
    lastSettleAtMs: z.number().finite().nullable(),
    lastImportAtMs: z.number().finite().nullable(),
    stateUpdatedAtMs: z.number().finite().nullable(),
  })
  .strict();

export const manualStartRequestSchema: z.ZodType<ManualStartRequest> = z
  .object({
    expectedGeneration: generationSchema,
    villageId: villageIdSchema,
    itemKey: trackerItemKeySchema,
    fromLevel: safeIntSchema,
    targetLevel: safeIntSchema,
    quantity: safeIntSchema,
    startedAtMs: z.number().finite(),
    sourceKind: z.enum(['row', 'group']),
    base: trackerBaseSchema,
  })
  .strict();

export const manualStartPayloadSchema: z.ZodType<ManualStartPayload> = z
  .object({
    generation: generationSchema,
    record: manualUpgradeRecordDtoSchema,
  })
  .strict();

export const manualCancelRequestSchema: z.ZodType<ManualCancelRequest> = z
  .object({
    expectedGeneration: generationSchema,
    villageId: villageIdSchema,
    recordId: z.string().uuid(),
  })
  .strict();

export const manualCancelPayloadSchema: z.ZodType<ManualCancelPayload> = z
  .object({
    generation: generationSchema,
    record: manualUpgradeRecordDtoSchema,
  })
  .strict();

export const manualAdjustRequestSchema: z.ZodType<ManualAdjustRequest> = z
  .object({
    expectedGeneration: generationSchema,
    villageId: villageIdSchema,
    recordId: z.string().uuid(),
    startedAtMs: z.number().finite(),
  })
  .strict();

export const manualAdjustPayloadSchema: z.ZodType<ManualAdjustPayload> = z
  .object({
    generation: generationSchema,
    record: manualUpgradeRecordDtoSchema,
  })
  .strict();

export const manualSettleRequestSchema: z.ZodType<ManualSettleRequest> = z
  .object({
    expectedGeneration: generationSchema,
    villageId: villageIdSchema.nullable().optional(),
  })
  .strict();

export const manualSettlePayloadSchema: z.ZodType<ManualSettlePayload> = z
  .object({
    generation: generationSchema,
    settledCount: z.number().int().nonnegative().safe(),
  })
  .strict();

export const manualReconcileRequestSchema: z.ZodType<ManualReconcileRequest> = z
  .object({
    expectedGeneration: generationSchema,
    villageId: villageIdSchema,
    decision: z.enum(['applyNonConflicting', 'keepLocal', 'acceptObserved']),
  })
  .strict();

export const manualReconcilePayloadSchema: z.ZodType<ManualReconcilePayload> = z
  .object({
    generation: generationSchema,
    attentionCount: z.number().int().nonnegative().safe(),
    duplicate: z.boolean(),
    lineageComparable: z.boolean(),
  })
  .strict();

export function isManualStatePayload(value: unknown): value is ManualStatePayload {
  return manualStatePayloadSchema.safeParse(value).success;
}

export function isManualStartPayload(value: unknown): value is ManualStartPayload {
  return manualStartPayloadSchema.safeParse(value).success;
}

export function isManualCancelPayload(value: unknown): value is ManualCancelPayload {
  return manualCancelPayloadSchema.safeParse(value).success;
}

export function isManualAdjustPayload(value: unknown): value is ManualAdjustPayload {
  return manualAdjustPayloadSchema.safeParse(value).success;
}

export function isManualSettlePayload(value: unknown): value is ManualSettlePayload {
  return manualSettlePayloadSchema.safeParse(value).success;
}

export function isManualReconcilePayload(value: unknown): value is ManualReconcilePayload {
  return manualReconcilePayloadSchema.safeParse(value).success;
}
