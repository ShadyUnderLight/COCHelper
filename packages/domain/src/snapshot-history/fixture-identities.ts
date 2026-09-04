import { createHash } from 'node:crypto';

/**
 * Module-owned bundled perf fixture identities (Issue #304 follow-up, mirrors
 * Swift `PerfFixtureIdentityRegistry` — same table values, verified byte-identical
 * observation identity keys across both canonicalizers).
 *
 * Authorization anchor for fixture provenance: loader-issued fixture IDs map to
 * the expected business observation identity of that fixture. This is NOT the
 * deleted inputBinding SHA allowlist: digests cover canonical BUSINESS
 * observation identity (duplicate-identity canonicalizer output), looked up by
 * loader-issued fixtureID — never content-derived, never rawJSON self-declaration.
 */
const EXPECTED_OBSERVATION_DIGESTS: Readonly<Record<string, string>> = {
  perf_account_snapshot_home: '7d1e538abe86e40b7164865bbac61a91f5bd7105db2072b496debd8c4437d2a7',
  perf_account_snapshot_builder: 'ced36e220b26ed30c0250c239a3233d13c7e19a8aaf8572078b5067eb814e066',
  perf_account_snapshot_mixed: '6e9dd5c3761337f65a0d47569ac0f6179b44e0a9acec9e8d7b4edfcb7ada50ed',
  perf_account_snapshot_variant: '7b255c841ab7cbe468b3f4158fd3fce6821de8905f32e0c154f629e70ed08742',
};

/**
 * Section set the controlled loader issues per fixture. Universe expectations
 * are built from THIS table — never from reload-time rawJSON declarations.
 * A fixture section may legitimately fail per-section revalidation later
 * (e.g. a stale declared count); that rejects the section, not the universe.
 */
const FIXTURE_REQUIRED_SECTIONS: Readonly<Record<string, readonly string[]>> = {
  perf_account_snapshot_home: [
    'buildings',
    'buildings2',
    'decos',
    'decos2',
    'equipment',
    'guardians',
    'helpers',
    'heroes',
    'heroes2',
    'house_parts',
    'obstacles',
    'obstacles2',
    'pets',
    'sceneries',
    'sceneries2',
    'siege_machines',
    'skins',
    'skins2',
    'spells',
    'traps',
    'traps2',
    'units',
    'units2',
  ],
  perf_account_snapshot_builder: [
    'buildings',
    'buildings2',
    'decos',
    'decos2',
    'equipment',
    'guardians',
    'helpers',
    'heroes',
    'heroes2',
    'house_parts',
    'obstacles',
    'obstacles2',
    'pets',
    'sceneries',
    'sceneries2',
    'siege_machines',
    'skins',
    'skins2',
    'spells',
    'traps',
    'traps2',
    'units',
    'units2',
  ],
  perf_account_snapshot_mixed: [
    'buildings',
    'buildings2',
    'decos',
    'decos2',
    'equipment',
    'guardians',
    'helpers',
    'heroes',
    'heroes2',
    'house_parts',
    'obstacles',
    'obstacles2',
    'pets',
    'sceneries',
    'sceneries2',
    'siege_machines',
    'skins',
    'skins2',
    'traps',
    'traps2',
    'units',
    'units2',
  ],
  perf_account_snapshot_variant: [
    'buildings',
    'buildings2',
    'decos',
    'decos2',
    'equipment',
    'guardians',
    'helpers',
    'heroes',
    'heroes2',
    'house_parts',
    'obstacles',
    'obstacles2',
    'pets',
    'sceneries',
    'sceneries2',
    'siege_machines',
    'skins',
    'skins2',
    'spells',
    'traps',
    'traps2',
    'units',
    'units2',
  ],
};

export function observationDigestForIdentityKey(identityKey: string): string {
  return createHash('sha256').update(identityKey, 'utf8').digest('hex');
}

export function requiredSectionsForFixture(fixtureID: string): ReadonlySet<string> | undefined {
  const sections = FIXTURE_REQUIRED_SECTIONS[fixtureID];
  return sections === undefined ? undefined : new Set(sections);
}

/**
 * Test/regen accessor: every registered fixture record. Invariant tests must
 * iterate this (not a hardcoded list) so new fixtures are covered.
 */
export function perfFixtureIdentityRecords(): readonly {
  readonly fixtureID: string;
  readonly observationDigest: string;
  readonly requiredSections: ReadonlySet<string>;
}[] {
  return Object.keys(EXPECTED_OBSERVATION_DIGESTS).map((fixtureID) => ({
    fixtureID,
    observationDigest: EXPECTED_OBSERVATION_DIGESTS[fixtureID]!,
    requiredSections: requiredSectionsForFixture(fixtureID) ?? new Set<string>(),
  }));
}

/** Claimed fixtureID is registered AND the observation identity matches. */
export function recognizesPerfFixture(fixtureID: string, identityKey: string): boolean {
  const expected = EXPECTED_OBSERVATION_DIGESTS[fixtureID];
  if (expected === undefined) {
    return false;
  }
  return observationDigestForIdentityKey(identityKey) === expected;
}
