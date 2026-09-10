/**
 * Projection IPC 共享 zod schema：Main 出参与 preload 出参共用。
 */

import { z } from 'zod';

import type {
  BuildingGroupDto,
  CatalogAssetRefDto,
  CatalogAvailabilityDto,
  CatalogCompatibilityDto,
  CatalogDurationStateDto,
  ProgressMetricDto,
  TrackerItemKeyDto,
  UpgradeDisplayRecordDto,
  UpgradeOverviewPayload,
  UpgradeOverviewStateDto,
  UpgradeRecentCompletionDto,
  UpgradeRequirementDto,
  VillageCategoryCompletionDto,
  VillageDetailFlatRowDto,
  VillageDetailGroupDto,
  VillageDetailPayload,
  VillageDetailRequest,
  VillageItemStateDto,
  VillageNextUpgradeDto,
  VillageProgressMetricsDto,
} from './projection-ipc';

const generationSchema = z.number().int().nonnegative().safe();
const villageIdSchema = z.string().min(1).max(128);
const safeIntSchema = z.number().int().safe();
const trackerBaseSchema = z.enum(['home', 'builder']);
const trackerCategorySchema = z.enum([
  'buildings',
  'traps',
  'troops',
  'spells',
  'siegeMachines',
  'heroes',
  'equipment',
  'pets',
  'guardians',
]);
const trackerDisplayCategorySchema = z.enum(['defense', 'walls', 'military', 'craftTable']);
const villageItemStatusSchema = z.enum([
  'upgrading',
  'complete',
  'maxed',
  'unknown',
  'unavailable',
  'available',
  'unverified',
]);
const effectiveStatusSchema = z.enum([
  'observed',
  'manualCompleted',
  'manualActive',
  'importedActive',
  'needsReimport',
  'conflict',
  'unknown',
  'unavailable',
]);
const progressMetricStateSchema = z.enum(['ready', 'partial', 'unavailable', 'unknown']);

const catalogAssetRefSchema: z.ZodType<CatalogAssetRefDto> = z
  .object({
    container: z.string().max(256).nullable(),
    exportName: z.string().max(256).nullable(),
    renderedPath: z.string().max(1024).nullable(),
    missingReason: z.string().max(500).nullable(),
  })
  .strict();

const catalogDurationStateSchema: z.ZodType<CatalogDurationStateDto> = z.discriminatedUnion(
  'kind',
  [
    z.object({ kind: z.literal('timed'), seconds: safeIntSchema }).strict(),
    z.object({ kind: z.literal('instant') }).strict(),
    z.object({ kind: z.literal('initialLevel') }).strict(),
    z.object({ kind: z.literal('notApplicable') }).strict(),
    z.object({ kind: z.literal('sourceMissing') }).strict(),
    z.object({ kind: z.literal('parseFailed') }).strict(),
    z.object({ kind: z.literal('unknownReason'), reason: z.string().max(500) }).strict(),
  ],
);

const upgradeRequirementSchema: z.ZodType<UpgradeRequirementDto> = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('townHall'), level: z.number().int().safe() }).strict(),
  z.object({ kind: z.literal('builderHall'), level: z.number().int().safe() }).strict(),
  z.object({ kind: z.literal('laboratory'), level: z.number().int().safe() }).strict(),
  z.object({ kind: z.literal('starLaboratory'), level: z.number().int().safe() }).strict(),
  z.object({ kind: z.literal('heroHall'), level: z.number().int().safe() }).strict(),
  z.object({ kind: z.literal('blacksmith'), level: z.number().int().safe() }).strict(),
]);

