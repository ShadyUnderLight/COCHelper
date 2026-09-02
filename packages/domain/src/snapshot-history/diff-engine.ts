import {
  jsonNumber,
  refSecondsToUnixSeconds,
  type CanonicalJsonValue,
  type UuidString,
} from '@coc-helper/wire';

import {
  SNAPSHOT_DIFF_ALGORITHM_VERSION,
  createSnapshotDiff,
  createSnapshotDiffCoverage,
  snapshotDiffCoverageAddingReason,
  snapshotDiffSectionCoverageIsComplete,
  type SnapshotChange,
  type SnapshotChangeKind,
  type SnapshotDiff,
  type SnapshotDiffComparisonState,
  type SnapshotDiffContentState,
  type SnapshotDiffDiagnostic,
  type SnapshotDiffDiagnosticKind,
  type SnapshotDiffFieldCoverage,
  type SnapshotDiffSectionCoverage,
} from './diff-types';
import { sortSnapshotChanges } from './diff-ordering';
import {
  observationCoverageSection,
  observationCoverageState,
  hydratedSectionOpensTrustGates,
  sectionCoverageIsComplete,
} from './coverage-access';
import {
  snapshotHistoryCoverageDuplicateKey,
  snapshotHistoryCoverageDuplicateKeysEqual,
} from './duplicate-key';
import { SNAPSHOT_HISTORY_SCHEMA } from './schema';
import { SNAPSHOT_HISTORY_ALL_SECTIONS, SNAPSHOT_HISTORY_ITEM_FIELDS } from './known-sections';
import type { SnapshotCoverageRevalidationPolicy, SnapshotHistoryEnvelope } from './store-types';
import {
  hydrateVerifiedCoverageOnEntry,
  hydrateVerifiedCoverageOnEnvelope,
} from './trust-hydration';
import type { HydratedSnapshotHistoryEntry } from './trust-hydration';
import {
  createSnapshotItemIdentity,
  snapshotItemIdentityKey,
  type CanonicalSnapshotObservation,
  type SnapshotCoverageState,
  type SnapshotDisplayBinding,
  type SnapshotItemIdentity,
  type SnapshotObservationItem,
  type SnapshotTimerFieldSpec,
  type SnapshotTimerSchema,
} from './types';

type TimerState = 'absent' | 'inactive' | 'active' | 'unknown';

type TimerResult = {
  kind?: SnapshotChangeKind;
  isUnknown: boolean;
  reason: string;
  requiredFields: string[];
};

type Histogram = {
  levels: Map<number, number>;
  total: number;
};

type TimerNormalizedResult = 'changed' | 'unchanged' | { unstable: string };

const TIMER_ELAPSED_TOLERANCE_SECONDS = 30;
const HISTOGRAM_SECTIONS = new Set(['buildings', 'buildings2', 'traps', 'traps2']);
const LEVEL_REQUIRED_SECTIONS = new Set([
  'buildings',
  'buildings2',
  'traps',
  'traps2',
  'units',
  'units2',
  'spells',
  'heroes',
  'heroes2',
  'pets',
  'equipment',
  'siege_machines',
]);

function validLevel(value: number | null | undefined): number | undefined {
  if (value === null || value === undefined || value < 0) {
    return undefined;
  }
  return value;
}

function validQuantity(value: number | null | undefined): number | undefined {
  if (value === null || value === undefined || value < 0) {
    return undefined;
  }
  return value;
}

function stableDisplayName(
  identity: SnapshotItemIdentity,
  binding: SnapshotObservationItem['display'],
): string {
  const trimmed = binding.displayName?.trim();
  if (trimmed) {
    return trimmed;
  }
  return `${identity.rawSection}#${identity.dataID}`;
}

function diagnosticSection(message: string): string | undefined {
  const prefix = message.split(':', 1)[0];
  if (!prefix) {
    return undefined;
  }
  const bracket = prefix.indexOf('[');
  const value = bracket >= 0 ? prefix.slice(0, bracket) : prefix;
  return value.length > 0 ? value : undefined;
}

function isUsableIdentity(identity: SnapshotItemIdentity): boolean {
  return (
    identity.base !== 'unknown' &&
    identity.rawSection.length > 0 &&
    identity.dataID > 0n &&
    identity.nestedKind !== 'unknown' &&
    (identity.nestedRootDataID === null ||
      identity.nestedRootDataID === undefined ||
      identity.nestedRootDataID > 0n) &&
    identity.nestedParentPath.every(
      (component) => component.dataID > 0n && component.kind !== 'unknown',
    )
  );
}

function isHistogramIdentity(identity: SnapshotItemIdentity): boolean {
  return identity.nestedKind === 'root' && HISTOGRAM_SECTIONS.has(identity.rawSection);
}

function requiresLevel(identity: SnapshotItemIdentity): boolean {
  return identity.nestedKind === 'root' && LEVEL_REQUIRED_SECTIONS.has(identity.rawSection);
}

function nestedEnumerationIsConfirmed(identity: SnapshotItemIdentity): boolean {
  return identity.nestedKind === 'root';
}

function histogramRepresentative(
  items: readonly SnapshotObservationItem[],
): SnapshotObservationItem | undefined {
  return [...items].sort((left, right) => {
    const leftKey = [left.level ?? Number.MAX_SAFE_INTEGER, left.count ?? 0] as const;
    const rightKey = [right.level ?? Number.MAX_SAFE_INTEGER, right.count ?? 0] as const;
    if (leftKey[0] !== rightKey[0]) {
      return leftKey[0] - rightKey[0];
    }
    return leftKey[1] - rightKey[1];
  })[0];
}

function histogram(items: readonly SnapshotObservationItem[]): Histogram | undefined {
  if (items.length === 0) {
    return undefined;
  }
  const levels = new Map<number, number>();
  for (const item of items) {
    const level = validLevel(item.level);
    const quantity = validQuantity(item.count);
    if (level === undefined || quantity === undefined || quantity <= 0) {
      return undefined;
    }
    const sum = (levels.get(level) ?? 0) + quantity;
    if (!Number.isSafeInteger(sum)) {
      return undefined;
    }
    levels.set(level, sum);
  }
  let total = 0;
  for (const value of levels.values()) {
    total += value;
    if (!Number.isSafeInteger(total)) {
      return undefined;
    }
  }
  return { levels, total };
}

function coverageFor(
  identity: SnapshotItemIdentity,
  from: HydratedSnapshotHistoryEntry | undefined,
  to: HydratedSnapshotHistoryEntry | undefined,
  fields: string[],
): ReturnType<typeof createSnapshotDiffCoverage> {
  const uniqueFields = [...new Set(fields)].sort();
  const result: SnapshotDiffFieldCoverage[] = uniqueFields.map((field) => ({
    base: identity.base,
    rawSection: identity.rawSection,
    field,
    fromState:
      from === undefined
        ? 'unavailable'
        : (observationCoverageState(from, identity.base, identity.rawSection, field) ??
          'unavailable'),
    toState:
      to === undefined
        ? 'unavailable'
        : (observationCoverageState(to, identity.base, identity.rawSection, field) ??
          'unavailable'),
  }));
  return createSnapshotDiffCoverage({ fields: result });
}

function mergeCoverage(
  left: ReturnType<typeof createSnapshotDiffCoverage>,
  right: ReturnType<typeof createSnapshotDiffCoverage>,
): ReturnType<typeof createSnapshotDiffCoverage> {
  return createSnapshotDiffCoverage({
    fields: [...left.fields, ...right.fields],
    reasons: [...left.reasons, ...right.reasons],
  });
}

