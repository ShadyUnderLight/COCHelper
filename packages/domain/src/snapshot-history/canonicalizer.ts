import {
  canonicalBytes,
  canonicalize as canonicalizeJson,
  jsonArray,
  jsonBool,
  jsonNull,
  jsonNumber,
  jsonObject,
  jsonString,
  generateUuid,
  parseCanonicalizerInt64,
  parseJson,
  sha256Fingerprint,
  sortedByCanonicalBytes,
  unixSecondsToRefSeconds,
  type CanonicalJsonValue,
  type Sha256Fingerprint,
  type UuidString,
} from '@coc-helper/wire';

import { prepareAccountText } from '../account/prepare';
import type { AccountSnapshot } from '../account/types';
import type { CraftTableCatalog } from '../catalog/craft-table';
import type { GameCatalog } from '../catalog/game-catalog';
import { normalizedTag } from '../tag/validator';
import {
  SNAPSHOT_COVERAGE_CONTRACT_FIELD,
  SNAPSHOT_HISTORY_ITEM_FIELDS,
  SNAPSHOT_HISTORY_NUMERIC_SECTIONS,
  SNAPSHOT_HISTORY_OBJECT_SECTIONS,
  SNAPSHOT_HISTORY_TIMER_FIELDS,
} from './known-sections';
import { SNAPSHOT_HISTORY_SCHEMA, SNAPSHOT_HISTORY_CANONICALIZATION_LIMITS } from './schema';
import type {
  CanonicalSnapshotObservation,
  SnapshotCoverageField,
  SnapshotCoverageProof,
  SnapshotCoverageSourceUniverse,
  SnapshotCoverageState,
  SnapshotDisplayBinding,
  SnapshotHistoryCanonicalizationError,
  SnapshotHistoryEntry,
  SnapshotItemIdentity,
  SnapshotLineageReason,
  SnapshotLineageResolution,
  SnapshotNestedKind,
  SnapshotNestedPathComponent,
  SnapshotObservationCoverage,
  SnapshotObservationItem,
  SnapshotSectionCoverage,
  SnapshotSectionPresence,
  SnapshotTimerFieldSpec,
  SnapshotTimerSchema,
} from './types';
import { snapshotHistoryCanonicalizationErrorMessage } from './types';
import {
  DEFAULT_ACCOUNT_TIMER_SCHEMA,
  SNAPSHOT_HISTORY_PARSER_VERSION,
  coverageProofExpectedCount,
  snapshotCoverageFieldId,
  snapshotHistoryBaseFromSection,
  snapshotItemIdentityKey,
  snapshotSectionCoverageId,
} from './types';
import { encodeIntegrityMaterialWire } from './wire-encode';

export type CanonicalizeSnapshotHistoryOptions = {
  readonly villageID: UuidString;
  readonly lineageID: UuidString;
  readonly appliedAtRefSeconds: number;
  readonly snapshotID?: UuidString;
  readonly isBaseline?: boolean;
  readonly baselineReason?: SnapshotLineageReason | null;
  readonly catalog?: GameCatalog;
  readonly craftTableCatalog?: CraftTableCatalog;
  readonly sectionProofs?: Readonly<Record<string, SnapshotCoverageProof>>;
  readonly sourceUniverse?: SnapshotCoverageSourceUniverse | null;
  readonly observationVersion?: number;
  readonly timerSchema?: SnapshotTimerSchema | null;
};

type CanonicalSource = {
  readonly fields: Record<string, CanonicalJsonValue>;
  readonly unknownFields: Record<string, CanonicalJsonValue>;
};

type SectionCoverageAnalysis = {
  readonly completeness: SnapshotCoverageState;
  readonly proof: SnapshotCoverageProof;
  readonly diagnostics: string[];
};

type ObjectRecord = {
  readonly index: number;
  readonly object: Record<string, CanonicalJsonValue> | null;
};

