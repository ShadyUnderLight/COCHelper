import type { CanonicalJsonValue, Sha256Fingerprint, UuidString } from '@coc-helper/wire';

import { ACCOUNT_PARSER_VERSION, ACCOUNT_TIMER_SCHEMA_VERSION } from '../account/types';
import {
  SNAPSHOT_HISTORY_BUILDER_SECTIONS,
  SNAPSHOT_HISTORY_HOME_SECTIONS,
} from './known-sections';
import { SNAPSHOT_HISTORY_SCHEMA } from './schema';

export type SnapshotTimerUnit = 'seconds' | 'milliseconds';
export type SnapshotTimerSemantics = 'remaining' | 'absolute';

export type SnapshotTimerFieldSpec = {
  readonly unit: SnapshotTimerUnit;
  readonly semantics: SnapshotTimerSemantics;
  readonly minValue?: number;
  readonly maxValue?: number;
};

export type SnapshotTimerSchema = {
  readonly version: string;
  readonly fields: Readonly<Record<string, SnapshotTimerFieldSpec>>;
};

export const DEFAULT_ACCOUNT_TIMER_SCHEMA: SnapshotTimerSchema = {
  version: ACCOUNT_TIMER_SCHEMA_VERSION,
  fields: {
    timer: { unit: 'seconds', semantics: 'remaining', minValue: 0 },
    helper_timer: { unit: 'seconds', semantics: 'remaining', minValue: 0 },
    helper_cooldown: { unit: 'seconds', semantics: 'remaining', minValue: 0 },
  },
};

export type SnapshotHistoryBase = 'home' | 'builder' | 'unknown';

export function snapshotHistoryBaseFromSection(section: string): SnapshotHistoryBase {
  if (SNAPSHOT_HISTORY_BUILDER_SECTIONS.has(section)) {
    return 'builder';
  }
  if (SNAPSHOT_HISTORY_HOME_SECTIONS.has(section)) {
    return 'home';
  }
  return 'unknown';
}

export type SnapshotNestedKind = 'root' | 'type' | 'module' | 'unknown';

export type SnapshotNestedPathComponent = {
  readonly kind: SnapshotNestedKind;
  readonly dataID: bigint;
};

export type SnapshotItemIdentity = {
  readonly base: SnapshotHistoryBase;
  readonly rawSection: string;
  readonly dataID: bigint;
  readonly nestedKind: SnapshotNestedKind;
  readonly nestedRootIdentity: string | null;
  readonly nestedRootDataID: bigint | null;
  readonly nestedParentPath: readonly SnapshotNestedPathComponent[];
};

export function snapshotItemIdentityKey(identity: SnapshotItemIdentity): string {
  const components = [
    identity.base,
    identity.rawSection,
    identity.dataID.toString(),
    identity.nestedKind,
    identity.nestedRootIdentity ?? '',
    identity.nestedParentPath.map((part) => `${part.kind}:${part.dataID.toString()}`).join(','),
  ];
  return components.map((value) => `${new TextEncoder().encode(value).length}:${value}`).join('|');
}

export function createSnapshotItemIdentity(
  section: string,
  dataID: bigint | number,
  options: {
    base?: SnapshotHistoryBase;
    nestedKind?: SnapshotNestedKind;
    nestedRootIdentity?: string | null;
    nestedRootDataID?: bigint | null;
    nestedParentPath?: readonly SnapshotNestedPathComponent[];
  } = {},
): SnapshotItemIdentity {
  return {
    base: options.base ?? snapshotHistoryBaseFromSection(section),
    rawSection: section,
    dataID: typeof dataID === 'bigint' ? dataID : BigInt(dataID),
    nestedKind: options.nestedKind ?? 'root',
    nestedRootIdentity: options.nestedRootIdentity ?? null,
    nestedRootDataID: options.nestedRootDataID ?? null,
    nestedParentPath: options.nestedParentPath ?? [],
  };
}

export type SnapshotDisplayBinding = {
  readonly displayName?: string;
  readonly category?: string;
  readonly displayCategory?: string;
  readonly catalogVersion?: string;
  readonly catalogFingerprint?: string;
};

export type SnapshotObservationItem = {
  readonly identity: SnapshotItemIdentity;
  readonly level: number | null;
  readonly count: number | null;
  readonly rawTimerEvidence: Readonly<Record<string, CanonicalJsonValue>>;
  readonly helperRecurrent: boolean | null;
  readonly gearUp: number | null;
  readonly weapon: number | null;
  readonly unknownFields: Readonly<Record<string, CanonicalJsonValue>>;
  readonly display: SnapshotDisplayBinding;
};

