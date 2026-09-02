import { createHash } from 'node:crypto';

import {
  canonicalBytes,
  canonicalize,
  parseJson,
  sortedObjectKeys,
  type CanonicalJsonValue,
} from '@coc-helper/wire';

import { prepareAccountText } from '../account/prepare';
import { parseAccountSnapshot } from '../account/parser';
import type { AccountSnapshot } from '../account/types';
import type { Clock } from '../primitives';
import { SNAPSHOT_HISTORY_ALL_SECTIONS } from './known-sections';
import { SNAPSHOT_HISTORY_SCHEMA } from './schema';
import type {
  SectionCoverageRuntimeTrust,
  SnapshotCoverageRevalidationPolicy,
  SourceUniverseRuntimeTrust,
} from './store-types';
import {
  snapshotHistoryBaseFromSection,
  type SnapshotCoverageProof,
  type SnapshotCoverageSourceUniverse,
  type SnapshotHistoryEntry,
  type SnapshotObservationCoverage,
  type SnapshotSectionCoverage,
} from './types';

export const SNAPSHOT_COVERAGE_TEST_FIXTURE_ADAPTER_ID = 'test-fixture';
export const SNAPSHOT_COVERAGE_PERF_FIXTURE_ADAPTER_ID = 'perf-fixture';
export const SNAPSHOT_COVERAGE_CURRENT_VERIFICATION_RULE_VERSION = '1';

export function sectionInputBinding(rawJSON: string, section: string): string | null {
  const topLevel = tryTopLevelObject(rawJSON);
  if (topLevel === undefined) {
    return null;
  }
  const value = topLevel[section];
  if (value === undefined) {
    return null;
  }
  try {
    const canonical = canonicalize(parseJson(JSON.stringify(value)));
    const digest = createHash('sha256').update(canonicalBytes(canonical)).digest('hex');
    return `sha256:${digest}`;
  } catch {
    return null;
  }
}

export function revalidateCoverageProof(input: {
  readonly proof: Extract<SnapshotCoverageProof, { kind: 'verified' }>;
  readonly rawJSON: string;
  readonly section: string;
  readonly policy: SnapshotCoverageRevalidationPolicy;
}): SectionCoverageRuntimeTrust {
  const { proof, rawJSON, section, policy } = input;
  if (
    proof.adapterID === SNAPSHOT_COVERAGE_TEST_FIXTURE_ADAPTER_ID &&
    policy === 'testsAllowTestFixture'
  ) {
    return revalidateTestFixtureProof(proof);
  }
  if (proof.verificationRuleVersion === null || proof.inputBinding === null) {
    return { kind: 'rejected', reason: '缺少 persisted revalidation 材料。' };
  }
  if (proof.verificationRuleVersion !== SNAPSHOT_COVERAGE_CURRENT_VERIFICATION_RULE_VERSION) {
    return {
      kind: 'rejected',
      reason: `verification rule 版本不受支持：${proof.verificationRuleVersion}。`,
    };
  }
  const computedBinding = sectionInputBinding(rawJSON, section);
  if (computedBinding === null || computedBinding !== proof.inputBinding) {
    return { kind: 'rejected', reason: '验证输入绑定不匹配。' };
  }
  if (!validatePersistedSectionStructure(rawJSON, section, proof.expectedCount)) {
    return { kind: 'rejected', reason: 'section 结构校验失败。' };
  }

  if (proof.adapterID === SNAPSHOT_COVERAGE_PERF_FIXTURE_ADAPTER_ID) {
    return revalidatePerfFixtureProof(proof, rawJSON, section);
  }
  return {
    kind: 'rejected',
    reason: `未注册的 coverage revalidator：${proof.adapterID}@${proof.protocolVersion}。`,
  };
}