export function canonicalizeSnapshotHistory(
  snapshot: AccountSnapshot,
  options: CanonicalizeSnapshotHistoryOptions,
): SnapshotHistoryEntry {
  const observationVersion = options.observationVersion ?? SNAPSHOT_HISTORY_SCHEMA.observation;
  if (
    options.sourceUniverse !== undefined &&
    options.sourceUniverse !== null &&
    observationVersion < SNAPSHOT_HISTORY_SCHEMA.observationWithSourceUniverse
  ) {
    throwCanonicalizationError({ kind: 'sourceUniverseRequiresObservationV6' });
  }

  const source = canonicalSource(snapshot.originalText, observationVersion);
  const timerSchema = options.timerSchema ?? DEFAULT_ACCOUNT_TIMER_SCHEMA;
  const sectionProofs = options.sectionProofs ?? {};
  const observation = makeObservation(
    source,
    options.catalog,
    options.craftTableCatalog,
    observationVersion,
    timerSchema,
  );
  const coverage = makeCoverage(
    source,
    snapshot.originalText,
    options.catalog,
    options.craftTableCatalog,
    sectionProofs,
    options.sourceUniverse ?? null,
    observationVersion,
    timerSchema,
  );
  const normalizedObservation: CanonicalSnapshotObservation = {
    schemaVersion: observationVersion,
    rawTopLevelFields: observation.rawTopLevelFields,
    unknownTopLevelFields: observation.unknownTopLevelFields,
    items: observation.items,
  };
  const canonicalFingerprint = fingerprintForObservation(normalizedObservation);
  const sourceTimestampRefSeconds =
    snapshot.capturedAtMs === null ? null : unixSecondsToRefSeconds(snapshot.capturedAtMs / 1000);

  const entryBase = {
    schemaVersion: SNAPSHOT_HISTORY_SCHEMA.entry,
    observationVersion,
    fingerprintVersion: SNAPSHOT_HISTORY_SCHEMA.fingerprint,
    integrityVersion: SNAPSHOT_HISTORY_SCHEMA.integrity,
    snapshotID: options.snapshotID ?? generateUuid(),
    villageID: options.villageID,
    lineageID: options.lineageID,
    normalizedPlayerTag: normalizedTag(snapshot.tag) ?? null,
    appliedAtRefSeconds: options.appliedAtRefSeconds,
    sourceTimestampRefSeconds,
    parserVersion: SNAPSHOT_HISTORY_PARSER_VERSION,
    canonicalFingerprint,
    rawJSON: snapshot.originalText,
    observation: normalizedObservation,
    coverage,
    isBaseline: options.isBaseline ?? false,
    baselineReason: options.isBaseline === true ? (options.baselineReason ?? null) : null,
    timerSchema:
      observationVersion >= SNAPSHOT_HISTORY_SCHEMA.observationWithTimerSchema ? timerSchema : null,
  };

  return {
    ...entryBase,
    integrityFingerprint: integrityFingerprint(entryBase),
  };
}

export function canonicalizeSnapshotHistoryWithLineage(
  snapshot: AccountSnapshot,
  options: Omit<
    CanonicalizeSnapshotHistoryOptions,
    'lineageID' | 'isBaseline' | 'baselineReason'
  > & {
    readonly lineage: SnapshotLineageResolution;
  },
): SnapshotHistoryEntry {
  return canonicalizeSnapshotHistory(snapshot, {
    ...options,
    lineageID: options.lineage.lineageID,
    isBaseline: options.lineage.isBaseline,
    baselineReason: options.lineage.isBaseline ? options.lineage.reason : null,
  });
}

export function fingerprintForObservation(
  observation: CanonicalSnapshotObservation,
): Sha256Fingerprint {
  const items = sortedByCanonicalBytes(observation.items, fingerprintValueForItem);
  const material = jsonObject({
    items: jsonArray(items.map(fingerprintValueForItem)),
    observationSchemaVersion: jsonNumber(String(observation.schemaVersion)),
    rawTopLevelFields: jsonObject(observation.rawTopLevelFields),
    unknownTopLevelFields: jsonObject(observation.unknownTopLevelFields),
  });
  return sha256Fingerprint(canonicalBytes(material));
}

export function integrityFingerprint(
  entry: Omit<SnapshotHistoryEntry, 'integrityFingerprint'>,
): Sha256Fingerprint {
  return sha256Fingerprint(encodeIntegrityMaterialWire(entry));
}

function canonicalSource(originalText: string, observationVersion: number): CanonicalSource {
  const prepared = prepareAccountText(originalText).text;
  if (prepared.length === 0) {
    throwCanonicalizationError({ kind: 'emptySource' });
  }

  let source: CanonicalJsonValue;
  try {
    source = canonicalizeJson(parseJson(prepared));
  } catch (error) {
    throwCanonicalizationError({
      kind: 'invalidJSON',
      message: error instanceof Error ? error.message : String(error),
    });
  }

  if (source.kind !== 'object') {
    throwCanonicalizationError({ kind: 'topLevelMustBeObject' });
  }

  const fields: Record<string, CanonicalJsonValue> = { ...source.fields };
  delete fields.tag;
  delete fields.timestamp;
  if (observationVersion >= SNAPSHOT_HISTORY_SCHEMA.observationWithoutCoverageMetadata) {
    delete fields[SNAPSHOT_COVERAGE_CONTRACT_FIELD];
  }

  const unknownFields: Record<string, CanonicalJsonValue> = {};
  for (const [key, value] of Object.entries(fields)) {
    if (
      !SNAPSHOT_HISTORY_OBJECT_SECTIONS.includes(
        key as (typeof SNAPSHOT_HISTORY_OBJECT_SECTIONS)[number],
      ) &&
      !SNAPSHOT_HISTORY_NUMERIC_SECTIONS.includes(
        key as (typeof SNAPSHOT_HISTORY_NUMERIC_SECTIONS)[number],
      ) &&
      key !== 'boosts'
    ) {
      unknownFields[key] = value;
    }
  }

  return { fields, unknownFields };
}

