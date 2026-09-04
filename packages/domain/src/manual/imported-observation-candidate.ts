import type { GameCatalog } from '../catalog/game-catalog';
import { isBaselineReconciled } from './baseline-gate';
import { isManualItemStateQueueAssignmentConfirmable } from './queue-assignment-eligibility';
import { inferredLocalQueueKindForItemKey, type LocalQueueKind } from './queue/local-queue-kind';
import type { QueueAssignmentDecision } from './queue/queue-assignment';
import {
  trackerItemKeyStableId,
  type ManualItemState,
  type ManualUpgradeCore,
  type TrackerItemKey,
} from './types';

export type ImportedObservationCandidate = {
  readonly itemKey: TrackerItemKey;
  readonly displayName: string;
  readonly hasTimer: boolean;
  readonly inferredQueueKind: LocalQueueKind | null;
  readonly assignment: QueueAssignmentDecision | null;
  readonly historicalAssignments: readonly QueueAssignmentDecision[];
  readonly isConfirmable: boolean;
  readonly unconfirmableReason: string | null;
  readonly stableID: string;
};

export function projectImportedObservationCandidates(input: {
  readonly core: ManualUpgradeCore;
  readonly currentBaseline: ManualBaselineReferenceLike | null;
  readonly queueAssignments: readonly QueueAssignmentDecision[];
  readonly catalog: GameCatalog | null;
  readonly displayNameForItemKey?: (itemKey: TrackerItemKey) => string;
}): readonly ImportedObservationCandidate[] {
  const isReconciled = isBaselineReconciled({
    core: input.core,
    currentBaseline: input.currentBaseline,
  });
  const currentLineage = input.currentBaseline?.lineageID ?? null;

  return input.core.itemStates
    .filter(
      (state) => state.importedObservation !== null && state.importedObservation !== undefined,
    )
    .map((itemState) =>
      projectImportedObservationCandidate({
        itemState,
        isReconciled,
        currentLineage,
        queueAssignments: input.queueAssignments,
        catalog: input.catalog,
        displayNameForItemKey: input.displayNameForItemKey,
      }),
    )
    .slice()
    .sort((left, right) => left.displayName.localeCompare(right.displayName, 'zh-Hans-CN'));
}

type ManualBaselineReferenceLike = {
  readonly revision: string;
  readonly lineageID: string | null;
};

function projectImportedObservationCandidate(input: {
  readonly itemState: ManualItemState;
  readonly isReconciled: boolean;
  readonly currentLineage: string | null;
  readonly queueAssignments: readonly QueueAssignmentDecision[];
  readonly catalog: GameCatalog | null;
  readonly displayNameForItemKey?: (itemKey: TrackerItemKey) => string;
}): ImportedObservationCandidate {
  const { itemState } = input;
  const itemKey = itemState.itemKey;
  const stableID = trackerItemKeyStableId(itemKey);
  const displayName =
    input.displayNameForItemKey?.(itemKey) ??
    input.catalog?.item(itemKey.rawSection, itemKey.dataID)?.name ??
    stableID;
  const assignment =
    input.queueAssignments.find(
      (entry) =>
        trackerItemKeyStableId(entry.itemKey) === stableID &&
        entry.baselineReference.lineageID === input.currentLineage,
    ) ?? null;
  const historicalAssignments = input.queueAssignments.filter(
    (entry) =>
      trackerItemKeyStableId(entry.itemKey) === stableID &&
      entry.baselineReference.lineageID !== input.currentLineage,
  );
  const evidenceConfirmable = isManualItemStateQueueAssignmentConfirmable(itemState);
  const inferredQueueKind = inferredLocalQueueKindForItemKey(itemKey);
  const isConfirmable = input.isReconciled && evidenceConfirmable && inferredQueueKind !== null;
  const observation = itemState.importedObservation;
  let unconfirmableReason: string | null = null;
  if (!input.isReconciled) {
    unconfirmableReason = '快照尚未对账，暂不能确认';
  } else if (observation?.observedTimer !== true) {
    unconfirmableReason = '没有进行中计时证据';
  } else if (!evidenceConfirmable) {
    unconfirmableReason = '观察证据不完整，暂不能确认';
  } else if (inferredQueueKind === null) {
    unconfirmableReason = '该项目没有可用的本地计时容量类别';
  }
  return {
    itemKey,
    displayName,
    hasTimer: observation?.observedTimer ?? false,
    inferredQueueKind,
    assignment,
    historicalAssignments,
    isConfirmable,
    unconfirmableReason,
    stableID,
  };
}
