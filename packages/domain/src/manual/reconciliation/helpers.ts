import type { UuidString } from '@coc-helper/wire';

import { baselineReferencesEqual, manualLevelDistributionsEqual } from '../equality';
import type {
  ManualItemState,
  ManualLevelDistribution,
  ManualUpgradeRecord,
  TrackerItemKey,
} from '../types';
import { trackerItemKeyStableId } from '../types';
import type {
  ManualReconciliationClassification,
  ManualReconciliationItem,
  ManualReconciliationPreview,
  ManualReconciliationTimeConfidence,
} from './types';

export function reconciliationTimeConfidence(
  previousSourceTimestampMs: number | null | undefined,
  newSourceTimestampMs: number | null | undefined,
): ManualReconciliationTimeConfidence {
  if (newSourceTimestampMs === null || newSourceTimestampMs === undefined) {
    return 'sourceTimestampAbsent';
  }
  if (!Number.isFinite(newSourceTimestampMs)) {
    return 'sourceTimestampConflict';
  }
  if (previousSourceTimestampMs === null || previousSourceTimestampMs === undefined) {
    return 'localAppliedAtOnly';
  }
  if (
    !Number.isFinite(previousSourceTimestampMs) ||
    newSourceTimestampMs < previousSourceTimestampMs
  ) {
    return 'sourceTimestampConflict';
  }
  return 'reliableSourceTimestamp';
}

export function manualLevelDistributionDominates(
  left: ManualLevelDistribution,
  right: ManualLevelDistribution,
): boolean {
  if (left.totalQuantity !== right.totalQuantity) {
    return false;
  }
  const levels = new Set<number>();
  for (const entry of left.levels) {
    levels.add(entry.level);
  }
  for (const entry of right.levels) {
    levels.add(entry.level);
  }
  for (const threshold of levels) {
    const leftSum = left.levels
      .filter((entry) => entry.level >= threshold)
      .reduce((sum, entry) => sum + entry.quantity, 0n);
    const rightSum = right.levels
      .filter((entry) => entry.level >= threshold)
      .reduce((sum, entry) => sum + entry.quantity, 0n);
    if (leftSum < rightSum) {
      return false;
    }
  }
  return true;
}

export function effectiveReconciliationDistribution(
  state: ManualItemState | undefined,
): ManualLevelDistribution | null {
  if (state === undefined) {
    return null;
  }
  switch (state.status) {
    case 'observed':
      return state.importedObservation?.levelDistribution ?? null;
    case 'manualCompleted':
      return state.manualCompletedDistribution;
    case 'unknown':
    case 'conflict':
      return null;
  }
}

export function hasReconciliationLocalState(
  state: ManualItemState | undefined,
  records: readonly ManualUpgradeRecord[],
): boolean {
  return state?.status === 'manualCompleted' || records.length > 0;
}

export function hasProtectableReconciliationLocalState(
  state: ManualItemState | undefined,
  records: readonly ManualUpgradeRecord[],
  previousDistribution: ManualLevelDistribution | null,
): boolean {
  if (hasReconciliationLocalState(state, records)) {
    return true;
  }
  if (previousDistribution !== null) {
    return true;
  }
  switch (state?.status) {
    case 'unknown':
    case 'conflict':
      return true;
    case 'observed':
    case 'manualCompleted':
    case undefined:
      return false;
  }
}

export function confirmedReconciliationRecords(
  records: readonly ManualUpgradeRecord[],
  previous: ManualLevelDistribution | null,
  observed: ManualLevelDistribution | null,
  sourceTimestampMs: number | null,
  requireExpectedEnd: boolean,
): readonly UuidString[] {
  if (previous === null || observed === null) {
    return [];
  }
  const levels = new Set<number>();
  for (const entry of previous.levels) {
    levels.add(entry.level);
  }
  for (const entry of observed.levels) {
    levels.add(entry.level);
  }
  const remainingDecrease = new Map<number, bigint>();
  const remainingIncrease = new Map<number, bigint>();
  for (const level of levels) {
    const previousQuantity = previous.quantityAt(level);
    const observedQuantity = observed.quantityAt(level);
    remainingDecrease.set(
      level,
      previousQuantity > observedQuantity ? previousQuantity - observedQuantity : 0n,
    );
    remainingIncrease.set(
      level,
      observedQuantity > previousQuantity ? observedQuantity - previousQuantity : 0n,
    );
  }
  const ordered = records.slice().sort((left, right) => {
    if (left.expectedEndAtMs !== right.expectedEndAtMs) {
      return left.expectedEndAtMs - right.expectedEndAtMs;
    }
    if (left.startedAtMs !== right.startedAtMs) {
      return left.startedAtMs - right.startedAtMs;
    }
    return left.recordID.localeCompare(right.recordID);
  });
  const confirmed: UuidString[] = [];
  for (const record of ordered) {
    if (record.status !== 'active') {
      continue;
    }
    if ((remainingIncrease.get(record.targetLevel) ?? 0n) < record.quantity) {
      continue;
    }
    if ((remainingDecrease.get(record.fromLevel) ?? 0n) < record.quantity) {
      continue;
    }
    if (requireExpectedEnd) {
      if (sourceTimestampMs === null || sourceTimestampMs < record.expectedEndAtMs) {
        continue;
      }
    }
    remainingIncrease.set(
      record.targetLevel,
      (remainingIncrease.get(record.targetLevel) ?? 0n) - record.quantity,
    );
    remainingDecrease.set(
      record.fromLevel,
      (remainingDecrease.get(record.fromLevel) ?? 0n) - record.quantity,
    );
    confirmed.push(record.recordID);
  }
  return confirmed;
}