function makeObservation(
  source: CanonicalSource,
  catalog: GameCatalog | undefined,
  craftTableCatalog: CraftTableCatalog | undefined,
  observationVersion: number,
  timerSchema: SnapshotTimerSchema,
): CanonicalSnapshotObservation {
  const items: SnapshotObservationItem[] = [];

  for (const section of [...SNAPSHOT_HISTORY_OBJECT_SECTIONS].sort()) {
    const value = source.fields[section];
    if (value === undefined || value.kind !== 'array') {
      continue;
    }
    collectObjectSectionItems(
      value.items,
      section,
      'root',
      null,
      null,
      [],
      catalog,
      craftTableCatalog,
      observationVersion,
      timerSchema,
      items,
    );
  }

  for (const section of [...SNAPSHOT_HISTORY_NUMERIC_SECTIONS].sort()) {
    const value = source.fields[section];
    if (value === undefined || value.kind !== 'array') {
      continue;
    }
    for (const entry of value.items) {
      const dataID = integerValue(entry);
      if (dataID === undefined) {
        continue;
      }
      const identity: SnapshotItemIdentity = {
        base: snapshotHistoryBaseFromSection(section),
        rawSection: section,
        dataID,
        nestedKind: 'root',
        nestedRootIdentity: null,
        nestedRootDataID: null,
        nestedParentPath: [],
      };
      items.push({
        identity,
        level: null,
        count: null,
        rawTimerEvidence: {},
        helperRecurrent: null,
        gearUp: null,
        weapon: null,
        unknownFields: {},
        display: displayBinding(identity, catalog, craftTableCatalog),
      });
    }
  }

  return {
    schemaVersion: SNAPSHOT_HISTORY_SCHEMA.observation,
    rawTopLevelFields: source.fields,
    unknownTopLevelFields: source.unknownFields,
    items: sortedByCanonicalBytes(items, fingerprintValueForItem),
  };
}

type ObjectTraversalWork = {
  readonly object: Record<string, CanonicalJsonValue>;
  readonly section: string;
  readonly nestedKind: SnapshotNestedKind;
  readonly rootIdentity: string | null;
  readonly rootDataID: bigint | null;
  readonly parentPath: readonly SnapshotNestedPathComponent[];
};

function ensureCanonicalizationLimits(
  itemCount: number,
  parentPath: readonly SnapshotNestedPathComponent[],
): void {
  if (itemCount >= SNAPSHOT_HISTORY_CANONICALIZATION_LIMITS.maxItemsPerEntry) {
    throwCanonicalizationError({
      kind: 'canonicalizationLimitExceeded',
      message: `单条 entry item 数量超过上限 ${SNAPSHOT_HISTORY_CANONICALIZATION_LIMITS.maxItemsPerEntry}。`,
    });
  }
  if (parentPath.length > SNAPSHOT_HISTORY_CANONICALIZATION_LIMITS.maxNestedDepth) {
    throwCanonicalizationError({
      kind: 'canonicalizationLimitExceeded',
      message: `嵌套深度超过上限 ${SNAPSHOT_HISTORY_CANONICALIZATION_LIMITS.maxNestedDepth}。`,
    });
  }
}

function collectObjectSectionItems(
  entries: readonly CanonicalJsonValue[],
  section: string,
  nestedKind: SnapshotNestedKind,
  rootIdentity: string | null,
  rootDataID: bigint | null,
  parentPath: readonly SnapshotNestedPathComponent[],
  catalog: GameCatalog | undefined,
  craftTableCatalog: CraftTableCatalog | undefined,
  observationVersion: number,
  timerSchema: SnapshotTimerSchema,
  items: SnapshotObservationItem[],
): void {
  const stack: ObjectTraversalWork[] = [];
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index]!;
    if (entry.kind !== 'object') {
      continue;
    }
    stack.push({
      object: entry.fields,
      section,
      nestedKind,
      rootIdentity,
      rootDataID,
      parentPath,
    });
  }

  while (stack.length > 0) {
    const work = stack.pop()!;
    ensureCanonicalizationLimits(items.length, work.parentPath);

    const dataID = integerValue(work.object.data);
    if (dataID === undefined) {
      continue;
    }

    const identity: SnapshotItemIdentity = {
      base: snapshotHistoryBaseFromSection(work.section),
      rawSection: work.section,
      dataID,
      nestedKind: work.nestedKind,
      nestedRootIdentity: work.rootIdentity,
      nestedRootDataID: work.rootDataID,
      nestedParentPath: work.parentPath,
    };

    const knownFields = new Set<string>(SNAPSHOT_HISTORY_ITEM_FIELDS);
    const unknownFields: Record<string, CanonicalJsonValue> = {};
    for (const [key, value] of Object.entries(work.object)) {
      if (!knownFields.has(key)) {
        unknownFields[key] = value;
      }
    }

    const timerEvidence: Record<string, CanonicalJsonValue> = {};
    for (const [key, value] of Object.entries(work.object)) {
      if (isTimerEvidenceField(key, observationVersion, timerSchema)) {
        timerEvidence[key] = value;
      }
    }

    items.push({
      identity,
      level:
        integerValue(work.object.lvl) === undefined ? null : Number(integerValue(work.object.lvl)!),
      count:
        integerValue(work.object.cnt) === undefined ? null : Number(integerValue(work.object.cnt)!),
      rawTimerEvidence: timerEvidence,
      helperRecurrent: booleanValue(work.object.helper_recurrent),
      gearUp:
        integerValue(work.object.gear_up) === undefined
          ? null
          : Number(integerValue(work.object.gear_up)!),
      weapon:
        integerValue(work.object.weapon) === undefined
          ? null
          : Number(integerValue(work.object.weapon)!),
      unknownFields,
      display: displayBinding(identity, catalog, craftTableCatalog),
    });

    const childRootIdentity = work.rootIdentity ?? snapshotItemIdentityKey(identity);
    const childRootDataID = work.rootDataID ?? dataID;
    const childParentPath: SnapshotNestedPathComponent[] = [
      ...work.parentPath,
      { kind: work.nestedKind, dataID },
    ];
    ensureCanonicalizationLimits(items.length, childParentPath);

    enqueueNestedChildren(
      stack,
      work.object,
      work.section,
      childRootIdentity,
      childRootDataID,
      childParentPath,
    );
  }
}

