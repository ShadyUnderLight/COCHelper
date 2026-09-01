import type { UuidString } from '@coc-helper/wire';
import { generateUuid } from '@coc-helper/wire';

import type { CatalogDurationState } from '../catalog/duration-state';
import type { CatalogUpgradeCost } from '../catalog/types';
import type { ManualUpgradeError } from './errors';
import { computeManualCoreContentFingerprint, manualUpgradeCoresEqual } from './fingerprint';
import {
  createManualLevelDistribution,
  createManualLevelQuantity,
  manualLevelDistributionAddChecked,
  manualLevelDistributionSubtractChecked,
  MANUAL_LEVEL_DISTRIBUTION_EMPTY,
} from './level-distribution';
import {
  baselineReferencesEqual,
  createManualImportedObservation,
  createManualItemState,
  createManualUpgradeRecord,
  isManualItemStateStructurallyValid,
  trackerItemKeysEqual,
} from './models';
import type {
  ManualBaselineReference,
  ManualCatalogProvenance,
  ManualEffectiveItemState,
  ManualItemState,
  ManualItemStatus,
  ManualLevelDistribution,
  ManualUpgradeCore,
  ManualUpgradeRecord,
  TrackerItemKey,
} from './types';
import { manualEffectiveItemState, trackerItemKeyStableId } from './types';

type StartUpgradeInput = {
  readonly itemKey: TrackerItemKey;
  readonly fromLevel: number;
  readonly targetLevel: number;
  readonly quantity: bigint;
  readonly startedAtMs: number;
  readonly durationState: CatalogDurationState | null;
  readonly frozenCosts: readonly CatalogUpgradeCost[] | null;
  readonly catalogProvenance: ManualCatalogProvenance;
  readonly baselineReference: ManualBaselineReference;
  readonly queueKind?: string | null;
  readonly recordID?: UuidString;
  readonly nowMs: number;
};

type ResolvedTiming = {
  readonly kind: 'timed' | 'instant';
  readonly durationSeconds: bigint;
  readonly expectedEndAtMs: number;
};

type MutableCore = {
  itemStates: ManualItemState[];
  records: ManualUpgradeRecord[];
  fingerprintRefreshCount: number;
};

export class ManualUpgradeCoreState implements ManualUpgradeCore {
  readonly itemStates: readonly ManualItemState[];
  readonly records: readonly ManualUpgradeRecord[];
  readonly contentFingerprint: string;

  private readonly fingerprintRefreshCountForTesting: number;

  private constructor(
    itemStates: readonly ManualItemState[],
    records: readonly ManualUpgradeRecord[],
    contentFingerprint: string,
    fingerprintRefreshCountForTesting: number,
  ) {
    this.itemStates = itemStates;
    this.records = records;
    this.contentFingerprint = contentFingerprint;
    this.fingerprintRefreshCountForTesting = fingerprintRefreshCountForTesting;
  }

  static create(
    input: {
      readonly itemStates?: readonly ManualItemState[];
      readonly records?: readonly ManualUpgradeRecord[];
    } = {},
  ): ManualUpgradeCoreState {
    const sortedStates = sortItemStates(input.itemStates ?? []);
    const sortedRecords = sortRecords(input.records ?? []);
    validateCoreShape(sortedStates, sortedRecords);
    return ManualUpgradeCoreState.fromSorted(sortedStates, sortedRecords, 0);
  }

  static fromSorted(
    itemStates: readonly ManualItemState[],
    records: readonly ManualUpgradeRecord[],
    fingerprintRefreshCountForTesting: number,
  ): ManualUpgradeCoreState {
    return new ManualUpgradeCoreState(
      itemStates,
      records,
      computeManualCoreContentFingerprint(itemStates, records),
      fingerprintRefreshCountForTesting,
    );
  }

  get activeRecords(): readonly ManualUpgradeRecord[] {
    return this.records
      .filter((record) => record.status === 'active')
      .slice()
      .sort(recordOrder);
  }