const villageNextUpgradeSchema: z.ZodType<VillageNextUpgradeDto> = z.discriminatedUnion('kind', [
  z
    .object({
      kind: z.literal('available'),
      level: z.number().int().safe(),
      durationSeconds: safeIntSchema.nullable(),
    })
    .strict(),
  z
    .object({
      kind: z.literal('requires'),
      nextLevel: z.number().int().safe(),
      requirements: z.array(upgradeRequirementSchema),
      referenceDurationSeconds: safeIntSchema.nullable(),
    })
    .strict(),
  z.object({ kind: z.literal('globalMaxed') }).strict(),
  z
    .object({
      kind: z.literal('inProgressFact'),
      level: z.number().int().safe(),
      durationSeconds: safeIntSchema.nullable(),
    })
    .strict(),
  z.object({ kind: z.literal('unverified') }).strict(),
  z.object({ kind: z.literal('unknown') }).strict(),
]);

const catalogAvailabilitySchema: z.ZodType<CatalogAvailabilityDto> = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('permanent') }).strict(),
  z
    .object({
      kind: z.literal('seasonal'),
      phaseID: z.string().max(128),
      phaseName: z.string().max(256).nullable(),
      status: z.enum(['active', 'notStarted', 'ended']),
    })
    .strict(),
  z.object({ kind: z.literal('unconfigured') }).strict(),
  z
    .object({
      kind: z.literal('conflict'),
      phaseID: z.string().max(128),
      phaseName: z.string().max(256).nullable(),
      lifecycle: z.string().max(128),
      sourceURL: z.string().max(1024).nullable(),
    })
    .strict(),
]);

const catalogCompatibilitySchema: z.ZodType<CatalogCompatibilityDto> = z.discriminatedUnion(
  'kind',
  [
    z.object({ kind: z.literal('unverified'), gameVersion: z.string().max(64) }).strict(),
    z.object({ kind: z.literal('verified'), gameVersion: z.string().max(64) }).strict(),
    z
      .object({
        kind: z.literal('mismatch'),
        catalogVersion: z.string().max(64),
        expectedVersion: z.string().max(64),
      })
      .strict(),
    z.object({ kind: z.literal('unavailable') }).strict(),
  ],
);

export const villageItemStateDtoSchema: z.ZodType<VillageItemStateDto> = z
  .object({
    id: z.string().min(1).max(512),
    section: z.string().min(1).max(64),
    dataID: safeIntSchema,
    base: trackerBaseSchema,
    name: z.string().max(256),
    category: trackerCategorySchema.nullable(),
    currentLevel: z.number().int().safe().nullable(),
    count: z.number().int().safe().nullable(),
    timerSeconds: safeIntSchema.nullable(),
    remainingSeconds: safeIntSchema.nullable(),
    nextLevel: z.number().int().safe().nullable(),
    nextLevelDurationSeconds: safeIntSchema.nullable(),
    nextLevelDurationState: catalogDurationStateSchema.nullable(),
    maxLevel: z.number().int().safe().nullable(),
    currentStageMaxLevel: z.number().int().safe().nullable(),
    nextUpgrade: villageNextUpgradeSchema.nullable(),
    status: villageItemStatusSchema,
    missingReason: z.string().max(500).nullable(),
    catalogItemMissingReason: z.string().max(500).nullable(),
    availability: catalogAvailabilitySchema,
    icon: catalogAssetRefSchema.nullable(),
    levelVisual: catalogAssetRefSchema.nullable(),
    currentLevelIcon: catalogAssetRefSchema.nullable(),
    currentLevelVisual: catalogAssetRefSchema.nullable(),
    isNested: z.boolean(),
    displayCategory: trackerDisplayCategorySchema.nullable(),
    countOverflowed: z.boolean(),
    effectiveStatus: effectiveStatusSchema.nullable(),
    effectiveCurrentLevel: z.number().int().safe().nullable(),
    effectiveTargetLevel: z.number().int().safe().nullable(),
    effectiveNextUpgrade: villageNextUpgradeSchema.nullable(),
    effectiveNextLevelDurationState: catalogDurationStateSchema.nullable(),
    effectiveDiagnostic: z.string().max(500).nullable(),
    effectiveIsMaxed: z.boolean(),
  })
  .strict();