export type CanonicalSnapshotObservation = {
  readonly schemaVersion: number;
  readonly rawTopLevelFields: Readonly<Record<string, CanonicalJsonValue>>;
  readonly unknownTopLevelFields: Readonly<Record<string, CanonicalJsonValue>>;
  readonly items: readonly SnapshotObservationItem[];
};

export type SnapshotCoverageState = 'complete' | 'partial' | 'unavailable';

export type SnapshotSectionPresence = 'missing' | 'presentEmpty' | 'presentNonEmpty' | 'invalid';

export type SnapshotCoverageProof =
  | {
      readonly kind: 'declared';
      readonly source: string;
      readonly version: string;
      readonly expectedCount: number | null;
    }
  | {
      readonly kind: 'verified';
      readonly source: string;
      readonly adapterID: string;
      readonly protocolVersion: string;
      readonly expectedCount: number | null;
      readonly verificationReason: string | null;
      readonly verificationRuleVersion: string | null;
      readonly inputBinding: string | null;
    }
  | {
      readonly kind: 'legacyAuthoritative';
      readonly source: string;
      readonly version: string;
      readonly expectedCount: number | null;
    }
  | { readonly kind: 'unavailable'; readonly reason: string };

export type SnapshotSectionCoverage = {
  readonly base: SnapshotHistoryBase;
  readonly rawSection: string;
  readonly presence: SnapshotSectionPresence;
  readonly completeness: SnapshotCoverageState;
  readonly proof: SnapshotCoverageProof;
  readonly observedCount: number;
};

export function snapshotSectionCoverageId(section: SnapshotSectionCoverage): string {
  return [section.base, section.rawSection]
    .map((value) => `${new TextEncoder().encode(value).length}:${value}`)
    .join('|');
}

export type SnapshotCoverageField = {
  readonly base: SnapshotHistoryBase;
  readonly rawSection: string;
  readonly field: string;
  readonly state: SnapshotCoverageState;
};

export function snapshotCoverageFieldId(field: SnapshotCoverageField): string {
  return [field.base, field.rawSection, field.field]
    .map((value) => `${new TextEncoder().encode(value).length}:${value}`)
    .join('|');
}

export type SnapshotSectionRelevance = 'required' | 'notApplicable' | 'unknown';

export type SnapshotCoverageSourceSectionRelevance = {
  readonly base: SnapshotHistoryBase;
  readonly rawSection: string;
  readonly relevance: SnapshotSectionRelevance;
};

export function snapshotCoverageSourceSectionRelevanceId(
  section: SnapshotCoverageSourceSectionRelevance,
): string {
  return [section.base, section.rawSection]
    .map((value) => `${new TextEncoder().encode(value).length}:${value}`)
    .join('|');
}

export type SnapshotCoverageSourceUniverse = {
  readonly adapterID: string;
  readonly protocolVersion: string;
  readonly sections: readonly SnapshotCoverageSourceSectionRelevance[];
};

export type SnapshotObservationCoverage = {
  readonly schemaVersion: number;
  readonly fields: readonly SnapshotCoverageField[];
  readonly sections: readonly SnapshotSectionCoverage[];
  readonly diagnostics: readonly string[];
  readonly sourceUniverse: SnapshotCoverageSourceUniverse | null;
};

export type SnapshotLineageOutcome = 'initial' | 'continued' | 'newLineage' | 'unknown';

export type SnapshotLineageReason =
  | 'initial'
  | 'sameVillageAndTag'
  | 'tagChanged'
  | 'missingTag'
  | 'invalidTag'
  | 'villageChanged'
  | 'previousConflict';

export type SnapshotLineageContext = {
  readonly villageID: UuidString;
  readonly lineageID: UuidString;
  readonly normalizedPlayerTag: string | null;
  readonly hasConflict: boolean;
};

export type SnapshotLineageResolution = {
  readonly lineageID: UuidString;
  readonly outcome: SnapshotLineageOutcome;
  readonly reason: SnapshotLineageReason;
  readonly isBaseline: boolean;
  readonly comparisonAllowed: boolean;
};

