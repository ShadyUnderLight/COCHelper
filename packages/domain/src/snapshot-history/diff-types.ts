import type {
  SnapshotCoverageState,
  SnapshotCoverageProof,
  SnapshotHistoryBase,
  SnapshotItemIdentity,
} from './types';
import { snapshotItemIdentityKey } from './types';

export const SNAPSHOT_DIFF_ALGORITHM_VERSION = 'snapshot-diff.v1';

export type SnapshotChangeKind =
  | 'levelIncreased'
  | 'levelDecreased'
  | 'quantityChanged'
  | 'newlyObserved'
  | 'noLongerObserved'
  | 'upgradeStarted'
  | 'upgradeCompleted'
  | 'timerChanged'
  | 'timerEndedObserved'
  | 'unknown';

export type SnapshotChangeEvidence = 'confirmed' | 'aggregateInferred' | 'unknown';

export type SnapshotDiffComparisonState =
  | 'comparable'
  | 'provenanceOnly'
  | 'insufficientCoverage'
  | 'suppressed';

export type SnapshotDiffContentState =
  | 'contentChanged'
  | 'provenanceOnly'
  | 'contentInsufficient'
  | 'comparableNoChange';

export type SnapshotDiffSectionCoverage = {
  readonly base: SnapshotHistoryBase;
  readonly rawSection: string;
  readonly fromState: SnapshotCoverageState;
  readonly toState: SnapshotCoverageState;
  readonly fromDataState: SnapshotCoverageState;
  readonly toDataState: SnapshotCoverageState;
  readonly fromSectionCompleteness: SnapshotCoverageState;
  readonly toSectionCompleteness: SnapshotCoverageState;
  readonly fromProof?: SnapshotCoverageProof;
  readonly toProof?: SnapshotCoverageProof;
  readonly fromTrustTrusted: boolean;
  readonly toTrustTrusted: boolean;
  readonly fromFieldStates: Readonly<Record<string, SnapshotCoverageState>>;
  readonly toFieldStates: Readonly<Record<string, SnapshotCoverageState>>;
  readonly fromObservedItemCount: number;
  readonly toObservedItemCount: number;
};

export function snapshotDiffSectionCoverageId(section: SnapshotDiffSectionCoverage): string {
  return [section.base, section.rawSection]
    .map((part) => `${new TextEncoder().encode(part).length}:${part}`)
    .join('|');
}

export function snapshotDiffSectionCoverageIsComplete(section: SnapshotDiffSectionCoverage): boolean {
  return (
    section.fromState === 'complete' &&
    section.toState === 'complete' &&
    section.fromDataState === 'complete' &&
    section.toDataState === 'complete' &&
    section.fromSectionCompleteness === 'complete' &&
    section.toSectionCompleteness === 'complete' &&
    section.fromTrustTrusted &&
    section.toTrustTrusted
  );
}

export type SnapshotDiffFieldCoverage = {
  readonly base: SnapshotHistoryBase;
  readonly rawSection: string;
  readonly field: string;
  readonly fromState: SnapshotCoverageState;
  readonly toState: SnapshotCoverageState;
};

export function snapshotDiffFieldCoverageId(field: SnapshotDiffFieldCoverage): string {
  return [field.base, field.rawSection, field.field]
    .map((part) => `${new TextEncoder().encode(part).length}:${part}`)
    .join('|');
}

export type SnapshotDiffCoverageState = 'complete' | 'partial' | 'insufficient';

export type SnapshotDiffCoverage = {
  readonly state: SnapshotDiffCoverageState;
  readonly fields: readonly SnapshotDiffFieldCoverage[];
  readonly reasons: readonly string[];
};

export type SnapshotDiffDiagnosticKind =
  | 'baseline'
  | 'villageMismatch'
  | 'lineageMismatch'
  | 'duplicateSnapshotID'
  | 'insufficientCoverage'
  | 'unknownIdentity'
  | 'malformedObservation'
  | 'mixedLineageInput'
  | 'incomparableTimerSchema';

export type SnapshotDiffDiagnostic = {
  readonly kind: SnapshotDiffDiagnosticKind;
  readonly message: string;
  readonly identity?: SnapshotItemIdentity;
  readonly rawSection?: string;
  readonly field?: string;
};

export function snapshotDiffDiagnosticId(diagnostic: SnapshotDiffDiagnostic): string {
  return [
    diagnostic.kind,
    diagnostic.identity ? snapshotItemIdentityKey(diagnostic.identity) : '',
    diagnostic.rawSection ?? '',
    diagnostic.field ?? '',
    diagnostic.message,
  ]
    .map((part) => `${new TextEncoder().encode(part).length}:${part}`)
    .join('|');
}

export type SnapshotChange = {
  readonly identity: SnapshotItemIdentity;
  readonly displayName: string;
  readonly category?: string;
  readonly displayCategory?: string;
  readonly base: SnapshotHistoryBase;
  readonly oldLevel?: number;
  readonly newLevel?: number;
  readonly oldQuantity?: number;
  readonly newQuantity?: number;
  readonly movedQuantity?: number;
  readonly levelDelta?: number;
  readonly changeKind: SnapshotChangeKind;
  readonly relatedChangeKinds: readonly SnapshotChangeKind[];
  readonly evidence: SnapshotChangeEvidence;
  readonly coverage: SnapshotDiffCoverage;
};