const progressMetricSchema: z.ZodType<ProgressMetricDto> = z
  .object({
    kind: z.string().min(1).max(64),
    numerator: safeIntSchema,
    denominator: safeIntSchema,
    state: progressMetricStateSchema,
    saturated: z.boolean(),
    units: z.string().max(64),
    degradedReason: z.string().max(500).nullable(),
    ratio: z.number().finite().nullable(),
  })
  .strict();

export const villageProgressMetricsDtoSchema: z.ZodType<VillageProgressMetricsDto> = z
  .object({
    currentStageProgress: progressMetricSchema,
    globalProgress: progressMetricSchema,
    snapshotCoverage: progressMetricSchema,
    instanceProgress: progressMetricSchema,
    effectiveTrackerProgress: progressMetricSchema,
  })
  .strict();

const trackerItemKeySchema: z.ZodType<TrackerItemKeyDto> = z
  .object({
    base: trackerBaseSchema,
    rawSection: z.string().min(1).max(64),
    dataID: safeIntSchema,
    nestedKind: z.string().min(1).max(64),
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
          kind: z.string().min(1).max(64),
          dataID: safeIntSchema,
        })
        .strict(),
    ),
    stableId: z.string().min(1).max(512),
  })
  .strict();

export const upgradeDisplayRecordDtoSchema: z.ZodType<UpgradeDisplayRecordDto> = z
  .object({
    id: z.string().min(1).max(512),
    villageID: villageIdSchema,
    villageName: z.string().min(1).max(256),
    villageTag: z.string().max(32).nullable(),
    base: trackerBaseSchema,
    item: villageItemStateDtoSchema,
    catalogVersion: z.string().max(64).nullable(),
    villageMetrics: villageProgressMetricsDtoSchema,
  })
  .strict();

const upgradeRecentCompletionSchema: z.ZodType<UpgradeRecentCompletionDto> = z
  .object({
    id: z.string().min(1).max(512),
    villageID: villageIdSchema,
    itemKey: trackerItemKeySchema,
    itemName: z.string().max(256),
    targetLevel: z.number().int().safe(),
    quantity: safeIntSchema,
    completedAtMs: z.number().finite(),
  })
  .strict();

const upgradeOverviewStateSchema: z.ZodType<UpgradeOverviewStateDto> = z
  .object({
    manualActiveCount: safeIntSchema,
    importedActiveCount: safeIntSchema,
    deduplicatedDisplayCount: safeIntSchema,
    manualCompletedCount: safeIntSchema,
    completedRecently: z.array(upgradeRecentCompletionSchema),
    activeRecords: z.array(upgradeDisplayRecordDtoSchema),
    attentionRecords: z.array(upgradeDisplayRecordDtoSchema),
    needsReimportRecords: z.array(upgradeDisplayRecordDtoSchema),
  })
  .strict();

export const upgradeOverviewPayloadSchema: z.ZodType<UpgradeOverviewPayload> = z
  .object({
    generation: generationSchema,
    nowMs: z.number().finite(),
    catalogVersion: z.string().max(64).nullable(),
    catalogIsUsable: z.boolean(),
    active: z.array(upgradeDisplayRecordDtoSchema),
    pending: z.array(upgradeDisplayRecordDtoSchema),
    state: upgradeOverviewStateSchema,
  })
  .strict();

export const villageDetailRequestSchema: z.ZodType<VillageDetailRequest> = z
  .object({
    villageId: villageIdSchema,
    base: trackerBaseSchema,
  })
  .strict();

const villageDetailGroupSchema: z.ZodType<VillageDetailGroupDto> = z
  .object({
    id: z.string().min(1).max(128),
    category: trackerCategorySchema.nullable(),
    displayCategory: trackerDisplayCategorySchema.nullable(),
    itemIds: z.array(z.string().min(1).max(512)),
  })
  .strict();