export type SnapshotHistoryEntry = {
  readonly schemaVersion: number;
  readonly observationVersion: number;
  readonly fingerprintVersion: number;
  readonly integrityVersion: number;
  readonly snapshotID: UuidString;
  readonly villageID: UuidString;
  readonly lineageID: UuidString;
  readonly normalizedPlayerTag: string | null;
  readonly appliedAtRefSeconds: number;
  readonly sourceTimestampRefSeconds: number | null;
  readonly parserVersion: string;
  readonly canonicalFingerprint: Sha256Fingerprint;
  readonly rawJSON: string;
  readonly observation: CanonicalSnapshotObservation;
  readonly coverage: SnapshotObservationCoverage;
  readonly isBaseline: boolean;
  readonly baselineReason: SnapshotLineageReason | null;
  readonly timerSchema: SnapshotTimerSchema | null;
  readonly integrityFingerprint: Sha256Fingerprint;
};

export type SnapshotHistoryCanonicalizationError =
  | { readonly kind: 'emptySource' }
  | { readonly kind: 'topLevelMustBeObject' }
  | { readonly kind: 'invalidJSON'; readonly message: string }
  | { readonly kind: 'sourceUniverseRequiresObservationV6' }
  | { readonly kind: 'canonicalizationLimitExceeded'; readonly message: string };

export function snapshotHistoryCanonicalizationErrorMessage(
  error: SnapshotHistoryCanonicalizationError,
): string {
  switch (error.kind) {
    case 'emptySource':
      return '快照原文为空，无法建立历史观察。';
    case 'topLevelMustBeObject':
      return '快照原文顶层必须是对象。';
    case 'invalidJSON':
      return `快照原文不是有效 JSON：${error.message}`;
    case 'sourceUniverseRequiresObservationV6':
      return 'source universe 需要 observation v6 或更高版本。';
    case 'canonicalizationLimitExceeded':
      return error.message;
  }
}

export function coverageProofExpectedCount(proof: SnapshotCoverageProof): number | null {
  switch (proof.kind) {
    case 'declared':
    case 'legacyAuthoritative':
      return proof.expectedCount;
    case 'verified':
      return proof.expectedCount;
    case 'unavailable':
      return null;
  }
}

function isNonBlankSource(source: string): boolean {
  return source.trim().length > 0;
}

function isParsableProtocolVersion(version: string): boolean {
  const components = version.split('.');
  if (components.length < 1 || components.length > 3) {
    return false;
  }
  return components.every((part) => part.length > 0 && /^[0-9]+$/.test(part));
}

export function isWellFormedCoverageDeclaration(proof: SnapshotCoverageProof): boolean {
  if (proof.kind !== 'declared' && proof.kind !== 'legacyAuthoritative') {
    return false;
  }
  if (!isNonBlankSource(proof.source) || !isParsableProtocolVersion(proof.version)) {
    return false;
  }
  return proof.expectedCount === null || proof.expectedCount >= 0;
}

export const SNAPSHOT_HISTORY_PARSER_VERSION = ACCOUNT_PARSER_VERSION;

export const SNAPSHOT_HISTORY_DEFAULT_SCHEMA = SNAPSHOT_HISTORY_SCHEMA;

export { SNAPSHOT_HISTORY_SCHEMA } from './schema';

const REGISTERED_COVERAGE_PROTOCOLS: Record<string, ReadonlySet<string>> = {
  'test-fixture': new Set(['1']),
  'perf-fixture': new Set(['1']),
};

/** 测试专用 verified coverage proof 工厂（对齐 SnapshotCoverageVerifier.issueTestFixture）。 */
export function issueTestCoverageProof(
  source = 'test-export',
  expectedCount: number | null = null,
  verificationReason = 'test injection',
): SnapshotCoverageProof {
  const adapterID = 'test-fixture';
  const protocolVersion = '1';
  if (!REGISTERED_COVERAGE_PROTOCOLS[adapterID]?.has(protocolVersion)) {
    return {
      kind: 'unavailable',
      reason: `coverage adapter 未注册或不支持协议版本：${adapterID}@${protocolVersion}。`,
    };
  }
  if (
    source.trim().length === 0 ||
    (expectedCount !== null && expectedCount < 0) ||
    verificationReason.trim().length === 0
  ) {
    return { kind: 'unavailable', reason: 'verified coverage 证据格式无效。' };
  }
  return {
    kind: 'verified',
    source,
    adapterID,
    protocolVersion,
    expectedCount,
    verificationReason,
    verificationRuleVersion: null,
    inputBinding: null,
  };
}
