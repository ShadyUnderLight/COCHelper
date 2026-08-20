import CryptoKit
import Foundation

/// Issue #224: persisted verified-coverage revalidation and load-time hydration.
enum SnapshotCoverageTrustHydration {
    static func hydrate(entry: SnapshotHistoryEntry) -> SnapshotHistoryEntry {
        let hydratedCoverage = hydrate(coverage: entry.coverage, rawJSON: entry.rawJSON)
        guard hydratedCoverage != entry.coverage else { return entry }
        return SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            fingerprintVersion: entry.fingerprintVersion,
            integrityVersion: entry.integrityVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            canonicalFingerprint: entry.canonicalFingerprint,
            rawJSON: entry.rawJSON,
            observation: entry.observation,
            coverage: hydratedCoverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason,
            timerSchema: entry.timerSchema,
            integrityFingerprint: entry.integrityFingerprint
        )
    }

    static func hydrate(
        coverage: SnapshotObservationCoverage,
        rawJSON: String
    ) -> SnapshotObservationCoverage {
        var sections = coverage.sections
        var changed = false
        for index in sections.indices {
            let section = sections[index]
            let hydratedProof = SnapshotCoverageVerifier.revalidatePersistedProof(
                section.proof,
                rawJSON: rawJSON,
                section: section.rawSection
            )
            guard hydratedProof != section.proof else { continue }
            sections[index] = SnapshotSectionCoverage(
                base: section.base,
                rawSection: section.rawSection,
                presence: section.presence,
                completeness: section.completeness,
                proof: hydratedProof,
                observedCount: section.observedCount
            )
            changed = true
        }
        guard changed else { return coverage }
        return SnapshotObservationCoverage(
            schemaVersion: coverage.schemaVersion,
            fields: coverage.fields,
            sections: sections,
            diagnostics: coverage.diagnostics
        )
    }

    static func sectionInputBinding(rawJSON: String, section: String) -> String? {
        guard let topLevel = try? topLevelObject(of: rawJSON),
              let value = topLevel[section],
              JSONSerialization.isValidJSONObject(value) else {
            return nil
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func topLevelObject(of text: String) throws -> [String: Any] {
        let prepared = AccountSnapshotImporter.prepare(text).text
        guard let data = prepared.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SnapshotHistoryCanonicalizationError.invalidJSON("顶层必须是 JSON 对象。")
        }
        return object
    }
}
