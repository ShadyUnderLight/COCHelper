import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

import { parseUuid } from '@coc-helper/wire';

import { parseAccountSnapshot } from '../account/parser';
import { canonicalizeSnapshotHistory } from './canonicalizer';
import { coverageProofsForSnapshot } from './coverage-adapter';
import {
  validateSnapshotHistoryEntry,
  validateSnapshotHistoryEntryIntegrity,
  validateSnapshotHistoryEnvelope,
} from './envelope-validate';
import {
  createSnapshotHistoryMigrationMarker,
  decodeSnapshotHistoryEnvelopeWire,
  encodeSnapshotHistoryEnvelopeWire,
} from './envelope-wire';
import { perfFixtureIdentityRecords, requiredSectionsForFixture } from './fixture-identities';
import { createSnapshotHistoryEnvelope, sectionTrustOpensGates } from './store-types';
import {
  hydrateVerifiedCoverageOnEntry,
  issuePerfFixtureSourceUniverse,
  type HydratedSnapshotHistoryEntry,
} from './trust-hydration';
import { type SnapshotCoverageProof, type SnapshotHistoryEntry } from './types';

const here = process.cwd();
const FIXTURES_DIR = resolve(here, 'Tests/COCHelperCoreTests/Fixtures');
const HOME_FIXTURE_ID = 'perf_account_snapshot_home';
const BUILDER_FIXTURE_ID = 'perf_account_snapshot_builder';
const VILLAGE_ID = parseUuid('11111111-1111-1111-1111-111111111111')!;
const LINEAGE_ID = parseUuid('22222222-2222-2222-2222-222222222222')!;

function fixtureText(name: string): string {
  return readFileSync(resolve(FIXTURES_DIR, `${name}.json`), 'utf8');
}

/** 签发期等价动作：declared perf proof → verified（loader 签发 fixtureID）。 */
function promoteForFixture(
  proofs: Record<string, SnapshotCoverageProof>,
  fixtureID: string,
): Record<string, SnapshotCoverageProof> {
  const out: Record<string, SnapshotCoverageProof> = {};
  for (const [section, proof] of Object.entries(proofs)) {
    // TS adapter 把 authoritative/declared 都归一化为声明；fixture 文件用的是
    // authoritative kind（Swift 侧同理映射为 declared）。
    if (
      (proof.kind === 'declared' || proof.kind === 'legacyAuthoritative') &&
      proof.source === 'perf-fixture' &&
      proof.version === '1'
    ) {
      out[section] = {
        kind: 'verified',
        source: proof.source,
        adapterID: 'perf-fixture',
        protocolVersion: proof.version,
        expectedCount: proof.expectedCount,
        verificationReason: 'bundled perf fixture',
        verificationRuleVersion: '1',
        fixtureID,
      };
    } else {
      out[section] = proof;
    }
  }
  return out;
}

function issueFixtureEntry(name: string): SnapshotHistoryEntry {
  const raw = fixtureText(name);
  const parsed = parseAccountSnapshot(raw, { clock: { nowMs: () => 1000 } });
  expect(parsed.ok).toBe(true);
  if (!parsed.ok) throw new Error(`fixture 解析失败: ${name}`);
  const required = requiredSectionsForFixture(name);
  expect(required).toBeDefined();
  return canonicalizeSnapshotHistory(parsed.value, {
    villageID: VILLAGE_ID,
    lineageID: LINEAGE_ID,
    appliedAtRefSeconds: 1000,
    isBaseline: true,
    sectionProofs: promoteForFixture(coverageProofsForSnapshot(parsed.value), name),
    sourceUniverse: issuePerfFixtureSourceUniverse(required!),
  });
}

/** 模拟 persist：深拷贝分离 → validate（含 integrity）→ production hydrate。 */
function reloadProduction(entry: SnapshotHistoryEntry): HydratedSnapshotHistoryEntry {
  const validated = validateSnapshotHistoryEntry(structuredClone(entry), {
    validateIntegrity: validateSnapshotHistoryEntryIntegrity,
  });
  return hydrateVerifiedCoverageOnEntry({ entry: validated, policy: 'production' });
}

function withFixtureID(
  entry: SnapshotHistoryEntry,
  fixtureID: string | null,
): SnapshotHistoryEntry {
  return {
    ...entry,
    coverage: {
      ...entry.coverage,
      sections: entry.coverage.sections.map((section) =>
        section.proof.kind === 'verified' && section.proof.adapterID === 'perf-fixture'
          ? { ...section, proof: { ...section.proof, fixtureID } }
          : section,
      ),
    },
  };
}