function revalidateTestFixtureProof(
  proof: Extract<SnapshotCoverageProof, { kind: 'verified' }>,
): SectionCoverageRuntimeTrust {
  if (proof.adapterID !== SNAPSHOT_COVERAGE_TEST_FIXTURE_ADAPTER_ID) {
    return { kind: 'rejected', reason: 'adapterID 与 test fixture 契约不一致。' };
  }
  if (!isWellFormedVerifiedWireProof(proof)) {
    return { kind: 'rejected', reason: 'test fixture wire evidence 无效。' };
  }
  return { kind: 'trusted' };
}

function revalidatePerfFixtureProof(
  proof: Extract<SnapshotCoverageProof, { kind: 'verified' }>,
  _rawJSON: string,
  _section: string,
): SectionCoverageRuntimeTrust {
  if (proof.adapterID !== SNAPSHOT_COVERAGE_PERF_FIXTURE_ADAPTER_ID) {
    return { kind: 'rejected', reason: 'adapterID 与 perf fixture 契约不一致。' };
  }
  if (proof.source !== SNAPSHOT_COVERAGE_PERF_FIXTURE_ADAPTER_ID) {
    return { kind: 'rejected', reason: 'perf fixture source 不匹配。' };
  }
  if (proof.verificationReason !== 'bundled perf fixture') {
    return { kind: 'rejected', reason: 'perf fixture verificationReason 不匹配。' };
  }
  return { kind: 'rejected', reason: 'rawJSON 不是受信任的 bundled perf fixture。' };
}

export function revalidateSourceUniverse(input: {
  readonly universe: SnapshotCoverageSourceUniverse;
  readonly snapshot: AccountSnapshot;
  readonly coverage: SnapshotObservationCoverage;
  readonly policy: SnapshotCoverageRevalidationPolicy;
}): SourceUniverseRuntimeTrust {
  if (!isRegisteredSourceUniverse(input.universe)) {
    return { kind: 'rejected', reason: 'source universe wire contract 无效。' };
  }
  if (input.universe.adapterID === SNAPSHOT_COVERAGE_TEST_FIXTURE_ADAPTER_ID) {
    if (input.policy !== 'testsAllowTestFixture') {
      return {
        kind: 'rejected',
        reason: 'production load 不得恢复 test-fixture source universe。',
      };
    }
    return revalidateTestFixtureSourceUniverse(input.universe, input.coverage);
  }
  if (input.universe.adapterID === SNAPSHOT_COVERAGE_PERF_FIXTURE_ADAPTER_ID) {
    return { kind: 'rejected', reason: 'rawJSON 不是受信任的 bundled perf fixture。' };
  }
  return { kind: 'rejected', reason: '未注册的 source universe adapter。' };
}

function revalidateTestFixtureSourceUniverse(
  universe: SnapshotCoverageSourceUniverse,
  coverage: SnapshotObservationCoverage,
): SourceUniverseRuntimeTrust {
  const authorizedRequired = new Set(
    coverage.sections
      .filter((section) => section.proof.kind === 'verified')
      .map((section) => section.rawSection),
  );
  const expected = issueTestFixtureSourceUniverse(authorizedRequired);
  if (JSON.stringify(expected) !== JSON.stringify(universe)) {
    return {
      kind: 'rejected',
      reason: 'test-fixture source universe 与 verified section proofs 不一致。',
    };
  }
  return { kind: 'trusted' };
}

export function issueTestFixtureSourceUniverse(
  requiredSections: ReadonlySet<string>,
): SnapshotCoverageSourceUniverse {
  const sections = [...SNAPSHOT_HISTORY_ALL_SECTIONS].sort().map((rawSection) => ({
    base: snapshotHistoryBaseFromSection(rawSection),
    rawSection,
    relevance: requiredSections.has(rawSection)
      ? ('required' as const)
      : ('notApplicable' as const),
  }));
  return {
    adapterID: SNAPSHOT_COVERAGE_TEST_FIXTURE_ADAPTER_ID,
    protocolVersion: '1',
    sections,
  };
}

export type HydratedSnapshotSectionCoverage = SnapshotSectionCoverage & {
  readonly runtimeTrust: SectionCoverageRuntimeTrust;
};

