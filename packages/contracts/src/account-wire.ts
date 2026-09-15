/** M-2 legacy 导入链 wire DTO（dto-mapping.md）。 */

export type AccountDiagnosticWire = {
  readonly id: string;
  readonly severity: 'info' | 'warning';
  readonly path: string;
  readonly message: string;
};

export type AccountItemWire = {
  readonly id: string;
  readonly section: string;
  readonly dataID: number;
  readonly level?: number;
  readonly count?: number;
  readonly timerSeconds?: number;
  readonly remainingSeconds?: number;
  readonly helperTimerSeconds?: number;
  readonly remainingHelperSeconds?: number;
  readonly helperCooldownSeconds?: number;
  readonly remainingHelperCooldownSeconds?: number;
  readonly helperRecurrent: boolean;
  readonly gearUp?: number;
  readonly weapon?: number;
  readonly types: readonly AccountItemWire[];
  readonly modules: readonly AccountItemWire[];
};

export type AccountSnapshotWire = {
  readonly tag?: string;
  readonly capturedAt?: number;
  readonly importedAt: number;
  readonly ageSeconds?: number;
  readonly originalText: string;
  readonly objectSections: Readonly<Record<string, readonly AccountItemWire[]>>;
  readonly numericSections: Readonly<Record<string, readonly number[]>>;
  readonly boosts: Readonly<Record<string, number>>;
  readonly unknownTopLevelKeys: readonly string[];
  readonly diagnostics: readonly AccountDiagnosticWire[];
};

export type QuickImportPreviewWire = {
  readonly snapshot: AccountSnapshotWire;
  readonly targetVillageId: string;
  readonly targetVillageName: string;
  readonly targetVillageTag: string | null;
  readonly targetVillageHasSnapshot: boolean;
  readonly replacesSameTag: boolean;
  readonly destinationDescription: string;
};

/**
 * #277-D 快捷导入专用最小快照摘要：只含确认 UI 需要的字段。
 * 绝不能含 originalText/objectSections/numericSections/boosts——剪贴板原文只活在 Main，
 * 经 IPC 到 Renderer 的只有摘要。
 */
export type QuickImportSnapshotSummaryWire = {
  readonly tag?: string;
  readonly diagnostics: readonly AccountDiagnosticWire[];
  readonly unknownTopLevelKeys: readonly string[];
};

/** #277-D 快捷导入 IPC 预览：快照部分为最小摘要，不含原文。 */
export type QuickPreparePreviewWire = {
  readonly snapshot: QuickImportSnapshotSummaryWire;
  readonly targetVillageId: string;
  readonly targetVillageName: string;
  readonly targetVillageTag: string | null;
  readonly targetVillageHasSnapshot: boolean;
  readonly replacesSameTag: boolean;
  readonly destinationDescription: string;
};

export type PendingImportPreviewWire = {
  readonly snapshot: AccountSnapshotWire;
  readonly targetKind: 'existing' | 'create' | 'ambiguous';
  readonly targetVillageId?: string;
  readonly targetVillageName?: string;
  readonly ambiguousTag?: string;
  readonly ambiguousVillageNames?: readonly string[];
};