function sectionPresenceAndDataAreComplete(
  entry: HydratedSnapshotHistoryEntry,
  identity: SnapshotItemIdentity,
): boolean {
  return (
    observationCoverageState(entry, identity.base, identity.rawSection, 'presence') ===
      'complete' &&
    observationCoverageState(entry, identity.base, identity.rawSection, 'data') === 'complete'
  );
}

function observedItemFieldsAreComplete(
  entry: HydratedSnapshotHistoryEntry,
  item: SnapshotObservationItem | undefined,
  fields: string[],
): boolean {
  if (!item) {
    return false;
  }
  return fields.every(
    (field) =>
      observationCoverageState(entry, item.identity.base, item.identity.rawSection, field) ===
      'complete',
  );
}

function histogramIsComplete(
  entry: HydratedSnapshotHistoryEntry,
  identity: SnapshotItemIdentity,
  items: readonly SnapshotObservationItem[],
): boolean {
  return (
    items.length > 0 &&
    items.every(
      (item) => validLevel(item.level) !== undefined && validQuantity(item.count) !== undefined,
    ) &&
    ['presence', 'data', 'lvl', 'cnt'].every(
      (field) =>
        observationCoverageState(entry, identity.base, identity.rawSection, field) === 'complete',
    )
  );
}

function makeSectionCoverage(
  from: HydratedSnapshotHistoryEntry,
  to: HydratedSnapshotHistoryEntry,
): SnapshotDiffSectionCoverage[] {
  return [...SNAPSHOT_HISTORY_ALL_SECTIONS].sort().map((section) => {
    const base = createSnapshotItemIdentity(section, 0).base;
    const fromSection = observationCoverageSection(from, base, section);
    const toSection = observationCoverageSection(to, base, section);
    const fieldNames = [...SNAPSHOT_HISTORY_ITEM_FIELDS, 'presence'];
    const fromFieldStates = Object.fromEntries(
      fieldNames.map((field) => [
        field,
        observationCoverageState(from, base, section, field) ?? 'unavailable',
      ]),
    ) as Record<string, SnapshotCoverageState>;
    const toFieldStates = Object.fromEntries(
      fieldNames.map((field) => [
        field,
        observationCoverageState(to, base, section, field) ?? 'unavailable',
      ]),
    ) as Record<string, SnapshotCoverageState>;
    return {
      base,
      rawSection: section,
      fromState: fromFieldStates.presence ?? 'unavailable',
      toState: toFieldStates.presence ?? 'unavailable',
      fromDataState: fromFieldStates.data ?? 'unavailable',
      toDataState: toFieldStates.data ?? 'unavailable',
      fromSectionCompleteness: fromSection?.completeness ?? 'unavailable',
      toSectionCompleteness: toSection?.completeness ?? 'unavailable',
      fromProof: fromSection?.proof,
      toProof: toSection?.proof,
      fromTrustTrusted: fromSection ? hydratedSectionOpensTrustGates(fromSection) : false,
      toTrustTrusted: toSection ? hydratedSectionOpensTrustGates(toSection) : false,
      fromFieldStates,
      toFieldStates,
      fromObservedItemCount: from.observation.items.filter(
        (item) => item.identity.rawSection === section,
      ).length,
      toObservedItemCount: to.observation.items.filter(
        (item) => item.identity.rawSection === section,
      ).length,
    };
  });
}

function timerNumber(
  value: CanonicalJsonValue,
  spec: SnapshotTimerFieldSpec | undefined,
): number | undefined {
  if (value.kind !== 'number') {
    return undefined;
  }
  const parsed = Number(value.value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return undefined;
  }
  if (spec?.minValue !== undefined && parsed < spec.minValue) {
    return undefined;
  }
  if (spec?.maxValue !== undefined && parsed > spec.maxValue) {
    return undefined;
  }
  return parsed;
}

function timerState(
  evidence: Readonly<Record<string, CanonicalJsonValue>>,
  schema: SnapshotTimerSchema | null | undefined,
  sourceTimestampRefSeconds: number | null | undefined,
): TimerState {
  if (Object.keys(evidence).length === 0) {
    return 'absent';
  }
  let hasActive = false;
  for (const key of Object.keys(evidence).sort()) {
    const value = evidence[key];
    if (!value) {
      return 'unknown';
    }
    const number = timerNumber(value, schema?.fields[key]);
    if (number === undefined) {
      return 'unknown';
    }
    if (schema?.fields[key]?.semantics === 'absolute') {
      if (sourceTimestampRefSeconds === null || sourceTimestampRefSeconds === undefined) {
        return 'unknown';
      }
      const unit = schema.fields[key]?.unit ?? 'seconds';
      const observed =
        unit === 'milliseconds' ? sourceTimestampRefSeconds * 1000 : sourceTimestampRefSeconds;
      if (number > observed) {
        hasActive = true;
      }
    } else if (number > 0) {
      hasActive = true;
    }
  }
  return hasActive ? 'active' : 'inactive';
}

function timerSpec(
  field: string,
  entry: HydratedSnapshotHistoryEntry,
): SnapshotTimerFieldSpec | undefined {
  if (entry.observationVersion >= SNAPSHOT_HISTORY_SCHEMA.observationWithTimerSchema) {
    return entry.timerSchema?.fields[field];
  }
  return { unit: 'seconds', semantics: 'remaining', minValue: 0 };
}

function timerSpecsAreCompatible(
  left: SnapshotTimerFieldSpec,
  right: SnapshotTimerFieldSpec,
): boolean {
  if (left.unit !== right.unit || left.semantics !== right.semantics) {
    return false;
  }
  const lowerBound = (spec: SnapshotTimerFieldSpec) => spec.minValue ?? 0;
  if (left.maxValue !== right.maxValue) {
    return false;
  }
  return lowerBound(left) === lowerBound(right);
}

function timerSpecsAreConsistent(
  from: HydratedSnapshotHistoryEntry,
  to: HydratedSnapshotHistoryEntry,
  fields: string[],
): boolean {
  for (const field of fields) {
    const oldSpec = timerSpec(field, from);
    const newSpec = timerSpec(field, to);
    if (!oldSpec && !newSpec) {
      continue;
    }
    if (!oldSpec || !newSpec) {
      return false;
    }
    if (!timerSpecsAreCompatible(oldSpec, newSpec)) {
      return false;
    }
  }
  return true;
}

function timerNumbersByField(
  evidence: Readonly<Record<string, CanonicalJsonValue>>,
  schema: SnapshotTimerSchema | null | undefined,
): Record<string, number[]> {
  const result: Record<string, number[]> = {};
  for (const key of Object.keys(evidence).sort()) {
    const value = evidence[key];
    if (!value) {
      continue;
    }
    const number = timerNumber(value, schema?.fields[key]);
    if (number !== undefined) {
      result[key] = [number];
    }
  }
  return result;
}

function aggregateTimerNumbersByField(
  items: readonly SnapshotObservationItem[],
  schema: SnapshotTimerSchema | null | undefined,
): Record<string, number[]> {
  const result: Record<string, number[]> = {};
  for (const item of items) {
    for (const key of Object.keys(item.rawTimerEvidence)) {
      const value = item.rawTimerEvidence[key];
      if (!value) {
        continue;
      }
      const number = timerNumber(value, schema?.fields[key]);
      if (number === undefined) {
        continue;
      }
      result[key] = [...(result[key] ?? []), number];
    }
  }
  for (const key of Object.keys(result)) {
    result[key]?.sort((left, right) => (left < right ? -1 : left > right ? 1 : 0));
  }
  return result;
}

