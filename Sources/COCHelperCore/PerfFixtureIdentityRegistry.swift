import CryptoKit
import Foundation

/// Module-owned bundled perf fixture identities (Issue #304 follow-up).
/// Contract: docs/electron/wire-contract-v1.md §WA-3.2.
///
/// Authorization anchor for fixture provenance: maps loader-issued fixture IDs
/// (fixture file base names, attached at the controlled `PerfFixtures` bundle
/// load path) to the expected business observation identity of that fixture.
///
/// This is NOT the deleted inputBinding SHA allowlist:
/// - Deleted allowlist: SHA-256 over prepared raw input TEXT (byte identity of
///   arbitrary persisted bytes, looked up by content hash).
/// - This registry: SHA-256 over `observationIdentityKey` (canonical BUSINESS
///   observation produced by the duplicate-identity canonicalizer — display
///   excluded, key order / whitespace insensitive). Lookup key is the
///   loader-issued fixtureID carried in persisted evidence, never content-derived.
/// Closed set (only the known bundled fixtures); unknown IDs fail closed, so it
/// cannot be repurposed as a generic fingerprint.
///
/// A persisted `rawJSON.coverage` claiming `source = perf-fixture` is a
/// declaration, not an authorization: trust additionally requires the entry
/// observation to match the registry record for the claimed fixtureID.
/// Co-tampering rawJSON declarations together with the persisted proof still
/// fails closed, because the attacker cannot mint registry records.
enum PerfFixtureIdentityRegistry {
    /// SHA-256 hex of `observationIdentityKey(entry.observation).utf8` per fixture.
    ///
    /// Derived from `Sources/COCHelperApp/PerfFixtures/*.json` (byte-identical to
    /// the test `Fixtures/` copies). Fail-closed on drift: any fixture content
    /// change breaks the positive reload tests until the table is regenerated.
    private static let expectedObservationDigests: [String: String] = [
        "perf_account_snapshot_home":
            "7d1e538abe86e40b7164865bbac61a91f5bd7105db2072b496debd8c4437d2a7",
        "perf_account_snapshot_builder":
            "ced36e220b26ed30c0250c239a3233d13c7e19a8aaf8572078b5067eb814e066",
        "perf_account_snapshot_mixed":
            "6e9dd5c3761337f65a0d47569ac0f6179b44e0a9acec9e8d7b4edfcb7ada50ed",
        "perf_account_snapshot_variant":
            "7b255c841ab7cbe468b3f4158fd3fce6821de8905f32e0c154f629e70ed08742",
    ]

    /// The section set the controlled loader issues for each fixture (the
    /// declaration-derived verified set at issue time). Universe expectations
    /// are built from THIS table — never from reload-time rawJSON declarations.
    /// A fixture section may legitimately fail per-section revalidation later
    /// (e.g. a stale declared count: home `traps` declares 22, content has 28);
    /// that rejects the section, not the universe.
    private static let fixtureRequiredSections: [String: Set<String>] = [
        "perf_account_snapshot_home": [
            "buildings", "buildings2", "decos", "decos2", "equipment",
            "guardians", "helpers", "heroes", "heroes2", "house_parts",
            "obstacles", "obstacles2", "pets", "sceneries", "sceneries2",
            "siege_machines", "skins", "skins2", "spells", "traps", "traps2",
            "units", "units2",
        ],
        "perf_account_snapshot_builder": [
            "buildings", "buildings2", "decos", "decos2", "equipment",
            "guardians", "helpers", "heroes", "heroes2", "house_parts",
            "obstacles", "obstacles2", "pets", "sceneries", "sceneries2",
            "siege_machines", "skins", "skins2", "spells", "traps", "traps2",
            "units", "units2",
        ],
        "perf_account_snapshot_mixed": [
            "buildings", "buildings2", "decos", "decos2", "equipment",
            "guardians", "helpers", "heroes", "heroes2", "house_parts",
            "obstacles", "obstacles2", "pets", "sceneries", "sceneries2",
            "siege_machines", "skins", "skins2", "traps", "traps2",
            "units", "units2",
        ],
        "perf_account_snapshot_variant": [
            "buildings", "buildings2", "decos", "decos2", "equipment",
            "guardians", "helpers", "heroes", "heroes2", "house_parts",
            "obstacles", "obstacles2", "pets", "sceneries", "sceneries2",
            "siege_machines", "skins", "skins2", "spells", "traps", "traps2",
            "units", "units2",
        ],
    ]

    /// Digest of an observation identity key, comparable against the table.
    static func observationDigest(forIdentityKey key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func requiredSections(for fixtureID: String) -> Set<String>? {
        fixtureRequiredSections[fixtureID]
    }

    /// Test/regen accessor: expected record for an ID (nil = unregistered).
    static func expectedObservationDigest(for fixtureID: String) -> String? {
        expectedObservationDigests[fixtureID]
    }

    /// Test/regen accessor: every registered fixture ID. Invariant tests must
    /// iterate this (not a hardcoded list) so new fixtures are covered.
    static var allRegisteredFixtureIDs: [String] {
        Array(expectedObservationDigests.keys)
    }

    /// Whether the claimed fixtureID is module-registered AND the observation
    /// identity matches the registry record. Unknown IDs fail closed.
    static func recognizes(fixtureID: String, identityKey: String) -> Bool {
        guard let expected = expectedObservationDigests[fixtureID] else { return false }
        return observationDigest(forIdentityKey: identityKey) == expected
    }

    /// Reverse lookup: which registered fixture (if any) has this observation
    /// identity. Used at issue time where no loader context exists (migration).
    static func fixtureID(forIdentityKey key: String) -> String? {
        let digest = observationDigest(forIdentityKey: key)
        return expectedObservationDigests.first { $0.value == digest }?.key
    }

    /// Which registered fixture (if any) the snapshot bytes are. The resolved
    /// ID authorizes the registry record (observation digest + required
    /// sections); callers must not substitute rawJSON declarations for it.
    static func fixtureID(for snapshot: AccountSnapshot) -> String? {
        guard let entry = try? SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1)
        ) else {
            return nil
        }
        let key = SnapshotHistoryCanonicalizer.observationIdentityKey(for: entry.observation)
        return fixtureID(forIdentityKey: key)
    }
}
