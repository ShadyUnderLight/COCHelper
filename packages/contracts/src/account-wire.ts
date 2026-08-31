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

export type PendingImportPreviewWire = {
  readonly snapshot: AccountSnapshotWire;
  readonly targetKind: 'existing' | 'create' | 'ambiguous';
  readonly targetVillageId?: string;
  readonly targetVillageName?: string;
  readonly ambiguousTag?: string;
  readonly ambiguousVillageNames?: readonly string[];
};