  get completedHistory(): readonly ManualUpgradeRecord[] {
    return this.records
      .filter((record) => record.status === 'completed')
      .slice()
      .sort(recordOrder);
  }

  get cancelledHistory(): readonly ManualUpgradeRecord[] {
    return this.records
      .filter((record) => record.status === 'cancelled')
      .slice()
      .sort(recordOrder);
  }

  get baselineReference(): ManualBaselineReference | null {
    const references = new Set(
      [...this.itemStates, ...this.records].map((entry) => JSON.stringify(entry.baselineReference)),
    );
    if (references.size !== 1) {
      return null;
    }
    return this.itemStates[0]?.baselineReference ?? this.records[0]?.baselineReference ?? null;
  }

  getFingerprintRefreshCountForTesting(): number {
    return this.fingerprintRefreshCountForTesting;
  }

  equals(other: ManualUpgradeCoreState): boolean {
    return manualUpgradeCoresEqual(this, other);
  }

  itemState(itemKey: TrackerItemKey): ManualItemState | undefined {
    return this.itemStates.find(
      (state) => trackerItemKeyStableId(state.itemKey) === trackerItemKeyStableId(itemKey),
    );
  }

  effectiveState(itemKey: TrackerItemKey): ManualEffectiveItemState | undefined {
    return manualEffectiveItemState(this, itemKey);
  }

  gatedForUnreconciledSnapshot(): ManualUpgradeCoreState {
    const states = this.itemStates.map((state) =>
      createManualItemState({
        itemKey: state.itemKey,
        baselineReference: state.baselineReference,
        status: 'unknown',
      }),
    );
    return ManualUpgradeCoreState.create({ itemStates: states });
  }

  startUpgrade(input: StartUpgradeInput): ManualUpgradeCoreState {
    const mutable = cloneMutable(this);
    startUpgradeImpl(mutable, input);
    return commitMutable(mutable, true);
  }

  cancelUpgrade(recordID: UuidString): ManualUpgradeCoreState {
    const mutable = cloneMutable(this);
    cancelUpgradeImpl(mutable, recordID);
    return commitMutable(mutable, true);
  }

  adjustStartTime(
    recordID: UuidString,
    startedAtMs: number,
    nowMs: number,
  ): ManualUpgradeCoreState {
    const mutable = cloneMutable(this);
    adjustStartTimeImpl(mutable, recordID, startedAtMs, nowMs);
    return commitMutable(mutable, true);
  }

  settleDue(atMs: number): {
    readonly core: ManualUpgradeCoreState;
    readonly settled: readonly ManualUpgradeRecord[];
  } {
    const mutable = cloneMutable(this);
    const settled = settleDueImpl(mutable, atMs);
    if (settled.length === 0) {
      return { core: this, settled: [] };
    }
    return { core: commitMutable(mutable, true), settled };
  }
}

function cloneMutable(core: ManualUpgradeCoreState): MutableCore {
  return {
    itemStates: core.itemStates.map((state) => ({ ...state })),
    records: core.records.map((record) => ({ ...record })),
    fingerprintRefreshCount: core.getFingerprintRefreshCountForTesting(),
  };
}

function commitMutable(mutable: MutableCore, refreshFingerprint: boolean): ManualUpgradeCoreState {
  const itemStates = sortItemStates(mutable.itemStates);
  const records = sortRecords(mutable.records);
  validateCoreShape(itemStates, records);
  const fingerprintRefreshCount = refreshFingerprint
    ? mutable.fingerprintRefreshCount + 1
    : mutable.fingerprintRefreshCount;
  return ManualUpgradeCoreState.fromSorted(itemStates, records, fingerprintRefreshCount);
}

function sortItemStates(itemStates: readonly ManualItemState[]): ManualItemState[] {
  return [...itemStates].sort((left, right) =>
    trackerItemKeyStableId(left.itemKey).localeCompare(trackerItemKeyStableId(right.itemKey)),
  );
}