function normalizedTimerComparison(
  oldNumbersByField: Record<string, number[]>,
  newNumbersByField: Record<string, number[]>,
  from: HydratedSnapshotHistoryEntry,
  to: HydratedSnapshotHistoryEntry,
): TimerNormalizedResult {
  if (from.sourceTimestampRefSeconds === null || to.sourceTimestampRefSeconds === null) {
    return { unstable: 'source timestamp 缺失或非法，无法规范化 timer。' };
  }
  const fromSeconds = from.sourceTimestampRefSeconds;
  const toSeconds = to.sourceTimestampRefSeconds;
  if (fromSeconds <= 0 || toSeconds <= 0) {
    return { unstable: 'source timestamp 缺失或非法，无法规范化 timer。' };
  }
  const elapsed = toSeconds - fromSeconds;
  if (elapsed < 0) {
    return { unstable: 'source timestamp 倒序，无法规范化 timer。' };
  }
  const fields = new Set([...Object.keys(oldNumbersByField), ...Object.keys(newNumbersByField)]);
  for (const field of [...fields].sort()) {
    const oldNumbers = oldNumbersByField[field];
    const newNumbers = newNumbersByField[field];
    if (!oldNumbers?.length || !newNumbers?.length) {
      return { unstable: `timer 字段 ${field} 仅在一侧出现，无法确认 timer 变化。` };
    }
    const oldSpec = from.timerSchema?.fields[field];
    if (oldNumbers.length !== newNumbers.length) {
      return { unstable: `timer 字段 ${field} 的实例数量不一致，无法稳定配对。` };
    }
    const isMilliseconds = oldSpec?.unit === 'milliseconds';
    const elapsedInUnit = isMilliseconds ? elapsed * 1000 : elapsed;
    const tolerance = isMilliseconds
      ? TIMER_ELAPSED_TOLERANCE_SECONDS * 1000
      : TIMER_ELAPSED_TOLERANCE_SECONDS;
    for (let index = 0; index < oldNumbers.length; index += 1) {
      const oldNumber = oldNumbers[index]!;
      const newNumber = newNumbers[index]!;
      let expected: number;
      if (oldSpec?.semantics === 'absolute') {
        expected = Number(oldNumber);
      } else {
        expected = Number(oldNumber) - elapsedInUnit;
      }
      if (Math.abs(Number(newNumber) - expected) > tolerance) {
        return 'changed';
      }
    }
  }
  return 'unchanged';
}

function aggregateTimerState(
  items: readonly SnapshotObservationItem[],
  schema: SnapshotTimerSchema | null | undefined,
  sourceTimestampRefSeconds: number | null | undefined,
): TimerState {
  let hasEvidence = false;
  let hasActive = false;
  for (const item of items) {
    if (Object.keys(item.rawTimerEvidence).length === 0) {
      continue;
    }
    hasEvidence = true;
    const state = timerState(item.rawTimerEvidence, schema, sourceTimestampRefSeconds);
    if (state === 'unknown') {
      return 'unknown';
    }
    if (state === 'active') {
      hasActive = true;
    }
  }
  if (!hasEvidence) {
    return 'absent';
  }
  return hasActive ? 'active' : 'inactive';
}

function timerTransition(
  old: SnapshotObservationItem,
  next: SnapshotObservationItem,
  from: HydratedSnapshotHistoryEntry,
  to: HydratedSnapshotHistoryEntry,
): TimerResult {
  const oldState = timerState(
    old.rawTimerEvidence,
    from.timerSchema,
    from.sourceTimestampRefSeconds,
  );
  const newState = timerState(next.rawTimerEvidence, to.timerSchema, to.sourceTimestampRefSeconds);
  const fields = [
    ...new Set([...Object.keys(old.rawTimerEvidence), ...Object.keys(next.rawTimerEvidence)]),
  ].sort();
  if (fields.length === 0) {
    return { isUnknown: false, reason: '', requiredFields: [] };
  }
  if (!timerSpecsAreConsistent(from, to, fields)) {
    return {
      isUnknown: true,
      reason: '两侧 timer 契约规格不一致，不能确认 timer 变化。',
      requiredFields: fields,
    };
  }
  const coverage = coverageFor(old.identity, from, to, fields);
  if (oldState === 'unknown' || newState === 'unknown' || coverage.state !== 'complete') {
    return {
      isUnknown: true,
      reason: 'timer 原始状态或 coverage 不足，不能确认 timer 变化。',
      requiredFields: fields,
    };
  }
  if ((oldState === 'absent' || oldState === 'inactive') && newState === 'active') {
    return { kind: 'upgradeStarted', isUnknown: false, reason: '', requiredFields: fields };
  }
  if (oldState === 'active' && newState === 'active') {
    const comparison = normalizedTimerComparison(
      timerNumbersByField(old.rawTimerEvidence, from.timerSchema),
      timerNumbersByField(next.rawTimerEvidence, to.timerSchema),
      from,
      to,
    );
    if (comparison === 'changed') {
      return { kind: 'timerChanged', isUnknown: false, reason: '', requiredFields: fields };
    }
    if (typeof comparison === 'object') {
      return { isUnknown: true, reason: comparison.unstable, requiredFields: fields };
    }
  }
  if (oldState === 'active' && (newState === 'absent' || newState === 'inactive')) {
    const oldLevel = validLevel(old.level);
    const newLevel = validLevel(next.level);
    if (oldLevel !== undefined && newLevel !== undefined && newLevel > oldLevel) {
      return { kind: 'upgradeCompleted', isUnknown: false, reason: '', requiredFields: fields };
    }
    return { kind: 'timerEndedObserved', isUnknown: false, reason: '', requiredFields: fields };
  }
  return { isUnknown: false, reason: '', requiredFields: fields };
}

function aggregateTimerTransition(
  oldItems: readonly SnapshotObservationItem[],
  newItems: readonly SnapshotObservationItem[],
  from: HydratedSnapshotHistoryEntry,
  to: HydratedSnapshotHistoryEntry,
  hasCredibleLevelUp: boolean,
  sectionProofComplete: boolean,
): TimerResult {
  const oldState = aggregateTimerState(oldItems, from.timerSchema, from.sourceTimestampRefSeconds);
  const newState = aggregateTimerState(newItems, to.timerSchema, to.sourceTimestampRefSeconds);
  const fields = [
    ...new Set([
      ...oldItems.flatMap((item) => Object.keys(item.rawTimerEvidence)),
      ...newItems.flatMap((item) => Object.keys(item.rawTimerEvidence)),
    ]),
  ].sort();
  if (fields.length === 0) {
    return { isUnknown: false, reason: '', requiredFields: [] };
  }
  const identity = (newItems[0] ?? oldItems[0])?.identity;
  if (!identity) {
    return { isUnknown: false, reason: '', requiredFields: [] };
  }
  if (!timerSpecsAreConsistent(from, to, fields)) {
    return {
      isUnknown: true,
      reason: '两侧 timer 契约规格不一致，不能确认 timer 变化。',
      requiredFields: fields,
    };
  }
  const coverage = coverageFor(identity, from, to, fields);
  if (oldState === 'unknown' || newState === 'unknown' || coverage.state !== 'complete') {
    return {
      isUnknown: true,
      reason: 'timer 原始状态或 coverage 不足，不能确认 timer 变化。',
      requiredFields: fields,
    };
  }
  if ((oldState === 'absent' || oldState === 'inactive') && newState === 'active') {
    return { kind: 'upgradeStarted', isUnknown: false, reason: '', requiredFields: fields };
  }
  if (oldState === 'active' && newState === 'active') {
    const comparison = normalizedTimerComparison(
      aggregateTimerNumbersByField(oldItems, from.timerSchema ?? undefined),
      aggregateTimerNumbersByField(newItems, to.timerSchema ?? undefined),
      from,
      to,
    );
    if (comparison === 'changed') {
      return { kind: 'timerChanged', isUnknown: false, reason: '', requiredFields: fields };
    }
    if (typeof comparison === 'object') {
      return { isUnknown: true, reason: comparison.unstable, requiredFields: fields };
    }
  }
  if (oldState === 'active' && (newState === 'absent' || newState === 'inactive')) {
    if (hasCredibleLevelUp) {
      return { kind: 'upgradeCompleted', isUnknown: false, reason: '', requiredFields: fields };
    }
    if (!sectionProofComplete) {
      return {
        isUnknown: true,
        reason: 'section 完整性证据不足，不能推断 timer 结束或升级完成。',
        requiredFields: fields,
      };
    }
    return { kind: 'timerEndedObserved', isUnknown: false, reason: '', requiredFields: fields };
  }
  return { isUnknown: false, reason: '', requiredFields: fields };
}

