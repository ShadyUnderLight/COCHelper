import type { UuidString } from '@coc-helper/wire';

export const ACCOUNT_PARSER_VERSION = 'account-json-0.1' as const;
export const ACCOUNT_TIMER_SCHEMA_VERSION = 'account-json-timer-1' as const;
export const COVERAGE_CONTRACT_FIELD = 'coverage' as const;

export type AccountDataDiagnosticSeverity = 'info' | 'warning';

export type AccountDataDiagnostic = {
  readonly id: UuidString;
  readonly severity: AccountDataDiagnosticSeverity;
  readonly path: string;
  readonly message: string;
};

export type AccountItem = {
  readonly id: string;
  readonly section: string;
  readonly dataID: bigint;
  readonly level: number | null;
  readonly count: number | null;
  readonly timerSeconds: bigint | null;
  readonly remainingSeconds: bigint | null;
  readonly helperTimerSeconds: bigint | null;
  readonly remainingHelperSeconds: bigint | null;
  readonly helperCooldownSeconds: bigint | null;
  readonly remainingHelperCooldownSeconds: bigint | null;
  readonly helperRecurrent: boolean;
  readonly gearUp: number | null;
  readonly weapon: number | null;
  readonly types: readonly AccountItem[];
  readonly modules: readonly AccountItem[];
};

export type AccountSnapshot = {
  readonly tag: string | null;
  readonly capturedAtMs: number | null;
  readonly importedAtMs: number;
  readonly ageSeconds: bigint | null;
  readonly originalText: string;
  readonly objectSections: Readonly<Record<string, readonly AccountItem[]>>;
  readonly numericSections: Readonly<Record<string, readonly bigint[]>>;
  readonly boosts: Readonly<Record<string, bigint>>;
  readonly unknownTopLevelKeys: readonly string[];
  readonly diagnostics: readonly AccountDataDiagnostic[];
};

export type AccountSnapshotImportError =
  | { readonly kind: 'emptyInput' }
  | { readonly kind: 'topLevelMustBeObject' }
  | { readonly kind: 'invalidJSON'; readonly message: string };

export function accountImportErrorMessage(error: AccountSnapshotImportError): string {
  switch (error.kind) {
    case 'emptyInput':
      return '没有可解析的文本。请先从游戏复制并粘贴 JSON。';
    case 'topLevelMustBeObject':
      return 'JSON 顶层必须是对象，以 { 开头。';
    case 'invalidJSON':
      return `JSON 解析失败：${error.message}`;
  }
}

export const OBJECT_SECTION_NAMES = new Set([
  'helpers',
  'guardians',
  'buildings',
  'traps',
  'decos',
  'obstacles',
  'units',
  'siege_machines',
  'heroes',
  'spells',
  'pets',
  'equipment',
  'buildings2',
  'traps2',
  'decos2',
  'obstacles2',
  'units2',
  'heroes2',
]);

export const NUMERIC_SECTION_NAMES = new Set([
  'house_parts',
  'skins',
  'sceneries',
  'skins2',
  'sceneries2',
]);

export function isBuilderBaseSection(section: string): boolean {
  return section.endsWith('2');
}