function sortRecords(records: readonly ManualUpgradeRecord[]): ManualUpgradeRecord[] {
  return [...records].sort((left, right) => left.recordID.localeCompare(right.recordID));
}

function validateCoreShape(
  sortedStates: readonly ManualItemState[],
  sortedRecords: readonly ManualUpgradeRecord[],
): void {
  for (const state of sortedStates) {
    if (!isManualItemStateStructurallyValid(state)) {
      throw { kind: 'invalidRecord' } satisfies ManualUpgradeError;
    }
  }
  for (let index = 1; index < sortedStates.length; index += 1) {
    if (
      trackerItemKeyStableId(sortedStates[index - 1]!.itemKey) ===
      trackerItemKeyStableId(sortedStates[index]!.itemKey)
    ) {
      throw { kind: 'invalidRecord' } satisfies ManualUpgradeError;
    }
  }

  const recordIDs = new Set<string>();
  for (const record of sortedRecords) {
    if (recordIDs.has(record.recordID)) {
      throw { kind: 'duplicateRecordID', recordID: record.recordID } satisfies ManualUpgradeError;
    }
    recordIDs.add(record.recordID);
    const state = sortedStates.find((entry) => trackerItemKeysEqual(entry.itemKey, record.itemKey));
    if (state === undefined) {
      throw { kind: 'missingItemState', itemKey: record.itemKey } satisfies ManualUpgradeError;
    }
    if (!baselineReferencesEqual(state.baselineReference, record.baselineReference)) {
      throw { kind: 'baselineMismatch', itemKey: record.itemKey } satisfies ManualUpgradeError;
    }
    if (record.status === 'active' && state.status !== 'manualCompleted') {
      throw { kind: 'unavailableItemState', itemKey: record.itemKey } satisfies ManualUpgradeError;
    }
  }
  for (const state of sortedStates) {
    const stateRecords = sortedRecords.filter((record) =>
      trackerItemKeysEqual(record.itemKey, state.itemKey),
    );
    validateConservation(state, stateRecords);
  }
}

function startUpgradeImpl(mutable: MutableCore, input: StartUpgradeInput): ManualUpgradeRecord {
  settleDueImpl(mutable, input.nowMs);

  const recordID = input.recordID ?? generateUuid();
  if (mutable.records.some((record) => record.recordID === recordID)) {
    throw { kind: 'duplicateRecordID', recordID } satisfies ManualUpgradeError;
  }
  const stateIndex = mutable.itemStates.findIndex((state) =>
    trackerItemKeysEqual(state.itemKey, input.itemKey),
  );
  if (stateIndex < 0) {
    throw { kind: 'missingItemState', itemKey: input.itemKey } satisfies ManualUpgradeError;
  }
  const state = mutable.itemStates[stateIndex]!;
  if (!baselineReferencesEqual(state.baselineReference, input.baselineReference)) {
    throw { kind: 'baselineMismatch', itemKey: input.itemKey } satisfies ManualUpgradeError;
  }
  if (state.status === 'unknown') {
    throw { kind: 'unavailableItemState', itemKey: input.itemKey } satisfies ManualUpgradeError;
  }
  if (state.status === 'conflict') {
    throw { kind: 'conflictingItemState', itemKey: input.itemKey } satisfies ManualUpgradeError;
  }
  if (input.startedAtMs > input.nowMs) {
    throw { kind: 'futureStart' } satisfies ManualUpgradeError;
  }

  const source = startableDistribution(state);
  const available = availableDistribution(state, mutable.records);
  manualLevelDistributionSubtractChecked(available, input.fromLevel, input.quantity);
  mutable.itemStates[stateIndex] = {
    ...state,
    manualCompletedDistribution: source,
    status: 'manualCompleted',
  };

  const timing = resolveTiming(input.durationState, input.startedAtMs);
  const record = createManualUpgradeRecord({
    recordID,
    itemKey: input.itemKey,
    fromLevel: input.fromLevel,
    targetLevel: input.targetLevel,
    quantity: input.quantity,
    startedAtMs: input.startedAtMs,
    expectedEndAtMs: timing.expectedEndAtMs,
    durationSeconds: timing.durationSeconds,
    durationKind: timing.kind,
    frozenCosts: input.frozenCosts,
    catalogProvenance: input.catalogProvenance,
    baselineReference: input.baselineReference,
    queueKind: input.queueKind ?? null,
    status: 'active',
  });
  mutable.records.push(record);
  settleDueImpl(mutable, input.nowMs);
  return recordForRecordID(mutable, recordID);
}