function primaryKind(input: {
  levelKind?: SnapshotChangeKind;
  levelDelta?: number;
  timerKind?: SnapshotChangeKind;
  quantityChanged: boolean;
}): SnapshotChangeKind | undefined {
  if (input.timerKind === 'upgradeCompleted' && (input.levelDelta ?? 0) > 0) {
    return 'upgradeCompleted';
  }
  if (input.timerKind === 'upgradeStarted' && !input.levelKind) {
    return 'upgradeStarted';
  }
  if (input.timerKind === 'timerChanged' && !input.levelKind) {
    return 'timerChanged';
  }
  if (input.timerKind === 'timerEndedObserved' && !input.levelKind) {
    return 'timerEndedObserved';
  }
  if (input.levelKind) {
    return input.levelKind;
  }
  if (input.timerKind) {
    return input.timerKind;
  }
  if (input.quantityChanged) {
    return 'quantityChanged';
  }
  return undefined;
}

function makeChange(input: {
  identity: SnapshotItemIdentity;
  old?: SnapshotObservationItem;
  new?: SnapshotObservationItem;
  oldLevel?: number;
  newLevel?: number;
  oldQuantity?: number;
  newQuantity?: number;
  movedQuantity?: number;
  levelDelta?: number;
  changeKind: SnapshotChangeKind;
  related: SnapshotChangeKind[];
  evidence: SnapshotChange['evidence'];
  coverage: ReturnType<typeof createSnapshotDiffCoverage>;
}): SnapshotChange {
  const display = input.new?.display ?? input.old?.display ?? {};
  const related = [...new Set(input.related.filter((kind) => kind !== input.changeKind))].sort();
  return {
    identity: input.identity,
    displayName: stableDisplayName(input.identity, display),
    category: display.category,
    displayCategory: display.displayCategory,
    base: input.identity.base,
    oldLevel: input.oldLevel,
    newLevel: input.newLevel,
    oldQuantity: input.oldQuantity,
    newQuantity: input.newQuantity,
    movedQuantity: input.movedQuantity,
    levelDelta: input.levelDelta,
    changeKind: input.changeKind,
    relatedChangeKinds: related,
    evidence: input.evidence,
    coverage: input.coverage,
  };
}

function unknownChange(input: {
  identity: SnapshotItemIdentity;
  old?: SnapshotObservationItem;
  new?: SnapshotObservationItem;
  oldQuantity?: number;
  newQuantity?: number;
  coverage: ReturnType<typeof createSnapshotDiffCoverage>;
  reason: string;
  related?: SnapshotChangeKind[];
  degradeCoverageTo?: ReturnType<typeof createSnapshotDiffCoverage>['state'];
}): SnapshotChange {
  const finalCoverage = snapshotDiffCoverageAddingReason(
    input.coverage,
    input.reason,
    input.degradeCoverageTo ?? 'partial',
  );
  return makeChange({
    identity: input.identity,
    old: input.old,
    new: input.new,
    oldLevel: validLevel(input.old?.level),
    newLevel: validLevel(input.new?.level),
    oldQuantity: input.oldQuantity ?? validQuantity(input.old?.count),
    newQuantity: input.newQuantity ?? validQuantity(input.new?.count),
    changeKind: 'unknown',
    related: input.related ?? [],
    evidence: 'unknown',
    coverage: finalCoverage,
  });
}

function appendAggregateTimerChange(
  timerResult: TimerResult,
  identity: SnapshotItemIdentity,
  oldItems: readonly SnapshotObservationItem[],
  newItems: readonly SnapshotObservationItem[],
  from: HydratedSnapshotHistoryEntry,
  to: HydratedSnapshotHistoryEntry,
  changes: SnapshotChange[],
  diagnostics: SnapshotDiffDiagnostic[],
): void {
  const timerCoverage = coverageFor(
    identity,
    from,
    to,
    [...new Set(timerResult.requiredFields)].sort(),
  );
  if (timerResult.kind) {
    changes.push(
      makeChange({
        identity,
        old: oldItems[0],
        new: newItems[0],
        changeKind: timerResult.kind,
        related: timerResult.kind === 'upgradeCompleted' ? ['levelIncreased'] : [],
        evidence: 'aggregateInferred',
        coverage: timerCoverage,
      }),
    );
    return;
  }
  if (timerResult.isUnknown) {
    const reason = timerResult.reason || 'timer 证据不足，无法确认变化。';
    changes.push(
      unknownChange({
        identity,
        old: oldItems[0],
        new: newItems[0],
        coverage: snapshotDiffCoverageAddingReason(timerCoverage, reason, 'partial'),
        reason,
      }),
    );
    diagnostics.push({
      kind: 'insufficientCoverage',
      message: reason,
      identity,
      rawSection: identity.rawSection,
    });
  }
}

function observationIdentityMatches(
  left: CanonicalSnapshotObservation,
  right: CanonicalSnapshotObservation,
): boolean {
  if (
    left.schemaVersion !== right.schemaVersion ||
    JSON.stringify(left.rawTopLevelFields) !== JSON.stringify(right.rawTopLevelFields) ||
    JSON.stringify(left.unknownTopLevelFields) !== JSON.stringify(right.unknownTopLevelFields) ||
    left.items.length !== right.items.length
  ) {
    return false;
  }
  const leftItems = [...left.items].sort((a, b) =>
    snapshotItemIdentityKey(a.identity).localeCompare(snapshotItemIdentityKey(b.identity)),
  );
  const rightItems = [...right.items].sort((a, b) =>
    snapshotItemIdentityKey(a.identity).localeCompare(snapshotItemIdentityKey(b.identity)),
  );
  return leftItems.every((leftItem, index) => {
    const rightItem = rightItems[index]!;
    return (
      snapshotItemIdentityKey(leftItem.identity) === snapshotItemIdentityKey(rightItem.identity) &&
      leftItem.level === rightItem.level &&
      leftItem.count === rightItem.count &&
      JSON.stringify(leftItem.rawTimerEvidence) === JSON.stringify(rightItem.rawTimerEvidence) &&
      leftItem.helperRecurrent === rightItem.helperRecurrent &&
      leftItem.gearUp === rightItem.gearUp &&
      leftItem.weapon === rightItem.weapon &&
      JSON.stringify(leftItem.unknownFields) === JSON.stringify(rightItem.unknownFields)
    );
  });
}

