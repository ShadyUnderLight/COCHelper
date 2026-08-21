import Foundation

/// Versioned contract for the deterministic history comparison algorithm.
///
/// The version is part of every diff so a future algorithm can coexist with
/// archived results without silently changing their meaning.
public enum SnapshotDiffAlgorithm {
    public static let version = "snapshot-diff.v1"
}

public enum SnapshotChangeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case levelIncreased
    case levelDecreased
    case quantityChanged
    case newlyObserved
    case noLongerObserved
    case upgradeStarted
    case upgradeCompleted
    case timerChanged
    case timerEndedObserved
    case unknown
}

public enum SnapshotChangeEvidence: String, Codable, Hashable, Sendable {
    case confirmed
    case aggregateInferred
    case unknown
}

public enum SnapshotDiffComparisonState: String, Codable, Hashable, Sendable {
    case comparable
    /// Issue #235: observation + coverage unchanged; only timer schema/provenance
    /// differs.  Statistics must treat this as a neutral audit interval.
    case provenanceOnly
    case insufficientCoverage
    case suppressed
}

/// Typed content outcome kept separate from comparison availability.
///
/// A provenance-only pair is comparable for timeline purposes, but must not
/// be routed through the ordinary business-change metric applicability path.
public enum SnapshotDiffContentState: String, Codable, Hashable, Sendable {
    case contentChanged
    case provenanceOnly
    case contentInsufficient
    case comparableNoChange
}

public struct SnapshotDiffSectionCoverage: Codable, Hashable, Sendable, Identifiable {
    public let base: SnapshotHistoryBase
    public let rawSection: String
    public let fromState: SnapshotCoverageState
    public let toState: SnapshotCoverageState
    public let fromDataState: SnapshotCoverageState
    public let toDataState: SnapshotCoverageState
    public let fromSectionCompleteness: SnapshotCoverageState
    public let toSectionCompleteness: SnapshotCoverageState
    public let fromProof: SnapshotCoverageProof?
    public let toProof: SnapshotCoverageProof?
    public let fromTrustTrusted: Bool
    public let toTrustTrusted: Bool
    public let fromFieldStates: [String: SnapshotCoverageState]
    public let toFieldStates: [String: SnapshotCoverageState]
    public let fromObservedItemCount: Int
    public let toObservedItemCount: Int

    public init(
        base: SnapshotHistoryBase,
        rawSection: String,
        fromState: SnapshotCoverageState,
        toState: SnapshotCoverageState,
        fromDataState: SnapshotCoverageState = .unavailable,
        toDataState: SnapshotCoverageState = .unavailable,
        fromSectionCompleteness: SnapshotCoverageState = .unavailable,
        toSectionCompleteness: SnapshotCoverageState = .unavailable,
        fromProof: SnapshotCoverageProof? = nil,
        toProof: SnapshotCoverageProof? = nil,
        fromTrustTrusted: Bool = false,
        toTrustTrusted: Bool = false,
        fromFieldStates: [String: SnapshotCoverageState] = [:],
        toFieldStates: [String: SnapshotCoverageState] = [:],
        fromObservedItemCount: Int = 0,
        toObservedItemCount: Int = 0
    ) {
        self.base = base
        self.rawSection = rawSection
        self.fromState = fromState
        self.toState = toState
        self.fromDataState = fromDataState
        self.toDataState = toDataState
        self.fromSectionCompleteness = fromSectionCompleteness
        self.toSectionCompleteness = toSectionCompleteness
        self.fromProof = fromProof
        self.toProof = toProof
        self.fromTrustTrusted = fromTrustTrusted
        self.toTrustTrusted = toTrustTrusted
        self.fromFieldStates = fromFieldStates
        self.toFieldStates = toFieldStates
        self.fromObservedItemCount = fromObservedItemCount
        self.toObservedItemCount = toObservedItemCount
    }

    public var id: String {
        [base.rawValue, rawSection].map { String($0.utf8.count) + ":" + $0 }.joined(separator: "|")
    }

    public var isComplete: Bool {
        fromState == .complete && toState == .complete &&
            fromDataState == .complete && toDataState == .complete &&
            fromSectionCompleteness == .complete &&
            toSectionCompleteness == .complete &&
            fromTrustTrusted &&
            toTrustTrusted
    }

    public func isComplete(for fields: Set<String>) -> Bool {
        guard fromSectionCompleteness == .complete,
              toSectionCompleteness == .complete,
              fromTrustTrusted,
              toTrustTrusted else {
            return false
        }
        return fields.allSatisfy {
            fieldIsComplete($0, state: fromFieldStates[$0] ?? .unavailable, observedItemCount: fromObservedItemCount) &&
                fieldIsComplete($0, state: toFieldStates[$0] ?? .unavailable, observedItemCount: toObservedItemCount)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case base
        case rawSection
        case fromState
        case toState
        case fromDataState
        case toDataState
        case fromSectionCompleteness
        case toSectionCompleteness
        case fromProof
        case toProof
        case fromFieldStates
        case toFieldStates
        case fromObservedItemCount
        case toObservedItemCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            base: try container.decode(SnapshotHistoryBase.self, forKey: .base),
            rawSection: try container.decode(String.self, forKey: .rawSection),
            fromState: try container.decode(SnapshotCoverageState.self, forKey: .fromState),
            toState: try container.decode(SnapshotCoverageState.self, forKey: .toState),
            fromDataState: try container.decodeIfPresent(SnapshotCoverageState.self, forKey: .fromDataState)
                ?? .unavailable,
            toDataState: try container.decodeIfPresent(SnapshotCoverageState.self, forKey: .toDataState)
                ?? .unavailable,
            fromSectionCompleteness: try container.decodeIfPresent(SnapshotCoverageState.self, forKey: .fromSectionCompleteness)
                ?? .unavailable,
            toSectionCompleteness: try container.decodeIfPresent(SnapshotCoverageState.self, forKey: .toSectionCompleteness)
                ?? .unavailable,
            fromProof: try container.decodeIfPresent(SnapshotCoverageProof.self, forKey: .fromProof),
            toProof: try container.decodeIfPresent(SnapshotCoverageProof.self, forKey: .toProof),
            fromFieldStates: try container.decodeIfPresent([String: SnapshotCoverageState].self, forKey: .fromFieldStates)
                ?? [:],
            toFieldStates: try container.decodeIfPresent([String: SnapshotCoverageState].self, forKey: .toFieldStates)
                ?? [:],
            fromObservedItemCount: try container.decodeIfPresent(Int.self, forKey: .fromObservedItemCount) ?? 0,
            toObservedItemCount: try container.decodeIfPresent(Int.self, forKey: .toObservedItemCount) ?? 0
        )
    }

    private func fieldIsComplete(
        _ field: String,
        state: SnapshotCoverageState,
        observedItemCount: Int
    ) -> Bool {
        if state == .complete { return true }
        return observedItemCount == 0 && state == .unavailable && field != "presence" && field != "data"
    }

    /// Issue #206: a section is explicitly out of scope for aggregate metrics
    /// when both sides carry verified proof of an empty universe.
    fileprivate var isNotApplicableForMetrics: Bool {
        guard fromSectionCompleteness == .complete,
              toSectionCompleteness == .complete,
              fromTrustTrusted,
              toTrustTrusted,
              fromObservedItemCount == 0,
              toObservedItemCount == 0,
              let fromProof,
              let toProof else {
            return false
        }
        guard SnapshotCoverageProof.expectedCount(of: fromProof) == 0,
              SnapshotCoverageProof.expectedCount(of: toProof) == 0 else {
            return false
        }
        return true
    }
}

private enum MetricSectionApplicability: Equatable {
    case complete
    case notApplicable
    case insufficient
}

/// Issue #206: aggregate-metric universe coverage for one adjacent diff.
private enum MetricUniverseState: Equatable {
    case complete
    case notApplicable
    case insufficient
  /// This diff does not observe or declare any section in the metric universe.
    case irrelevant
}

/// Issue #206: every aggregate metric must prove its full applicable universe
/// before absence-based zero is allowed.  OR-ing any single complete section is
/// not sufficient when sibling sections are silently missing.
private struct MetricApplicabilityEvaluator {
    let sectionCoverage: [SnapshotDiffSectionCoverage]

    func applicability(for section: String, fields: Set<String>) -> MetricSectionApplicability {
        guard let coverage = sectionCoverage.first(where: { $0.rawSection == section }) else {
            return .insufficient
        }
        if coverage.isNotApplicableForMetrics {
            return .notApplicable
        }
        if coverage.isComplete(for: fields) {
            return .complete
        }
        return .insufficient
    }

    func universeState(sections: Set<String>, fields: Set<String>) -> MetricUniverseState {
        guard !sections.isEmpty else { return .insufficient }
        var sawComplete = false
        for section in sections.sorted() {
            switch applicability(for: section, fields: fields) {
            case .complete:
                sawComplete = true
            case .notApplicable:
                break
            case .insufficient:
                return .insufficient
            }
        }
        return sawComplete ? .complete : .notApplicable
    }

    /// Provenance-only pairs have no business observation delta.  They may
    /// establish a zero for a section that is actually observed and complete,
    /// while absent sibling sections remain outside this pair's evidence
    /// rather than poisoning that no-op metric.  Real content changes still
    /// use `universeState` above and therefore keep #206 fail-closed behavior.
    func provenanceOnlyState(sections: Set<String>, fields: Set<String>) -> MetricUniverseState {
        guard !sections.isEmpty else { return .insufficient }
        var sawRelevant = false
        var sawComplete = false
        for section in sections.sorted() {
            guard let coverage = sectionCoverage.first(where: { $0.rawSection == section }),
                  isSectionRelevant(coverage) else {
                continue
            }
            sawRelevant = true
            switch applicability(for: section, fields: fields) {
            case .complete:
                sawComplete = true
            case .notApplicable:
                break
            case .insufficient:
                return .insufficient
            }
        }
        if sawComplete { return .complete }
        return sawRelevant ? .notApplicable : .irrelevant
    }

    func universeSatisfied(sections: Set<String>, fields: Set<String>) -> Bool {
        universeState(sections: sections, fields: fields) == .complete
    }

    func isUniverseRelevant(sections: Set<String>, in diff: SnapshotDiff) -> Bool {
        for section in sections {
            guard let coverage = sectionCoverage.first(where: { $0.rawSection == section }) else {
                continue
            }
            if isSectionRelevant(coverage) {
                return true
            }
        }
        let normalizedSections = Set(sections.map {
            $0.hasSuffix("2") ? String($0.dropLast()) : $0
        })
        for change in diff.changes {
            let section = change.identity.rawSection.hasSuffix("2")
                ? String(change.identity.rawSection.dropLast())
                : change.identity.rawSection
            if normalizedSections.contains(section) {
                return true
            }
        }
        return false
    }

    /// Issue #235: provenance-only may certify a definite zero without requiring
    /// every sibling section in the metric universe, but only when every
    /// observed/relevant section is complete+trusted.  Missing/unavailable
    /// siblings are ignored; partial/untrusted relevant sections fail closed.
    func neutralMetricEligibility(
        sections: Set<String>,
        fields: Set<String>,
        in diff: SnapshotDiff
    ) -> MetricUniverseState {
        guard isUniverseRelevant(sections: sections, in: diff) else { return .irrelevant }
        var sawComplete = false
        for section in sections.sorted() {
            guard let coverage = sectionCoverage.first(where: { $0.rawSection == section }) else {
                continue
            }
            if coverage.isNotApplicableForMetrics {
                continue
            }
            guard isSectionRelevant(coverage) else {
                continue
            }
            if coverage.isComplete(for: fields) {
                sawComplete = true
            } else {
                return .insufficient
            }
        }
        return sawComplete ? .complete : .notApplicable
    }

    private func isSectionRelevant(_ coverage: SnapshotDiffSectionCoverage) -> Bool {
        if coverage.fromObservedItemCount > 0 || coverage.toObservedItemCount > 0 {
            return true
        }
        if coverage.fromState != .unavailable || coverage.toState != .unavailable {
            return true
        }
        if coverage.fromSectionCompleteness != .unavailable ||
            coverage.toSectionCompleteness != .unavailable {
            return true
        }
        return false
    }
}

private struct DiffMetricApplicability {
    let building: MetricUniverseState
    let wall: MetricUniverseState
    let hero: MetricUniverseState
    let troop: MetricUniverseState
    let spell: MetricUniverseState
    let pet: MetricUniverseState
    let equipment: MetricUniverseState
    let hasSectionCoverage: Bool
    let hasChanges: Bool

    init(diff: SnapshotDiff) {
        let evaluator = MetricApplicabilityEvaluator(sectionCoverage: diff.sectionCoverage)
        let levelFields: Set<String> = ["presence", "data", "lvl"]
        let histogramFields: Set<String> = ["presence", "data", "lvl", "cnt"]
        let buildingSections: Set<String> = ["buildings", "buildings2", "traps", "traps2"]
        let wallSections: Set<String> = ["buildings", "buildings2"]
        let heroSections: Set<String> = ["heroes", "heroes2"]
        let troopSections: Set<String> = ["units", "units2"]
        func state(sections: Set<String>, fields: Set<String>) -> MetricUniverseState {
            if diff.contentState == .provenanceOnly {
                return evaluator.provenanceOnlyState(sections: sections, fields: fields)
            }
            return evaluator.isUniverseRelevant(sections: sections, in: diff)
                ? evaluator.universeState(sections: sections, fields: fields)
                : .irrelevant
        }
        building = state(sections: buildingSections, fields: histogramFields)
        wall = state(sections: wallSections, fields: histogramFields)
        hero = state(sections: heroSections, fields: levelFields)
        troop = state(sections: troopSections, fields: levelFields)
        spell = state(sections: ["spells"], fields: levelFields)
        pet = state(sections: ["pets"], fields: levelFields)
        equipment = state(sections: ["equipment"], fields: levelFields)
        hasSectionCoverage = !diff.sectionCoverage.isEmpty
        hasChanges = !diff.changes.isEmpty
    }
}