function enqueueNestedChildren(
  stack: ObjectTraversalWork[],
  object: Record<string, CanonicalJsonValue>,
  section: string,
  rootIdentity: string,
  rootDataID: bigint,
  parentPath: readonly SnapshotNestedPathComponent[],
): void {
  const nestedArrays: Array<{
    readonly kind: SnapshotNestedKind;
    readonly value: CanonicalJsonValue | undefined;
  }> = [
    { kind: 'module', value: object.modules },
    { kind: 'type', value: object.types },
  ];
  for (const nested of nestedArrays) {
    if (nested.value === undefined || nested.value.kind !== 'array') {
      continue;
    }
    for (let index = nested.value.items.length - 1; index >= 0; index -= 1) {
      const child = nested.value.items[index]!;
      if (child.kind !== 'object') {
        continue;
      }
      stack.push({
        object: child.fields,
        section,
        nestedKind: nested.kind,
        rootIdentity,
        rootDataID,
        parentPath,
      });
    }
  }
}

function displayBinding(
  identity: SnapshotItemIdentity,
  catalog: GameCatalog | undefined,
  craftTableCatalog: CraftTableCatalog | undefined,
): SnapshotDisplayBinding {
  if (
    craftTableCatalog !== undefined &&
    (identity.nestedKind === 'type' || identity.nestedKind === 'module')
  ) {
    return craftTableDisplayBinding(identity, catalog, craftTableCatalog) ?? {};
  }

  const craftBinding = craftTableDisplayBinding(identity, catalog, craftTableCatalog);
  if (craftBinding !== undefined) {
    return craftBinding;
  }

  if (catalog === undefined) {
    return {};
  }

  const item = catalog.item(identity.rawSection, identity.dataID);
  if (item === undefined) {
    return {};
  }
  return {
    displayName: item.name ?? undefined,
    category: item.category ?? undefined,
    displayCategory: item.displayCategory ?? undefined,
    catalogVersion: catalog.gameVersion,
    catalogFingerprint: catalog.manifest?.sourceFingerprint ?? undefined,
  };
}

function craftTableDisplayBinding(
  identity: SnapshotItemIdentity,
  catalog: GameCatalog | undefined,
  craftTableCatalog: CraftTableCatalog | undefined,
): SnapshotDisplayBinding | undefined {
  if (craftTableCatalog === undefined) {
    return undefined;
  }

  let name: string | undefined;
  switch (identity.nestedKind) {
    case 'type':
      name = craftTableCatalog.defense(identity.dataID)?.name;
      break;
    case 'module':
      name = craftTableCatalog.module(identity.dataID)?.name;
      break;
    default:
      name = undefined;
  }
  if (name === undefined) {
    return undefined;
  }

  const rootItem =
    identity.nestedRootDataID === null
      ? undefined
      : catalog?.item(identity.rawSection, identity.nestedRootDataID);
  return {
    displayName: name,
    category: rootItem?.category,
    displayCategory: 'craftTable',
    catalogVersion: craftTableCatalog.gameVersion,
    catalogFingerprint: craftTableCatalog.sourceFingerprint ?? undefined,
  };
}