function isProvenanceOnlyPair(
  from: HydratedSnapshotHistoryEntry,
  to: HydratedSnapshotHistoryEntry,
): boolean {
  if (JSON.stringify(from.timerSchema) === JSON.stringify(to.timerSchema)) {
    return false;
  }
  if (
    !snapshotHistoryCoverageDuplicateKeysEqual(
      snapshotHistoryCoverageDuplicateKey(from.coverage),
      snapshotHistoryCoverageDuplicateKey(to.coverage),
    )
  ) {
    return false;
  }
  return observationIdentityMatches(from.observation, to.observation);
}

function provenanceTimerFields(
  from: HydratedSnapshotHistoryEntry,
  to: HydratedSnapshotHistoryEntry,
): string[] {
  const fields = new Set<string>();
  for (const key of Object.keys(from.timerSchema?.fields ?? {})) {
    fields.add(key);
  }
  for (const key of Object.keys(to.timerSchema?.fields ?? {})) {
    fields.add(key);
  }
  for (const item of from.observation.items) {
    for (const key of Object.keys(item.rawTimerEvidence)) {
      fields.add(key);
    }
  }
  for (const item of to.observation.items) {
    for (const key of Object.keys(item.rawTimerEvidence)) {
      fields.add(key);
    }
  }
  return [...fields].sort();
}

function blockingObservationDiagnostics(
  entry: HydratedSnapshotHistoryEntry,
): SnapshotDiffDiagnostic[] {
  const diagnostics: SnapshotDiffDiagnostic[] = [];
  const groups = new Map<string, SnapshotObservationItem[]>();
  for (const item of entry.observation.items) {
    const key = snapshotItemIdentityKey(item.identity);
    groups.set(key, [...(groups.get(key) ?? []), item]);
  }
  for (const key of [...groups.keys()].sort()) {
    const items = groups.get(key) ?? [];
    const representative = items[0];
    if (!representative) {
      continue;
    }
    const identity = representative.identity;
    if (!isUsableIdentity(identity)) {
      diagnostics.push({
        kind: 'unknownIdentity',
        message: '发现无法确认的历史 identity。',
        identity,
        rawSection: identity.rawSection,
      });
      continue;
    }
    if (isHistogramIdentity(identity)) {
      if (items.length > 0 && !histogram(items)) {
        diagnostics.push({
          kind: 'malformedObservation',
          message: '重复建筑/城墙 histogram 的 level/count 无效或总量溢出。',
          identity,
          rawSection: identity.rawSection,
        });
      }
      continue;
    }
    if (items.length > 1) {
      diagnostics.push({
        kind: 'malformedObservation',
        message: '唯一 identity 出现重复记录，已保留为 unknown。',
        identity,
        rawSection: identity.rawSection,
      });
      continue;
    }
    const item = items[0];
    if (!item) {
      continue;
    }
    if (requiresLevel(identity) && validLevel(item.level) === undefined) {
      diagnostics.push({
        kind: 'insufficientCoverage',
        message: 'level 缺失或非法。',
        identity,
        rawSection: identity.rawSection,
      });
    }
    if (item.count !== null && validQuantity(item.count) === undefined) {
      diagnostics.push({
        kind: 'insufficientCoverage',
        message: 'count 缺失或非法。',
        identity,
        rawSection: identity.rawSection,
      });
    }
  }
  return diagnostics;
}

function compareExistingUnique(
  old: SnapshotObservationItem,
  next: SnapshotObservationItem,
  from: HydratedSnapshotHistoryEntry,
  to: HydratedSnapshotHistoryEntry,
  changes: SnapshotChange[],
  diagnostics: SnapshotDiffDiagnostic[],
): void {
  const related: SnapshotChangeKind[] = [];
  const semanticKinds: SnapshotChangeKind[] = [];
  const reasons: string[] = [];
  const requiredFields = ['data'];

  const oldLevel = validLevel(old.level);
  const newLevel = validLevel(next.level);
  const levelIsRequired = requiresLevel(old.identity);
  const levelWasReported = old.level !== null || next.level !== null;
  const levelProblem = levelIsRequired && (oldLevel === undefined || newLevel === undefined);
  let levelKind: SnapshotChangeKind | undefined;
  let levelDelta: number | undefined;
  if (oldLevel !== undefined && newLevel !== undefined) {
    if (oldLevel !== newLevel) {
      levelDelta = newLevel - oldLevel;
      levelKind = newLevel > oldLevel ? 'levelIncreased' : 'levelDecreased';
      semanticKinds.push(levelKind);
      requiredFields.push('lvl');
    }
  } else if (levelProblem) {
    reasons.push('level 缺失或非法');
    requiredFields.push('lvl');
  } else if (levelIsRequired || levelWasReported) {
    requiredFields.push('lvl');
  }

  const oldCount = validQuantity(old.count);
  const newCount = validQuantity(next.count);
  let quantityProblem = false;
  if (old.count !== null || next.count !== null) {
    requiredFields.push('cnt');
    if (oldCount !== undefined && newCount !== undefined) {
      if (oldCount !== newCount) {
        semanticKinds.push('quantityChanged');
      }
    } else {
      quantityProblem = true;
      reasons.push('count 缺失或非法');
    }
  }

  const timer = timerTransition(old, next, from, to);
  if (timer.kind || timer.isUnknown) {
    requiredFields.push(...timer.requiredFields);
  }
  if (timer.kind) {
    semanticKinds.push(timer.kind);
  }
  if (timer.isUnknown) {
    reasons.push(timer.reason);
  }

  if (semanticKinds.length === 0 && reasons.length === 0) {
    return;
  }

  const coverage = coverageFor(old.identity, from, to, [...new Set(requiredFields)].sort());
  const semanticUnknown =
    levelProblem || quantityProblem || timer.isUnknown || coverage.state !== 'complete';
  if (semanticUnknown) {
    const reason =
      reasons.length === 0 ? '变化所需字段 coverage 不足。' : `${[...reasons].sort().join('；')}。`;
    changes.push(
      unknownChange({
        identity: old.identity,
        old,
        new: next,
        coverage: snapshotDiffCoverageAddingReason(coverage, reason, 'partial'),
        reason,
        related: semanticKinds,
      }),
    );
    diagnostics.push({
      kind: 'insufficientCoverage',
      message: reason,
      identity: old.identity,
      rawSection: old.identity.rawSection,
    });
    return;
  }

  const quantityChanged = oldCount !== undefined && newCount !== undefined && oldCount !== newCount;
  const primary = primaryKind({
    levelKind,
    levelDelta,
    timerKind: timer.kind,
    quantityChanged,
  });
  if (!primary) {
    return;
  }
  const uniqueKinds = [...new Set(semanticKinds)].filter((kind) => kind !== primary);
  related.push(...uniqueKinds);
  const delta = oldLevel !== undefined && newLevel !== undefined ? newLevel - oldLevel : undefined;
  changes.push(
    makeChange({
      identity: old.identity,
      old,
      new: next,
      oldLevel,
      newLevel,
      oldQuantity: quantityChanged ? oldCount : undefined,
      newQuantity: quantityChanged ? newCount : undefined,
      levelDelta: delta,
      changeKind: primary,
      related,
      evidence: 'confirmed',
      coverage,
    }),
  );
}