export type HydratedSnapshotObservationCoverage = Omit<SnapshotObservationCoverage, 'sections'> & {
  readonly sections: readonly HydratedSnapshotSectionCoverage[];
  readonly sourceUniverseRuntimeTrust: SourceUniverseRuntimeTrust;
};

export type HydratedSnapshotHistoryEntry = Omit<SnapshotHistoryEntry, 'coverage'> & {
  readonly coverage: HydratedSnapshotObservationCoverage;
};

export function hydrateVerifiedCoverageOnEntry(input: {
  readonly entry: SnapshotHistoryEntry;
  readonly policy?: SnapshotCoverageRevalidationPolicy;
  readonly clock?: Clock;
}): HydratedSnapshotHistoryEntry {
  const hydratedCoverage = hydrateVerifiedCoverage({
    coverage: input.entry.coverage,
    rawJSON: input.entry.rawJSON,
    policy: input.policy ?? 'production',
    clock: input.clock,
  });
  if (hydratedCoverage === input.entry.coverage) {
    return {
      ...input.entry,
      coverage: withDefaultRuntimeTrust(input.entry.coverage),
    };
  }
  return {
    ...input.entry,
    coverage: hydratedCoverage,
  };
}

export function hydrateVerifiedCoverageOnEnvelope(input: {
  readonly envelope: import('./store-types').SnapshotHistoryEnvelope;
  readonly policy?: SnapshotCoverageRevalidationPolicy;
  readonly clock?: Clock;
}): import('./store-types').SnapshotHistoryEnvelope {
  const policy = input.policy ?? 'production';
  let changed = false;
  const hydratedEntries = input.envelope.entries.map((entry) => {
    const hydrated = hydrateVerifiedCoverageOnEntry({ entry, policy, clock: input.clock });
    if (hydrated.coverage !== withDefaultRuntimeTrust(entry.coverage)) {
      changed = true;
    }
    return hydrated;
  });
  if (!changed) {
    return input.envelope;
  }
  return {
    ...input.envelope,
    entries: hydratedEntries as SnapshotHistoryEntry[],
  };
}

function withDefaultRuntimeTrust(
  coverage: SnapshotObservationCoverage,
): HydratedSnapshotObservationCoverage {
  return {
    ...coverage,
    sections: coverage.sections.map((section) => ({
      ...section,
      runtimeTrust: initialSectionRuntimeTrust(section.proof),
    })),
    sourceUniverseRuntimeTrust: initialSourceUniverseRuntimeTrust(coverage.sourceUniverse),
  };
}

function hydrateVerifiedCoverage(input: {
  readonly coverage: SnapshotObservationCoverage;
  readonly rawJSON: string;
  readonly policy: SnapshotCoverageRevalidationPolicy;
  readonly clock?: Clock;
}): HydratedSnapshotObservationCoverage {
  const snapshot = tryParseSnapshot(input.rawJSON, input.clock);
  let universeTrust = initialSourceUniverseRuntimeTrust(input.coverage.sourceUniverse);
  if (input.coverage.sourceUniverse !== null && universeTrust.kind !== 'trusted') {
    if (snapshot !== undefined) {
      universeTrust = revalidateSourceUniverse({
        universe: input.coverage.sourceUniverse,
        snapshot,
        coverage: input.coverage,
        policy: input.policy,
      });
    } else if (universeTrust.kind === 'pending') {
      universeTrust = {
        kind: 'rejected',
        reason: '无法解析 source JSON 以重验证 source universe。',
      };
    }
  }

  let sectionsChanged = false;
  const sections = input.coverage.sections.map((section) => {
    if (
      section.proof.kind !== 'verified' ||
      initialSectionRuntimeTrust(section.proof).kind === 'trusted'
    ) {
      return { ...section, runtimeTrust: initialSectionRuntimeTrust(section.proof) };
    }
    const trust = revalidateCoverageProof({
      proof: section.proof,
      rawJSON: input.rawJSON,
      section: section.rawSection,
      policy: input.policy,
    });
    if (trust.kind !== initialSectionRuntimeTrust(section.proof).kind) {
      sectionsChanged = true;
    }
    return { ...section, runtimeTrust: trust };
  });

  if (
    !sectionsChanged &&
    universeTrust.kind === initialSourceUniverseRuntimeTrust(input.coverage.sourceUniverse).kind
  ) {
    return withDefaultRuntimeTrust(input.coverage);
  }
  return {
    ...input.coverage,
    sections,
    sourceUniverseRuntimeTrust: universeTrust,
  };
}