function makeCoverage(
  source: CanonicalSource,
  originalText: string,
  catalog: GameCatalog | undefined,
  craftTableCatalog: CraftTableCatalog | undefined,
  sectionProofs: Readonly<Record<string, SnapshotCoverageProof>>,
  sourceUniverse: SnapshotCoverageSourceUniverse | null,
  schemaVersion: number,
  timerSchema: SnapshotTimerSchema,
): SnapshotObservationCoverage {
  const fields: SnapshotCoverageField[] = [];
  const sections: SnapshotSectionCoverage[] = [];
  const diagnostics: string[] = [];

  for (const section of [...SNAPSHOT_HISTORY_OBJECT_SECTIONS].sort()) {
    const base = snapshotHistoryBaseFromSection(section);
    const value = source.fields[section];
    if (value === undefined) {
      sections.push(
        makeSectionCoverage(
          base,
          section,
          'missing',
          'unavailable',
          proofForSection(section, sectionProofs, '源 JSON 缺少 section。'),
          0,
        ),
      );
      appendUnavailableFields(base, section, fields);
      continue;
    }

    if (value.kind !== 'array') {
      sections.push(
        makeSectionCoverage(
          base,
          section,
          'invalid',
          'partial',
          proofForSection(section, sectionProofs, 'section 不是数组。'),
          0,
        ),
      );
      appendPartialFields(base, section, fields);
      diagnostics.push(`${section}: 顶层值不是数组。`);
      continue;
    }

    fields.push({ base, rawSection: section, field: 'presence', state: 'complete' });
    const sectionAnalysis = analyzeSectionCoverage(section, value.items, sectionProofs[section]);
    const boundProof = sectionAnalysis.proof;
    sections.push(
      makeSectionCoverage(
        base,
        section,
        value.items.length === 0 ? 'presentEmpty' : 'presentNonEmpty',
        sectionAnalysis.completeness,
        boundProof,
        value.items.length,
      ),
    );
    diagnostics.push(...sectionAnalysis.diagnostics);

    const records = value.items.map((entry, index) => ({
      index,
      object: entry.kind === 'object' ? entry.fields : null,
    }));
    const invalidRootRecords = records.filter((record) => record.object === null);
    if (invalidRootRecords.length > 0) {
      diagnostics.push(`${section}: 数组中存在非对象记录。`);
      for (const record of invalidRootRecords) {
        diagnostics.push(`${section}[${record.index}]: 根记录不是对象，无法验证 nested fields。`);
      }
    }
    for (const record of records) {
      if (record.object === null) {
        continue;
      }
      if (integerValue(record.object.data) === undefined) {
        diagnostics.push(
          `${section}[${record.index}].data: 缺少有效 dataID，记录未纳入 canonical observation。`,
        );
      }
    }

    for (const field of SNAPSHOT_HISTORY_ITEM_FIELDS) {
      let state: SnapshotCoverageState;
      if (field === 'types' || field === 'modules') {
        const nested = nestedFieldState(
          records,
          field,
          section,
          catalog,
          craftTableCatalog,
          diagnostics,
        );
        state = nested.state;
      } else if (field === 'data') {
        state = dataFieldState(records, section, catalog, null, craftTableCatalog, diagnostics);
      } else if (isTimerField(field)) {
        const objects = records.flatMap((record) =>
          record.object === null ? [] : [record.object],
        );
        state = timerFieldState(
          objects,
          value.items.length - objects.length,
          field,
          timerSchema.fields[field],
        );
      } else {
        state = fieldState(
          records.flatMap((record) => (record.object === null ? [] : [record.object])),
          value.items.length - records.filter((record) => record.object !== null).length,
          field,
          (value) => validateItemFieldValue(value, field),
        );
      }
      fields.push({ base, rawSection: section, field, state });
    }
  }

  for (const section of [...SNAPSHOT_HISTORY_NUMERIC_SECTIONS].sort()) {
    const base = snapshotHistoryBaseFromSection(section);
    const value = source.fields[section];
    if (value === undefined) {
      sections.push(
        makeSectionCoverage(
          base,
          section,
          'missing',
          'unavailable',
          proofForSection(section, sectionProofs, '源 JSON 缺少 section。'),
          0,
        ),
      );
      fields.push({ base, rawSection: section, field: 'presence', state: 'unavailable' });
      fields.push({ base, rawSection: section, field: 'data', state: 'unavailable' });
      continue;
    }

    if (value.kind !== 'array') {
      sections.push(
        makeSectionCoverage(
          base,
          section,
          'invalid',
          'partial',
          proofForSection(section, sectionProofs, 'section 不是数组。'),
          0,
        ),
      );
      fields.push({ base, rawSection: section, field: 'presence', state: 'partial' });
      fields.push({ base, rawSection: section, field: 'data', state: 'partial' });
      diagnostics.push(`${section}: 顶层值不是数组。`);
      continue;
    }

    fields.push({ base, rawSection: section, field: 'presence', state: 'complete' });
    const sectionAnalysis = analyzeSectionCoverage(section, value.items, sectionProofs[section]);
    sections.push(
      makeSectionCoverage(
        base,
        section,
        value.items.length === 0 ? 'presentEmpty' : 'presentNonEmpty',
        sectionAnalysis.completeness,
        sectionAnalysis.proof,
        value.items.length,
      ),
    );
    diagnostics.push(...sectionAnalysis.diagnostics);
    fields.push({
      base,
      rawSection: section,
      field: 'data',
      state: numericDataState(value.items, section, catalog, null, craftTableCatalog, diagnostics),
    });
  }

  for (const key of Object.keys(source.unknownFields).sort()) {
    fields.push({
      base: 'unknown',
      rawSection: '$topLevel',
      field: key,
      state: 'complete',
    });
  }

  return finalizeCoverage(schemaVersion, fields, sections, diagnostics, sourceUniverse);
}

function finalizeCoverage(
  schemaVersion: number,
  fields: SnapshotCoverageField[],
  sections: SnapshotSectionCoverage[],
  diagnostics: string[],
  sourceUniverse: SnapshotCoverageSourceUniverse | null,
): SnapshotObservationCoverage {
  return {
    schemaVersion,
    fields: [...fields].sort((left, right) =>
      snapshotCoverageFieldId(left).localeCompare(snapshotCoverageFieldId(right)),
    ),
    sections: [...sections].sort((left, right) =>
      snapshotSectionCoverageId(left).localeCompare(snapshotSectionCoverageId(right)),
    ),
    diagnostics: [...diagnostics].sort(),
    sourceUniverse,
  };
}