export function reconciliationClassificationMessage(
  classification: ManualReconciliationClassification,
): string {
  switch (classification) {
    case 'duplicate':
      return '观察未变化；不会重新开始或重复结算手动记录。';
    case 'newObservation':
      return '当前没有需要保护的本地手动状态，可以安全建立新的观察基线。';
    case 'exactMatch':
      return '导入观察与本地有效完成状态一致。';
    case 'observedAhead':
      return '导入观察明确达到或超过本地完成状态。';
    case 'manualAhead':
      return '本地手动状态领先于导入观察，默认不会回滚。';
    case 'staleImport':
      return '来源时间早于当前历史基线，默认保留本地状态。';
    case 'observedTimerEnded':
      return '只观察到 timer 消失，不能据此声称完成、取消或失败。';
    case 'possibleDuplicate':
      return '导入 timer 缺少 target/start/queue identity，不能与本地 active 自动合并。';
    case 'unknown':
      return '等级、数量或字段覆盖不足，缺失不能解释为删除、归零或完成。';
    case 'conflict':
      return '导入观察与本地状态无法形成单调升级关系。';
    case 'lineageMismatch':
      return '不同 village/lineage 禁止自动匹配；必须显式接受导入观察。';
  }
}

/**
 * Issue #304：直接比较去除随机 ID（previewID/appliedAt）的语义字段，
 * 替代 candidateFingerprint 摘要比较。
 *
 * newReference 的 revision/lineageID 是按导入分配的临时 ID：
 * 非 duplicate 时忽略（同旧指纹只含内容 fingerprint 的语义）；
 * duplicate 时 revision 携带 :observation:N 序列，必须精确匹配。
 */
export function reconciliationCandidateMatches(
  expected: ManualReconciliationPreview,
  actual: ManualReconciliationPreview,
): boolean {
  return (
    expected.duplicate === actual.duplicate &&
    expected.lineageComparable === actual.lineageComparable &&
    expected.timeConfidence === actual.timeConfidence &&
    newReferencesMatch(expected, actual) &&
    (expected.newNormalizedPlayerTag ?? null) === (actual.newNormalizedPlayerTag ?? null) &&
    (expected.sourceTimestampMs ?? null) === (actual.sourceTimestampMs ?? null) &&
    reconciliationItemsEqual(expected.items, actual.items)
  );
}

function newReferencesMatch(
  expected: ManualReconciliationPreview,
  actual: ManualReconciliationPreview,
): boolean {
  if (expected.duplicate || actual.duplicate) {
    return baselineReferencesEqual(expected.newReference, actual.newReference);
  }
  return true;
}

function reconciliationItemsEqual(
  left: readonly ManualReconciliationItem[],
  right: readonly ManualReconciliationItem[],
): boolean {
  if (left.length !== right.length) {
    return false;
  }
  return left.every((leftItem, index) => {
    const rightItem = right[index]!;
    return (
      trackerItemKeyStableId(leftItem.itemKey) === trackerItemKeyStableId(rightItem.itemKey) &&
      leftItem.displayName === rightItem.displayName &&
      leftItem.classification === rightItem.classification &&
      leftItem.message === rightItem.message &&
      distributionsEqual(leftItem.previousDistribution, rightItem.previousDistribution) &&
      distributionsEqual(leftItem.observedDistribution, rightItem.observedDistribution) &&
      uuidArraysEqual(leftItem.relatedRecordIDs, rightItem.relatedRecordIDs) &&
      uuidArraysEqual(leftItem.confirmedRecordIDs, rightItem.confirmedRecordIDs) &&
      leftItem.observedTimer === rightItem.observedTimer &&
      leftItem.coverageComplete === rightItem.coverageComplete &&
      leftItem.observedDistributionComplete === rightItem.observedDistributionComplete &&
      leftItem.observedSectionTrustGatesOpen === rightItem.observedSectionTrustGatesOpen &&
      leftItem.observedTimerCoverageComplete === rightItem.observedTimerCoverageComplete
    );
  });
}

function uuidArraysEqual(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

export function recordsForItemKey(
  records: readonly ManualUpgradeRecord[],
  itemKey: TrackerItemKey,
): readonly ManualUpgradeRecord[] {
  const stableId = trackerItemKeyStableId(itemKey);
  return records.filter((record) => trackerItemKeyStableId(record.itemKey) === stableId);
}

export function distributionsEqual(
  left: ManualLevelDistribution | null,
  right: ManualLevelDistribution | null,
): boolean {
  if (left === null || right === null) {
    return left === right;
  }
  return manualLevelDistributionsEqual(left, right);
}