const villageCategoryCompletionSchema: z.ZodType<VillageCategoryCompletionDto> = z
  .object({
    id: z.string().min(1).max(128),
    category: trackerCategorySchema.nullable(),
    displayCategory: trackerDisplayCategorySchema.nullable(),
    knownCount: safeIntSchema,
    completedCount: safeIntSchema,
    unknownCount: safeIntSchema,
    saturated: z.boolean(),
    completionRatio: z.number().finite().nullable(),
    isFullyMaxed: z.boolean(),
  })
  .strict();

const villageDetailFlatRowSchema: z.ZodType<VillageDetailFlatRowDto> = z.discriminatedUnion(
  'kind',
  [
    z
      .object({
        kind: z.literal('sectionHeader'),
        groupID: z.string().min(1).max(128),
        stats: villageCategoryCompletionSchema.nullable(),
      })
      .strict(),
    z
      .object({
        kind: z.literal('craftTable'),
        groupID: z.string().min(1).max(128),
        stats: villageCategoryCompletionSchema.nullable(),
      })
      .strict(),
    z
      .object({
        kind: z.literal('groupHeader'),
        groupID: z.string().min(1).max(128),
      })
      .strict(),
    z
      .object({
        kind: z.literal('instance'),
        groupID: z.string().min(1).max(128),
        instanceID: z.string().min(1).max(512),
        leadingDivider: z.boolean(),
      })
      .strict(),
    z
      .object({
        kind: z.literal('legacy'),
        itemID: z.string().min(1).max(512),
        groupID: z.string().min(1).max(128),
        indented: z.boolean(),
        leadingDivider: z.boolean(),
      })
      .strict(),
  ],
);

const buildingGroupSchema: z.ZodType<BuildingGroupDto> = z
  .object({
    id: z.string().min(1).max(256),
    base: trackerBaseSchema,
    section: z.string().min(1).max(64),
    dataID: safeIntSchema,
    name: z.string().max(256),
    category: trackerCategorySchema.nullable(),
    displayCategory: trackerDisplayCategorySchema.nullable(),
    instanceIds: z.array(z.string().min(1).max(512)),
    summary: z
      .object({
        instanceCount: safeIntSchema,
        remainingLevelCount: safeIntSchema,
        totalDurationSeconds: safeIntSchema,
        costByResource: z.array(
          z
            .object({
              resource: z.string().min(1).max(64),
              totalCost: safeIntSchema,
            })
            .strict(),
        ),
        saturated: z.boolean(),
        completeness: z.enum(['complete', 'partialMissing', 'versionMismatch']),
      })
      .strict(),
    trackerStatus: effectiveStatusSchema,
  })
  .strict();

export const villageDetailPayloadSchema: z.ZodType<VillageDetailPayload> = z
  .object({
    generation: generationSchema,
    nowMs: z.number().finite(),
    villageId: villageIdSchema,
    villageName: z.string().min(1).max(256),
    villageTag: z.string().max(32).nullable(),
    base: trackerBaseSchema,
    catalogVersion: z.string().max(64).nullable(),
    catalogIsUsable: z.boolean(),
    compatibility: catalogCompatibilitySchema,
    items: z.array(villageItemStateDtoSchema),
    instanceItems: z.array(villageItemStateDtoSchema),
    groups: z.array(villageDetailGroupSchema),
    completion: z.array(villageCategoryCompletionSchema),
    totalCompletion: villageCategoryCompletionSchema,
    metrics: villageProgressMetricsDtoSchema,
    buildingGroups: z.array(buildingGroupSchema),
    flatRows: z.array(villageDetailFlatRowSchema),
  })
  .strict();

export const emptyProjectionRequestSchema = z.object({}).strict();

export function isUpgradeOverviewPayload(value: unknown): value is UpgradeOverviewPayload {
  return upgradeOverviewPayloadSchema.safeParse(value).success;
}

export function isVillageDetailPayload(value: unknown): value is VillageDetailPayload {
  return villageDetailPayloadSchema.safeParse(value).success;
}