function makeSectionCoverage(
  base: ReturnType<typeof snapshotHistoryBaseFromSection>,
  rawSection: string,
  presence: SnapshotSectionPresence,
  completeness: SnapshotCoverageState,
  proof: SnapshotCoverageProof,
  observedCount: number,
): SnapshotSectionCoverage {
  return {
    base,
    rawSection,
    presence,
    completeness,
    proof,
    observedCount: Math.max(0, observedCount),
  };
}

function analyzeSectionCoverage(
  section: string,
  values: readonly CanonicalJsonValue[],
  proof: SnapshotCoverageProof | undefined,
): SectionCoverageAnalysis {
  if (proof === undefined) {
    return {
      completeness: 'unavailable',
      proof: { kind: 'unavailable', reason: '来源未提供 section 完整性证明。' },
      diagnostics: [],
    };
  }

  if (!isModuleIssuedVerifiedProof(proof)) {
    return { completeness: 'unavailable', proof, diagnostics: [] };
  }

  const expectedCount = coverageProofExpectedCount(proof);
  if (expectedCount !== null && expectedCount !== values.length) {
    return {
      completeness: 'partial',
      proof,
      diagnostics: [`${section}: observed count 与来源声明不一致。`],
    };
  }

  const hasInvalidElement = values.some((value) => {
    if (value.kind === 'object') {
      if (SNAPSHOT_HISTORY_NUMERIC_SECTIONS.includes(section as never)) {
        return true;
      }
      if (integerValue(value.fields.data) === undefined) {
        return true;
      }
      for (const nestedField of ['types', 'modules'] as const) {
        const nestedValue = value.fields[nestedField];
        if (nestedValue === undefined) {
          continue;
        }
        if (nestedValue.kind !== 'array') {
          return true;
        }
        if (
          nestedValue.items.some(
            (child) => child.kind !== 'object' || integerValue(child.fields.data) === undefined,
          )
        ) {
          return true;
        }
      }
      return false;
    }
    if (SNAPSHOT_HISTORY_NUMERIC_SECTIONS.includes(section as never)) {
      return integerValue(value) === undefined;
    }
    return true;
  });

  if (hasInvalidElement) {
    return {
      completeness: 'partial',
      proof,
      diagnostics: [`${section}: section 含无法解析的元素。`],
    };
  }

  return { completeness: 'complete', proof, diagnostics: [] };
}

function proofForSection(
  section: string,
  proofs: Readonly<Record<string, SnapshotCoverageProof>>,
  fallback: string,
): SnapshotCoverageProof {
  return proofs[section] ?? { kind: 'unavailable', reason: fallback };
}

function nestedFieldState(
  records: readonly ObjectRecord[],
  field: string,
  section: string,
  catalog: GameCatalog | undefined,
  craftTableCatalog: CraftTableCatalog | undefined,
  diagnostics: string[],
): { state: SnapshotCoverageState } {
  if (records.length === 0) {
    return { state: 'unavailable' };
  }

  const present = records.flatMap((record) =>
    record.object !== null && record.object[field] !== undefined
      ? [{ index: record.index, object: record.object }]
      : [],
  );
  const hasInvalidRoot = records.some(
    (record) => record.object === null || integerValue(record.object.data) === undefined,
  );
  if (present.length === 0) {
    return { state: hasInvalidRoot ? 'partial' : 'unavailable' };
  }

  let state: SnapshotCoverageState =
    hasInvalidRoot || present.length !== records.length ? 'partial' : 'complete';
  for (const record of present) {
    const path = `${section}[${record.index}].${field}`;
    const nestedValue = record.object[field];
    if (nestedValue === undefined || nestedValue.kind !== 'array') {
      state = 'partial';
      diagnostics.push(`${path}: 嵌套值不是数组。`);
      continue;
    }
    const nested = validateNestedArray(
      nestedValue.items,
      path,
      section,
      field === 'types' ? 'type' : 'module',
      catalog,
      craftTableCatalog,
    );
    diagnostics.push(...nested.diagnostics);
    if (nested.state !== 'complete') {
      state = 'partial';
    }
  }
  return { state };
}

function validateNestedArray(
  values: readonly CanonicalJsonValue[],
  path: string,
  section: string,
  nestedKind: SnapshotNestedKind,
  catalog: GameCatalog | undefined,
  craftTableCatalog: CraftTableCatalog | undefined,
): { state: SnapshotCoverageState; diagnostics: string[] } {
  const diagnostics: string[] = [];
  let complete = true;

  for (const [index, value] of values.entries()) {
    const childPath = `${path}[${index}]`;
    if (value.kind !== 'object') {
      complete = false;
      diagnostics.push(`${childPath}: 子项不是对象。`);
      continue;
    }
    const dataID = integerValue(value.fields.data);
    if (dataID !== undefined) {
      const known = isKnownDataID(dataID, section, nestedKind, catalog, craftTableCatalog);
      if (known === false) {
        complete = false;
        diagnostics.push(
          `${childPath}.data: 未知 dataID ${dataID.toString()}，不在传入 known dataID universe 中。`,
        );
      }
    } else {
      complete = false;
      diagnostics.push(`${childPath}.data: 缺少有效 dataID，记录未纳入 canonical observation。`);
    }

    for (const nestedField of ['types', 'modules'] as const) {
      const nestedValue = value.fields[nestedField];
      if (nestedValue === undefined) {
        continue;
      }
      const nestedPath = `${childPath}.${nestedField}`;
      if (nestedValue.kind !== 'array') {
        complete = false;
        diagnostics.push(`${nestedPath}: 嵌套值不是数组。`);
        continue;
      }
      const nested = validateNestedArray(
        nestedValue.items,
        nestedPath,
        section,
        nestedField === 'types' ? 'type' : 'module',
        catalog,
        craftTableCatalog,
      );
      diagnostics.push(...nested.diagnostics);
      if (nested.state !== 'complete') {
        complete = false;
      }
    }
  }

  return { state: complete ? 'complete' : 'partial', diagnostics };
}

