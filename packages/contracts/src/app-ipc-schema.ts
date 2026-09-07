/**
 * E3-02 业务 IPC 共享 zod schema：Main 入参与 preload 出参/event 共用，避免双轨漂移。
 */

import { z } from 'zod';

import type {
  AccountDiagnosticWire,
  AccountItemWire,
  AccountSnapshotWire,
  PendingImportPreviewWire,
} from './account-wire';
import type {
  AppSnapshotPayload,
  ImportCommitPayload,
  ImportCommitRequest,
  ImportDiscardPayload,
  ImportDiscardRequest,
  ImportPreparePayload,
  ImportPrepareRequest,
  PendingImportSummaryDto,
  VillageSelectPayload,
  VillageSelectRequest,
  VillageSummaryDto,
} from './app-ipc';

const generationSchema = z.number().int().nonnegative().safe();
const villageIdSchema = z.string().min(1).max(128);
const safeIntSchema = z.number().int().safe();

export const appAvailabilitySchema = z.enum(['loading', 'available', 'recovery', 'unavailable']);

export const villageStoreStatusDtoSchema = z.enum([
  'missing',
  'available',
  'empty',
  'readOnly',
  'corrupt',
  'unsupported',
  'writeFailed',
]);

export const villageSummaryDtoSchema: z.ZodType<VillageSummaryDto> = z
  .object({
    id: villageIdSchema,
    name: z.string().min(1).max(256),
    tag: z.string().max(32).nullable(),
    hasImportedData: z.boolean(),
  })
  .strict();

export const pendingImportSummaryDtoSchema: z.ZodType<PendingImportSummaryDto> = z
  .object({
    targetKind: z.enum(['existing', 'create']),
    targetVillageId: villageIdSchema.optional(),
    targetVillageName: z.string().min(1).max(256).optional(),
    snapshotTag: z.string().max(32).nullable(),
  })
  .strict();

const accountDiagnosticWireSchema: z.ZodType<AccountDiagnosticWire> = z
  .object({
    id: z.string().min(1).max(128),
    severity: z.enum(['info', 'warning']),
    path: z.string().max(256),
    message: z.string().max(500),
  })
  .strict();

const accountItemWireSchema: z.ZodType<AccountItemWire> = z.lazy(() =>
  z
    .object({
      id: z.string().min(1).max(256),
      section: z.string().min(1).max(64),
      dataID: safeIntSchema,
      level: z.number().int().safe().optional(),
      count: z.number().int().safe().optional(),
      timerSeconds: safeIntSchema.optional(),
      remainingSeconds: safeIntSchema.optional(),
      helperTimerSeconds: safeIntSchema.optional(),
      remainingHelperSeconds: safeIntSchema.optional(),
      helperCooldownSeconds: safeIntSchema.optional(),
      remainingHelperCooldownSeconds: safeIntSchema.optional(),
      helperRecurrent: z.boolean(),
      gearUp: z.number().int().safe().optional(),
      weapon: z.number().int().safe().optional(),
      types: z.array(accountItemWireSchema),
      modules: z.array(accountItemWireSchema),
    })
    .strict(),
);

const accountSnapshotWireSchema: z.ZodType<AccountSnapshotWire> = z
  .object({
    tag: z.string().max(32).optional(),
    capturedAt: z.number().finite().optional(),
    importedAt: z.number().finite(),
    ageSeconds: safeIntSchema.optional(),
    originalText: z.string().max(5_000_000),
    objectSections: z.record(z.string(), z.array(accountItemWireSchema)),
    numericSections: z.record(z.string(), z.array(safeIntSchema)),
    boosts: z.record(z.string(), safeIntSchema),
    unknownTopLevelKeys: z.array(z.string().max(128)),
    diagnostics: z.array(accountDiagnosticWireSchema),
  })
  .strict();

export const pendingImportPreviewWireSchema: z.ZodType<PendingImportPreviewWire> = z
  .object({
    snapshot: accountSnapshotWireSchema,
    targetKind: z.enum(['existing', 'create', 'ambiguous']),
    targetVillageId: villageIdSchema.optional(),
    targetVillageName: z.string().min(1).max(256).optional(),
    ambiguousTag: z.string().max(32).optional(),
    ambiguousVillageNames: z.array(z.string().min(1).max(256)).optional(),
  })
  .strict();

export const appSnapshotPayloadSchema: z.ZodType<AppSnapshotPayload> = z
  .object({
    generation: generationSchema,
    availability: appAvailabilitySchema,
    villageStatus: villageStoreStatusDtoSchema,
    villageError: z.string().max(500).nullable(),
    canWrite: z.boolean(),
    selectedVillageId: villageIdSchema.nullable(),
    villages: z.array(villageSummaryDtoSchema),
    pendingImport: pendingImportSummaryDtoSchema.nullable(),
  })
  .strict();

export const villageSelectRequestSchema: z.ZodType<VillageSelectRequest> = z
  .object({
    villageId: villageIdSchema,
  })
  .strict();

export const villageSelectPayloadSchema: z.ZodType<VillageSelectPayload> = z
  .object({
    generation: generationSchema,
    selectedVillageId: villageIdSchema,
  })
  .strict();

export const importPrepareRequestSchema: z.ZodType<ImportPrepareRequest> = z
  .object({
    text: z.string().max(5_000_000),
    villageId: villageIdSchema.nullable().optional(),
  })
  .strict();

export const importPreparePayloadSchema: z.ZodType<ImportPreparePayload> = z
  .object({
    generation: generationSchema,
    pending: pendingImportSummaryDtoSchema,
    preview: pendingImportPreviewWireSchema,
  })
  .strict();

export const importCommitRequestSchema: z.ZodType<ImportCommitRequest> = z
  .object({
    expectedGeneration: generationSchema,
  })
  .strict();

export const importCommitPayloadSchema: z.ZodType<ImportCommitPayload> = z
  .object({
    generation: generationSchema,
    selectedVillageId: villageIdSchema.nullable(),
  })
  .strict();

export const importDiscardRequestSchema: z.ZodType<ImportDiscardRequest> = z
  .object({
    expectedGeneration: generationSchema,
  })
  .strict();

export const importDiscardPayloadSchema: z.ZodType<ImportDiscardPayload> = z
  .object({
    generation: generationSchema,
  })
  .strict();

export const emptyObjectRequestSchema = z.object({}).strict();

export function isAppSnapshotPayload(value: unknown): value is AppSnapshotPayload {
  return appSnapshotPayloadSchema.safeParse(value).success;
}

export function isImportPreparePayload(value: unknown): value is ImportPreparePayload {
  return importPreparePayloadSchema.safeParse(value).success;
}

export function isVillageSelectPayload(value: unknown): value is VillageSelectPayload {
  return villageSelectPayloadSchema.safeParse(value).success;
}

export function isImportCommitPayload(value: unknown): value is ImportCommitPayload {
  return importCommitPayloadSchema.safeParse(value).success;
}

export function isImportDiscardPayload(value: unknown): value is ImportDiscardPayload {
  return importDiscardPayloadSchema.safeParse(value).success;
}
