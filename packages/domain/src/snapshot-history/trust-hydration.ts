import { parseJson, sortedObjectKeys, type CanonicalJsonValue } from '@coc-helper/wire';

import { prepareAccountText } from '../account/prepare';
import { parseAccountSnapshot } from '../account/parser';
import type { AccountSnapshot } from '../account/types';
import type { Clock } from '../primitives';
import { observationIdentityKey } from './canonicalizer';
import { coverageProofsForSnapshot } from './coverage-adapter';
import { recognizesPerfFixture, requiredSectionsForFixture } from './fixture-identities';
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

export function revalidateCoverageProof(input: {
  readonly proof: Extract<SnapshotCoverageProof, { kind: 'verified' }>;
  readonly rawJSON: string;
  readonly section: string;
  readonly policy: SnapshotCoverageRevalidationPolicy;
  /**
   * Issue #304 follow-up：已校验 envelope 的 entry observation 身份
   *（validate 已证明其等于 rawJSON 重建值）。缺失时 perf 路径 fail-closed。
   */
  readonly observationKey?: string;
}): SectionCoverageRuntimeTrust {
  const { proof, rawJSON, section, policy, observationKey } = input;
  if (
    proof.adapterID === SNAPSHOT_COVERAGE_TEST_FIXTURE_ADAPTER_ID &&
    policy === 'testsAllowTestFixture'
  ) {
    return revalidateTestFixtureProof(proof);
  }
  // Issue #304：不再比较内容 inputBinding 摘要；保留 rule 版本门、
  // section 结构校验与 adapter 来源校验。
  if (proof.verificationRuleVersion === null) {
    return { kind: 'rejected', reason: '缺少 persisted revalidation 材料。' };
  }
  if (proof.verificationRuleVersion !== SNAPSHOT_COVERAGE_CURRENT_VERIFICATION_RULE_VERSION) {
    return {
      kind: 'rejected',
      reason: `verification rule 版本不受支持：${proof.verificationRuleVersion}。`,
    };
  }
  if (!validatePersistedSectionStructure(rawJSON, section, proof.expectedCount)) {
    return { kind: 'rejected', reason: 'section 结构校验失败。' };
  }

  if (proof.adapterID === SNAPSHOT_COVERAGE_PERF_FIXTURE_ADAPTER_ID) {
    return revalidatePerfFixtureProof(proof, rawJSON, section, observationKey);
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
  rawJSON: string,
  section: string,
  observationKey: string | undefined,
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
  // Issue #304 follow-up：fixture 身份必须由 loader 签发，且 entry observation
  // 必须命中该 fixture 的 registry 记录。rawJSON.coverage 自报声明只是随后
  // 的一致性门，不再是授权依据：两边一起改也过不了 registry 比对。
  if (proof.fixtureID === null || proof.fixtureID.length === 0) {
    return { kind: 'rejected', reason: 'perf fixture 缺少受控 fixture 身份。' };
  }
  if (observationKey === undefined || !recognizesPerfFixture(proof.fixtureID, observationKey)) {
    return { kind: 'rejected', reason: 'perf fixture 身份与 registry 记录不一致。' };
  }
  // Issue #304：不再用内容 hash allowlist 判定；rawJSON 仍须按 adapter 契约
  // 声明该 section（业务来源表达）。
  if (!perfFixtureDeclaresSection(rawJSON, section, proof.expectedCount)) {
    return { kind: 'rejected', reason: 'perf fixture coverage 声明与 section 不一致。' };
  }
  return { kind: 'trusted' };
}

function perfFixtureDeclaresSection(
  rawJSON: string,
  section: string,
  expectedCount: number | null,
): boolean {
  const snapshot = tryParseSnapshot(rawJSON);
  if (snapshot === undefined) {
    return false;
  }
  const proofs = coverageProofsForSnapshot(snapshot);
  const proof = proofs[section];
  if (proof === undefined) {
    return false;
  }
  // TS adapter 把 authoritative/declared 声明分别归一化为
  // legacyAuthoritative/declared（Swift 侧统一归一化为 declared）；
  // 两者都是有效的 fixture 来源表达，判定语义与 Swift 一致。
  if (proof.kind !== 'declared' && proof.kind !== 'legacyAuthoritative') {
    return false;
  }
  return (
    proof.source === SNAPSHOT_COVERAGE_PERF_FIXTURE_ADAPTER_ID &&
    proof.version === '1' &&
    proof.expectedCount === expectedCount
  );
}

export function revalidateSourceUniverse(input: {
  readonly universe: SnapshotCoverageSourceUniverse;
  /** 保留字段位：perf/test 路径均不再需要 snapshot（registry/verified-proof 路径）。 */
  readonly snapshot?: AccountSnapshot;
  readonly coverage: SnapshotObservationCoverage;
  readonly policy: SnapshotCoverageRevalidationPolicy;
  /** entry 携带的 verified perf proof fixture 身份集合（去重）。 */
  readonly perfFixtureIDs?: ReadonlySet<string>;
  readonly observationKey?: string;
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
    return revalidatePerfFixtureSourceUniverse(
      input.universe,
      input.perfFixtureIDs ?? new Set(),
      input.observationKey,
    );
  }
  return { kind: 'rejected', reason: '未注册的 source universe adapter。' };
}

function revalidatePerfFixtureSourceUniverse(
  universe: SnapshotCoverageSourceUniverse,
  fixtureIDs: ReadonlySet<string>,
  observationKey: string | undefined,
): SourceUniverseRuntimeTrust {
  // Issue #304 follow-up：universe 期望来自 registry 的 fixture 真实 section
  // 集，绝不从 reload-time rawJSON 自报声明派生（自证自销）。身份必须唯一且
  // entry observation 必须命中该 fixture 记录。
  if (fixtureIDs.size !== 1) {
    return { kind: 'rejected', reason: 'perf fixture 身份缺失或不一致。' };
  }
  const fixtureID = [...fixtureIDs][0]!;
  if (observationKey === undefined || !recognizesPerfFixture(fixtureID, observationKey)) {
    return { kind: 'rejected', reason: 'perf fixture 身份与 registry 记录不一致。' };
  }
  const requiredSections = requiredSectionsForFixture(fixtureID);
  if (requiredSections === undefined) {
    return { kind: 'rejected', reason: '未注册的 perf fixture 身份。' };
  }
  const expected = issuePerfFixtureSourceUniverse(requiredSections);
  if (JSON.stringify(expected) !== JSON.stringify(universe)) {
    return { kind: 'rejected', reason: 'perf fixture source universe 与 registry 背书不一致。' };
  }
  return { kind: 'trusted' };
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

export function issuePerfFixtureSourceUniverse(
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
    adapterID: SNAPSHOT_COVERAGE_PERF_FIXTURE_ADAPTER_ID,
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
    observationKey: observationIdentityKey(input.entry.observation),
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
  /** 已校验 envelope 的 entry observation 身份（必填，perf 路径授权之用）。 */
  readonly observationKey: string;
}): HydratedSnapshotObservationCoverage {
  const snapshot = tryParseSnapshot(input.rawJSON, input.clock);

  // Section 先行：universe 需要 entry 携带的 fixture 身份集合。
  // entry 必须来自已校验 envelope（validate 已证明 observation 等于 rawJSON
  // 重建值），registry 比对才有效；直接 hydrate 未校验 envelope 会使 perf
  // 路径 fail-closed。
  const { observationKey } = input;
  let sectionsChanged = false;
  const perfFixtureIDs = new Set<string>();
  const sections = input.coverage.sections.map((section) => {
    if (section.proof.kind === 'verified') {
      if (
        section.proof.adapterID === SNAPSHOT_COVERAGE_PERF_FIXTURE_ADAPTER_ID &&
        section.proof.fixtureID !== null &&
        section.proof.fixtureID.length > 0
      ) {
        perfFixtureIDs.add(section.proof.fixtureID);
      }
      if (initialSectionRuntimeTrust(section.proof).kind === 'trusted') {
        return { ...section, runtimeTrust: initialSectionRuntimeTrust(section.proof) };
      }
      const trust = revalidateCoverageProof({
        proof: section.proof,
        rawJSON: input.rawJSON,
        section: section.rawSection,
        policy: input.policy,
        observationKey,
      });
      if (trust.kind !== initialSectionRuntimeTrust(section.proof).kind) {
        sectionsChanged = true;
      }
      return { ...section, runtimeTrust: trust };
    }
    return { ...section, runtimeTrust: initialSectionRuntimeTrust(section.proof) };
  });

  let universeTrust = initialSourceUniverseRuntimeTrust(input.coverage.sourceUniverse);
  if (input.coverage.sourceUniverse !== null && universeTrust.kind !== 'trusted') {
    if (
      input.coverage.sourceUniverse.adapterID === SNAPSHOT_COVERAGE_PERF_FIXTURE_ADAPTER_ID ||
      snapshot !== undefined
    ) {
      // perf universe 不依赖 snapshot 解析（registry 路径）。
      universeTrust = revalidateSourceUniverse({
        universe: input.coverage.sourceUniverse,
        snapshot,
        coverage: input.coverage,
        policy: input.policy,
        perfFixtureIDs,
        observationKey,
      });
    } else if (universeTrust.kind === 'pending') {
      universeTrust = {
        kind: 'rejected',
        reason: '无法解析 source JSON 以重验证 source universe。',
      };
    }
  }

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