/// Field-level provenance for one change.  Raw coverage is retained so an
/// unavailable timer field cannot be mistaken for a confirmed disappearance.
public struct SnapshotDiffFieldCoverage: Codable, Hashable, Sendable, Identifiable {
    public let base: SnapshotHistoryBase
    public let rawSection: String
    public let field: String
    public let fromState: SnapshotCoverageState
    public let toState: SnapshotCoverageState

    public init(
        base: SnapshotHistoryBase,
        rawSection: String,
        field: String,
        fromState: SnapshotCoverageState,
        toState: SnapshotCoverageState
    ) {
        self.base = base
        self.rawSection = rawSection
        self.field = field
        self.fromState = fromState
        self.toState = toState
    }

    public var id: String {
        [base.rawValue, rawSection, field]
            .map { String($0.utf8.count) + ":" + $0 }
            .joined(separator: "|")
    }

}

public struct SnapshotDiffCoverage: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case complete
        case partial
        case insufficient
    }

    public let state: State
    public let fields: [SnapshotDiffFieldCoverage]
    public let reasons: [String]

    public init(
        state: State? = nil,
        fields: [SnapshotDiffFieldCoverage] = [],
        reasons: [String] = []
    ) {
        self.fields = Self.normalizedFields(fields)
        self.reasons = Array(Set(reasons)).sorted()
        self.state = state ?? Self.derivedState(from: self.fields)
    }

    fileprivate func addingReason(_ reason: String, degradingTo minimum: State = .partial) -> SnapshotDiffCoverage {
        let nextState: State
        switch (state, minimum) {
        case (.insufficient, _): nextState = .insufficient
        case (.partial, .insufficient): nextState = .insufficient
        case (.partial, _): nextState = .partial
        case (.complete, .insufficient): nextState = .insufficient
        case (.complete, .partial): nextState = .partial
        case (.complete, .complete): nextState = .complete
        }
        return SnapshotDiffCoverage(
            state: nextState,
            fields: fields,
            reasons: reasons + [reason]
        )
    }

    private static func derivedState(from fields: [SnapshotDiffFieldCoverage]) -> State {
        if fields.contains(where: {
            $0.fromState == .unavailable || $0.toState == .unavailable
        }) {
            return .insufficient
        }
        if fields.contains(where: {
            $0.fromState == .partial || $0.toState == .partial
        }) {
            return .partial
        }
        return .complete
    }

    private static func normalizedFields(_ fields: [SnapshotDiffFieldCoverage]) -> [SnapshotDiffFieldCoverage] {
        var merged: [String: SnapshotDiffFieldCoverage] = [:]
        for field in fields {
            guard let previous = merged[field.id] else {
                merged[field.id] = field
                continue
            }
            merged[field.id] = SnapshotDiffFieldCoverage(
                base: field.base,
                rawSection: field.rawSection,
                field: field.field,
                fromState: worse(previous.fromState, field.fromState),
                toState: worse(previous.toState, field.toState)
            )
        }
        return merged.values.sorted { $0.id < $1.id }
    }

    private static func worse(
        _ lhs: SnapshotCoverageState,
        _ rhs: SnapshotCoverageState
    ) -> SnapshotCoverageState {
        if lhs == .unavailable || rhs == .unavailable { return .unavailable }
        if lhs == .partial || rhs == .partial { return .partial }
        return .complete
    }
}

public enum SnapshotDiffDiagnosticKind: String, Codable, Hashable, Sendable {
    case baseline
    case villageMismatch
    case lineageMismatch
    case duplicateSnapshotID
    case insufficientCoverage
    case unknownIdentity
    case malformedObservation
    case mixedLineageInput
    /// 观察内容未变，仅 timer schema/provenance 不可比较。
    case incomparableTimerSchema
}

public struct SnapshotDiffDiagnostic: Codable, Hashable, Sendable, Identifiable {
    public let kind: SnapshotDiffDiagnosticKind
    public let message: String
    public let identity: SnapshotItemIdentity?
    public let rawSection: String?
    public let field: String?

    public init(
        kind: SnapshotDiffDiagnosticKind,
        message: String,
        identity: SnapshotItemIdentity? = nil,
        rawSection: String? = nil,
        field: String? = nil
    ) {
        self.kind = kind
        self.message = message
        self.identity = identity
        self.rawSection = rawSection
        self.field = field
    }

    public var id: String {
        [kind.rawValue, identity?.key ?? "", rawSection ?? "", field ?? "", message]
            .map { String($0.utf8.count) + ":" + $0 }
            .joined(separator: "|")
    }
}

public struct SnapshotChange: Codable, Hashable, Sendable, Identifiable {
    public let identity: SnapshotItemIdentity
    public let displayName: String
    public let category: String?
    public let displayCategory: String?
    public let base: SnapshotHistoryBase
    public let oldLevel: Int?
    public let newLevel: Int?
    public let oldQuantity: Int?
    public let newQuantity: Int?
    public let movedQuantity: Int?
    public let levelDelta: Int?
    public let changeKind: SnapshotChangeKind
    /// Additional observations attached to the same identity.  For example,
    /// a level increase with a raw timer change is one change record with
    /// `levelIncreased` plus `timerChanged`, not two completion events.
    public let relatedChangeKinds: [SnapshotChangeKind]
    public let evidence: SnapshotChangeEvidence
    public let coverage: SnapshotDiffCoverage

    public init(
        identity: SnapshotItemIdentity,
        displayName: String,
        category: String? = nil,
        displayCategory: String? = nil,
        base: SnapshotHistoryBase? = nil,
        oldLevel: Int? = nil,
        newLevel: Int? = nil,
        oldQuantity: Int? = nil,
        newQuantity: Int? = nil,
        movedQuantity: Int? = nil,
        levelDelta: Int? = nil,
        changeKind: SnapshotChangeKind,
        relatedChangeKinds: [SnapshotChangeKind] = [],
        evidence: SnapshotChangeEvidence,
        coverage: SnapshotDiffCoverage
    ) {
        self.identity = identity
        self.displayName = displayName
        self.category = category
        self.displayCategory = displayCategory
        self.base = base ?? identity.base
        self.oldLevel = oldLevel
        self.newLevel = newLevel
        self.oldQuantity = oldQuantity
        self.newQuantity = newQuantity
        self.movedQuantity = movedQuantity
        self.levelDelta = levelDelta
        self.changeKind = changeKind
        self.relatedChangeKinds = Array(Set(relatedChangeKinds)).sorted { $0.rawValue < $1.rawValue }
        self.evidence = evidence
        self.coverage = coverage
    }

    public var id: String {
        [
            identity.key,
            changeKind.rawValue,
            String(oldLevel ?? Int.min),
            String(newLevel ?? Int.min),
            String(movedQuantity ?? Int.min)
        ].joined(separator: "|")
    }
}

public struct SnapshotDiff: Codable, Hashable, Sendable {
    public let fromSnapshotID: UUID
    public let toSnapshotID: UUID
    public let villageID: UUID
    public let lineageID: UUID
    public let fromAppliedAt: Date
    public let toAppliedAt: Date
    public let algorithmVersion: String
    public let comparisonState: SnapshotDiffComparisonState
    public let contentState: SnapshotDiffContentState
    public let sectionCoverage: [SnapshotDiffSectionCoverage]
    public let changes: [SnapshotChange]
    public let diagnostics: [SnapshotDiffDiagnostic]

    public init(
        fromSnapshotID: UUID,
        toSnapshotID: UUID,
        villageID: UUID,
        lineageID: UUID,
        fromAppliedAt: Date = .distantPast,
        toAppliedAt: Date = .distantPast,
        algorithmVersion: String = SnapshotDiffAlgorithm.version,
        comparisonState: SnapshotDiffComparisonState = .comparable,
        contentState: SnapshotDiffContentState = .contentChanged,
        sectionCoverage: [SnapshotDiffSectionCoverage] = [],
        changes: [SnapshotChange] = [],
        diagnostics: [SnapshotDiffDiagnostic] = []
    ) {
        self.fromSnapshotID = fromSnapshotID
        self.toSnapshotID = toSnapshotID
        self.villageID = villageID
        self.lineageID = lineageID
        self.fromAppliedAt = fromAppliedAt
        self.toAppliedAt = toAppliedAt
        self.algorithmVersion = algorithmVersion
        self.comparisonState = comparisonState
        self.contentState = contentState
        self.sectionCoverage = sectionCoverage.sorted { $0.id < $1.id }
        self.changes = changes.sorted(by: SnapshotDiffOrdering.change)
        self.diagnostics = diagnostics.sorted { $0.id < $1.id }
    }
}

/// Compares immutable canonical observations only.  No current catalog,
/// current time, live countdown, or array position is consulted here.
public enum SnapshotDiffEngine {
    public static func diff(
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry
    ) -> SnapshotDiff {
        compare(from: from, to: to)
    }

    public static func compare(
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry
    ) -> SnapshotDiff {
        var diagnostics: [SnapshotDiffDiagnostic] = []
        let sectionCoverage = makeSectionCoverage(from: from, to: to)
        diagnostics.append(contentsOf: from.coverage.diagnostics.sorted().map {
            SnapshotDiffDiagnostic(
                kind: .malformedObservation,
                message: "from snapshot: " + $0,
                rawSection: diagnosticSection(from: $0)
            )
        })
        diagnostics.append(contentsOf: to.coverage.diagnostics.sorted().map {
            SnapshotDiffDiagnostic(
                kind: .malformedObservation,
                message: "to snapshot: " + $0,
                rawSection: diagnosticSection(from: $0)
            )
        })

        guard from.villageID == to.villageID else {
            diagnostics.append(SnapshotDiffDiagnostic(
                kind: .villageMismatch,
                message: "不同 villageID 的历史记录禁止比较。"
            ))
            return SnapshotDiff(
                fromSnapshotID: from.snapshotID,
                toSnapshotID: to.snapshotID,
                villageID: to.villageID,
                lineageID: to.lineageID,
                fromAppliedAt: from.appliedAt,
                toAppliedAt: to.appliedAt,
                comparisonState: .suppressed,
                contentState: .contentInsufficient,
                sectionCoverage: sectionCoverage,
                diagnostics: diagnostics
            )
        }

        guard from.lineageID == to.lineageID else {
            diagnostics.append(SnapshotDiffDiagnostic(
                kind: .lineageMismatch,
                message: "不同 lineageID 的历史记录禁止比较。"
            ))
            return SnapshotDiff(
                fromSnapshotID: from.snapshotID,
                toSnapshotID: to.snapshotID,
                villageID: to.villageID,
                lineageID: to.lineageID,
                fromAppliedAt: from.appliedAt,
                toAppliedAt: to.appliedAt,
                comparisonState: .suppressed,
                contentState: .contentInsufficient,
                sectionCoverage: sectionCoverage,
                diagnostics: diagnostics
            )
        }

        guard !to.isBaseline else {
            diagnostics.append(SnapshotDiffDiagnostic(
                kind: .baseline,
                message: "baseline 没有 predecessor，禁止把它解释为历史变化。"
            ))
            return SnapshotDiff(
                fromSnapshotID: from.snapshotID,
                toSnapshotID: to.snapshotID,
                villageID: to.villageID,
                lineageID: to.lineageID,
                fromAppliedAt: from.appliedAt,
                toAppliedAt: to.appliedAt,
                comparisonState: .suppressed,
                contentState: .contentInsufficient,
                sectionCoverage: sectionCoverage,
                diagnostics: diagnostics
            )
        }

        guard from.snapshotID != to.snapshotID else {
            diagnostics.append(SnapshotDiffDiagnostic(
                kind: .duplicateSnapshotID,
                message: "相同 snapshotID 不能形成历史变化。"
            ))
            return SnapshotDiff(
                fromSnapshotID: from.snapshotID,
                toSnapshotID: to.snapshotID,
                villageID: to.villageID,
                lineageID: to.lineageID,
                fromAppliedAt: from.appliedAt,
                toAppliedAt: to.appliedAt,
                comparisonState: .suppressed,
                contentState: .contentInsufficient,
                sectionCoverage: sectionCoverage,
                diagnostics: diagnostics
            )
        }

        if isProvenanceOnlyPair(from: from, to: to) {
            if !timerSpecsAreConsistent(from: from, to: to, fields: provenanceTimerFields(from: from, to: to)) {
                diagnostics.append(SnapshotDiffDiagnostic(
                    kind: .incomparableTimerSchema,
                    message: "观察内容未变，但两侧 timer 契约不一致，不能确认 timer 变化。"
                ))
            }
            diagnostics.append(contentsOf: blockingObservationDiagnostics(in: from))
            return SnapshotDiff(
                fromSnapshotID: from.snapshotID,
                toSnapshotID: to.snapshotID,
                villageID: from.villageID,
                lineageID: from.lineageID,
                fromAppliedAt: from.appliedAt,
                toAppliedAt: to.appliedAt,
                comparisonState: .provenanceOnly,
                sectionCoverage: sectionCoverage,
                changes: [],
                diagnostics: diagnostics
            )
        }

        let hasComparableSection = sectionCoverage.contains { $0.isComplete }
        guard hasComparableSection || !from.observation.items.isEmpty || !to.observation.items.isEmpty else {
            diagnostics.append(SnapshotDiffDiagnostic(
                kind: .insufficientCoverage,
                message: "两个历史记录都没有可比较的完整 section coverage。"
            ))
            return SnapshotDiff(
                fromSnapshotID: from.snapshotID,
                toSnapshotID: to.snapshotID,
                villageID: from.villageID,
                lineageID: from.lineageID,
                fromAppliedAt: from.appliedAt,
                toAppliedAt: to.appliedAt,
                comparisonState: .insufficientCoverage,
                contentState: .contentInsufficient,
                sectionCoverage: sectionCoverage,
                diagnostics: diagnostics
            )
        }

        var changes: [SnapshotChange] = []
        let oldGroups = Dictionary(grouping: from.observation.items, by: { $0.identity.key })
        let newGroups = Dictionary(grouping: to.observation.items, by: { $0.identity.key })
        let keys = Set(oldGroups.keys).union(newGroups.keys).sorted()

        for key in keys {
            let oldItems = oldGroups[key] ?? []
            let newItems = newGroups[key] ?? []
            let representative = (newItems.first ?? oldItems.first)

            guard let representative else { continue }
            guard isUsableIdentity(representative.identity) else {
                let coverage = coverageFor(
                    identity: representative.identity,
                    from: from,
                    to: to,
                    fields: ["data"]
                ).addingReason("identity 无法确认，保留为 unknown。", degradingTo: .insufficient)
                changes.append(unknownChange(
                    identity: representative.identity,
                    old: oldItems.first,
                    new: newItems.first,
                    coverage: coverage,
                    reason: "identity 无法确认，不能安全 join。"
                ))
                diagnostics.append(SnapshotDiffDiagnostic(
                    kind: .unknownIdentity,
                    message: "发现无法确认的历史 identity。",
                    identity: representative.identity,
                    rawSection: representative.identity.rawSection
                ))
                continue
            }

            if isHistogramIdentity(representative.identity) {
                compareHistogram(
                    oldItems: oldItems,
                    newItems: newItems,
                    from: from,
                    to: to,
                    changes: &changes,
                    diagnostics: &diagnostics
                )
            } else if oldItems.count > 1 || newItems.count > 1 {
                let coverage = coverageFor(
                    identity: representative.identity,
                    from: from,
                    to: to,
                    fields: ["data", "lvl", "cnt"]
                ).addingReason("唯一 identity 在同一快照中出现多次，不能按实例猜测。", degradingTo: .insufficient)
                changes.append(unknownChange(
                    identity: representative.identity,
                    old: oldItems.first,
                    new: newItems.first,
                    coverage: coverage,
                    reason: "唯一 identity 出现重复记录。"
                ))
                diagnostics.append(SnapshotDiffDiagnostic(
                    kind: .malformedObservation,
                    message: "唯一 identity 出现重复记录，已保留为 unknown。",
                    identity: representative.identity,
                    rawSection: representative.identity.rawSection
                ))
            } else {
                compareUnique(
                    old: oldItems.first,
                    new: newItems.first,
                    from: from,
                    to: to,
                    changes: &changes,
                    diagnostics: &diagnostics
                )
            }
        }

        let hasInsufficientDiagnostic = diagnostics.contains {
            $0.kind == .insufficientCoverage || $0.kind == .unknownIdentity || $0.kind == .malformedObservation
        }
        let hasKnownChange = changes.contains {
            $0.evidence != .unknown && $0.coverage.state != .insufficient
        }
        let state: SnapshotDiffComparisonState = !hasKnownChange && hasInsufficientDiagnostic
            ? .insufficientCoverage
            : .comparable
        let contentState: SnapshotDiffContentState
        if state == .insufficientCoverage {
            contentState = .contentInsufficient
        } else if !changes.isEmpty {
            contentState = .contentChanged
        } else {
            contentState = .comparableNoChange
        }

        return SnapshotDiff(
            fromSnapshotID: from.snapshotID,
            toSnapshotID: to.snapshotID,
            villageID: from.villageID,
            lineageID: from.lineageID,
            fromAppliedAt: from.appliedAt,
            toAppliedAt: to.appliedAt,
            comparisonState: state,
            contentState: contentState,
            sectionCoverage: sectionCoverage,
            changes: changes,
            diagnostics: diagnostics
        )
    }