export function snapshotChangeId(change: SnapshotChange): string {
  return [
    snapshotItemIdentityKey(change.identity),
    change.changeKind,
    String(change.oldLevel ?? Number.MIN_SAFE_INTEGER),
    String(change.newLevel ?? Number.MIN_SAFE_INTEGER),
    String(change.movedQuantity ?? Number.MIN_SAFE_INTEGER),
  ].join('|');
}

export type SnapshotDiff = {
  readonly fromSnapshotID: string;
  readonly toSnapshotID: string;
  readonly villageID: string;
  readonly lineageID: string;
  readonly fromAppliedAt: Date;
  readonly toAppliedAt: Date;
  readonly algorithmVersion: string;
  readonly comparisonState: SnapshotDiffComparisonState;
  readonly contentState: SnapshotDiffContentState;
  readonly sectionCoverage: readonly SnapshotDiffSectionCoverage[];
  readonly changes: readonly SnapshotChange[];
  readonly diagnostics: readonly SnapshotDiffDiagnostic[];
};

function worseCoverageState(
  left: SnapshotCoverageState,
  right: SnapshotCoverageState,
): SnapshotCoverageState {
  if (left === 'unavailable' || right === 'unavailable') {
    return 'unavailable';
  }
  if (left === 'partial' || right === 'partial') {
    return 'partial';
  }
  return 'complete';
}

function derivedSnapshotDiffCoverageState(
  fields: readonly SnapshotDiffFieldCoverage[],
): SnapshotDiffCoverageState {
  if (fields.some((field) => field.fromState === 'unavailable' || field.toState === 'unavailable')) {
    return 'insufficient';
  }
  if (fields.some((field) => field.fromState === 'partial' || field.toState === 'partial')) {
    return 'partial';
  }
  return 'complete';
}

function normalizeSnapshotDiffCoverageFields(
  fields: readonly SnapshotDiffFieldCoverage[],
): SnapshotDiffFieldCoverage[] {
  const merged = new Map<string, SnapshotDiffFieldCoverage>();
  for (const field of fields) {
    const id = snapshotDiffFieldCoverageId(field);
    const previous = merged.get(id);
    if (!previous) {
      merged.set(id, field);
      continue;
    }
    merged.set(id, {
      base: field.base,
      rawSection: field.rawSection,
      field: field.field,
      fromState: worseCoverageState(previous.fromState, field.fromState),
      toState: worseCoverageState(previous.toState, field.toState),
    });
  }
  return [...merged.values()].sort((left, right) =>
    snapshotDiffFieldCoverageId(left).localeCompare(snapshotDiffFieldCoverageId(right)),
  );
}

export function createSnapshotDiffCoverage(input: {
  state?: SnapshotDiffCoverageState;
  fields?: readonly SnapshotDiffFieldCoverage[];
  reasons?: readonly string[];
} = {}): SnapshotDiffCoverage {
  const fields = normalizeSnapshotDiffCoverageFields(input.fields ?? []);
  const reasons = [...new Set(input.reasons ?? [])].sort();
  return {
    fields,
    reasons,
    state: input.state ?? derivedSnapshotDiffCoverageState(fields),
  };
}

export function snapshotDiffCoverageAddingReason(
  coverage: SnapshotDiffCoverage,
  reason: string,
  minimum: SnapshotDiffCoverageState = 'partial',
): SnapshotDiffCoverage {
  let nextState: SnapshotDiffCoverageState;
  switch (coverage.state) {
    case 'insufficient':
      nextState = 'insufficient';
      break;
    case 'partial':
      nextState = minimum === 'insufficient' ? 'insufficient' : 'partial';
      break;
    case 'complete':
      nextState = minimum;
      break;
  }
  return createSnapshotDiffCoverage({
    state: nextState,
    fields: coverage.fields,
    reasons: [...coverage.reasons, reason],
  });
}

export function createSnapshotDiff(input: {
  fromSnapshotID: string;
  toSnapshotID: string;
  villageID: string;
  lineageID: string;
  fromAppliedAt?: Date;
  toAppliedAt?: Date;
  algorithmVersion?: string;
  comparisonState?: SnapshotDiffComparisonState;
  contentState?: SnapshotDiffContentState;
  sectionCoverage?: readonly SnapshotDiffSectionCoverage[];
  changes?: readonly SnapshotChange[];
  diagnostics?: readonly SnapshotDiffDiagnostic[];
}): SnapshotDiff {
  const sectionCoverage = [...(input.sectionCoverage ?? [])].sort((left, right) =>
    snapshotDiffSectionCoverageId(left).localeCompare(snapshotDiffSectionCoverageId(right)),
  );
  const diagnostics = [...(input.diagnostics ?? [])].sort((left, right) =>
    snapshotDiffDiagnosticId(left).localeCompare(snapshotDiffDiagnosticId(right)),
  );
  return {
    fromSnapshotID: input.fromSnapshotID,
    toSnapshotID: input.toSnapshotID,
    villageID: input.villageID,
    lineageID: input.lineageID,
    fromAppliedAt: input.fromAppliedAt ?? new Date(0),
    toAppliedAt: input.toAppliedAt ?? new Date(0),
    algorithmVersion: input.algorithmVersion ?? SNAPSHOT_DIFF_ALGORITHM_VERSION,
    comparisonState: input.comparisonState ?? 'comparable',
    contentState: input.contentState ?? 'contentChanged',
    sectionCoverage,
    changes: input.changes ?? [],
    diagnostics,
  };
}