function compareUnique(
  old: SnapshotObservationItem | undefined,
  next: SnapshotObservationItem | undefined,
  from: HydratedSnapshotHistoryEntry,
  to: HydratedSnapshotHistoryEntry,
  changes: SnapshotChange[],
  diagnostics: SnapshotDiffDiagnostic[],
): void {
  const identity = next?.identity ?? old?.identity;
  if (!identity) {
    return;
  }
  if (old && next) {
    compareExistingUnique(old, next, from, to, changes, diagnostics);
    return;
  }

  const observedOnNew = next !== undefined;
  const presenceSide = observedOnNew ? from : to;
  const observedSide = observedOnNew ? to : from;
  const observed = next ?? old;
  if (observed === undefined) {
    return;
  }
  const presenceCoverage = coverageFor(identity, from, to, ['presence', 'data']);
  const observedFields = ['data'];
  if (requiresLevel(identity)) {
    observedFields.push('lvl');
  }
  if (observed.count !== null) {
    observedFields.push('cnt');
  }
  const observedEntry = observedOnNew ? to : from;
  const observedCoverage = coverageFor(identity, observedEntry, observedEntry, observedFields);
  const coverage = mergeCoverage(presenceCoverage, observedCoverage);
  const universeComplete = sectionPresenceAndDataAreComplete(presenceSide, identity);
  const universeProofComplete =
    sectionCoverageIsComplete(presenceSide, identity) && nestedEnumerationIsConfirmed(identity);
  const itemComplete = observedItemFieldsAreComplete(observedSide, observed, observedFields);
  const kind: SnapshotChangeKind = observedOnNew ? 'newlyObserved' : 'noLongerObserved';

  if (universeComplete && universeProofComplete && itemComplete && coverage.state === 'complete') {
    changes.push(
      makeChange({
        identity,
        old,
        new: next,
        oldQuantity: validQuantity(old?.count),
        newQuantity: validQuantity(next?.count),
        changeKind: kind,
        related: [],
        evidence: 'confirmed',
        coverage,
      }),
    );
    return;
  }

  const reason =
    universeComplete && universeProofComplete
      ? '项目自身字段 coverage 不足，不能确认观察变化。'
      : '对应 section/presence coverage 不完整，不能确认新增或消失。';
  changes.push(
    unknownChange({
      identity,
      old,
      new: next,
      coverage: snapshotDiffCoverageAddingReason(
        coverage,
        reason,
        universeComplete && universeProofComplete ? 'partial' : 'insufficient',
      ),
      reason,
    }),
  );
  diagnostics.push({
    kind: 'insufficientCoverage',
    message: reason,
    identity,
    rawSection: identity.rawSection,
  });
}

function compareHistogram(
  oldItems: readonly SnapshotObservationItem[],
  newItems: readonly SnapshotObservationItem[],
  from: HydratedSnapshotHistoryEntry,
  to: HydratedSnapshotHistoryEntry,
  changes: SnapshotChange[],
  diagnostics: SnapshotDiffDiagnostic[],
): void {
  const representative = newItems[0] ?? oldItems[0];
  if (!representative) {
    return;
  }
  const identity = representative.identity;
  const coverage = coverageFor(identity, from, to, ['presence', 'data', 'lvl', 'cnt']);

  if (oldItems.length === 0 || newItems.length === 0) {
    const observedOnNew = newItems.length > 0;
    const presenceSide = observedOnNew ? from : to;
    const observedSide = observedOnNew ? to : from;
    const oldHistogram = histogram(oldItems);
    const newHistogram = histogram(newItems);
    const observedHistogram = observedOnNew ? newHistogram : oldHistogram;
    const universeComplete = sectionPresenceAndDataAreComplete(presenceSide, identity);
    const observedComplete = observedOnNew
      ? histogramIsComplete(observedSide, identity, newItems)
      : sectionPresenceAndDataAreComplete(observedSide, identity);
    const observedProofComplete = sectionCoverageIsComplete(observedSide, identity);
    const presenceProofComplete = sectionCoverageIsComplete(presenceSide, identity);
    const changeCoverage = mergeCoverage(
      coverageFor(identity, presenceSide, presenceSide, ['presence', 'data']),
      observedOnNew
        ? coverageFor(identity, observedSide, observedSide, ['data', 'lvl', 'cnt'])
        : coverageFor(identity, observedSide, observedSide, ['presence', 'data']),
    );
    if (
      universeComplete &&
      presenceProofComplete &&
      observedProofComplete &&
      observedComplete &&
      observedHistogram
    ) {
      const total = observedHistogram.total;
      changes.push(
        makeChange({
          identity,
          old: oldItems[0],
          new: newItems[0],
          oldQuantity: observedOnNew ? undefined : total,
          newQuantity: observedOnNew ? total : undefined,
          changeKind: observedOnNew ? 'newlyObserved' : 'noLongerObserved',
          related: [],
          evidence: 'confirmed',
          coverage: changeCoverage,
        }),
      );
      return;
    }
  }

  const oldHistogram = histogram(oldItems);
  const newHistogram = histogram(newItems);
  if (!oldHistogram || !newHistogram) {
    const sectionProofComplete =
      sectionCoverageIsComplete(from, identity) && sectionCoverageIsComplete(to, identity);
    const timerResult = aggregateTimerTransition(
      oldItems,
      newItems,
      from,
      to,
      false,
      sectionProofComplete,
    );
    if (timerResult.kind || timerResult.isUnknown) {
      appendAggregateTimerChange(
        timerResult,
        identity,
        oldItems,
        newItems,
        from,
        to,
        changes,
        diagnostics,
      );
      if (timerResult.kind) {
        diagnostics.push({
          kind: 'insufficientCoverage',
          message: '重复建筑/城墙 histogram 的 level/count 无效或总量溢出；等级/数量指标数据不足。',
          identity,
          rawSection: identity.rawSection,
        });
      }
      return;
    }
    const reason = '重复建筑/城墙 histogram 的 level/count 无效或总量溢出。';
    changes.push(
      unknownChange({
        identity,
        old: oldItems[0],
        new: newItems[0],
        coverage: snapshotDiffCoverageAddingReason(coverage, reason, 'partial'),
        reason,
      }),
    );
    diagnostics.push({
      kind: 'insufficientCoverage',
      message: reason,
      identity,
      rawSection: identity.rawSection,
    });
    return;
  }

  const sectionProofComplete =
    sectionCoverageIsComplete(from, identity) && sectionCoverageIsComplete(to, identity);
  if (coverage.state !== 'complete' || !sectionProofComplete) {
    const timerResult = aggregateTimerTransition(
      oldItems,
      newItems,
      from,
      to,
      false,
      sectionProofComplete,
    );
    if (timerResult.kind) {
      appendAggregateTimerChange(
        timerResult,
        identity,
        oldItems,
        newItems,
        from,
        to,
        changes,
        diagnostics,
      );
    }
    const reason = '重复建筑/城墙 histogram 的 section、level 或 count coverage 不完整。';
    changes.push(
      unknownChange({
        identity,
        old: oldItems[0],
        new: newItems[0],
        oldQuantity: oldHistogram.total,
        newQuantity: newHistogram.total,
        coverage: snapshotDiffCoverageAddingReason(
          coverage,
          reason,
          sectionProofComplete ? 'partial' : 'insufficient',
        ),
        reason,
      }),
    );
    diagnostics.push({
      kind: 'insufficientCoverage',
      message: reason,
      identity,
      rawSection: identity.rawSection,
    });
    return;
  }

  const oldRemaining = new Map(oldHistogram.levels);
  const newRemaining = new Map(newHistogram.levels);
  let anyLevelUp = false;
  for (const level of [...new Set([...oldRemaining.keys(), ...newRemaining.keys()])]) {
    const unchanged = Math.min(oldRemaining.get(level) ?? 0, newRemaining.get(level) ?? 0);
    oldRemaining.set(level, (oldRemaining.get(level) ?? 0) - unchanged);
    newRemaining.set(level, (newRemaining.get(level) ?? 0) - unchanged);
  }

  const oldLevels = [...oldRemaining.entries()]
    .filter(([, count]) => count > 0)
    .map(([level]) => level)
    .sort((a, b) => a - b);
  const newLevels = [...newRemaining.entries()]
    .filter(([, count]) => count > 0)
    .map(([level]) => level)
    .sort((a, b) => a - b);
  let oldIndex = 0;
  let newIndex = 0;
  const pendingChanges: SnapshotChange[] = [];
  while (oldIndex < oldLevels.length && newIndex < newLevels.length) {
    const oldLevel = oldLevels[oldIndex]!;
    const newLevel = newLevels[newIndex]!;
    const delta = newLevel - oldLevel;
    if (delta <= 0) {
      break;
    }
    const moved = Math.min(oldRemaining.get(oldLevel) ?? 0, newRemaining.get(newLevel) ?? 0);
    anyLevelUp = true;
    pendingChanges.push(
      makeChange({
        identity,
        old: oldItems[0],
        new: newItems[0],
        oldLevel,
        newLevel,
        oldQuantity: oldHistogram.levels.get(oldLevel),
        newQuantity: newHistogram.levels.get(newLevel),
        movedQuantity: moved,
        levelDelta: delta,
        changeKind: 'levelIncreased',
        related: [],
        evidence: 'aggregateInferred',
        coverage,
      }),
    );
    oldRemaining.set(oldLevel, (oldRemaining.get(oldLevel) ?? 0) - moved);
    newRemaining.set(newLevel, (newRemaining.get(newLevel) ?? 0) - moved);
    if ((oldRemaining.get(oldLevel) ?? 0) === 0) {
      oldIndex += 1;
    }
    if ((newRemaining.get(newLevel) ?? 0) === 0) {
      newIndex += 1;
    }
  }

  const oldResidual = [...oldRemaining.values()].some((count) => count > 0);
  const newResidual = [...newRemaining.values()].some((count) => count > 0);
  if (oldResidual || newResidual) {
    const timerResult = aggregateTimerTransition(
      oldItems,
      newItems,
      from,
      to,
      false,
      sectionProofComplete,
    );
    if (timerResult.kind || timerResult.isUnknown) {
      appendAggregateTimerChange(
        timerResult,
        identity,
        oldItems,
        newItems,
        from,
        to,
        changes,
        diagnostics,
      );
    }
    const oldSummary = [...oldRemaining.entries()]
      .filter(([, count]) => count > 0)
      .sort(([left], [right]) => left - right)
      .map(([level, count]) => `Lv.${level} ×${count}`)
      .join('、');
    const newSummary = [...newRemaining.entries()]
      .filter(([, count]) => count > 0)
      .sort(([left], [right]) => left - right)
      .map(([level, count]) => `Lv.${level} ×${count}`)
      .join('、');
    const residualParts: string[] = [];
    if (oldSummary) {
      residualParts.push(`旧侧未配对：${oldSummary}`);
    }
    if (newSummary) {
      residualParts.push(`新侧未配对：${newSummary}`);
    }
    const reason = `重复建筑/城墙 histogram 无法守恒解释（${residualParts.join('；')}），fail-closed。`;
    changes.push(
      unknownChange({
        identity,
        old: histogramRepresentative(oldItems),
        new: histogramRepresentative(newItems),
        oldQuantity: oldHistogram.total,
        newQuantity: newHistogram.total,
        coverage: snapshotDiffCoverageAddingReason(coverage, reason, 'complete'),
        reason,
        degradeCoverageTo: 'complete',
      }),
    );
    diagnostics.push({
      kind: 'insufficientCoverage',
      message: reason,
      identity,
      rawSection: identity.rawSection,
    });
    return;
  }

  changes.push(...pendingChanges);
  const timerResult = aggregateTimerTransition(
    oldItems,
    newItems,
    from,
    to,
    anyLevelUp,
    sectionProofComplete,
  );
  if (timerResult.kind || timerResult.isUnknown) {
    appendAggregateTimerChange(
      timerResult,
      identity,
      oldItems,
      newItems,
      from,
      to,
      changes,
      diagnostics,
    );
  }
}