    /// Forms diffs only between adjacent submitted entries within each
    /// village/lineage.  A baseline is allowed to be the left side of the
    /// first real pair; it is not compared with a predecessor and therefore
    /// cannot manufacture a full-history "newly observed" diff by itself.
    public static func adjacentDiffs(
        in entries: [SnapshotHistoryEntry],
        villageID: UUID? = nil,
        lineageID: UUID? = nil
    ) -> [SnapshotDiff] {
        guard entries.count >= 2 else { return [] }
        var diffs: [SnapshotDiff] = []
        for index in 1..<entries.count {
            let previous = entries[index - 1]
            let current = entries[index]
            guard previous.villageID == current.villageID,
                  previous.lineageID == current.lineageID else {
                continue
            }
            if let villageID,
               (previous.villageID != villageID || current.villageID != villageID) {
                continue
            }
            if let lineageID,
               (previous.lineageID != lineageID || current.lineageID != lineageID) {
                continue
            }
            diffs.append(compare(from: previous, to: current))
        }
        return diffs
    }

    public static func adjacentDiffs(
        in envelope: SnapshotHistoryEnvelope,
        villageID: UUID? = nil,
        lineageID: UUID? = nil
    ) -> [SnapshotDiff] {
        adjacentDiffs(in: envelope.entries, villageID: villageID, lineageID: lineageID)
    }

    private static func compareUnique(
        old: SnapshotObservationItem?,
        new: SnapshotObservationItem?,
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry,
        changes: inout [SnapshotChange],
        diagnostics: inout [SnapshotDiffDiagnostic]
    ) {
        guard let identity = new?.identity ?? old?.identity else { return }

        if let old, let new {
            compareExistingUnique(
                old: old,
                new: new,
                from: from,
                to: to,
                changes: &changes,
                diagnostics: &diagnostics
            )
            return
        }

        let observedOnNew = new != nil
        let observed = new ?? old
        let presenceSide = observedOnNew ? from : to
        let observedSide = observedOnNew ? to : from
        let presenceCoverage = coverageFor(
            identity: identity,
            from: from,
            to: to,
            fields: ["presence", "data"]
        )
        var observedFields = ["data"]
        if requiresLevel(identity) { observedFields.append("lvl") }
        if observed?.count != nil { observedFields.append("cnt") }
        let observedEntry = observedOnNew ? to : from
        let observedCoverage = coverageFor(
            identity: identity,
            from: observedEntry,
            to: observedEntry,
            fields: observedFields
        )
        let coverage = mergeCoverage(presenceCoverage, observedCoverage)
        let universeComplete = sectionPresenceAndDataAreComplete(
            entry: presenceSide,
            identity: identity
        )
        let universeProofComplete = sectionCoverageIsComplete(
            entry: presenceSide,
            identity: identity
        ) && nestedEnumerationIsConfirmed(identity: identity)
        let itemComplete = observedItemFieldsAreComplete(
            entry: observedSide,
            item: observed,
            fields: observedFields
        )
        let kind: SnapshotChangeKind = observedOnNew ? .newlyObserved : .noLongerObserved

        if universeComplete && universeProofComplete && itemComplete && coverage.state == .complete {
            changes.append(makeChange(
                identity: identity,
                old: old,
                new: new,
                oldLevel: old?.level,
                newLevel: new?.level,
                oldQuantity: validQuantity(old?.count),
                newQuantity: validQuantity(new?.count),
                movedQuantity: nil,
                levelDelta: nil,
                changeKind: kind,
                related: [],
                evidence: .confirmed,
                coverage: coverage
            ))
        } else {
            let reason = universeComplete && universeProofComplete
                ? "项目自身字段 coverage 不足，不能确认观察变化。"
                : "对应 section/presence coverage 不完整，不能确认新增或消失。"
            let unknownCoverage = coverage.addingReason(
                reason,
                degradingTo: universeComplete && universeProofComplete ? .partial : .insufficient
            )
            changes.append(unknownChange(
                identity: identity,
                old: old,
                new: new,
                coverage: unknownCoverage,
                reason: reason
            ))
            diagnostics.append(SnapshotDiffDiagnostic(
                kind: .insufficientCoverage,
                message: reason,
                identity: identity,
                rawSection: identity.rawSection
            ))
        }
    }

    private static func compareExistingUnique(
        old: SnapshotObservationItem,
        new: SnapshotObservationItem,
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry,
        changes: inout [SnapshotChange],
        diagnostics: inout [SnapshotDiffDiagnostic]
    ) {
        var related: [SnapshotChangeKind] = []
        var semanticKinds: [SnapshotChangeKind] = []
        var reasons: [String] = []
        var requiredFields = ["data"]

        let oldLevel = validLevel(old.level)
        let newLevel = validLevel(new.level)
        let levelIsRequired = requiresLevel(old.identity)
        let levelWasReported = old.level != nil || new.level != nil
        let levelProblem = levelIsRequired && (oldLevel == nil || newLevel == nil)
        var levelKind: SnapshotChangeKind?
        var levelDelta: Int?
        if let oldLevel, let newLevel {
            if oldLevel != newLevel {
                levelDelta = newLevel - oldLevel
                levelKind = newLevel > oldLevel ? .levelIncreased : .levelDecreased
                semanticKinds.append(levelKind!)
                requiredFields.append("lvl")
            }
        } else if levelProblem {
            reasons.append("level 缺失或非法")
            requiredFields.append("lvl")
        } else if levelIsRequired || levelWasReported {
            requiredFields.append("lvl")
        }

        let oldCount = validQuantity(old.count)
        let newCount = validQuantity(new.count)
        var quantityProblem = false
        if old.count != nil || new.count != nil {
            requiredFields.append("cnt")
            if let oldCount, let newCount {
                if oldCount != newCount {
                    semanticKinds.append(.quantityChanged)
                }
            } else {
                quantityProblem = true
                reasons.append("count 缺失或非法")
            }
        }

        let timer = timerTransition(old: old, new: new, from: from, to: to)
        if timer.kind != nil || timer.isUnknown {
            requiredFields.append(contentsOf: timer.requiredFields)
        }
        if let kind = timer.kind {
            semanticKinds.append(kind)
        }
        if timer.isUnknown {
            reasons.append(timer.reason)
        }

        guard !semanticKinds.isEmpty || !reasons.isEmpty else { return }

        let coverage = coverageFor(
            identity: old.identity,
            from: from,
            to: to,
            fields: Array(Set(requiredFields)).sorted()
        )
        let semanticUnknown = levelProblem || quantityProblem || timer.isUnknown || coverage.state != .complete
        if semanticUnknown {
            let reason = reasons.isEmpty
                ? "变化所需字段 coverage 不足。"
                : reasons.sorted().joined(separator: "；") + "。"
            let unknownCoverage = coverage.addingReason(reason, degradingTo: .partial)
            let knownKinds = semanticKinds
            changes.append(unknownChange(
                identity: old.identity,
                old: old,
                new: new,
                coverage: unknownCoverage,
                reason: reason,
                related: knownKinds
            ))
            diagnostics.append(SnapshotDiffDiagnostic(
                kind: .insufficientCoverage,
                message: reason,
                identity: old.identity,
                rawSection: old.identity.rawSection
            ))
            return
        }

        let quantityChanged = oldCount != nil && newCount != nil && oldCount != newCount
        let primary = primaryKind(
            levelKind: levelKind,
            levelDelta: levelDelta,
            timerKind: timer.kind,
            quantityChanged: quantityChanged
        )
        guard let primary else { return }
        semanticKinds.append(contentsOf: levelKind == nil ? [] : [levelKind!])
        let uniqueKinds = Array(Set(semanticKinds)).filter { $0 != primary }
        related.append(contentsOf: uniqueKinds)
        let oldLevelValue = oldLevel
        let newLevelValue = newLevel
        let delta = oldLevelValue.flatMap { oldValue in
            newLevelValue.map { $0 - oldValue }
        }
        changes.append(makeChange(
            identity: old.identity,
            old: old,
            new: new,
            oldLevel: oldLevelValue,
            newLevel: newLevelValue,
            oldQuantity: quantityChanged ? oldCount : nil,
            newQuantity: quantityChanged ? newCount : nil,
            movedQuantity: nil,
            levelDelta: delta,
            changeKind: primary,
            related: related,
            evidence: .confirmed,
            coverage: coverage
        ))
    }

