/**
 * #276-S3 Manual typed IPC：state / start / cancel / adjust / settle / reconcile。
 * command 必须显式 villageId + expectedGeneration（CAS）。
 */

import type { Result } from './result';
import type { TrackerItemKeyDto } from './projection-ipc';

export const MANUAL_STATE_CHANNEL = 'manual.state' as const;
export const MANUAL_START_CHANNEL = 'manual.start' as const;
export const MANUAL_CANCEL_CHANNEL = 'manual.cancel' as const;
export const MANUAL_ADJUST_CHANNEL = 'manual.adjust' as const;
export const MANUAL_SETTLE_CHANNEL = 'manual.settle' as const;
export const MANUAL_RECONCILE_CHANNEL = 'manual.reconcile' as const;

export const MANUAL_IPC_CHANNELS = [
  MANUAL_STATE_CHANNEL,
  MANUAL_START_CHANNEL,
  MANUAL_CANCEL_CHANNEL,
  MANUAL_ADJUST_CHANNEL,
  MANUAL_SETTLE_CHANNEL,
  MANUAL_RECONCILE_CHANNEL,
] as const;

export type ManualTrackerStatusDto =
  'missing' | 'available' | 'empty' | 'unavailable' | 'migrationRequired';

export type ManualReconciliationDecisionDto =
  'applyNonConflicting' | 'keepLocal' | 'acceptObserved';

export type ManualStateRequest = {
  readonly villageId: string;
};

export type ManualStatePayload = {
  readonly generation: number;
  readonly villageId: string;
  readonly status: ManualTrackerStatusDto;
  readonly error: string | null;
  readonly baselineRevision: string | null;
  readonly baselineLineageId: string | null;
  readonly activeRecordCount: number;
  readonly itemStateCount: number;
  readonly lastSettleAtMs: number | null;
  readonly lastImportAtMs: number | null;
  readonly stateUpdatedAtMs: number | null;
};

export type ManualStateResponse = Result<ManualStatePayload>;

export type ManualStartRequest = {
  readonly expectedGeneration: number;
  readonly villageId: string;
  readonly itemKey: TrackerItemKeyDto;
  readonly fromLevel: number;
  readonly targetLevel: number;
  readonly quantity: number;
  readonly startedAtMs: number;
  readonly sourceKind: 'row' | 'group';
  readonly base: 'home' | 'builder';
};

export type ManualUpgradeRecordDto = {
  readonly recordId: string;
  readonly status: 'active' | 'completed' | 'cancelled';
  readonly fromLevel: number;
  readonly targetLevel: number;
  readonly quantity: number;
  readonly startedAtMs: number;
  readonly expectedEndAtMs: number;
};

export type ManualStartPayload = {
  readonly generation: number;
  readonly record: ManualUpgradeRecordDto;
};

export type ManualStartResponse = Result<ManualStartPayload>;

export type ManualCancelRequest = {
  readonly expectedGeneration: number;
  readonly villageId: string;
  readonly recordId: string;
};

export type ManualCancelPayload = {
  readonly generation: number;
  readonly record: ManualUpgradeRecordDto;
};

export type ManualCancelResponse = Result<ManualCancelPayload>;

export type ManualAdjustRequest = {
  readonly expectedGeneration: number;
  readonly villageId: string;
  readonly recordId: string;
  readonly startedAtMs: number;
};

export type ManualAdjustPayload = {
  readonly generation: number;
  readonly record: ManualUpgradeRecordDto;
};

export type ManualAdjustResponse = Result<ManualAdjustPayload>;

export type ManualSettleRequest = {
  readonly expectedGeneration: number;
  /** 省略则结算所有已对账村庄。 */
  readonly villageId?: string | null;
};

export type ManualSettlePayload = {
  readonly generation: number;
  readonly settledCount: number;
};

export type ManualSettleResponse = Result<ManualSettlePayload>;

export type ManualReconcileRequest = {
  readonly expectedGeneration: number;
  readonly villageId: string;
  readonly decision: ManualReconciliationDecisionDto;
};

export type ManualReconcilePayload = {
  readonly generation: number;
  readonly attentionCount: number;
  readonly duplicate: boolean;
  readonly lineageComparable: boolean;
};

export type ManualReconcileResponse = Result<ManualReconcilePayload>;

export type ManualIpcBridge = {
  manualState: (request: ManualStateRequest) => Promise<ManualStateResponse>;
  manualStart: (request: ManualStartRequest) => Promise<ManualStartResponse>;
  manualCancel: (request: ManualCancelRequest) => Promise<ManualCancelResponse>;
  manualAdjust: (request: ManualAdjustRequest) => Promise<ManualAdjustResponse>;
  manualSettle: (request: ManualSettleRequest) => Promise<ManualSettleResponse>;
  manualReconcile: (request: ManualReconcileRequest) => Promise<ManualReconcileResponse>;
};

export const MANUAL_IPC_BRIDGE_KEYS = [
  'manualState',
  'manualStart',
  'manualCancel',
  'manualAdjust',
  'manualSettle',
  'manualReconcile',
] as const satisfies ReadonlyArray<keyof ManualIpcBridge>;