function pushDiagnostic(
  diagnostics: SnapshotDiffDiagnostic[],
  kind: SnapshotDiffDiagnosticKind,
  message: string,
  extra: Partial<SnapshotDiffDiagnostic> = {},
): void {
  diagnostics.push({ kind, message, ...extra });
}

export const SnapshotDiffEngine = {
  diff(from: HydratedSnapshotHistoryEntry, to: HydratedSnapshotHistoryEntry): SnapshotDiff {
    return SnapshotDiffEngine.compare(from, to);
  },

  compare(from: HydratedSnapshotHistoryEntry, to: HydratedSnapshotHistoryEntry): SnapshotDiff {
    const diagnostics: SnapshotDiffDiagnostic[] = [];
    const sectionCoverage = makeSectionCoverage(from, to);
    diagnostics.push(
      ...from.coverage.diagnostics
        .slice()
        .sort()
        .map((message): SnapshotDiffDiagnostic => ({
          kind: 'malformedObservation',
          message: `from snapshot: ${message}`,
          rawSection: diagnosticSection(message),
        })),
    );
    diagnostics.push(
      ...to.coverage.diagnostics
        .slice()
        .sort()
        .map((message): SnapshotDiffDiagnostic => ({
          kind: 'malformedObservation',
          message: `to snapshot: ${message}`,
          rawSection: diagnosticSection(message),
        })),
    );

    if (from.villageID !== to.villageID) {
      pushDiagnostic(diagnostics, 'villageMismatch', '不同 villageID 的历史记录禁止比较。');
      return finalizeDiff(from, to, {
        comparisonState: 'suppressed',
        contentState: 'contentInsufficient',
        sectionCoverage,
        diagnostics,
      });
    }

    if (from.lineageID !== to.lineageID) {
      pushDiagnostic(diagnostics, 'lineageMismatch', '不同 lineageID 的历史记录禁止比较。');
      return finalizeDiff(from, to, {
        comparisonState: 'suppressed',
        contentState: 'contentInsufficient',
        sectionCoverage,
        diagnostics,
      });
    }

    if (to.isBaseline) {
      pushDiagnostic(
        diagnostics,
        'baseline',
        'baseline 没有 predecessor，禁止把它解释为历史变化。',
      );
      return finalizeDiff(from, to, {
        comparisonState: 'suppressed',
        contentState: 'contentInsufficient',
        sectionCoverage,
        diagnostics,
      });
    }

    if (from.snapshotID === to.snapshotID) {
      pushDiagnostic(diagnostics, 'duplicateSnapshotID', '相同 snapshotID 不能形成历史变化。');
      return finalizeDiff(from, to, {
        comparisonState: 'suppressed',
        contentState: 'contentInsufficient',
        sectionCoverage,
        diagnostics,
      });
    }

    if (isProvenanceOnlyPair(from, to)) {
      if (!timerSpecsAreConsistent(from, to, provenanceTimerFields(from, to))) {
        pushDiagnostic(
          diagnostics,
          'incomparableTimerSchema',
          '观察内容未变，但两侧 timer 契约不一致，不能确认 timer 变化。',
        );
      }
      diagnostics.push(...blockingObservationDiagnostics(from));
      return finalizeDiff(from, to, {
        comparisonState: 'provenanceOnly',
        contentState: 'provenanceOnly',
        sectionCoverage,
        changes: [],
        diagnostics,
      });
    }

    const hasComparableSection = sectionCoverage.some((section) =>
      snapshotDiffSectionCoverageIsComplete(section),
    );
    if (
      !hasComparableSection &&
      from.observation.items.length === 0 &&
      to.observation.items.length === 0
    ) {
      pushDiagnostic(
        diagnostics,
        'insufficientCoverage',
        '两个历史记录都没有可比较的完整 section coverage。',
      );
      return finalizeDiff(from, to, {
        comparisonState: 'insufficientCoverage',
        contentState: 'contentInsufficient',
        sectionCoverage,
        diagnostics,
      });
    }

    const changes: SnapshotChange[] = [];
    const oldGroups = new Map<string, SnapshotObservationItem[]>();
    const newGroups = new Map<string, SnapshotObservationItem[]>();
    for (const item of from.observation.items) {
      const key = snapshotItemIdentityKey(item.identity);
      oldGroups.set(key, [...(oldGroups.get(key) ?? []), item]);
    }
    for (const item of to.observation.items) {
      const key = snapshotItemIdentityKey(item.identity);
      newGroups.set(key, [...(newGroups.get(key) ?? []), item]);
    }
    const keys = [...new Set([...oldGroups.keys(), ...newGroups.keys()])].sort();

    for (const key of keys) {
      const oldItems = oldGroups.get(key) ?? [];
      const newItems = newGroups.get(key) ?? [];
      const representative = newItems[0] ?? oldItems[0];
      if (!representative) {
        continue;
      }
      if (!isUsableIdentity(representative.identity)) {
        const coverage = snapshotDiffCoverageAddingReason(
          coverageFor(representative.identity, from, to, ['data']),
          'identity 无法确认，保留为 unknown。',
          'insufficient',
        );
        changes.push(
          unknownChange({
            identity: representative.identity,
            old: oldItems[0],
            new: newItems[0],
            coverage,
            reason: 'identity 无法确认，不能安全 join。',
          }),
        );
        diagnostics.push({
          kind: 'unknownIdentity',
          message: '发现无法确认的历史 identity。',
          identity: representative.identity,
          rawSection: representative.identity.rawSection,
        });
        continue;
      }

      if (isHistogramIdentity(representative.identity)) {
        compareHistogram(oldItems, newItems, from, to, changes, diagnostics);
      } else if (oldItems.length > 1 || newItems.length > 1) {
        const coverage = snapshotDiffCoverageAddingReason(
          coverageFor(representative.identity, from, to, ['data', 'lvl', 'cnt']),
          '唯一 identity 在同一快照中出现多次，不能按实例猜测。',
          'insufficient',
        );
        changes.push(
          unknownChange({
            identity: representative.identity,
            old: oldItems[0],
            new: newItems[0],
            coverage,
            reason: '唯一 identity 出现重复记录。',
          }),
        );
        diagnostics.push({
          kind: 'malformedObservation',
          message: '唯一 identity 出现重复记录，已保留为 unknown。',
          identity: representative.identity,
          rawSection: representative.identity.rawSection,
        });
      } else {
        compareUnique(oldItems[0], newItems[0], from, to, changes, diagnostics);
      }
    }

    const hasInsufficientDiagnostic = diagnostics.some(
      (diagnostic) =>
        diagnostic.kind === 'insufficientCoverage' ||
        diagnostic.kind === 'unknownIdentity' ||
        diagnostic.kind === 'malformedObservation',
    );
    const hasKnownChange = changes.some(
      (change) => change.evidence !== 'unknown' && change.coverage.state !== 'insufficient',
    );
    const comparisonState: SnapshotDiffComparisonState =
      !hasKnownChange && hasInsufficientDiagnostic ? 'insufficientCoverage' : 'comparable';
    let contentState: SnapshotDiffContentState;
    if (comparisonState === 'insufficientCoverage') {
      contentState = 'contentInsufficient';
    } else if (changes.length > 0) {
      contentState = 'contentChanged';
    } else {
      contentState = 'comparableNoChange';
    }

    return finalizeDiff(from, to, {
      comparisonState,
      contentState,
      sectionCoverage,
      changes,
      diagnostics,
    });
  },

  adjacentDiffs(
    entries: readonly HydratedSnapshotHistoryEntry[],
    villageID?: UuidString,
    lineageID?: UuidString,
  ): SnapshotDiff[] {
    if (entries.length < 2) {
      return [];
    }
    const diffs: SnapshotDiff[] = [];
    for (let index = 1; index < entries.length; index += 1) {
      const previous = entries[index - 1]!;
      const current = entries[index]!;
      if (previous.villageID !== current.villageID || previous.lineageID !== current.lineageID) {
        continue;
      }
      if (
        villageID !== undefined &&
        (previous.villageID !== villageID || current.villageID !== villageID)
      ) {
        continue;
      }
      if (
        lineageID !== undefined &&
        (previous.lineageID !== lineageID || current.lineageID !== lineageID)
      ) {
        continue;
      }
      diffs.push(SnapshotDiffEngine.compare(previous, current));
    }
    return diffs;
  },

  adjacentDiffsInEnvelope(
    envelope: SnapshotHistoryEnvelope,
    villageID?: UuidString,
    lineageID?: UuidString,
    policy: SnapshotCoverageRevalidationPolicy = 'production',
  ): SnapshotDiff[] {
    const hydrated = hydrateVerifiedCoverageOnEnvelope({ envelope, policy });
    const entries = hydrated.entries.map((entry) =>
      hydrateVerifiedCoverageOnEntry({ entry, policy }),
    );
    return SnapshotDiffEngine.adjacentDiffs(entries, villageID, lineageID);
  },
};