    private static func compareHistogram(
        oldItems: [SnapshotObservationItem],
        newItems: [SnapshotObservationItem],
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry,
        changes: inout [SnapshotChange],
        diagnostics: inout [SnapshotDiffDiagnostic]
    ) {
        let representative = newItems.first ?? oldItems.first
        guard let identity = representative?.identity else { return }
        let coverage = coverageFor(
            identity: identity,
            from: from,
            to: to,
            fields: ["presence", "data", "lvl", "cnt"]
        )

        if oldItems.isEmpty || newItems.isEmpty {
            let observedOnNew = !newItems.isEmpty
            let presenceSide = observedOnNew ? from : to
            let observedSide = observedOnNew ? to : from
            let oldHistogram = histogram(oldItems)
            let newHistogram = histogram(newItems)
            let observedHistogram = observedOnNew ? newHistogram : oldHistogram
            let universeComplete = sectionPresenceAndDataAreComplete(entry: presenceSide, identity: identity)
            let observedComplete = observedOnNew
                ? histogramIsComplete(
                    entry: observedSide,
                    identity: identity,
                    items: newItems
                )
                : sectionPresenceAndDataAreComplete(entry: observedSide, identity: identity)
            let observedProofComplete = sectionCoverageIsComplete(
                entry: observedSide,
                identity: identity
            )
            let presenceProofComplete = sectionCoverageIsComplete(
                entry: presenceSide,
                identity: identity
            )
            let changeCoverage = mergeCoverage(
                coverageFor(
                    identity: identity,
                    from: presenceSide,
                    to: presenceSide,
                    fields: ["presence", "data"]
                ),
                observedOnNew
                    ? coverageFor(
                        identity: identity,
                        from: observedSide,
                        to: observedSide,
                        fields: ["data", "lvl", "cnt"]
                    )
                    : coverageFor(
                        identity: identity,
                        from: observedSide,
                        to: observedSide,
                        fields: ["presence", "data"]
                    )
            )
            if universeComplete && presenceProofComplete && observedProofComplete && observedComplete,
               let observedHistogram {
                let total = observedHistogram.total
                changes.append(makeChange(
                    identity: identity,
                    old: oldItems.first,
                    new: newItems.first,
                    oldLevel: nil,
                    newLevel: nil,
                    oldQuantity: observedOnNew ? nil : total,
                    newQuantity: observedOnNew ? total : nil,
                    movedQuantity: nil,
                    levelDelta: nil,
                    changeKind: observedOnNew ? .newlyObserved : .noLongerObserved,
                    related: [],
                    evidence: .confirmed,
                    coverage: changeCoverage
                ))
                return
            }
        }

        guard let oldHistogram = histogram(oldItems), let newHistogram = histogram(newItems) else {
            let timerResult = aggregateTimerTransition(
                oldItems: oldItems,
                newItems: newItems,
                from: from,
                to: to,
                hasCredibleLevelUp: false,
                sectionProofComplete: sectionCoverageIsComplete(entry: from, identity: identity)
                    && sectionCoverageIsComplete(entry: to, identity: identity)
            )
            if timerResult.kind != nil || timerResult.isUnknown {
                appendAggregateTimerChange(
                    timerResult,
                    identity: identity,
                    oldItems: oldItems,
                    newItems: newItems,
                    from: from,
                    to: to,
                    changes: &changes,
                    diagnostics: &diagnostics
                )
                // Issue #176：timer 事件独立保留，但 histogram 的 level/count
                // 因缺 cnt 无法构造时，等级/数量指标必须显式标记数据不足，
                // 不得被 timer 事件"带成"可用 0。isUnknown 时
                // appendAggregateTimerChange 已附加 diagnostic，不重复输出。
                if timerResult.kind != nil {
                    let reason = "重复建筑/城墙 histogram 的 level/count 无效或总量溢出；等级/数量指标数据不足。"
                    diagnostics.append(SnapshotDiffDiagnostic(
                        kind: .insufficientCoverage,
                        message: reason,
                        identity: identity,
                        rawSection: identity.rawSection
                    ))
                }
                return
            }
            let reason = "重复建筑/城墙 histogram 的 level/count 无效或总量溢出。"
            let unknownCoverage = coverage.addingReason(reason, degradingTo: .partial)
            changes.append(unknownChange(
                identity: identity,
                old: oldItems.first,
                new: newItems.first,
                coverage: unknownCoverage,
                reason: reason
            ))
            diagnostics.append(SnapshotDiffDiagnostic(
                kind: .insufficientCoverage,
                message: reason,
                identity: identity,
                rawSection: identity.rawSection
            ))
            return
        }

        let sectionProofComplete = sectionCoverageIsComplete(entry: from, identity: identity)
            && sectionCoverageIsComplete(entry: to, identity: identity)
        guard coverage.state == .complete, sectionProofComplete else {
            // timer 出现/变化类事件（upgradeStarted/timerChanged）只依赖 timer
            // 字段证据，不依赖 section/level/count coverage，可以独立输出；
            // timer 消失类结果需要 section proof，在此必然降级为 unknown，
            // 由下方 level unknown 表达，不再重复输出。
            let timerResult = aggregateTimerTransition(
                oldItems: oldItems,
                newItems: newItems,
                from: from,
                to: to,
                hasCredibleLevelUp: false,
                sectionProofComplete: sectionProofComplete
            )
            if timerResult.kind != nil {
                appendAggregateTimerChange(
                    timerResult,
                    identity: identity,
                    oldItems: oldItems,
                    newItems: newItems,
                    from: from,
                    to: to,
                    changes: &changes,
                    diagnostics: &diagnostics
                )
            }
            let reason = "重复建筑/城墙 histogram 的 section、level 或 count coverage 不完整。"
            let unknownCoverage = coverage.addingReason(
                reason,
                degradingTo: sectionProofComplete ? .partial : .insufficient
            )
            changes.append(unknownChange(
                identity: identity,
                old: oldItems.first,
                new: newItems.first,
                oldQuantity: oldHistogram.total,
                newQuantity: newHistogram.total,
                coverage: unknownCoverage,
                reason: reason
            ))
            diagnostics.append(SnapshotDiffDiagnostic(
                kind: .insufficientCoverage,
                message: reason,
                identity: identity,
                rawSection: identity.rawSection
            ))
            return
        }

        var oldRemaining = oldHistogram.levels
        var newRemaining = newHistogram.levels
        var anyLevelUp = false
        for level in Set(oldRemaining.keys).intersection(newRemaining.keys) {
            let unchanged = min(oldRemaining[level] ?? 0, newRemaining[level] ?? 0)
            oldRemaining[level, default: 0] -= unchanged
            newRemaining[level, default: 0] -= unchanged
        }

        let oldLevels = oldRemaining.keys.filter { (oldRemaining[$0] ?? 0) > 0 }.sorted()
        let newLevels = newRemaining.keys.filter { (newRemaining[$0] ?? 0) > 0 }.sorted()
        var oldIndex = 0
        var newIndex = 0
        var pendingChanges: [SnapshotChange] = []
        while oldIndex < oldLevels.count && newIndex < newLevels.count {
            let oldLevel = oldLevels[oldIndex]
            let newLevel = newLevels[newIndex]
            let delta = newLevel - oldLevel
            // 单调迁移规则只允许升级；同级剩余已在 unchanged 消除中处理，
            // 任何降级都意味着分布无法逐级解释，立即停止配对。
            guard delta > 0 else { break }
            let moved = min(oldRemaining[oldLevel] ?? 0, newRemaining[newLevel] ?? 0)
            anyLevelUp = true
            pendingChanges.append(makeChange(
                identity: identity,
                old: oldItems.first,
                new: newItems.first,
                oldLevel: oldLevel,
                newLevel: newLevel,
                oldQuantity: oldHistogram.levels[oldLevel],
                newQuantity: newHistogram.levels[newLevel],
                movedQuantity: moved,
                levelDelta: delta,
                changeKind: .levelIncreased,
                related: [],
                evidence: .aggregateInferred,
                coverage: coverage
            ))
            oldRemaining[oldLevel, default: 0] -= moved
            newRemaining[newLevel, default: 0] -= moved
            if oldRemaining[oldLevel, default: 0] == 0 { oldIndex += 1 }
            if newRemaining[newLevel, default: 0] == 0 { newIndex += 1 }
        }

        // 守恒校验：配对结束后两侧都不得有剩余量。任何未配对的剩余
        // （或配对中发现的降级冲突）都表示证据不足或分布冲突，必须
        // fail-closed 为 unknown，不得输出部分 level growth、quantity
        // 变化、deletion 或 new item。timer 事件在其自身证据完整时
        // 可以独立保留，但不能把等级迁移标成 confirmed。
        let oldResidual = oldRemaining.values.contains { $0 > 0 }
        let newResidual = newRemaining.values.contains { $0 > 0 }
        guard !oldResidual, !newResidual else {
            let timerResult = aggregateTimerTransition(
                oldItems: oldItems,
                newItems: newItems,
                from: from,
                to: to,
                hasCredibleLevelUp: false,
                sectionProofComplete: sectionProofComplete
            )
            if timerResult.kind != nil || timerResult.isUnknown {
                appendAggregateTimerChange(
                    timerResult,
                    identity: identity,
                    oldItems: oldItems,
                    newItems: newItems,
                    from: from,
                    to: to,
                    changes: &changes,
                    diagnostics: &diagnostics
                )
            }
            let oldSummary = oldRemaining
                .filter { $0.value > 0 }
                .sorted { $0.key < $1.key }
                .map { "Lv.\($0.key) ×\($0.value)" }
                .joined(separator: "、")
            let newSummary = newRemaining
                .filter { $0.value > 0 }
                .sorted { $0.key < $1.key }
                .map { "Lv.\($0.key) ×\($0.value)" }
                .joined(separator: "、")
            var residualParts: [String] = []
            if !oldSummary.isEmpty { residualParts.append("旧侧未配对：\(oldSummary)") }
            if !newSummary.isEmpty { residualParts.append("新侧未配对：\(newSummary)") }
            let reason = "重复建筑/城墙 histogram 无法守恒解释（\(residualParts.joined(separator: "；"))），fail-closed。"
            // 守恒失败是分布冲突而非证据不足：字段/section coverage 本身完整，
            // 保持 coverage.state = .complete 并追加 reason，使下游（如手动对账
            // 的 conflict 判定）能区分"证据不足"与"分布冲突"两种 unknown。
            let unknownCoverage = coverage.addingReason(reason, degradingTo: .complete)
            // 代表 item 按 (level, count) 确定性选取，保证结果与数组顺序无关。
            let representativeOld = histogramRepresentative(oldItems)
            let representativeNew = histogramRepresentative(newItems)
            changes.append(unknownChange(
                identity: identity,
                old: representativeOld,
                new: representativeNew,
                oldQuantity: oldHistogram.total,
                newQuantity: newHistogram.total,
                coverage: unknownCoverage,
                reason: reason,
                degradeCoverageTo: .complete
            ))
            diagnostics.append(SnapshotDiffDiagnostic(
                kind: .insufficientCoverage,
                message: reason,
                identity: identity,
                rawSection: identity.rawSection
            ))
            return
        }

        changes.append(contentsOf: pendingChanges)

        let timerResult = aggregateTimerTransition(
            oldItems: oldItems,
            newItems: newItems,
            from: from,
            to: to,
            hasCredibleLevelUp: anyLevelUp,
            sectionProofComplete: sectionProofComplete
        )
        if timerResult.kind != nil || timerResult.isUnknown {
            appendAggregateTimerChange(
                timerResult,
                identity: identity,
                oldItems: oldItems,
                newItems: newItems,
                from: from,
                to: to,
                changes: &changes,
                diagnostics: &diagnostics
            )
        }
    }

    private static func timerTransition(
        old: SnapshotObservationItem,
        new: SnapshotObservationItem,
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry
    ) -> TimerResult {
        let oldState = timerState(
            old.rawTimerEvidence,
            schema: from.timerSchema,
            sourceTimestamp: from.sourceTimestamp
        )
        let newState = timerState(
            new.rawTimerEvidence,
            schema: to.timerSchema,
            sourceTimestamp: to.sourceTimestamp
        )
        let fields = Set(old.rawTimerEvidence.keys).union(new.rawTimerEvidence.keys).sorted()
        guard !fields.isEmpty else { return TimerResult() }
        // Issue #175 review：契约规格不一致必须在任何状态转换（含
        // active→inactive / inactive→active）前 fail-closed，不能只拦
        // active→active 的数值比较。
        guard timerSpecsAreConsistent(from: from, to: to, fields: fields) else {
            return TimerResult(
                kind: nil,
                isUnknown: true,
                reason: "两侧 timer 契约规格不一致，不能确认 timer 变化。",
                requiredFields: fields
            )
        }

        let coverage = coverageFor(
            identity: old.identity,
            from: from,
            to: to,
            fields: fields
        )
        if oldState == .unknown || newState == .unknown || coverage.state != .complete {
            return TimerResult(
                kind: nil,
                isUnknown: true,
                reason: "timer 原始状态或 coverage 不足，不能确认 timer 变化。",
                requiredFields: fields
            )
        }

        switch (oldState, newState) {
        case (.absent, .active), (.inactive, .active):
            return TimerResult(kind: .upgradeStarted, requiredFields: fields)
        case (.active, .active):
            switch normalizedTimerComparison(
                oldNumbersByField: timerNumbersByField(old.rawTimerEvidence, schema: from.timerSchema),
                newNumbersByField: timerNumbersByField(new.rawTimerEvidence, schema: to.timerSchema),
                from: from,
                to: to
            ) {
            case .changed:
                return TimerResult(kind: .timerChanged, requiredFields: fields)
            case .unstable(let reason):
                return TimerResult(kind: nil, isUnknown: true, reason: reason, requiredFields: fields)
            case .unchanged:
                break
            }
        case (.active, .absent), (.active, .inactive):
            if let oldLevel = validLevel(old.level), let newLevel = validLevel(new.level), newLevel > oldLevel {
                return TimerResult(kind: .upgradeCompleted, requiredFields: fields)
            }
            return TimerResult(kind: .timerEndedObserved, requiredFields: fields)
        case (.unknown, _), (_, .unknown):
            return TimerResult(
                kind: nil,
                isUnknown: true,
                reason: "timer 原始值无法解析。",
                requiredFields: fields
            )
        default:
            break
        }
        return TimerResult(requiredFields: fields)
    }