function cancelUpgradeImpl(mutable: MutableCore, recordID: UuidString): ManualUpgradeRecord {
  const recordIndex = mutable.records.findIndex((record) => record.recordID === recordID);
  if (recordIndex < 0) {
    throw { kind: 'recordNotFound', recordID } satisfies ManualUpgradeError;
  }
  const record = mutable.records[recordIndex]!;
  if (record.status !== 'active') {
    if (record.status === 'completed') {
      throw { kind: 'cannotCancelCompleted', recordID } satisfies ManualUpgradeError;
    }
    throw { kind: 'recordNotActive', recordID } satisfies ManualUpgradeError;
  }
  const stateIndex = mutable.itemStates.findIndex((state) =>
    trackerItemKeysEqual(state.itemKey, record.itemKey),
  );
  if (stateIndex < 0) {
    throw { kind: 'missingItemState', itemKey: record.itemKey } satisfies ManualUpgradeError;
  }
  completedDistributionForMutation(mutable.itemStates[stateIndex]!);
  mutable.itemStates[stateIndex] = {
    ...mutable.itemStates[stateIndex]!,
    status: 'manualCompleted',
  };
  mutable.records[recordIndex] = { ...record, status: 'cancelled' };
  return mutable.records[recordIndex]!;
}

function adjustStartTimeImpl(
  mutable: MutableCore,
  recordID: UuidString,
  startedAtMs: number,
  nowMs: number,
): ManualUpgradeRecord {
  const recordIndex = mutable.records.findIndex((record) => record.recordID === recordID);
  if (recordIndex < 0) {
    throw { kind: 'recordNotFound', recordID } satisfies ManualUpgradeError;
  }
  const oldRecord = mutable.records[recordIndex]!;
  if (oldRecord.status !== 'active') {
    throw { kind: 'recordNotActive', recordID } satisfies ManualUpgradeError;
  }
  if (startedAtMs > nowMs) {
    throw { kind: 'futureStart' } satisfies ManualUpgradeError;
  }

  const durationState: CatalogDurationState =
    oldRecord.durationKind === 'instant'
      ? { kind: 'instant' }
      : { kind: 'timed', seconds: oldRecord.durationSeconds };
  const timing = resolveTiming(durationState, startedAtMs);
  mutable.records[recordIndex] = createManualUpgradeRecord({
    recordID: oldRecord.recordID,
    itemKey: oldRecord.itemKey,
    fromLevel: oldRecord.fromLevel,
    targetLevel: oldRecord.targetLevel,
    quantity: oldRecord.quantity,
    startedAtMs,
    expectedEndAtMs: timing.expectedEndAtMs,
    durationSeconds: timing.durationSeconds,
    durationKind: timing.kind,
    frozenCosts: oldRecord.frozenCosts,
    catalogProvenance: oldRecord.catalogProvenance,
    baselineReference: oldRecord.baselineReference,
    queueKind: oldRecord.queueKind,
    status: 'active',
  });
  settleDueImpl(mutable, nowMs);
  return recordForRecordID(mutable, recordID);
}

