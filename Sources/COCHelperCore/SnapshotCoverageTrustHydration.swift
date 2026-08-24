import CryptoKit
import Foundation

/// Issue #224 / #236: persisted verified-coverage and source-universe revalidation.
enum SnapshotCoverageTrustHydration {
    static func hydrate(
        entry: SnapshotHistoryEntry,
        policy: SnapshotCoverageRevalidationPolicy
    ) -> SnapshotHistoryEntry {
        let hydratedCoverage = hydrate(
            coverage: entry.coverage,
            rawJSON: entry.rawJSON,
            policy: policy
        )
        guard coverageTrustChanged(from: entry.coverage, to: hydratedCoverage) else {
            return entry
        }
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
        rawJSON: String,
        policy: SnapshotCoverageRevalidationPolicy
    ) -> SnapshotObservationCoverage {
        let snapshot = try? AccountSnapshotImporter.parse(rawJSON, now: Date(timeIntervalSince1970: 1))
        var universeTrust = coverage.sourceUniverseRuntimeTrust
        if let universe = coverage.sourceUniverse, universeTrust != .trusted {
            if let snapshot {
                universeTrust = SnapshotCoverageSourceUniverseRevalidators.revalidate(
                    universe: universe,
                    snapshot: snapshot,
                    coverage: coverage,
                    policy: policy
                )
            } else if universeTrust == .pending {
                universeTrust = .rejected("无法解析 source JSON 以重验证 source universe。")
            }
        }

        var sections = coverage.sections
        var sectionsChanged = false
        for index in sections.indices {
            let section = sections[index]
            guard case .verified(let evidence) = section.proof else { continue }
            if section.runtimeTrust == .trusted {
                continue
            }
            let trust = SnapshotCoverageProofRevalidators.revalidate(
                evidence: evidence,
                rawJSON: rawJSON,
                section: section.rawSection,
                policy: policy
            )
            guard trust != section.runtimeTrust else { continue }
            sections[index] = SnapshotSectionCoverage(
                base: section.base,
                rawSection: section.rawSection,
                presence: section.presence,
                completeness: section.completeness,
                proof: section.proof,
                observedCount: section.observedCount,
                runtimeTrust: trust
            )
            sectionsChanged = true
        }

        guard sectionsChanged || universeTrust != coverage.sourceUniverseRuntimeTrust else {
            return coverage
        }
        return SnapshotObservationCoverage(
            schemaVersion: coverage.schemaVersion,
            fields: coverage.fields,
            sections: sections,
            diagnostics: coverage.diagnostics,
            sourceUniverse: coverage.sourceUniverse,
            sourceUniverseRuntimeTrust: universeTrust
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

    private static func coverageTrustChanged(
        from: SnapshotObservationCoverage,
        to: SnapshotObservationCoverage
    ) -> Bool {
        if from.sourceUniverseRuntimeTrust != to.sourceUniverseRuntimeTrust {
            return true
        }
        guard from.sections.count == to.sections.count else { return true }
        for (lhs, rhs) in zip(from.sections, to.sections) where lhs.runtimeTrust != rhs.runtimeTrust {
            return true
        }
        return false
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