    private static func primaryKind(
        levelKind: SnapshotChangeKind?,
        levelDelta: Int?,
        timerKind: SnapshotChangeKind?,
        quantityChanged: Bool
    ) -> SnapshotChangeKind? {
        if timerKind == .upgradeCompleted && (levelDelta ?? 0) > 0 {
            return .upgradeCompleted
        }
        if timerKind == .upgradeStarted && levelKind == nil {
            return .upgradeStarted
        }
        if timerKind == .timerChanged && levelKind == nil {
            return .timerChanged
        }
        if timerKind == .timerEndedObserved && levelKind == nil {
            return .timerEndedObserved
        }
        if let levelKind { return levelKind }
        if let timerKind { return timerKind }
        if quantityChanged { return .quantityChanged }
        return nil
    }

    private static func makeChange(
        identity: SnapshotItemIdentity,
        old: SnapshotObservationItem?,
        new: SnapshotObservationItem?,
        oldLevel: Int?,
        newLevel: Int?,
        oldQuantity: Int?,
        newQuantity: Int?,
        movedQuantity: Int?,
        levelDelta: Int?,
        changeKind: SnapshotChangeKind,
        related: [SnapshotChangeKind],
        evidence: SnapshotChangeEvidence,
        coverage: SnapshotDiffCoverage
    ) -> SnapshotChange {
        let display = new?.display ?? old?.display ?? SnapshotDisplayBinding()
        return SnapshotChange(
            identity: identity,
            displayName: stableDisplayName(identity: identity, binding: display),
            category: display.category,
            displayCategory: display.displayCategory,
            oldLevel: oldLevel,
            newLevel: newLevel,
            oldQuantity: oldQuantity,
            newQuantity: newQuantity,
            movedQuantity: movedQuantity,
            levelDelta: levelDelta,
            changeKind: changeKind,
            relatedChangeKinds: related,
            evidence: evidence,
            coverage: coverage
        )
    }

    private static func unknownChange(
        identity: SnapshotItemIdentity,
        old: SnapshotObservationItem?,
        new: SnapshotObservationItem?,
        oldQuantity: Int? = nil,
        newQuantity: Int? = nil,
        coverage: SnapshotDiffCoverage,
        reason: String,
        related: [SnapshotChangeKind] = [],
        degradeCoverageTo minimum: SnapshotDiffCoverage.State = .partial
    ) -> SnapshotChange {
        let finalCoverage = coverage.addingReason(reason, degradingTo: minimum)
        return makeChange(
            identity: identity,
            old: old,
            new: new,
            oldLevel: validLevel(old?.level),
            newLevel: validLevel(new?.level),
            oldQuantity: oldQuantity ?? validQuantity(old?.count),
            newQuantity: newQuantity ?? validQuantity(new?.count),
            movedQuantity: nil,
            levelDelta: nil,
            changeKind: .unknown,
            related: related,
            evidence: .unknown,
            coverage: finalCoverage
        )
    }

    private static func coverageFor(
        identity: SnapshotItemIdentity,
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry,
        fields: [String]
    ) -> SnapshotDiffCoverage {
        let fields = Array(Set(fields)).sorted()
        let result = fields.map { field -> SnapshotDiffFieldCoverage in
            let fromState = from.coverage.state(
                base: identity.base,
                rawSection: identity.rawSection,
                field: field
            ) ?? .unavailable
            let toState = to.coverage.state(
                base: identity.base,
                rawSection: identity.rawSection,
                field: field
            ) ?? .unavailable
            return SnapshotDiffFieldCoverage(
                base: identity.base,
                rawSection: identity.rawSection,
                field: field,
                fromState: fromState,
                toState: toState
            )
        }
        return SnapshotDiffCoverage(fields: result)
    }

    private static func mergeCoverage(
        _ lhs: SnapshotDiffCoverage,
        _ rhs: SnapshotDiffCoverage
    ) -> SnapshotDiffCoverage {
        SnapshotDiffCoverage(
            fields: lhs.fields + rhs.fields,
            reasons: lhs.reasons + rhs.reasons
        )
    }

    private static func sectionPresenceAndDataAreComplete(
        entry: SnapshotHistoryEntry,
        identity: SnapshotItemIdentity
    ) -> Bool {
        entry.coverage.state(base: identity.base, rawSection: identity.rawSection, field: "presence") == .complete &&
            entry.coverage.state(base: identity.base, rawSection: identity.rawSection, field: "data") == .complete
    }

    private static func sectionCoverageIsComplete(
        entry: SnapshotHistoryEntry,
        identity: SnapshotItemIdentity
    ) -> Bool {
        entry.coverage.section(
            base: identity.base,
            rawSection: identity.rawSection
        )?.isComplete == true
    }

    /// A root-level authoritative proof covers root record enumeration only.
    /// Field-level `types`/`modules` completeness proves the array is
    /// parseable, not that its nested enumeration was not truncated, and a
    /// root-level `modules:[]` says nothing about deeper `types[].modules[]`.
    /// Until an explicit nested enumeration proof (expected counts per nested
    /// path) exists, single-sided nested appearance/disappearance fails
    /// closed and stays unknown + insufficient.
    private static func nestedEnumerationIsConfirmed(identity: SnapshotItemIdentity) -> Bool {
        identity.nestedKind == .root
    }

    private static func observedItemFieldsAreComplete(
        entry: SnapshotHistoryEntry,
        item: SnapshotObservationItem?,
        fields: [String]
    ) -> Bool {
        guard item != nil else { return false }
        return fields.allSatisfy {
            entry.coverage.state(
                base: item!.identity.base,
                rawSection: item!.identity.rawSection,
                field: $0
            ) == .complete
        }
    }

    private static func histogramIsComplete(
        entry: SnapshotHistoryEntry,
        identity: SnapshotItemIdentity,
        items: [SnapshotObservationItem]
    ) -> Bool {
        !items.isEmpty &&
            items.allSatisfy { validLevel($0.level) != nil && validQuantity($0.count) != nil } &&
            ["presence", "data", "lvl", "cnt"].allSatisfy {
                entry.coverage.state(base: identity.base, rawSection: identity.rawSection, field: $0) == .complete
            }
    }

    private static func makeSectionCoverage(
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry
    ) -> [SnapshotDiffSectionCoverage] {
        SnapshotHistoryKnownSections.all.sorted().map { section in
            let base = SnapshotHistoryBase(section: section)
            let fromSection = from.coverage.section(base: base, rawSection: section)
            let toSection = to.coverage.section(base: base, rawSection: section)
            return SnapshotDiffSectionCoverage(
                base: base,
                rawSection: section,
                fromState: from.coverage.state(base: base, rawSection: section, field: "presence") ?? .unavailable,
                toState: to.coverage.state(base: base, rawSection: section, field: "presence") ?? .unavailable,
                fromDataState: from.coverage.state(base: base, rawSection: section, field: "data") ?? .unavailable,
                toDataState: to.coverage.state(base: base, rawSection: section, field: "data") ?? .unavailable,
                fromSectionCompleteness: fromSection?.completeness ?? .unavailable,
                toSectionCompleteness: toSection?.completeness ?? .unavailable,
                fromProof: fromSection?.proof,
                toProof: toSection?.proof,
                fromTrustTrusted: fromSection?.opensTrustGates ?? false,
                toTrustTrusted: toSection?.opensTrustGates ?? false,
                fromFieldStates: Dictionary(uniqueKeysWithValues: (Array(SnapshotHistoryKnownSections.itemFields) + ["presence"]).map {
                    ($0, from.coverage.state(base: base, rawSection: section, field: $0) ?? .unavailable)
                }),
                toFieldStates: Dictionary(uniqueKeysWithValues: (Array(SnapshotHistoryKnownSections.itemFields) + ["presence"]).map {
                    ($0, to.coverage.state(base: base, rawSection: section, field: $0) ?? .unavailable)
                }),
                fromObservedItemCount: from.observation.items.filter { $0.identity.rawSection == section }.count,
                toObservedItemCount: to.observation.items.filter { $0.identity.rawSection == section }.count
            )
        }
    }

    private static func isUsableIdentity(_ identity: SnapshotItemIdentity) -> Bool {
        identity.base != .unknown && !identity.rawSection.isEmpty && identity.dataID > 0 && identity.nestedKind != .unknown &&
            (identity.nestedRootDataID == nil || identity.nestedRootDataID! > 0) &&
            identity.nestedParentPath.allSatisfy { $0.dataID > 0 && $0.kind != .unknown }
    }

    /// Issue #235: provenance-only must not bypass observation validation that the
    /// normal diff path would fail-closed on.  Emits blocking diagnostics only.
    private static func blockingObservationDiagnostics(
        in entry: SnapshotHistoryEntry
    ) -> [SnapshotDiffDiagnostic] {
        var diagnostics: [SnapshotDiffDiagnostic] = []
        let groups = Dictionary(grouping: entry.observation.items, by: { $0.identity.key })
        for key in groups.keys.sorted() {
            let items = groups[key] ?? []
            guard let representative = items.first else { continue }
            let identity = representative.identity

            guard isUsableIdentity(identity) else {
                diagnostics.append(SnapshotDiffDiagnostic(
                    kind: .unknownIdentity,
                    message: "发现无法确认的历史 identity。",
                    identity: identity,
                    rawSection: identity.rawSection
                ))
                continue
            }

            if isHistogramIdentity(identity) {
                if !items.isEmpty, histogram(items) == nil {
                    diagnostics.append(SnapshotDiffDiagnostic(
                        kind: .malformedObservation,
                        message: "重复建筑/城墙 histogram 的 level/count 无效或总量溢出。",
                        identity: identity,
                        rawSection: identity.rawSection
                    ))
                }
                continue
            }

            if items.count > 1 {
                diagnostics.append(SnapshotDiffDiagnostic(
                    kind: .malformedObservation,
                    message: "唯一 identity 出现重复记录，已保留为 unknown。",
                    identity: identity,
                    rawSection: identity.rawSection
                ))
                continue
            }

            guard let item = items.first else { continue }
            if requiresLevel(identity), validLevel(item.level) == nil {
                diagnostics.append(SnapshotDiffDiagnostic(
                    kind: .insufficientCoverage,
                    message: "level 缺失或非法。",
                    identity: identity,
                    rawSection: identity.rawSection
                ))
            }
            if item.count != nil, validQuantity(item.count) == nil {
                diagnostics.append(SnapshotDiffDiagnostic(
                    kind: .insufficientCoverage,
                    message: "count 缺失或非法。",
                    identity: identity,
                    rawSection: identity.rawSection
                ))
            }
        }
        return diagnostics
    }

    private static func isHistogramIdentity(_ identity: SnapshotItemIdentity) -> Bool {
        identity.nestedKind == .root && ["buildings", "buildings2", "traps", "traps2"].contains(identity.rawSection)
    }

    private static func requiresLevel(_ identity: SnapshotItemIdentity) -> Bool {
        identity.nestedKind == .root && [
            "buildings", "buildings2", "traps", "traps2", "units", "units2",
            "spells", "heroes", "heroes2", "pets", "equipment", "siege_machines"
        ].contains(identity.rawSection)
    }

    /// 按 (level, count) 确定性选取代表 item，保证结果与数组顺序无关；
    /// 用于 fail-closed 的 unknown change 展示（display/level 不具迁移语义）。
    private static func histogramRepresentative(_ items: [SnapshotObservationItem]) -> SnapshotObservationItem? {
        items.min { lhs, rhs in
            let lhsKey = (lhs.level ?? Int.max, lhs.count ?? 0)
            let rhsKey = (rhs.level ?? Int.max, rhs.count ?? 0)
            return lhsKey < rhsKey
        }
    }

