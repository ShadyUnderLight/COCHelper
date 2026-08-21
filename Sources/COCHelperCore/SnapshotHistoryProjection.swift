import Foundation

/// User-visible availability for one village's active snapshot lineage.
///
/// Storage failures remain distinct from legitimate empty/baseline states so
/// callers never turn unavailable history into an invented zero-change row.
public enum SnapshotHistoryAvailability: Hashable, Sendable {
    case noSnapshot
    case empty
    case baselineOnly
    case available
    case insufficient(String)
    case corrupt(String)
    case unsupported(String)
    case unavailable(String)
}

/// Stable, history-bound category filters.  Mapping uses the category strings
/// captured in each immutable history entry; the current GameCatalog is never
/// consulted.
public enum SnapshotHistoryCategory: String, CaseIterable, Hashable, Identifiable, Sendable {
    case all
    case buildings
    case walls
    case heroes
    case troops
    case spells
    case pets
    case equipment
    case siegeMachines
    case guardians
    case unknown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "全部"
        case .buildings: "建筑"
        case .walls: "城墙"
        case .heroes: "英雄"
        case .troops: "兵种"
        case .spells: "法术"
        case .pets: "战宠"
        case .equipment: "英雄装备"
        case .siegeMachines: "攻城机器"
        case .guardians: "守卫"
        case .unknown: "未知/覆盖不足"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .buildings: "building.2.fill"
        case .walls: "square.grid.3x3"
        case .heroes: "person.crop.circle.badge.star"
        case .troops: "figure.2.arms.open"
        case .spells: "wand.and.stars"
        case .pets: "pawprint.fill"
        case .equipment: "shield.lefthalf.filled"
        case .siegeMachines: "car.fill"
        case .guardians: "person.2.fill"
        case .unknown: "questionmark.diamond"
        }
    }

    fileprivate static func boundCategory(for change: SnapshotChange) -> SnapshotHistoryCategory {
        if change.displayCategory == TrackerDisplayCategory.walls.rawValue {
            return .walls
        }
        if change.displayCategory == TrackerDisplayCategory.defense.rawValue
            || change.displayCategory == TrackerDisplayCategory.military.rawValue
            || change.displayCategory == TrackerDisplayCategory.craftTable.rawValue {
            return .buildings
        }

        switch change.category {
        case TrackerCategory.buildings.rawValue, TrackerCategory.traps.rawValue:
            return .buildings
        case TrackerCategory.heroes.rawValue:
            return .heroes
        case TrackerCategory.troops.rawValue:
            return .troops
        case TrackerCategory.spells.rawValue:
            return .spells
        case TrackerCategory.pets.rawValue:
            return .pets
        case TrackerCategory.equipment.rawValue:
            return .equipment
        case TrackerCategory.siegeMachines.rawValue:
            return .siegeMachines
        case TrackerCategory.guardians.rawValue:
            return .guardians
        default:
            return .unknown
        }
    }

    fileprivate func matches(_ change: SnapshotChange) -> Bool {
        switch self {
        case .all:
            true
        case .unknown:
            Self.boundCategory(for: change) == .unknown
                || change.changeKind == .unknown
                || change.evidence == .unknown
                || change.coverage.state != .complete
        default:
            Self.boundCategory(for: change) == self
        }
    }
}

public struct SnapshotHistoryCategorySummary: Hashable, Identifiable, Sendable {
    public let category: SnapshotHistoryCategory
    public let count: Int

    public var id: String { category.rawValue }

    public init(category: SnapshotHistoryCategory, count: Int) {
        self.category = category
        self.count = max(0, count)
    }
}

public extension SnapshotChange {
    /// Quantity represented by one history change row.
    ///
    /// Whole-group additions/removals intentionally carry only one side of
    /// the quantity pair.  Other change kinds must not consume a lone value,
    /// because an unknown/partial comparison cannot safely turn an observed
    /// quantity into a confirmed delta.
    var snapshotHistoryImpact: Int {
        if let movedQuantity, movedQuantity > 0 { return movedQuantity }

        switch changeKind {
        case .newlyObserved:
            if let newQuantity, newQuantity > 0 { return newQuantity }
        case .noLongerObserved:
            if let oldQuantity, oldQuantity > 0 { return oldQuantity }
        default:
            break
        }

        if let oldQuantity, let newQuantity {
            let (delta, overflow) = newQuantity.subtractingReportingOverflow(oldQuantity)
            if overflow || delta == Int.min { return Int.max }
            let magnitude = abs(delta)
            if magnitude > 0 { return magnitude }
        }
        return 1
    }