function finalizeDiff(
  from: HydratedSnapshotHistoryEntry,
  to: HydratedSnapshotHistoryEntry,
  input: {
    comparisonState: SnapshotDiffComparisonState;
    contentState: SnapshotDiffContentState;
    sectionCoverage: SnapshotDiffSectionCoverage[];
    changes?: SnapshotChange[];
    diagnostics: SnapshotDiffDiagnostic[];
  },
): SnapshotDiff {
  return createSnapshotDiff({
    fromSnapshotID: from.snapshotID,
    toSnapshotID: to.snapshotID,
    villageID: from.villageID,
    lineageID: from.lineageID,
    fromAppliedAt: new Date(refSecondsToUnixSeconds(from.appliedAtRefSeconds) * 1000),
    toAppliedAt: new Date(refSecondsToUnixSeconds(to.appliedAtRefSeconds) * 1000),
    algorithmVersion: SNAPSHOT_DIFF_ALGORITHM_VERSION,
    comparisonState: input.comparisonState,
    contentState: input.contentState,
    sectionCoverage: input.sectionCoverage,
    changes: sortSnapshotChanges(input.changes ?? []),
    diagnostics: input.diagnostics,
  });
}

export function createSnapshotObservationItem(input: {
  identity: SnapshotItemIdentity;
  level?: number | null;
  count?: number | null;
  timer?: number;
  display?: SnapshotDisplayBinding;
}): SnapshotObservationItem {
  return {
    identity: input.identity,
    level: input.level ?? null,
    count: input.count ?? null,
    rawTimerEvidence: input.timer === undefined ? {} : { timer: jsonNumber(String(input.timer)) },
    helperRecurrent: null,
    gearUp: null,
    weapon: null,
    unknownFields: {},
    display: input.display ?? {},
  };
}