    private static func histogram(_ items: [SnapshotObservationItem]) -> Histogram? {
        guard !items.isEmpty else { return nil }
        var levels: [Int: Int] = [:]
        for item in items {
            guard let level = validLevel(item.level), let quantity = validQuantity(item.count), quantity > 0 else {
                return nil
            }
            let (sum, overflow) = (levels[level] ?? 0).addingReportingOverflow(quantity)
            guard !overflow else { return nil }
            levels[level] = sum
        }
        var total = 0
        for value in levels.values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = sum
        }
        return Histogram(levels: levels, total: total)
    }

    private static func validLevel(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func validQuantity(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func stableDisplayName(
        identity: SnapshotItemIdentity,
        binding: SnapshotDisplayBinding
    ) -> String {
        if let name = binding.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return identity.rawSection + "#" + String(identity.dataID)
    }

    private static func diagnosticSection(from message: String) -> String? {
        let prefix = message.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first
        guard let prefix else { return nil }
        let value = String(prefix)
        if let bracket = value.firstIndex(of: "[") {
            return String(value[..<bracket])
        }
        return value.isEmpty ? nil : value
    }

    private static func isTimerField(_ field: String) -> Bool {
        SnapshotHistoryKnownSections.timerFields.contains(field)
    }

    private static func timerState(
        _ evidence: [String: CanonicalJSONValue],
        schema: SnapshotTimerSchema?,
        sourceTimestamp: Date?
    ) -> TimerState {
        guard !evidence.isEmpty else { return .absent }
        var hasActive = false
        for key in evidence.keys.sorted() {
            guard let value = evidence[key],
                  let number = timerNumber(value, spec: schema?.fields[key]) else { return .unknown }
            if schema?.fields[key]?.semantics == .absolute {
                // 结束时间戳：必须与观测时刻（sourceTimestamp）比较，
                // 观测时刻按字段单位换算。观测时刻缺失时无法判断是否
                // 过期 → fail-closed，不猜测。
                guard let sourceTimestamp else { return .unknown }
                let unit = schema?.fields[key]?.unit ?? .seconds
                let observed: Int64 = unit == .milliseconds
                    ? Int64(sourceTimestamp.timeIntervalSince1970 * 1000)
                    : Int64(sourceTimestamp.timeIntervalSince1970)
                if number > observed {
                    hasActive = true
                }
            } else if number > 0 {
                hasActive = true
            }
        }
        return hasActive ? .active : .inactive
    }

    private static func timerNumber(
        _ value: CanonicalJSONValue,
        spec: SnapshotTimerFieldSpec?
    ) -> Int64? {
        guard case .number(let raw) = value else { return nil }
        guard let number = Int64(raw), number >= 0 else { return nil }
        if let minValue = spec?.minValue, number < minValue { return nil }
        if let maxValue = spec?.maxValue, number > maxValue { return nil }
        return number
    }

    /// remaining timer 自然倒计时的容差（秒）。两次观测间期望值 = old − elapsed，
    /// 偏差超过该容差才视为业务变化（覆盖时钟抖动与抓取延迟）。
    private static let timerElapsedTolerance: TimeInterval = 30

    /// 聚合多个重复实例的 timer 状态：任一 evidence 无法解析 → unknown；
    /// 任一 active（>0）→ active；全部为空 → absent；否则 inactive。
    private static func aggregateTimerState(
        _ items: [SnapshotObservationItem],
        schema: SnapshotTimerSchema?,
        sourceTimestamp: Date?
    ) -> TimerState {
        var hasEvidence = false
        var hasActive = false
        for item in items {
            if item.rawTimerEvidence.isEmpty { continue }
            hasEvidence = true
            switch timerState(item.rawTimerEvidence, schema: schema, sourceTimestamp: sourceTimestamp) {
            case .unknown:
                return .unknown
            case .active:
                hasActive = true
            case .absent, .inactive:
                break
            }
        }
        guard hasEvidence else { return .absent }
        return hasActive ? .active : .inactive
    }

    /// 聚合 timer 状态迁移。active→active 时按"remaining 规范化"比较：
    /// 同一字段可解析数值集合数量不同 → unknown（身份无法稳定聚合，fail-closed）；
    /// 数量相同 → 排序后逐位比较，全部自然流逝才无变化。
    /// timer 消失类结果（upgradeCompleted/timerEndedObserved）需要 section
    /// 完整性证明：section 不完整时对象可能只是未导出，不得推断 timer 结束。
    private static func aggregateTimerTransition(
        oldItems: [SnapshotObservationItem],
        newItems: [SnapshotObservationItem],
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry,
        hasCredibleLevelUp: Bool,
        sectionProofComplete: Bool
    ) -> TimerResult {
        let oldState = aggregateTimerState(
            oldItems,
            schema: from.timerSchema,
            sourceTimestamp: from.sourceTimestamp
        )
        let newState = aggregateTimerState(
            newItems,
            schema: to.timerSchema,
            sourceTimestamp: to.sourceTimestamp
        )
        let fields = Set(oldItems.flatMap { $0.rawTimerEvidence.keys })
            .union(newItems.flatMap { $0.rawTimerEvidence.keys })
            .sorted()
        guard !fields.isEmpty else { return TimerResult() }
        guard let identity = (newItems.first ?? oldItems.first)?.identity else { return TimerResult() }
        // Issue #175 review：契约规格不一致必须在任何状态转换前 fail-closed。
        guard timerSpecsAreConsistent(from: from, to: to, fields: fields) else {
            return TimerResult(
                kind: nil,
                isUnknown: true,
                reason: "两侧 timer 契约规格不一致，不能确认 timer 变化。",
                requiredFields: fields
            )
        }

        let coverage = coverageFor(identity: identity, from: from, to: to, fields: fields)
        if oldState == .unknown || newState == .unknown || coverage.state != .complete {
            return TimerResult(
                kind: nil,
                isUnknown: true,
                reason: "timer 原始状态或 coverage 不足，不能确认 timer 变化。",
                requiredFields: fields
            )
        }

        switch (oldState, newState) {
        case (.absent, .active), (.inactive, .active):
            return TimerResult(kind: .upgradeStarted, requiredFields: fields)
        case (.active, .active):
            switch normalizedTimerComparison(
                oldNumbersByField: aggregateTimerNumbersByField(oldItems, schema: from.timerSchema),
                newNumbersByField: aggregateTimerNumbersByField(newItems, schema: to.timerSchema),
                from: from,
                to: to
            ) {
            case .changed:
                return TimerResult(kind: .timerChanged, requiredFields: fields)
            case .unstable(let reason):
                return TimerResult(kind: nil, isUnknown: true, reason: reason, requiredFields: fields)
            case .unchanged:
                break
            }
        case (.active, .absent), (.active, .inactive):
            if hasCredibleLevelUp {
                return TimerResult(kind: .upgradeCompleted, requiredFields: fields)
            }
            guard sectionProofComplete else {
                return TimerResult(
                    kind: nil,
                    isUnknown: true,
                    reason: "section 完整性证据不足，不能推断 timer 结束或升级完成。",
                    requiredFields: fields
                )
            }
            return TimerResult(kind: .timerEndedObserved, requiredFields: fields)
        default:
            break
        }
        return TimerResult(requiredFields: fields)
    }

    /// remaining timer 规范化比较结果。
    private enum TimerNormalizedResult {
        case changed
        case unchanged
        case unstable(String)
    }

    /// Issue #207：observation + 可序列化 coverage 相同、仅 timer schema 不同的相邻 pair。
    /// 不得走 remaining/absolute 数值比较，否则会把 provenance 当成 timerChanged。
    /// coverage 比较排除 runtimeWitness；observation 比较忽略 display。
    private static func isProvenanceOnlyPair(
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry
    ) -> Bool {
        guard from.timerSchema != to.timerSchema else { return false }
        guard SnapshotHistoryCoverageDuplicateKey(from.coverage)
                == SnapshotHistoryCoverageDuplicateKey(to.coverage) else {
            return false
        }
        return observationIdentityMatches(from.observation, to.observation)
    }

    private static func observationIdentityMatches(
        _ lhs: CanonicalSnapshotObservation,
        _ rhs: CanonicalSnapshotObservation
    ) -> Bool {
        guard lhs.schemaVersion == rhs.schemaVersion,
              lhs.rawTopLevelFields == rhs.rawTopLevelFields,
              lhs.unknownTopLevelFields == rhs.unknownTopLevelFields,
              lhs.items.count == rhs.items.count else {
            return false
        }
        let left = lhs.items.sorted { $0.identity.key < $1.identity.key }
        let right = rhs.items.sorted { $0.identity.key < $1.identity.key }
        return zip(left, right).allSatisfy { lhsItem, rhsItem in
            lhsItem.identity == rhsItem.identity
                && lhsItem.level == rhsItem.level
                && lhsItem.count == rhsItem.count
                && lhsItem.rawTimerEvidence == rhsItem.rawTimerEvidence
                && lhsItem.helperRecurrent == rhsItem.helperRecurrent
                && lhsItem.gearUp == rhsItem.gearUp
                && lhsItem.weapon == rhsItem.weapon
                && lhsItem.unknownFields == rhsItem.unknownFields
        }
    }

    private static func provenanceTimerFields(
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry
    ) -> [String] {
        var fields = Set<String>()
        if let keys = from.timerSchema?.fields.keys {
            fields.formUnion(keys)
        }
        if let keys = to.timerSchema?.fields.keys {
            fields.formUnion(keys)
        }
        for item in from.observation.items {
            fields.formUnion(item.rawTimerEvidence.keys)
        }
        for item in to.observation.items {
            fields.formUnion(item.rawTimerEvidence.keys)
        }
        return fields.sorted()
    }

    /// 字段的契约规格。v4+ entry 用冻结的 schema；v3 及更早 entry 没有
    /// 冻结契约，其 evidence 语义 = 默认 seconds/remaining、非负无上限。
    /// v4 无契约（显式 nil）保持 fail-closed：nil 与任何有规格的字段不兼容，
    /// 不允许把「无 evidence」当作业务转换。
    private static func timerSpec(
        for field: String,
        in entry: SnapshotHistoryEntry
    ) -> SnapshotTimerFieldSpec? {
        if entry.observationVersion >= SnapshotHistorySchema.observationWithTimerSchema {
            return entry.timerSchema?.fields[field]
        }
        return SnapshotTimerFieldSpec(unit: .seconds, semantics: .remaining, minValue: 0)
    }

    /// 两侧 entry 对 evidence 字段的契约规格必须兼容（v3 及更早按默认
    /// seconds/remaining、非负无上限参与比较）。不一致时不得做任何状态转换。
    private static func timerSpecsAreConsistent(
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry,
        fields: [String]
    ) -> Bool {
        for field in fields {
            let oldSpec = timerSpec(for: field, in: from)
            let newSpec = timerSpec(for: field, in: to)
            switch (oldSpec, newSpec) {
            case (nil, nil):
                continue
            case (nil, _), (_, nil):
                // v4 无契约（显式 nil）与任何有规格的字段不兼容 → fail-closed
                return false
            case let (old?, new?):
                if !timerSpecsAreCompatible(old, new) { return false }
            }
        }
        return true
    }

    /// 语义兼容：单位/语义相同，且范围约束不收紧 legacy 默认语义
    /// （非负、无上限）。minValue 的 nil 与 0 等价（timerNumber 本就
    /// 要求非负）；任何显式正数下限或显式上限都会改变可接受数值集合。
    private static func timerSpecsAreCompatible(
        _ lhs: SnapshotTimerFieldSpec,
        _ rhs: SnapshotTimerFieldSpec
    ) -> Bool {
        guard lhs.unit == rhs.unit, lhs.semantics == rhs.semantics else { return false }
        func lowerBound(_ spec: SnapshotTimerFieldSpec) -> Int64 { spec.minValue ?? 0 }
        if lhs.maxValue != rhs.maxValue { return false }
        return lowerBound(lhs) == lowerBound(rhs)
    }

    /// 规范化 timer 比较（unique 与 aggregate 共用）：
    /// - 时间证据：sourceTimestamp 缺失/非法（≤ 0）/倒序 → unstable，不得猜测；
    /// - 字段证据：timer 字段集合不一致（某字段仅单侧出现）→ unstable；
    /// - 数量证据：同字段实例数量不一致 → unstable（无法稳定配对）；
    /// - 数值证据：remaining 按 `old − elapsed`（按单位换算）、absolute 按 `old`
    ///   规范化，偏差超过容差 → changed；全部自然 → unchanged。
    ///   v3 及更早 entry（无冻结契约）按默认秒/remaining 语义处理。
    ///   两侧契约规格一致性由调用方在状态转换前统一校验。
    private static func normalizedTimerComparison(
        oldNumbersByField: [String: [Int64]],
        newNumbersByField: [String: [Int64]],
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry
    ) -> TimerNormalizedResult {
        guard let fromTime = from.sourceTimestamp,
              let toTime = to.sourceTimestamp,
              fromTime.timeIntervalSince1970 > 0,
              toTime.timeIntervalSince1970 > 0 else {
            return .unstable("source timestamp 缺失或非法，无法规范化 timer。")
        }
        let elapsed = toTime.timeIntervalSince(fromTime)
        guard elapsed >= 0 else {
            return .unstable("source timestamp 倒序，无法规范化 timer。")
        }
        let fields = Set(oldNumbersByField.keys).union(newNumbersByField.keys)
        for field in fields.sorted() {
            guard let oldNumbers = oldNumbersByField[field], !oldNumbers.isEmpty,
                  let newNumbers = newNumbersByField[field], !newNumbers.isEmpty else {
                return .unstable("timer 字段 \(field) 仅在一侧出现，无法确认 timer 变化。")
            }
            let oldSpec = from.timerSchema?.fields[field]
            guard oldNumbers.count == newNumbers.count else {
                return .unstable("timer 字段 \(field) 的实例数量不一致，无法稳定配对。")
            }
            let isMilliseconds = oldSpec?.unit == .milliseconds
            let elapsedInUnit = isMilliseconds ? elapsed * 1000 : elapsed
            let tolerance = isMilliseconds ? timerElapsedTolerance * 1000 : timerElapsedTolerance
            for (oldNumber, newNumber) in zip(oldNumbers, newNumbers) {
                let expected: Double
                switch oldSpec?.semantics {
                case .absolute:
                    // 绝对结束时间戳不随流逝减少；值稳定不变是自然状态。
                    expected = Double(oldNumber)
                case .remaining, nil:
                    // 默认 remaining 语义（v3 及更早 entry 与无契约字段）。
                    expected = Double(oldNumber) - elapsedInUnit
                }
                if abs(Double(newNumber) - expected) > tolerance {
                    return .changed
                }
            }
        }
        return .unchanged
    }

    /// 按字段收集可解析的 timer 数值（unique 场景每字段至多一个）。
    private static func timerNumbersByField(
        _ evidence: [String: CanonicalJSONValue],
        schema: SnapshotTimerSchema?
    ) -> [String: [Int64]] {
        var result: [String: [Int64]] = [:]
        for key in evidence.keys.sorted() {
            if let number = evidence[key].flatMap({ timerNumber($0, spec: schema?.fields[key]) }) {
                result[key] = [number]
            }
        }
        return result
    }

    /// 按字段收集所有实例的可解析 timer 数值（aggregate 场景）。
    private static func aggregateTimerNumbersByField(
        _ items: [SnapshotObservationItem],
        schema: SnapshotTimerSchema?
    ) -> [String: [Int64]] {
        var result: [String: [Int64]] = [:]
        for item in items {
            for key in item.rawTimerEvidence.keys {
                guard let number = item.rawTimerEvidence[key]
                    .flatMap({ timerNumber($0, spec: schema?.fields[key]) }) else { continue }
                result[key, default: []].append(number)
            }
        }
        for key in result.keys {
            result[key]?.sort()
        }
        return result
    }

    /// 把 aggregate timer 结果输出为独立 change（evidence: .aggregateInferred）。
    private static func appendAggregateTimerChange(
        _ timerResult: TimerResult,
        identity: SnapshotItemIdentity,
        oldItems: [SnapshotObservationItem],
        newItems: [SnapshotObservationItem],
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry,
        changes: inout [SnapshotChange],
        diagnostics: inout [SnapshotDiffDiagnostic]
    ) {
        let timerCoverage = coverageFor(
            identity: identity,
            from: from,
            to: to,
            fields: Array(Set(timerResult.requiredFields)).sorted()
        )
        if let kind = timerResult.kind {
            changes.append(makeChange(
                identity: identity,
                old: oldItems.first,
                new: newItems.first,
                oldLevel: nil,
                newLevel: nil,
                oldQuantity: nil,
                newQuantity: nil,
                movedQuantity: nil,
                levelDelta: nil,
                changeKind: kind,
                related: kind == .upgradeCompleted ? [.levelIncreased] : [],
                evidence: .aggregateInferred,
                coverage: timerCoverage
            ))
        } else if timerResult.isUnknown {
            let reason = timerResult.reason.isEmpty
                ? "timer 证据不足，无法确认变化。"
                : timerResult.reason
            changes.append(unknownChange(
                identity: identity,
                old: oldItems.first,
                new: newItems.first,
                coverage: timerCoverage.addingReason(reason, degradingTo: .partial),
                reason: reason
            ))
            diagnostics.append(SnapshotDiffDiagnostic(
                kind: .insufficientCoverage,
                message: reason,
                identity: identity,
                rawSection: identity.rawSection
            ))
        }
    }

    private struct Histogram {
        let levels: [Int: Int]
        let total: Int
    }

    private enum TimerState {
        case absent
        case inactive
        case active
        case unknown
    }

    private struct TimerResult {
        let kind: SnapshotChangeKind?
        let isUnknown: Bool
        let reason: String
        let requiredFields: [String]

        init(
            kind: SnapshotChangeKind? = nil,
            isUnknown: Bool = false,
            reason: String = "",
            requiredFields: [String] = []
        ) {
            self.kind = kind
            self.isUnknown = isUnknown
            self.reason = reason
            self.requiredFields = requiredFields
        }
    }
}

private enum SnapshotDiffOrdering {
    static func change(_ lhs: SnapshotChange, _ rhs: SnapshotChange) -> Bool {
        if lhs.identity.key != rhs.identity.key { return lhs.identity.key < rhs.identity.key }
        if lhs.changeKind.rawValue != rhs.changeKind.rawValue { return lhs.changeKind.rawValue < rhs.changeKind.rawValue }
        if lhs.oldLevel != rhs.oldLevel { return (lhs.oldLevel ?? Int.min) < (rhs.oldLevel ?? Int.min) }
        if lhs.newLevel != rhs.newLevel { return (lhs.newLevel ?? Int.min) < (rhs.newLevel ?? Int.min) }
        return (lhs.movedQuantity ?? Int.min) < (rhs.movedQuantity ?? Int.min)
    }

    static func diff(_ lhs: SnapshotDiff, _ rhs: SnapshotDiff) -> Bool {
        if lhs.toAppliedAt != rhs.toAppliedAt { return lhs.toAppliedAt < rhs.toAppliedAt }
        return lhs.toSnapshotID.uuidString < rhs.toSnapshotID.uuidString
    }
}

public enum SnapshotStatisticValueState: String, Codable, Hashable, Sendable {
    case available
    case insufficientData
}

public struct SnapshotStatisticValue: Codable, Hashable, Sendable {
    public let state: SnapshotStatisticValueState
    public let value: Int?
    public let reason: String?

    public init(
        state: SnapshotStatisticValueState,
        value: Int? = nil,
        reason: String? = nil
    ) {
        self.state = state
        self.value = value
        self.reason = reason
    }

    public static func available(_ value: Int) -> SnapshotStatisticValue {
        SnapshotStatisticValue(state: .available, value: value)
    }

    public static func insufficientData(_ reason: String) -> SnapshotStatisticValue {
        SnapshotStatisticValue(state: .insufficientData, reason: reason)
    }
}

public struct SnapshotHistoryStatisticsWindow: Codable, Hashable, Sendable {
    public let start: Date
    public let end: Date
    /// 已确认建筑升级完成：只统计证据满足 confirmed 口径的完成。
    public let buildingUpgradeCompletions: SnapshotStatisticValue
    /// 聚合推断建筑升级完成：同一 aggregate 的 level migration + timer
    /// disappearance 只计 1 次；与 confirmed 口径独立，UI 不得混用标题。
    public let aggregateInferredBuildingUpgradeCompletions: SnapshotStatisticValue
    public let buildingLevelGrowth: SnapshotStatisticValue
    public let aggregateInferredBuildingLevelGrowth: SnapshotStatisticValue
    public let wallLevelGrowth: SnapshotStatisticValue
    public let aggregateInferredWallLevelGrowth: SnapshotStatisticValue
    public let heroLevelGrowth: SnapshotStatisticValue
    public let troopLevelGrowth: SnapshotStatisticValue
    public let spellLevelGrowth: SnapshotStatisticValue
    public let petLevelGrowth: SnapshotStatisticValue
    public let heroEquipmentLevelGrowth: SnapshotStatisticValue
    public let aggregateInferredEventCount: SnapshotStatisticValue

    /// Confirmed wall growth is the safe remainder after removing the
    /// aggregate-inferred subset from the total wall growth.  Keep this
    /// derivation in Core so the UI never invents evidence partitions.
    public var confirmedWallLevelGrowth: SnapshotStatisticValue {
        guard wallLevelGrowth.state == .available,
              aggregateInferredWallLevelGrowth.state == .available,
              let total = wallLevelGrowth.value,
              let inferred = aggregateInferredWallLevelGrowth.value else {
            let reasons = [wallLevelGrowth.reason, aggregateInferredWallLevelGrowth.reason]
                .compactMap { $0 }
            return .insufficientData(
                reasons.first ?? "城墙总增长或聚合推断增长数据不足，无法拆分已确认部分。"
            )
        }
        let (confirmed, overflow) = total.subtractingReportingOverflow(inferred)
        guard !overflow, confirmed >= 0 else {
            return .insufficientData("城墙增长证据分区不一致，无法安全拆分。")
        }
        return .available(confirmed)
    }

    fileprivate init(
        start: Date,
        end: Date,
        buildingUpgradeCompletions: SnapshotStatisticValue,
        aggregateInferredBuildingUpgradeCompletions: SnapshotStatisticValue,
        buildingLevelGrowth: SnapshotStatisticValue,
        aggregateInferredBuildingLevelGrowth: SnapshotStatisticValue,
        wallLevelGrowth: SnapshotStatisticValue,
        aggregateInferredWallLevelGrowth: SnapshotStatisticValue,
        heroLevelGrowth: SnapshotStatisticValue,
        troopLevelGrowth: SnapshotStatisticValue,
        spellLevelGrowth: SnapshotStatisticValue,
        petLevelGrowth: SnapshotStatisticValue,
        heroEquipmentLevelGrowth: SnapshotStatisticValue,
        aggregateInferredEventCount: SnapshotStatisticValue
    ) {
        self.start = start
        self.end = end
        self.buildingUpgradeCompletions = buildingUpgradeCompletions
        self.aggregateInferredBuildingUpgradeCompletions = aggregateInferredBuildingUpgradeCompletions
        self.buildingLevelGrowth = buildingLevelGrowth
        self.aggregateInferredBuildingLevelGrowth = aggregateInferredBuildingLevelGrowth
        self.wallLevelGrowth = wallLevelGrowth
        self.aggregateInferredWallLevelGrowth = aggregateInferredWallLevelGrowth
        self.heroLevelGrowth = heroLevelGrowth
        self.troopLevelGrowth = troopLevelGrowth
        self.spellLevelGrowth = spellLevelGrowth
        self.petLevelGrowth = petLevelGrowth
        self.heroEquipmentLevelGrowth = heroEquipmentLevelGrowth
        self.aggregateInferredEventCount = aggregateInferredEventCount
    }
}

public struct SnapshotHistoryStatistics: Codable, Hashable, Sendable {
    public let referenceDate: Date
    public let timeZoneIdentifier: String
    public let today: SnapshotHistoryStatisticsWindow
    public let last7Days: SnapshotHistoryStatisticsWindow
    public let last30Days: SnapshotHistoryStatisticsWindow
    public let diagnostics: [String]

    public init(
        referenceDate: Date,
        timeZoneIdentifier: String,
        today: SnapshotHistoryStatisticsWindow,
        last7Days: SnapshotHistoryStatisticsWindow,
        last30Days: SnapshotHistoryStatisticsWindow,
        diagnostics: [String] = []
    ) {
        self.referenceDate = referenceDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.today = today
        self.last7Days = last7Days
        self.last30Days = last30Days
        self.diagnostics = Array(Set(diagnostics)).sorted()
    }

    public static func calculate(
        diffs: [SnapshotDiff],
        referenceDate: Date,
        calendar inputCalendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> SnapshotHistoryStatistics {
        var calendar = inputCalendar
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: referenceDate)
        let sevenStart = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let thirtyStart = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday

        var diagnostics: [String] = []
        let identities = Set(diffs.map { $0.villageID.uuidString + "|" + $0.lineageID.uuidString })
        let inputIsSingleLineage = identities.count <= 1
        if !inputIsSingleLineage {
            diagnostics.append("统计输入包含多个 village/lineage；必须先按同一 village/lineage 分组。")
        }
        if diffs.isEmpty {
            diagnostics.append("没有可比较的相邻 diff。")
        }
        let usableDiffs = inputIsSingleLineage ? diffs : []
        return SnapshotHistoryStatistics(
            referenceDate: referenceDate,
            timeZoneIdentifier: timeZone.identifier,
            today: makeWindow(
                diffs: usableDiffs,
                start: startOfToday,
                end: referenceDate,
                calendar: calendar
            ),
            last7Days: makeWindow(
                diffs: usableDiffs,
                start: sevenStart,
                end: referenceDate,
                calendar: calendar
            ),
            last30Days: makeWindow(
                diffs: usableDiffs,
                start: thirtyStart,
                end: referenceDate,
                calendar: calendar
            ),
            diagnostics: diagnostics
        )
    }

    private static func makeWindow(
        diffs: [SnapshotDiff],
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> SnapshotHistoryStatisticsWindow {
        let windowDiffs = diffs.filter { diff in
            diff.toAppliedAt >= start && diff.toAppliedAt <= end
        }
        let accumulators = MetricAccumulators(
            diffs: windowDiffs,
            start: start,
            end: end,
            calendar: calendar
        )
        return SnapshotHistoryStatisticsWindow(
            start: start,
            end: end,
            buildingUpgradeCompletions: accumulators.buildingCompletions.result(),
            aggregateInferredBuildingUpgradeCompletions: accumulators.aggregateBuildingCompletions.result(),
            buildingLevelGrowth: accumulators.buildingGrowth.result(),
            aggregateInferredBuildingLevelGrowth: accumulators.aggregateBuildingGrowth.result(),
            wallLevelGrowth: accumulators.wallGrowth.result(),
            aggregateInferredWallLevelGrowth: accumulators.aggregateWallGrowth.result(),
            heroLevelGrowth: accumulators.heroGrowth.result(),
            troopLevelGrowth: accumulators.troopGrowth.result(),
            spellLevelGrowth: accumulators.spellGrowth.result(),
            petLevelGrowth: accumulators.petGrowth.result(),
            heroEquipmentLevelGrowth: accumulators.equipmentGrowth.result(),
            aggregateInferredEventCount: accumulators.aggregateEvents.result()
        )
    }
}

private enum SnapshotMetricCategory {
    case building
    case wall
    case hero
    case troop
    case spell
    case pet
    case equipment
}

private struct MetricAccumulator {
    var value = 0
    var hasComparableDiff = false
    var hasUnknown = false
    var overflowed = false

    mutating func markComparable() {
        hasComparableDiff = true
    }

    mutating func add(_ delta: Int) {
        let (sum, overflow) = value.addingReportingOverflow(delta)
        if overflow {
            overflowed = true
        } else {
            value = sum
        }
    }

    mutating func markUnknown() {
        hasUnknown = true
    }

    func result() -> SnapshotStatisticValue {
        if overflowed { return .insufficientData("统计值溢出，无法安全汇总。") }
        if hasUnknown { return .insufficientData("相关历史变化存在 unknown 或 coverage 不足。") }
        guard hasComparableDiff else { return .insufficientData("窗口内没有可比较的相邻 diff。") }
        return .available(value)
    }
}

private struct MetricAccumulators {
    var buildingCompletions = MetricAccumulator()
    var aggregateBuildingCompletions = MetricAccumulator()
    var buildingGrowth = MetricAccumulator()
    var aggregateBuildingGrowth = MetricAccumulator()
    var wallGrowth = MetricAccumulator()
    var aggregateWallGrowth = MetricAccumulator()
    var heroGrowth = MetricAccumulator()
    var troopGrowth = MetricAccumulator()
    var spellGrowth = MetricAccumulator()
    var petGrowth = MetricAccumulator()
    var equipmentGrowth = MetricAccumulator()
    var aggregateEvents = MetricAccumulator()

    init(diffs: [SnapshotDiff], start: Date, end: Date, calendar: Calendar) {
        _ = start
        _ = end
        _ = calendar
        for diff in diffs {
            switch diff.comparisonState {
            case .provenanceOnly:
                applyProvenanceOnlyContribution(for: diff)
                markUnknownForDiagnostics(in: diff)
            case .comparable:
                let diffApplicability = DiffMetricApplicability(diff: diff)
                applyDiffApplicability(diffApplicability)
                for change in diff.changes {
                    apply(change, diffApplicability: diffApplicability)
                }
                markUnknownForUnclassified(in: diff.changes)
                markUnknownForUnknownCategories(in: diff.changes)
                markUnknownForDiagnostics(in: diff)
            case .insufficientCoverage, .suppressed:
                markUnknownForDiagnostics(in: diff)
            }
        }
    }

    /// Issue #235: provenance-only audit append must not re-run #206 universe
    /// applicability (which would poison metrics) or fabricate growth/events.
    /// It may only mark relevant growth metrics comparable when neutral
    /// eligibility proves complete+trusted observed sections.
    private mutating func applyProvenanceOnlyContribution(for diff: SnapshotDiff) {
        let evaluator = MetricApplicabilityEvaluator(sectionCoverage: diff.sectionCoverage)
        let levelFields: Set<String> = ["presence", "data", "lvl"]
        let histogramFields: Set<String> = ["presence", "data", "lvl", "cnt"]
        let buildingSections: Set<String> = ["buildings", "buildings2", "traps", "traps2"]
        let wallSections: Set<String> = ["buildings", "buildings2"]
        let heroSections: Set<String> = ["heroes", "heroes2"]
        let troopSections: Set<String> = ["units", "units2"]

        switch evaluator.neutralMetricEligibility(sections: buildingSections, fields: histogramFields, in: diff) {
        case .complete:
            buildingGrowth.markComparable()
            aggregateBuildingGrowth.markComparable()
        case .insufficient:
            buildingGrowth.markUnknown()
            aggregateBuildingGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
        switch evaluator.neutralMetricEligibility(sections: wallSections, fields: histogramFields, in: diff) {
        case .complete:
            wallGrowth.markComparable()
            aggregateWallGrowth.markComparable()
        case .insufficient:
            wallGrowth.markUnknown()
            aggregateWallGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
        switch evaluator.neutralMetricEligibility(sections: heroSections, fields: levelFields, in: diff) {
        case .complete:
            heroGrowth.markComparable()
        case .insufficient:
            heroGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
        switch evaluator.neutralMetricEligibility(sections: troopSections, fields: levelFields, in: diff) {
        case .complete:
            troopGrowth.markComparable()
        case .insufficient:
            troopGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
        switch evaluator.neutralMetricEligibility(sections: ["spells"], fields: levelFields, in: diff) {
        case .complete:
            spellGrowth.markComparable()
        case .insufficient:
            spellGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
        switch evaluator.neutralMetricEligibility(sections: ["pets"], fields: levelFields, in: diff) {
        case .complete:
            petGrowth.markComparable()
        case .insufficient:
            petGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
        switch evaluator.neutralMetricEligibility(sections: ["equipment"], fields: levelFields, in: diff) {
        case .complete:
            equipmentGrowth.markComparable()
        case .insufficient:
            equipmentGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
    }

    private mutating func applyDiffApplicability(_ applicability: DiffMetricApplicability) {
        switch applicability.building {
        case .complete:
            buildingCompletions.markComparable()
            aggregateBuildingCompletions.markComparable()
            buildingGrowth.markComparable()
            aggregateBuildingGrowth.markComparable()
        case .insufficient:
            buildingCompletions.markUnknown()
            aggregateBuildingCompletions.markUnknown()
            buildingGrowth.markUnknown()
            aggregateBuildingGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
        switch applicability.wall {
        case .complete:
            wallGrowth.markComparable()
            aggregateWallGrowth.markComparable()
        case .insufficient:
            wallGrowth.markUnknown()
            aggregateWallGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
        switch applicability.hero {
        case .complete:
            heroGrowth.markComparable()
        case .insufficient:
            heroGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
        switch applicability.troop {
        case .complete:
            troopGrowth.markComparable()
        case .insufficient:
            troopGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
        switch applicability.spell {
        case .complete:
            spellGrowth.markComparable()
        case .insufficient:
            spellGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
        switch applicability.pet {
        case .complete:
            petGrowth.markComparable()
        case .insufficient:
            petGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
        switch applicability.equipment {
        case .complete:
            equipmentGrowth.markComparable()
        case .insufficient:
            equipmentGrowth.markUnknown()
        case .notApplicable, .irrelevant:
            break
        }
        if applicability.hasSectionCoverage || applicability.hasChanges {
            aggregateEvents.markComparable()
        }
    }

    private func universeState(
        for category: SnapshotMetricCategory,
        in applicability: DiffMetricApplicability
    ) -> MetricUniverseState {
        switch category {
        case .building: return applicability.building
        case .wall: return applicability.wall
        case .hero: return applicability.hero
        case .troop: return applicability.troop
        case .spell: return applicability.spell
        case .pet: return applicability.pet
        case .equipment: return applicability.equipment
        }
    }

    private mutating func apply(
        _ change: SnapshotChange,
        diffApplicability: DiffMetricApplicability
    ) {
        guard let category = Self.category(for: change) else {
            // An unknown category is intentionally not guessed from the
            // current catalog.  It remains a diagnostic rather than being
            // assigned to every metric.
            return
        }

        let positiveLevelDelta = change.levelDelta.flatMap { $0 > 0 ? $0 : nil }
        if change.evidence == .aggregateInferred {
            aggregateEvents.add(1)
            guard universeState(for: category, in: diffApplicability) == .complete else {
                return
            }
            // 聚合完成的唯一计数点：一条 .upgradeCompleted change 对应一次
            // aggregate 完成（level migration 那条不计 completion）；无 level
            // migration 的 timer 消失是 timerEndedObserved，也不计 completion。
            if category == .building && change.changeKind == .upgradeCompleted {
                aggregateBuildingCompletions.add(1)
            }
            guard let positiveLevelDelta, let moved = change.movedQuantity else {
                return
            }
            let (product, overflow) = positiveLevelDelta.multipliedReportingOverflow(by: moved)
            guard !overflow else {
                switch category {
                case .building: aggregateBuildingGrowth.overflowed = true
                case .wall: aggregateWallGrowth.overflowed = true
                case .hero, .troop, .spell, .pet, .equipment: break
                }
                return
            }
            switch category {
            case .building:
                aggregateBuildingGrowth.add(product)
            case .wall:
                aggregateWallGrowth.add(product)
                wallGrowth.add(product)
            case .hero, .troop, .spell, .pet, .equipment: break
            }
            return
        }

        guard change.evidence == .confirmed else {
            if change.changeKind == .unknown || change.levelDelta != nil {
                markUnknown(category: category)
            }
            return
        }

        guard universeState(for: category, in: diffApplicability) == .complete else {
            return
        }

        guard let positiveLevelDelta else { return }
        switch category {
        case .building:
            buildingGrowth.add(positiveLevelDelta)
            if change.changeKind == .levelIncreased || change.changeKind == .upgradeCompleted {
                buildingCompletions.add(1)
            }
        case .wall:
            wallGrowth.add(positiveLevelDelta)
        case .hero:
            heroGrowth.add(positiveLevelDelta)
        case .troop:
            troopGrowth.add(positiveLevelDelta)
        case .spell:
            spellGrowth.add(positiveLevelDelta)
        case .pet:
            petGrowth.add(positiveLevelDelta)
        case .equipment:
            equipmentGrowth.add(positiveLevelDelta)
        }
    }

    private mutating func markUnknownForUnknownCategories(in changes: [SnapshotChange]) {
        for change in changes where change.evidence == .unknown || change.coverage.state != .complete {
            guard let category = Self.category(for: change) else { continue }
            if change.changeKind == .unknown || change.levelDelta != nil || change.relatedChangeKinds.contains(.levelIncreased) {
                markUnknown(category: category)
                aggregateEvents.markUnknown()
            }
        }
    }

    private mutating func markUnknownForUnclassified(in changes: [SnapshotChange]) {
        for change in changes where Self.category(for: change) == nil {
            let section = change.identity.rawSection.hasSuffix("2")
                ? String(change.identity.rawSection.dropLast())
                : change.identity.rawSection
            switch section {
            case "buildings":
                buildingCompletions.markUnknown()
                aggregateBuildingCompletions.markUnknown()
                buildingGrowth.markUnknown()
                wallGrowth.markUnknown()
                aggregateBuildingGrowth.markUnknown()
                aggregateWallGrowth.markUnknown()
            case "traps":
                buildingCompletions.markUnknown()
                aggregateBuildingCompletions.markUnknown()
                buildingGrowth.markUnknown()
                aggregateBuildingGrowth.markUnknown()
            case "heroes": heroGrowth.markUnknown()
            case "units": troopGrowth.markUnknown()
            case "spells": spellGrowth.markUnknown()
            case "pets": petGrowth.markUnknown()
            case "equipment": equipmentGrowth.markUnknown()
            default: break
            }
        }
    }

    private mutating func markUnknownForDiagnostics(in diff: SnapshotDiff) {
        let relevant = diff.diagnostics.filter {
            switch $0.kind {
            case .insufficientCoverage, .unknownIdentity, .malformedObservation:
                return true
            case .baseline, .villageMismatch, .lineageMismatch, .duplicateSnapshotID, .mixedLineageInput, .incomparableTimerSchema:
                return false
            }
        }
        guard !relevant.isEmpty else { return }

        for diagnostic in relevant {
            // Issue #176：城墙与普通建筑共享 rawSection "buildings"，section
            // 粒度传播会互相污染。diagnostic 有 identity 且能在本 diff 的
            // changes 中匹配到同 identity 的 change 时，按 change 的
            // category/displayCategory 传播；匹配不到才回退 section 粒度
            // （保守，保持既有行为）。
            if let identity = diagnostic.identity,
               let matched = diff.changes.first(where: { $0.identity == identity }),
               let category = Self.category(for: matched) {
                markUnknown(category: category)
                continue
            }
            if let section = diagnostic.rawSection ?? diagnostic.identity?.rawSection {
                markUnknown(section: section)
            } else {
                markAllUnknown()
            }
        }
    }

    private mutating func markUnknown(section rawSection: String) {
        let section = rawSection.hasSuffix("2")
            ? String(rawSection.dropLast())
            : rawSection
        switch section {
        case "buildings":
            buildingCompletions.markUnknown()
            aggregateBuildingCompletions.markUnknown()
            buildingGrowth.markUnknown()
            aggregateBuildingGrowth.markUnknown()
            wallGrowth.markUnknown()
            aggregateWallGrowth.markUnknown()
        case "traps":
            buildingCompletions.markUnknown()
            aggregateBuildingCompletions.markUnknown()
            buildingGrowth.markUnknown()
            aggregateBuildingGrowth.markUnknown()
        case "heroes": heroGrowth.markUnknown()
        case "units": troopGrowth.markUnknown()
        case "spells": spellGrowth.markUnknown()
        case "pets": petGrowth.markUnknown()
        case "equipment": equipmentGrowth.markUnknown()
        default: break
        }
    }

    private mutating func markAllUnknown() {
        buildingCompletions.markUnknown()
        aggregateBuildingCompletions.markUnknown()
        buildingGrowth.markUnknown()
        aggregateBuildingGrowth.markUnknown()
        wallGrowth.markUnknown()
        aggregateWallGrowth.markUnknown()
        heroGrowth.markUnknown()
        troopGrowth.markUnknown()
        spellGrowth.markUnknown()
        petGrowth.markUnknown()
        equipmentGrowth.markUnknown()
    }

    private mutating func markUnknown(category: SnapshotMetricCategory) {
        switch category {
        case .building:
            buildingGrowth.markUnknown()
            buildingCompletions.markUnknown()
            aggregateBuildingCompletions.markUnknown()
            aggregateBuildingGrowth.markUnknown()
        case .wall:
            wallGrowth.markUnknown()
            aggregateWallGrowth.markUnknown()
        case .hero: heroGrowth.markUnknown()
        case .troop: troopGrowth.markUnknown()
        case .spell: spellGrowth.markUnknown()
        case .pet: petGrowth.markUnknown()
        case .equipment: equipmentGrowth.markUnknown()
        }
    }

    private static func category(for change: SnapshotChange) -> SnapshotMetricCategory? {
        guard let category = change.category else { return nil }
        let section = change.identity.rawSection.hasSuffix("2")
            ? String(change.identity.rawSection.dropLast())
            : change.identity.rawSection
        switch section {
        case "buildings", "traps":
            guard category == section, change.identity.nestedKind == .root else { return nil }
            if section == "buildings" && change.displayCategory == TrackerDisplayCategory.walls.rawValue {
                return .wall
            }
            return .building
        case "heroes":
            return category == "heroes" && change.identity.nestedKind == .root ? .hero : nil
        case "units":
            return category == "troops" && change.identity.nestedKind == .root ? .troop : nil
        case "spells":
            return category == "spells" && change.identity.nestedKind == .root ? .spell : nil
        case "pets":
            return category == "pets" && change.identity.nestedKind == .root ? .pet : nil
        case "equipment":
            return category == "equipment" && change.identity.nestedKind == .root ? .equipment : nil
        default:
            return nil
        }
    }
}