    /// Quantity suffix used by the immutable history detail row.
    var snapshotHistoryQuantityText: String? {
        if let movedQuantity, movedQuantity > 1 {
            return "×\(movedQuantity)"
        }
        if let oldQuantity, let newQuantity, oldQuantity != newQuantity {
            return "数量 \(oldQuantity) → \(newQuantity)"
        }
        switch changeKind {
        case .newlyObserved:
            if let newQuantity, newQuantity > 1 { return "×\(newQuantity)" }
        case .noLongerObserved:
            if let oldQuantity, oldQuantity > 1 { return "×\(oldQuantity)" }
        default:
            break
        }
        return nil
    }

    var snapshotHistoryIsUncertain: Bool {
        changeKind == .unknown || evidence == .unknown || coverage.state != .complete
    }
}

public struct SnapshotHistoryRow: Hashable, Identifiable, Sendable {
    public let snapshotID: UUID
    public let lineageID: UUID
    public let appliedAt: Date
    public let sourceTimestamp: Date?
    public let isBaseline: Bool
    public let duplicateImportCount: Int
    public let lastSeenAt: Date?
    public let comparisonState: SnapshotDiffComparisonState?
    public let totalChangeCount: Int
    public let visibleChangeCount: Int
    public let summaries: [SnapshotHistoryCategorySummary]
    public let summary: String
    public let changes: [SnapshotChange]
    public let diagnostics: [String]
    public let isExpandedByDefault: Bool

    fileprivate let unfilteredChanges: [SnapshotChange]
    fileprivate let unfilteredDiagnostics: [String]

    public var id: UUID { snapshotID }
    public var containsUncertainChanges: Bool {
        changes.contains { $0.snapshotHistoryIsUncertain }
    }

    fileprivate init(
        entry: SnapshotHistoryEntry,
        diff: SnapshotDiff?,
        duplicateMetadata: SnapshotHistoryDuplicateMetadata?
    ) {
        let changes = diff?.changes ?? []
        let diagnostics = Array(Set(
            entry.coverage.diagnostics + (diff?.diagnostics.map(\.message) ?? [])
        )).sorted()
        let summaries = Self.summaries(for: changes)

        self.snapshotID = entry.snapshotID
        self.lineageID = entry.lineageID
        self.appliedAt = entry.appliedAt
        self.sourceTimestamp = entry.sourceTimestamp
        self.isBaseline = entry.isBaseline
        self.duplicateImportCount = duplicateMetadata?.duplicateImportCount ?? 0
        self.lastSeenAt = duplicateMetadata?.lastSeenAt
        self.comparisonState = diff?.comparisonState
        self.totalChangeCount = Self.impactCount(of: changes)
        self.visibleChangeCount = Self.impactCount(of: changes)
        self.summaries = summaries
        self.summary = Self.summary(
            isBaseline: entry.isBaseline,
            comparisonState: diff?.comparisonState,
            changes: changes
        )
        self.changes = changes
        self.diagnostics = diagnostics
        self.isExpandedByDefault = false
        self.unfilteredChanges = changes
        self.unfilteredDiagnostics = diagnostics
    }

    private init(
        source: SnapshotHistoryRow,
        visibleChanges: [SnapshotChange],
        visibleDiagnostics: [String]
    ) {
        let summaries = Self.summaries(for: visibleChanges)
        self.snapshotID = source.snapshotID
        self.lineageID = source.lineageID
        self.appliedAt = source.appliedAt
        self.sourceTimestamp = source.sourceTimestamp
        self.isBaseline = source.isBaseline
        self.duplicateImportCount = source.duplicateImportCount
        self.lastSeenAt = source.lastSeenAt
        self.comparisonState = source.comparisonState
        self.totalChangeCount = source.totalChangeCount
        self.visibleChangeCount = Self.impactCount(of: visibleChanges)
        self.summaries = summaries
        self.summary = Self.summary(
            isBaseline: source.isBaseline,
            comparisonState: source.comparisonState,
            changes: visibleChanges
        )
        self.changes = visibleChanges
        self.diagnostics = visibleDiagnostics
        self.isExpandedByDefault = false
        self.unfilteredChanges = source.unfilteredChanges
        self.unfilteredDiagnostics = source.unfilteredDiagnostics
    }