function dataFieldState(
  records: readonly ObjectRecord[],
  section: string,
  catalog: GameCatalog | undefined,
  nestedKind: SnapshotNestedKind | null,
  craftTableCatalog: CraftTableCatalog | undefined,
  diagnostics: string[],
): SnapshotCoverageState {
  if (records.length === 0) {
    return 'complete';
  }

  let state: SnapshotCoverageState = 'complete';
  for (const record of records) {
    if (record.object === null) {
      state = 'partial';
      continue;
    }
    const dataID = integerValue(record.object.data);
    if (dataID === undefined) {
      state = 'partial';
      continue;
    }
    const known = isKnownDataID(dataID, section, nestedKind, catalog, craftTableCatalog);
    if (known === undefined) {
      continue;
    }
    if (!known) {
      state = 'partial';
      diagnostics.push(
        `${section}[${record.index}].data: 未知 dataID ${dataID.toString()}，不在传入 known dataID universe 中。`,
      );
    }
  }
  return state;
}

function numericDataState(
  values: readonly CanonicalJsonValue[],
  section: string,
  catalog: GameCatalog | undefined,
  nestedKind: SnapshotNestedKind | null,
  craftTableCatalog: CraftTableCatalog | undefined,
  diagnostics: string[],
): SnapshotCoverageState {
  if (values.length === 0) {
    return 'complete';
  }

  let state: SnapshotCoverageState = 'complete';
  for (const [index, value] of values.entries()) {
    const dataID = integerValue(value);
    if (dataID === undefined) {
      state = 'partial';
      diagnostics.push(`${section}[${index}]: 不是有效 dataID。`);
      continue;
    }
    const known = isKnownDataID(dataID, section, nestedKind, catalog, craftTableCatalog);
    if (known === undefined) {
      continue;
    }
    if (!known) {
      state = 'partial';
      diagnostics.push(
        `${section}[${index}]: 未知 dataID ${dataID.toString()}，不在传入 known dataID universe 中。`,
      );
    }
  }
  return state;
}

function appendUnavailableFields(
  base: ReturnType<typeof snapshotHistoryBaseFromSection>,
  section: string,
  fields: SnapshotCoverageField[],
): void {
  fields.push({ base, rawSection: section, field: 'presence', state: 'unavailable' });
  for (const field of SNAPSHOT_HISTORY_ITEM_FIELDS) {
    fields.push({ base, rawSection: section, field, state: 'unavailable' });
  }
}

function appendPartialFields(
  base: ReturnType<typeof snapshotHistoryBaseFromSection>,
  section: string,
  fields: SnapshotCoverageField[],
): void {
  fields.push({ base, rawSection: section, field: 'presence', state: 'partial' });
  for (const field of SNAPSHOT_HISTORY_ITEM_FIELDS) {
    fields.push({ base, rawSection: section, field, state: 'partial' });
  }
}

function fieldState(
  objects: readonly Record<string, CanonicalJsonValue>[],
  invalidObjectCount: number,
  field: string,
  isValid: (value: CanonicalJsonValue | undefined) => boolean,
): SnapshotCoverageState {
  if (objects.length === 0) {
    return invalidObjectCount === 0 ? (field === 'data' ? 'complete' : 'unavailable') : 'partial';
  }
  const present = objects.filter((object) => object[field] !== undefined);
  if (present.length === 0) {
    return field === 'data' ? 'partial' : 'unavailable';
  }
  if (
    invalidObjectCount !== 0 ||
    present.length !== objects.length ||
    !objects.every((object) => isValid(object[field]))
  ) {
    return 'partial';
  }
  return 'complete';
}

function timerFieldState(
  objects: readonly Record<string, CanonicalJsonValue>[],
  invalidObjectCount: number,
  field: string,
  spec: SnapshotTimerFieldSpec | undefined,
): SnapshotCoverageState {
  if (objects.length === 0) {
    return invalidObjectCount === 0 ? 'unavailable' : 'partial';
  }
  const present = objects.filter((object) => object[field] !== undefined);
  if (present.length === 0) {
    return invalidObjectCount === 0 ? 'complete' : 'partial';
  }
  if (
    invalidObjectCount !== 0 ||
    present.length !== objects.length ||
    !objects.every((object) => {
      const value = object[field];
      const timer = integerValue(value);
      if (timer === undefined) {
        return false;
      }
      if (timer < 0n) {
        return false;
      }
      if (spec?.minValue !== undefined && timer < BigInt(spec.minValue)) {
        return false;
      }
      if (spec?.maxValue !== undefined && timer > BigInt(spec.maxValue)) {
        return false;
      }
      return true;
    })
  ) {
    return 'partial';
  }
  return 'complete';
}