function settleDueImpl(mutable: MutableCore, atMs: number): ManualUpgradeRecord[] {
  const due = mutable.records
    .filter((record) => record.status === 'active' && record.expectedEndAtMs <= atMs)
    .slice()
    .sort(recordOrder);
  const settled: ManualUpgradeRecord[] = [];
  for (const dueRecord of due) {
    const recordIndex = mutable.records.findIndex(
      (record) => record.recordID === dueRecord.recordID && record.status === 'active',
    );
    if (recordIndex < 0) {
      continue;
    }
    const stateIndex = mutable.itemStates.findIndex((state) =>
      trackerItemKeysEqual(state.itemKey, dueRecord.itemKey),
    );
    if (stateIndex < 0) {
      throw { kind: 'missingItemState', itemKey: dueRecord.itemKey } satisfies ManualUpgradeError;
    }
    const updated = manualLevelDistributionSubtractChecked(
      manualLevelDistributionAddChecked(
        completedDistributionForMutation(mutable.itemStates[stateIndex]!),
        dueRecord.targetLevel,
        dueRecord.quantity,
      ),
      dueRecord.fromLevel,
      dueRecord.quantity,
    );
    mutable.itemStates[stateIndex] = {
      ...mutable.itemStates[stateIndex]!,
      manualCompletedDistribution: updated,
      status: 'manualCompleted',
    };
    mutable.records[recordIndex] = { ...mutable.records[recordIndex]!, status: 'completed' };
    settled.push(mutable.records[recordIndex]!);
  }
  return settled;
}

function recordForRecordID(mutable: MutableCore, recordID: UuidString): ManualUpgradeRecord {
  const record = mutable.records.find((entry) => entry.recordID === recordID);
  if (record === undefined) {
    throw { kind: 'recordNotFound', recordID } satisfies ManualUpgradeError;
  }
  return record;
}

function recordOrder(left: ManualUpgradeRecord, right: ManualUpgradeRecord): number {
  if (left.expectedEndAtMs !== right.expectedEndAtMs) {
    return left.expectedEndAtMs - right.expectedEndAtMs;
  }
  return left.recordID.localeCompare(right.recordID);
}

function validateConservation(
  state: ManualItemState,
  records: readonly ManualUpgradeRecord[],
): void {
  if (records.length === 0) {
    return;
  }
  if (state.status !== 'manualCompleted') {
    throw { kind: 'invalidRecord' } satisfies ManualUpgradeError;
  }

  const completed = records.filter((record) => record.status === 'completed').sort(recordOrder);
  const active = records.filter((record) => record.status === 'active').sort(recordOrder);

  if (
    state.importedObservation?.levelDistribution !== undefined &&
    state.importedObservation.levelDistribution !== null
  ) {
    let expected = state.importedObservation.levelDistribution;
    for (const record of completed) {
      expected = manualLevelDistributionSubtractChecked(
        expected,
        record.fromLevel,
        record.quantity,
      );
      expected = manualLevelDistributionAddChecked(expected, record.targetLevel, record.quantity);
    }
    if (!levelDistributionsStructurallyEqual(expected, state.manualCompletedDistribution)) {
      throw { kind: 'invalidRecord' } satisfies ManualUpgradeError;
    }
    validateActiveReservations(active, expected);
    return;
  }

  validateActiveReservations(active, state.manualCompletedDistribution);
}

function validateActiveReservations(
  records: readonly ManualUpgradeRecord[],
  distribution: ManualLevelDistribution,
): void {
  let available = distribution;
  for (const record of records) {
    available = manualLevelDistributionSubtractChecked(
      available,
      record.fromLevel,
      record.quantity,
    );
  }
}

function levelDistributionsStructurallyEqual(
  left: ManualLevelDistribution,
  right: ManualLevelDistribution,
): boolean {
  if (left.levels.length !== right.levels.length) {
    return false;
  }
  for (let index = 0; index < left.levels.length; index += 1) {
    const leftEntry = left.levels[index]!;
    const rightEntry = right.levels[index]!;
    if (leftEntry.level !== rightEntry.level || leftEntry.quantity !== rightEntry.quantity) {
      return false;
    }
  }
  return true;
}