describe('perf fixture provenance (Issue #304 follow-up)', () => {
  it('合法 fixture reload 恢复 trust', () => {
    const reloaded = reloadProduction(issueFixtureEntry(HOME_FIXTURE_ID));
    const trusted = reloaded.coverage.sections.filter((s) =>
      sectionTrustOpensGates(s.runtimeTrust),
    );
    expect(trusted.length).toBeGreaterThan(0);
    expect(reloaded.coverage.sourceUniverseRuntimeTrust).toEqual({ kind: 'trusted' });
    const heroes = reloaded.coverage.sections.find((s) => s.rawSection === 'heroes');
    expect(heroes).toBeDefined();
    expect(sectionTrustOpensGates(heroes!.runtimeTrust)).toBe(true);
  });

  it('fixtureID 经 envelope wire round-trip 后仍然授权 trust', () => {
    const entry = issueFixtureEntry(HOME_FIXTURE_ID);
    const envelope = createSnapshotHistoryEnvelope({
      entries: [entry],
      lineages: [
        {
          villageID: entry.villageID,
          lineageID: entry.lineageID,
          normalizedPlayerTag: entry.normalizedPlayerTag,
          lastEntryID: entry.snapshotID,
          lastAppliedAtRefSeconds: entry.appliedAtRefSeconds,
          hasConflict: false,
          isActive: true,
        },
      ],
      migrationMarker: createSnapshotHistoryMigrationMarker(entry.appliedAtRefSeconds),
    });
    const decoded = decodeSnapshotHistoryEnvelopeWire(encodeSnapshotHistoryEnvelopeWire(envelope));
    const validated = validateSnapshotHistoryEnvelope(decoded);
    const first = validated.entries[0];
    expect(first).toBeDefined();
    // wire 若丢 fixtureID，此处必为 rejected：序列化本身参与授权链。
    const hydrated = hydrateVerifiedCoverageOnEntry({ entry: first!, policy: 'production' });
    expect(hydrated.coverage.sections.some((s) => sectionTrustOpensGates(s.runtimeTrust))).toBe(
      true,
    );
    expect(hydrated.coverage.sourceUniverseRuntimeTrust).toEqual({ kind: 'trusted' });
  });

  it('协同篡改（声明+proof 一起改）被拒绝', () => {
    const text = JSON.stringify({
      tag: '#ABC123',
      heroes: [{ data: 1, lvl: 1 }],
      coverage: {
        heroes: { kind: 'declared', source: 'perf-fixture', version: '1', expectedCount: 1 },
      },
    });
    const parsed = parseAccountSnapshot(text, { clock: { nowMs: () => 1000 } });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) throw new Error('synthetic 解析失败');
    const base = canonicalizeSnapshotHistory(parsed.value, {
      villageID: VILLAGE_ID,
      lineageID: LINEAGE_ID,
      appliedAtRefSeconds: 1000,
      isBaseline: true,
      sectionProofs: {},
      sourceUniverse: issuePerfFixtureSourceUniverse(new Set(['heroes'])),
    });
    const forged: SnapshotHistoryEntry = {
      ...base,
      coverage: {
        ...base.coverage,
        sections: base.coverage.sections.map((section) =>
          section.rawSection === 'heroes'
            ? {
                ...section,
                presence: 'presentNonEmpty',
                completeness: 'complete',
                observedCount: 1,
                proof: {
                  kind: 'verified',
                  source: 'perf-fixture',
                  adapterID: 'perf-fixture',
                  protocolVersion: '1',
                  expectedCount: 1,
                  verificationReason: 'bundled perf fixture',
                  verificationRuleVersion: '1',
                  // 注意：真实 fixtureID，但内容根本不是该 fixture。
                  fixtureID: HOME_FIXTURE_ID,
                } satisfies SnapshotCoverageProof,
              }
            : section,
        ),
      },
    };
    const reloaded = reloadProduction(forged);
    const heroes = reloaded.coverage.sections.find((s) => s.rawSection === 'heroes');
    expect(heroes).toBeDefined();
    expect(sectionTrustOpensGates(heroes!.runtimeTrust)).toBe(false);
    expect(heroes!.runtimeTrust).toEqual({
      kind: 'rejected',
      reason: 'perf fixture 身份与 registry 记录不一致。',
    });
    expect(reloaded.coverage.sourceUniverseRuntimeTrust.kind).not.toBe('trusted');
  });

  it('fixtureID 移植到另一份内容被拒绝', () => {
    const home = issueFixtureEntry(HOME_FIXTURE_ID);
    const parsed = parseAccountSnapshot(fixtureText(BUILDER_FIXTURE_ID), {
      clock: { nowMs: () => 1000 },
    });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) throw new Error('builder 解析失败');
    const homeProofs: Record<string, SnapshotCoverageProof> = {};
    for (const section of home.coverage.sections) {
      if (section.proof.kind === 'verified') {
        homeProofs[section.rawSection] = section.proof;
      }
    }
    const transplanted = canonicalizeSnapshotHistory(parsed.value, {
      villageID: VILLAGE_ID,
      lineageID: LINEAGE_ID,
      appliedAtRefSeconds: 1000,
      isBaseline: true,
      sectionProofs: homeProofs,
      sourceUniverse: home.coverage.sourceUniverse,
    });
    const reloaded = reloadProduction(transplanted);
    expect(reloaded.coverage.sections.some((s) => sectionTrustOpensGates(s.runtimeTrust))).toBe(
      false,
    );
    expect(reloaded.coverage.sourceUniverseRuntimeTrust.kind).not.toBe('trusted');
  });

  it('未知 fixtureID 被拒绝', () => {
    const reloaded = reloadProduction(
      withFixtureID(issueFixtureEntry(HOME_FIXTURE_ID), 'no-such-fixture'),
    );
    expect(reloaded.coverage.sections.some((s) => sectionTrustOpensGates(s.runtimeTrust))).toBe(
      false,
    );
    expect(reloaded.coverage.sourceUniverseRuntimeTrust.kind).not.toBe('trusted');
  });

  it('仅篡改声明块：该 section 被拒，其他 section 保持 trusted', () => {
    const entry = issueFixtureEntry(HOME_FIXTURE_ID);
    const top = JSON.parse(entry.rawJSON) as Record<string, unknown>;
    const coverage = { ...(top.coverage as Record<string, unknown>) };
    coverage.heroes = { ...(coverage.heroes as Record<string, unknown>), version: '2' };
    top.coverage = coverage;
    // coverage 块不进 observation：validate 必须通过，拒绝发生在声明门。
    const reloaded = reloadProduction({ ...entry, rawJSON: JSON.stringify(top) });
    const heroes = reloaded.coverage.sections.find((s) => s.rawSection === 'heroes');
    expect(heroes).toBeDefined();
    expect(sectionTrustOpensGates(heroes!.runtimeTrust)).toBe(false);
    expect(heroes!.runtimeTrust.kind).toBe('rejected');
    expect(
      reloaded.coverage.sections.some(
        (s) => s.rawSection !== 'heroes' && sectionTrustOpensGates(s.runtimeTrust),
      ),
    ).toBe(true);
  });

  it('universe 被加料：universe 被拒，section 保持 trusted', () => {
    const entry = issueFixtureEntry(HOME_FIXTURE_ID);
    const universe = entry.coverage.sourceUniverse!;
    let flipped = false;
    const tamperedUniverse = {
      ...universe,
      sections: universe.sections.map((section) => {
        if (!flipped && section.relevance === 'required') {
          flipped = true;
          return { ...section, relevance: 'notApplicable' as const };
        }
        return section;
      }),
    };
    expect(flipped).toBe(true);
    const reloaded = reloadProduction({
      ...entry,
      coverage: { ...entry.coverage, sourceUniverse: tamperedUniverse },
    });
    expect(reloaded.coverage.sourceUniverseRuntimeTrust.kind).not.toBe('trusted');
    expect(reloaded.coverage.sections.some((s) => sectionTrustOpensGates(s.runtimeTrust))).toBe(
      true,
    );
  });

  it('registry observation 身份全局唯一（禁止 authorization aliasing）', () => {
    // 若两个 fixtureID 共享同一 observation digest 但授权 section 集不同，
    // 攻击者只替换 persisted fixtureID 即可完成合法 ID substitution。
    const records = perfFixtureIdentityRecords();
    expect(records.length).toBeGreaterThan(0);
    const digests = records.map((r) => r.observationDigest);
    expect(new Set(digests).size).toBe(digests.length);
  });
});
