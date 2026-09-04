export const MANUAL_TRACKER_SCHEMA = {
  envelope: 1,
  store: 1,
  /** v2（Issue #304）：baseline 移除 fingerprint，provenance 移除 sourceFingerprint。旧文件标记不可用。 */
  village: 2,
} as const;

export type ManualTrackerDiagnosticKind = 'invalidState' | 'migration' | 'conflict' | 'unavailable';

export type ManualTrackerDiagnostic = {
  readonly kind: ManualTrackerDiagnosticKind;
  readonly code: string;
  readonly message: string;
  readonly recordedAtMs: number;
};

export function createManualTrackerDiagnostic(input: {
  readonly kind: ManualTrackerDiagnosticKind;
  readonly code: string;
  readonly message: string;
  readonly recordedAtMs?: number;
}): ManualTrackerDiagnostic {
  return {
    kind: input.kind,
    code: input.code,
    message: input.message,
    recordedAtMs: input.recordedAtMs ?? Date.now(),
  };
}

export type ManualTrackerMigrationMarker = {
  readonly version: number;
  readonly completedAtMs: number;
};

export function createManualTrackerMigrationMarker(input: {
  readonly version?: number;
  readonly completedAtMs: number;
}): ManualTrackerMigrationMarker {
  return {
    version: input.version ?? MANUAL_TRACKER_SCHEMA.envelope,
    completedAtMs: input.completedAtMs,
  };
}