function startableDistribution(state: ManualItemState): ManualLevelDistribution {
  switch (state.status) {
    case 'observed':
      if (
        state.importedObservation?.levelDistribution === undefined ||
        state.importedObservation.levelDistribution === null
      ) {
        throw { kind: 'unavailableItemState', itemKey: state.itemKey } satisfies ManualUpgradeError;
      }
      return state.importedObservation.levelDistribution;
    case 'manualCompleted':
      return state.manualCompletedDistribution;
    case 'unknown':
      throw { kind: 'unavailableItemState', itemKey: state.itemKey } satisfies ManualUpgradeError;
    case 'conflict':
      throw { kind: 'conflictingItemState', itemKey: state.itemKey } satisfies ManualUpgradeError;
  }
}

function completedDistributionForMutation(state: ManualItemState): ManualLevelDistribution {
  return startableDistribution(state);
}

function availableDistribution(
  state: ManualItemState,
  records: readonly ManualUpgradeRecord[],
): ManualLevelDistribution {
  let available = completedDistributionForMutation(state);
  for (const record of records) {
    if (record.status === 'active' && trackerItemKeysEqual(record.itemKey, state.itemKey)) {
      available = manualLevelDistributionSubtractChecked(
        available,
        record.fromLevel,
        record.quantity,
      );
    }
  }
  return available;
}

function resolveTiming(
  durationState: CatalogDurationState | null,
  startedAtMs: number,
): ResolvedTiming {
  if (durationState === null) {
    throw {
      kind: 'durationUnavailable',
      durationState: { kind: 'unknownReason', reason: 'missing_duration_state' },
    } satisfies ManualUpgradeError;
  }
  switch (durationState.kind) {
    case 'timed': {
      if (durationState.seconds <= 0n) {
        throw { kind: 'invalidDuration' } satisfies ManualUpgradeError;
      }
      const intervalMs = Number(durationState.seconds) * 1000;
      if (!Number.isFinite(intervalMs)) {
        throw { kind: 'arithmeticOverflow' } satisfies ManualUpgradeError;
      }
      const expectedEndAtMs = startedAtMs + intervalMs;
      if (!Number.isFinite(expectedEndAtMs) || expectedEndAtMs < startedAtMs) {
        throw { kind: 'arithmeticOverflow' } satisfies ManualUpgradeError;
      }
      return {
        kind: 'timed',
        durationSeconds: durationState.seconds,
        expectedEndAtMs,
      };
    }
    case 'instant':
      return { kind: 'instant', durationSeconds: 0n, expectedEndAtMs: startedAtMs };
    case 'initialLevel':
    case 'notApplicable':
    case 'sourceMissing':
    case 'parseFailed':
    case 'unknownReason':
      throw { kind: 'durationUnavailable', durationState } satisfies ManualUpgradeError;
  }
}

export function createManualUpgradeCoreState(
  input: {
    readonly itemStates?: readonly ManualItemState[];
    readonly records?: readonly ManualUpgradeRecord[];
  } = {},
): ManualUpgradeCoreState {
  return ManualUpgradeCoreState.create(input);
}

export function createManualLevelDistributionFromPairs(
  values: readonly (readonly [number, bigint])[],
): ManualLevelDistribution {
  return createManualLevelDistribution(
    values.map(([level, quantity]) => createManualLevelQuantity(level, quantity)),
  );
}

export function createManualItemStateForStatus(input: {
  readonly itemKey: TrackerItemKey;
  readonly baselineReference: ManualBaselineReference;
  readonly imported?: ManualLevelDistribution | null;
  readonly manual?: ManualLevelDistribution;
  readonly status: ManualItemStatus;
  readonly sourceTimestampMs?: number | null;
}): ManualItemState {
  const importedObservation =
    input.imported === undefined
      ? null
      : createManualImportedObservation({
          reference: input.baselineReference,
          levelDistribution: input.imported,
          sourceTimestampMs: input.sourceTimestampMs ?? null,
        });
  return createManualItemState({
    itemKey: input.itemKey,
    baselineReference: input.baselineReference,
    importedObservation,
    manualCompletedDistribution: input.manual ?? MANUAL_LEVEL_DISTRIBUTION_EMPTY,
    status: input.status,
  });
}
