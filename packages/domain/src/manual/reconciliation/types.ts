import type { UuidString } from '@coc-helper/wire';

import type { ManualBaselineReference, ManualLevelDistribution, TrackerItemKey } from '../types';

export type ManualReconciliationDecision = 'applyNonConflicting' | 'keepLocal' | 'acceptObserved';

export type ManualReconciliationTimeConfidence =
  | 'reliableSourceTimestamp'
  | 'sourceTimestampAbsent'
  | 'sourceTimestampConflict'
  | 'localAppliedAtOnly';

export type ManualReconciliationClassification =
  | 'duplicate'
  | 'newObservation'
  | 'exactMatch'
  | 'observedAhead'
  | 'manualAhead'
  | 'staleImport'
  | 'observedTimerEnded'
  | 'possibleDuplicate'
  | 'unknown'
  | 'conflict'
  | 'lineageMismatch';

export const MANUAL_RECONCILIATION_CLASSIFICATION_LABELS: Readonly<
  Record<ManualReconciliationClassification, string>
> = {
  duplicate: '重复导入',
  newObservation: '新观察',
  exactMatch: '观察一致',
  observedAhead: '导入观察领先',
  manualAhead: '本地手动状态领先',
  staleImport: '旧快照',
  observedTimerEnded: '计时消失，结果未知',
  possibleDuplicate: '可能重复的进行中记录',
  unknown: '证据不足',
  conflict: '冲突',
  lineageMismatch: '账号身份不一致',
};

export function manualReconciliationClassificationNeedsAttention(
  classification: ManualReconciliationClassification,
): boolean {
  switch (classification) {
    case 'duplicate':
    case 'newObservation':
    case 'exactMatch':
    case 'observedAhead':
      return false;
    case 'manualAhead':
    case 'staleImport':
    case 'observedTimerEnded':
    case 'possibleDuplicate':
    case 'unknown':
    case 'conflict':
    case 'lineageMismatch':
      return true;
  }
}

export type ManualReconciliationTimeConfidenceLabel =
  (typeof MANUAL_RECONCILIATION_TIME_CONFIDENCE_LABELS)[ManualReconciliationTimeConfidence];

export const MANUAL_RECONCILIATION_TIME_CONFIDENCE_LABELS = {
  reliableSourceTimestamp: '来源时间可比较',
  sourceTimestampAbsent: '新快照未提供来源时间',
  sourceTimestampConflict: '新快照来源时间更早',
  localAppliedAtOnly: '仅有本地应用时间',
} as const;

export type ManualReconciliationItem = {
  readonly itemKey: TrackerItemKey;
  readonly displayName: string;
  readonly classification: ManualReconciliationClassification;
  readonly message: string;
  readonly previousDistribution: ManualLevelDistribution | null;
  readonly observedDistribution: ManualLevelDistribution | null;
  readonly relatedRecordIDs: readonly UuidString[];
  readonly confirmedRecordIDs: readonly UuidString[];
  readonly observedTimer: boolean;
  readonly coverageComplete: boolean;
};

export type ManualReconciliationPreview = {
  readonly previewID: UuidString;
  readonly villageID: UuidString;
  readonly previousReference: ManualBaselineReference | null;
  readonly previousSnapshotID: UuidString | null;
  readonly previousSnapshotFingerprint: string | null;
  readonly previousLineageID: string | null;
  readonly manualStateUpdatedAtMs: number;
  readonly newReference: ManualBaselineReference;
  readonly newNormalizedPlayerTag: string | null;
  readonly sourceTimestampMs: number | null;
  readonly appliedAtMs: number;
  readonly timeConfidence: ManualReconciliationTimeConfidence;
  readonly duplicate: boolean;
  readonly lineageComparable: boolean;
  readonly candidateFingerprint: string;
  readonly items: readonly ManualReconciliationItem[];
};

export function manualReconciliationPreviewAttentionCount(
  preview: ManualReconciliationPreview,
): number {
  return preview.items.filter((item) =>
    manualReconciliationClassificationNeedsAttention(item.classification),
  ).length;
}

export function manualReconciliationPreviewRequiresExplicitDecision(
  preview: ManualReconciliationPreview,
): boolean {
  return manualReconciliationPreviewAttentionCount(preview) > 0;
}

export function manualReconciliationPreviewCount(
  preview: ManualReconciliationPreview,
  classification: ManualReconciliationClassification,
): number {
  return preview.items.filter((item) => item.classification === classification).length;
}

export type ManualReconciliationRecord = {
  readonly reconciliationID: UuidString;
  readonly previousReference: ManualBaselineReference | null;
  readonly newReference: ManualBaselineReference;
  readonly decision: ManualReconciliationDecision;
  readonly timeConfidence: ManualReconciliationTimeConfidence;
  readonly sourceTimestampMs: number | null;
  readonly duplicate: boolean;
  readonly appliedAtMs: number;
  readonly items: readonly ManualReconciliationItem[];
};