function initialSectionRuntimeTrust(proof: SnapshotCoverageProof): SectionCoverageRuntimeTrust {
  return proof.kind === 'verified' ? { kind: 'pending' } : { kind: 'notApplicable' };
}

function initialSourceUniverseRuntimeTrust(
  universe: SnapshotCoverageSourceUniverse | null,
): SourceUniverseRuntimeTrust {
  if (universe === null) {
    return { kind: 'notApplicable' };
  }
  return { kind: 'pending' };
}

function isWellFormedVerifiedWireProof(
  proof: Extract<SnapshotCoverageProof, { kind: 'verified' }>,
): boolean {
  if (proof.verificationReason === null || proof.verificationReason.trim().length === 0) {
    return false;
  }
  if (proof.source.trim().length === 0) {
    return false;
  }
  return isRegisteredAdapter(proof.adapterID, proof.protocolVersion);
}

function isRegisteredAdapter(adapterID: string, protocolVersion: string): boolean {
  const registered: Record<string, readonly string[]> = {
    [SNAPSHOT_COVERAGE_TEST_FIXTURE_ADAPTER_ID]: ['1'],
    [SNAPSHOT_COVERAGE_PERF_FIXTURE_ADAPTER_ID]: ['1'],
  };
  return registered[adapterID]?.includes(protocolVersion) ?? false;
}

function isRegisteredSourceUniverse(universe: SnapshotCoverageSourceUniverse): boolean {
  return isRegisteredAdapter(universe.adapterID, universe.protocolVersion);
}

function validatePersistedSectionStructure(
  rawJSON: string,
  section: string,
  expectedCount: number | null,
): boolean {
  const topLevel = tryTopLevelObject(rawJSON);
  if (topLevel === undefined) {
    return false;
  }
  const value = topLevel[section];
  if (!Array.isArray(value)) {
    return false;
  }
  if (expectedCount !== null && value.length !== expectedCount) {
    return false;
  }
  return true;
}

function tryTopLevelObject(text: string): Record<string, unknown> | undefined {
  const prepared = prepareAccountText(text).text;
  try {
    const parsed = parseJson(prepared);
    if (parsed.kind !== 'object') {
      return undefined;
    }
    const result: Record<string, unknown> = {};
    for (const key of sortedObjectKeys(parsed.fields)) {
      result[key] = canonicalJsonValueToUnknown(parsed.fields[key]!);
    }
    return result;
  } catch {
    return undefined;
  }
}

function canonicalJsonValueToUnknown(value: CanonicalJsonValue): unknown {
  switch (value.kind) {
    case 'null':
      return null;
    case 'bool':
      return value.value;
    case 'number':
      return Number(value.value);
    case 'string':
      return value.value;
    case 'array':
      return value.items.map(canonicalJsonValueToUnknown);
    case 'object': {
      const result: Record<string, unknown> = {};
      for (const key of sortedObjectKeys(value.fields)) {
        result[key] = canonicalJsonValueToUnknown(value.fields[key]!);
      }
      return result;
    }
  }
}

function tryParseSnapshot(rawJSON: string, clock?: Clock): AccountSnapshot | undefined {
  const parsed = parseAccountSnapshot(rawJSON, {
    clock: clock ?? { nowMs: () => 1000 },
  });
  return parsed.ok ? parsed.value : undefined;
}

export function coverageHasLegacySectionEvidence(coverage: SnapshotObservationCoverage): boolean {
  return (
    coverage.schemaVersion < SNAPSHOT_HISTORY_SCHEMA.observationWithSectionEvidence &&
    coverage.sections.length === 0
  );
}