    fileprivate func applying(category: SnapshotHistoryCategory) -> SnapshotHistoryRow? {
        guard category != .all else { return self }
        guard !isBaseline else { return nil }

        let visibleChanges = unfilteredChanges.filter(category.matches)
        let includesCoverageDiagnostics = category == .unknown
            && (comparisonState == .insufficientCoverage || !unfilteredDiagnostics.isEmpty)
        guard !visibleChanges.isEmpty || includesCoverageDiagnostics else { return nil }

        return SnapshotHistoryRow(
            source: self,
            visibleChanges: visibleChanges,
            visibleDiagnostics: includesCoverageDiagnostics ? unfilteredDiagnostics : []
        )
    }

    private static func summaries(for changes: [SnapshotChange]) -> [SnapshotHistoryCategorySummary] {
        var totals: [SnapshotHistoryCategory: Int] = [:]
        for change in changes {
            let category = SnapshotHistoryCategory.boundCategory(for: change)
            totals[category] = saturatedAdd(totals[category] ?? 0, change.snapshotHistoryImpact)
        }
        return totals.map { SnapshotHistoryCategorySummary(category: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                let left = SnapshotHistoryCategory.allCases.firstIndex(of: lhs.category) ?? Int.max
                let right = SnapshotHistoryCategory.allCases.firstIndex(of: rhs.category) ?? Int.max
                return left < right
            }
    }

    private static func impactCount(of changes: [SnapshotChange]) -> Int {
        changes.reduce(0) { saturatedAdd($0, $1.snapshotHistoryImpact) }
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private static func summary(
        isBaseline: Bool,
        comparisonState: SnapshotDiffComparisonState?,
        changes: [SnapshotChange]
    ) -> String {
        if isBaseline { return "初始基线（不计变化）" }
        if changes.isEmpty {
            switch comparisonState {
            case .insufficientCoverage:
                return "覆盖不足，无法确认变化"
            case .provenanceOnly:
                return "来源信息变化，无业务变化"
            default:
                return "没有可确认变化"
            }
        }

        let confirmedChanges = changes.filter {
            $0.evidence == .confirmed && !$0.snapshotHistoryIsUncertain
        }
        let inferredChanges = changes.filter {
            $0.evidence == .aggregateInferred && !$0.snapshotHistoryIsUncertain
        }
        let pendingChanges = changes.filter {
            $0.evidence == .unknown || $0.snapshotHistoryIsUncertain
        }

        var parts: [String] = []
        if let confirmed = summaryGroup(
            summaries: summaries(for: confirmedChanges),
            limit: 3,
            prefix: "",
            suffix: { " +" + String($0) }
        ) {
            parts.append(confirmed)
        }
        if let inferred = summaryGroup(
            summaries: summaries(for: inferredChanges),
            limit: 2,
            prefix: "推断：",
            suffix: { " +" + String($0) }
        ) {
            parts.append(inferred)
        }
        if let pending = summaryGroup(
            summaries: summaries(for: pendingChanges),
            limit: 2,
            prefix: "待确认：",
            suffix: { " " + String($0) + " 项" }
        ) {
            parts.append(pending)
        }
        if comparisonState == .insufficientCoverage && pendingChanges.isEmpty {
            parts.append("覆盖不足，无法确认完整变化")
        }
        return parts.isEmpty ? "没有可确认变化" : parts.joined(separator: " · ")
    }

    private static func summaryGroup(
        summaries: [SnapshotHistoryCategorySummary],
        limit: Int,
        prefix: String,
        suffix: (Int) -> String
    ) -> String? {
        guard !summaries.isEmpty else { return nil }
        let visible = summaries.prefix(limit).map {
            $0.category.title + suffix($0.count)
        }.joined(separator: " · ")
        let remaining = max(0, summaries.count - limit)
        return prefix + visible + (remaining > 0 ? " · 另 \(remaining) 类" : "")
    }
}

/// Complete, deterministic input for the Village Detail history UI.
///
/// The builder first isolates the active `villageID + lineageID` entries and
/// only then forms adjacent diffs.  This preserves A1 → A2 when another
/// village's B1 import is interleaved in the shared append-only envelope.
public struct SnapshotHistoryProjection: Hashable, Sendable {
    public let villageID: UUID
    public let activeLineageID: UUID?
    public let availability: SnapshotHistoryAvailability
    public let totalSnapshotCount: Int
    public let latestAppliedAt: Date?
    public let latestCheckedAt: Date?
    public let latestSummary: String?
    public let timeline: [SnapshotHistoryRow]
    public let selectedCategory: SnapshotHistoryCategory
    public let statistics: SnapshotHistoryStatistics
    public let diagnostics: [String]
    /// Issue #224: latest entry verified-coverage trust for UI.
    public let coverageTrustState: SnapshotCoverageTrustDisplayState
    fileprivate let unfilteredTimeline: [SnapshotHistoryRow]

    public var filterIsEmpty: Bool {
        selectedCategory != .all && timeline.isEmpty
    }

    public static func project(
        envelope: SnapshotHistoryEnvelope,
        villageID: UUID,
        hasCurrentSnapshot: Bool,
        selectedCategory: SnapshotHistoryCategory = .all,
        referenceDate: Date = Date(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> SnapshotHistoryProjection {
        let villageEntries = envelope.entries.filter { $0.villageID == villageID }
        guard !villageEntries.isEmpty else {
            return emptyProjection(
                villageID: villageID,
                availability: hasCurrentSnapshot ? .empty : .noSnapshot,
                selectedCategory: selectedCategory,
                referenceDate: referenceDate,
                calendar: calendar,
                timeZone: timeZone
            )
        }

        guard let activeLineage = envelope.activeLineage(for: villageID) else {
            return emptyProjection(
                villageID: villageID,
                availability: .insufficient("找不到当前村庄的 active lineage。"),
                selectedCategory: selectedCategory,
                referenceDate: referenceDate,
                calendar: calendar,
                timeZone: timeZone,
                diagnostics: ["历史条目存在，但 active lineage 索引不可用。"]
            )
        }

        // Preserve append order after isolating the active lineage.  The
        // envelope is the submitted-order source of truth; appliedAt is only
        // used to sort rows for display.
        let entries = villageEntries.filter { $0.lineageID == activeLineage.lineageID }
        guard !entries.isEmpty else {
            return emptyProjection(
                villageID: villageID,
                activeLineageID: activeLineage.lineageID,
                availability: .insufficient("active lineage 没有可用历史条目。"),
                selectedCategory: selectedCategory,
                referenceDate: referenceDate,
                calendar: calendar,
                timeZone: timeZone
            )
        }

        let diffs = SnapshotDiffEngine.adjacentDiffs(in: entries)
        let diffByTarget = Dictionary(uniqueKeysWithValues: diffs.map { ($0.toSnapshotID, $0) })
        let rows = entries.map { entry in
            SnapshotHistoryRow(
                entry: entry,
                diff: diffByTarget[entry.snapshotID],
                duplicateMetadata: envelope.duplicateMetadata[entry.snapshotID.uuidString]
            )
        }.sorted { lhs, rhs in
            if lhs.appliedAt != rhs.appliedAt { return lhs.appliedAt > rhs.appliedAt }
            return lhs.snapshotID.uuidString < rhs.snapshotID.uuidString
        }

        let diagnostics = Array(Set(
            rows.flatMap(\.diagnostics)
                + (activeLineage.hasConflict ? ["当前 lineage 存在 Tag 缺失或身份冲突，比较结果受限。"] : [])
        )).sorted()

        let availability: SnapshotHistoryAvailability
        if activeLineage.hasConflict {
            availability = .insufficient("当前历史身份存在冲突，无法进行完整比较。")
        } else if entries.count == 1 && entries[0].isBaseline {
            availability = .baselineOnly
        } else if diffs.isEmpty {
            availability = .insufficient("没有可比较的相邻快照。")
        } else if diffs.allSatisfy({
            $0.comparisonState != .comparable && $0.comparisonState != .provenanceOnly
        }) {
            availability = .insufficient("相邻快照覆盖不足，无法确认完整变化。")
        } else if rows.first?.comparisonState == .insufficientCoverage
                    || rows.first?.containsUncertainChanges == true {
            availability = .insufficient("最新相邻快照覆盖不足，部分变化仍待确认。")
        } else {
            availability = .available
        }

        let latestEntry = rows.first.flatMap { row in
            entries.first { $0.snapshotID == row.snapshotID }
        }
        let coverageTrustState = latestEntry.map {
            SnapshotCoverageTrustDisplayState.evaluate(coverage: $0.coverage)
        } ?? .insufficientCoverage

        let allProjection = SnapshotHistoryProjection(
            villageID: villageID,
            activeLineageID: activeLineage.lineageID,
            availability: availability,
            totalSnapshotCount: entries.count,
            latestAppliedAt: rows.map(\.appliedAt).max(),
            latestCheckedAt: rows.compactMap(\.lastSeenAt).max(),
            latestSummary: rows.first?.summary,
            timeline: rows,
            selectedCategory: .all,
            statistics: SnapshotHistoryStatistics.calculate(
                diffs: diffs,
                referenceDate: referenceDate,
                calendar: calendar,
                timeZone: timeZone
            ),
            diagnostics: diagnostics,
            coverageTrustState: coverageTrustState,
            unfilteredTimeline: rows
        )
        return allProjection.applying(category: selectedCategory)
    }

    public static func unavailable(
        villageID: UUID,
        hasCurrentSnapshot: Bool,
        availability: SnapshotHistoryAvailability,
        selectedCategory: SnapshotHistoryCategory = .all,
        referenceDate: Date = Date(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> SnapshotHistoryProjection {
        emptyProjection(
            villageID: villageID,
            availability: availability,
            selectedCategory: selectedCategory,
            referenceDate: referenceDate,
            calendar: calendar,
            timeZone: timeZone,
            diagnostics: hasCurrentSnapshot ? [] : ["当前村庄尚未导入账号快照。"]
        )
    }

    public func applying(category: SnapshotHistoryCategory) -> SnapshotHistoryProjection {
        guard category != .all else {
            return SnapshotHistoryProjection(
                villageID: villageID,
                activeLineageID: activeLineageID,
                availability: availability,
                totalSnapshotCount: totalSnapshotCount,
                latestAppliedAt: latestAppliedAt,
                latestCheckedAt: latestCheckedAt,
                latestSummary: latestSummary,
                timeline: unfilteredTimeline,
                selectedCategory: .all,
                statistics: statistics,
                diagnostics: diagnostics,
                coverageTrustState: coverageTrustState,
                unfilteredTimeline: unfilteredTimeline
            )
        }
        return SnapshotHistoryProjection(
            villageID: villageID,
            activeLineageID: activeLineageID,
            availability: availability,
            totalSnapshotCount: totalSnapshotCount,
            latestAppliedAt: latestAppliedAt,
            latestCheckedAt: latestCheckedAt,
            latestSummary: latestSummary,
            timeline: unfilteredTimeline.compactMap { $0.applying(category: category) },
            selectedCategory: category,
            statistics: statistics,
            diagnostics: diagnostics,
            coverageTrustState: coverageTrustState,
            unfilteredTimeline: unfilteredTimeline
        )
    }

    private static func emptyProjection(
        villageID: UUID,
        activeLineageID: UUID? = nil,
        availability: SnapshotHistoryAvailability,
        selectedCategory: SnapshotHistoryCategory,
        referenceDate: Date,
        calendar: Calendar,
        timeZone: TimeZone,
        diagnostics: [String] = []
    ) -> SnapshotHistoryProjection {
        SnapshotHistoryProjection(
            villageID: villageID,
            activeLineageID: activeLineageID,
            availability: availability,
            totalSnapshotCount: 0,
            latestAppliedAt: nil,
            latestCheckedAt: nil,
            latestSummary: nil,
            timeline: [],
            selectedCategory: selectedCategory,
            statistics: SnapshotHistoryStatistics.calculate(
                diffs: [],
                referenceDate: referenceDate,
                calendar: calendar,
                timeZone: timeZone
            ),
            diagnostics: diagnostics,
            coverageTrustState: .insufficientCoverage,
            unfilteredTimeline: []
        )
    }
}