function fingerprintValueForItem(item: SnapshotObservationItem): CanonicalJsonValue {
  return jsonObject({
    count: item.count === null ? jsonNull() : jsonNumber(String(item.count)),
    gearUp: item.gearUp === null ? jsonNull() : jsonNumber(String(item.gearUp)),
    helperRecurrent: item.helperRecurrent === null ? jsonNull() : jsonBool(item.helperRecurrent),
    identity: jsonObject({
      base: jsonString(item.identity.base),
      dataID: jsonNumber(item.identity.dataID.toString()),
      nestedKind: jsonString(item.identity.nestedKind),
      nestedParentPath: jsonArray(
        item.identity.nestedParentPath.map((part) =>
          jsonObject({
            dataID: jsonNumber(part.dataID.toString()),
            kind: jsonString(part.kind),
          }),
        ),
      ),
      nestedRootDataID:
        item.identity.nestedRootDataID === null
          ? jsonNull()
          : jsonNumber(item.identity.nestedRootDataID.toString()),
      nestedRootIdentity:
        item.identity.nestedRootIdentity === null
          ? jsonNull()
          : jsonString(item.identity.nestedRootIdentity),
      rawSection: jsonString(item.identity.rawSection),
    }),
    level: item.level === null ? jsonNull() : jsonNumber(String(item.level)),
    rawTimerEvidence: jsonObject(item.rawTimerEvidence),
    unknownFields: jsonObject(item.unknownFields),
    weapon: item.weapon === null ? jsonNull() : jsonNumber(String(item.weapon)),
  });
}

function isKnownDataID(
  dataID: bigint,
  section: string,
  nestedKind: SnapshotNestedKind | null,
  catalog: GameCatalog | undefined,
  craftTableCatalog: CraftTableCatalog | undefined,
): boolean | undefined {
  if (nestedKind !== null && nestedKind !== 'root') {
    if (craftTableCatalog === undefined) {
      return undefined;
    }
    switch (nestedKind) {
      case 'type':
        return craftTableCatalog.defense(dataID) !== undefined;
      case 'module':
        return craftTableCatalog.module(dataID) !== undefined;
      default:
        return undefined;
    }
  }

  if (catalog === undefined || catalog.itemsInSection(section).length === 0) {
    return undefined;
  }
  return catalog.item(section, dataID) !== undefined;
}

function isTimerEvidenceField(
  key: string,
  observationVersion: number,
  timerSchema: SnapshotTimerSchema,
): boolean {
  if (observationVersion >= SNAPSHOT_HISTORY_SCHEMA.observationWithTimerSchema) {
    return Object.prototype.hasOwnProperty.call(timerSchema.fields, key);
  }
  if (observationVersion >= SNAPSHOT_HISTORY_SCHEMA.observationWithTimerAllowlist) {
    return SNAPSHOT_HISTORY_TIMER_FIELDS.includes(
      key as (typeof SNAPSHOT_HISTORY_TIMER_FIELDS)[number],
    );
  }
  const normalized = key.toLowerCase();
  return normalized.includes('timer') || normalized.includes('cooldown');
}

function isTimerField(field: string): boolean {
  return SNAPSHOT_HISTORY_TIMER_FIELDS.includes(
    field as (typeof SNAPSHOT_HISTORY_TIMER_FIELDS)[number],
  );
}

function validateItemFieldValue(value: CanonicalJsonValue | undefined, field: string): boolean {
  switch (field) {
    case 'data':
    case 'lvl':
    case 'cnt':
    case 'timer':
    case 'helper_timer':
    case 'helper_cooldown':
    case 'gear_up':
    case 'weapon':
      return integerValue(value) !== undefined;
    case 'helper_recurrent':
      return booleanValue(value) !== null;
    default:
      return true;
  }
}

function integerValue(value: CanonicalJsonValue | undefined): bigint | undefined {
  return parseCanonicalizerInt64(value);
}

function isModuleIssuedVerifiedProof(proof: SnapshotCoverageProof): boolean {
  return proof.kind === 'verified';
}

function booleanValue(value: CanonicalJsonValue | undefined): boolean | null {
  if (value === undefined) {
    return null;
  }
  if (value.kind !== 'bool') {
    return null;
  }
  return value.value;
}

function throwCanonicalizationError(error: SnapshotHistoryCanonicalizationError): never {
  throw new SnapshotHistoryCanonicalizationException(error);
}

export class SnapshotHistoryCanonicalizationException extends Error {
  readonly error: SnapshotHistoryCanonicalizationError;

  constructor(error: SnapshotHistoryCanonicalizationError) {
    super(snapshotHistoryCanonicalizationErrorMessage(error));
    this.name = 'SnapshotHistoryCanonicalizationException';
    this.error = error;
  }
}
