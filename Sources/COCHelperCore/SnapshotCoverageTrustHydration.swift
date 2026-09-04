import Foundation

/// Issue #224 / #236: persisted verified-coverage and source-universe revalidation.
enum SnapshotCoverageTrustHydration {
    static func hydrate(
        entry: SnapshotHistoryEntry,
        policy: SnapshotCoverageRevalidationPolicy
    ) -> SnapshotHistoryEntry {
        // entry 必须来自已校验 envelope：validateIntegrity 已证明
        // entry.observation 等于 rawJSON 重建值，registry 比对才有效。
        let observationKey = SnapshotHistoryCanonicalizer.observationIdentityKey(
            for: entry.observation
        )
        let hydratedCoverage = hydrate(
            coverage: entry.coverage,
            rawJSON: entry.rawJSON,
            policy: policy,
            observationKey: observationKey
        )
        guard coverageTrustChanged(from: entry.coverage, to: hydratedCoverage) else {
            return entry
        }
        return SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            rawJSON: entry.rawJSON,
            observation: entry.observation,
            coverage: hydratedCoverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason,
            timerSchema: entry.timerSchema
        )
    }

    static func hydrate(
        coverage: SnapshotObservationCoverage,
        rawJSON: String,
        policy: SnapshotCoverageRevalidationPolicy,
        observationKey: String? = nil
    ) -> SnapshotObservationCoverage {
        let snapshot = try? AccountSnapshotImporter.parse(rawJSON, now: Date(timeIntervalSince1970: 1))

        // Section 先行：universe 需要 entry 携带的 fixture 身份集合。
        var sections = coverage.sections
        var sectionsChanged = false
        var perfFixtureIDs = Set<String>()
        for index in sections.indices {
            let section = sections[index]
            guard case .verified(let evidence) = section.proof else { continue }
            if evidence.adapterID == SnapshotCoverageVerifier.perfFixtureAdapterID,
               let fixtureID = evidence.fixtureID, !fixtureID.isEmpty {
                perfFixtureIDs.insert(fixtureID)
            }
            if section.runtimeTrust == .trusted {
                continue
            }
            let trust = SnapshotCoverageProofRevalidators.revalidate(
                evidence: evidence,
                rawJSON: rawJSON,
                section: section.rawSection,
                policy: policy,
                observationKey: observationKey
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

        var universeTrust = coverage.sourceUniverseRuntimeTrust
        if let universe = coverage.sourceUniverse, universeTrust != .trusted {
            if let snapshot {
                universeTrust = SnapshotCoverageSourceUniverseRevalidators.revalidate(
                    universe: universe,
                    snapshot: snapshot,
                    coverage: coverage,
                    policy: policy,
                    perfFixtureIDs: perfFixtureIDs,
                    observationKey: observationKey
                )
            } else if universe.adapterID == SnapshotCoverageVerifier.perfFixtureAdapterID {
                // rawJSON 无法解析时 snapshot 为 nil：perf universe 不依赖
                // snapshot（registry 路径），照常重验证。
                universeTrust = SnapshotCoverageSourceUniverseRevalidators.revalidate(
                    universe: universe,
                    snapshot: nil,
                    coverage: coverage,
                    policy: policy,
                    perfFixtureIDs: perfFixtureIDs,
                    observationKey: observationKey
                )
            } else if universeTrust == .pending {
                universeTrust = .rejected("无法解析 source JSON 以重验证 source universe。")
            }
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
}
