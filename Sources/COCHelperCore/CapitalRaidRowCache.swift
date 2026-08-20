import Foundation

/// Issue #221：突袭周末 row identity 生命周期缓存（ephemeral render sidecar）。
///
/// 在 #211 轻量 `tripleKey#seq` 之上补全 UI 行 identity 生命周期：
/// - load more 增量 append，旧行 ID 不变；
/// - refresh 仅做可证明匹配并更新 payload；
/// - duplicate/reorder 歧义时 bump generation 并 fail-closed 重建；
/// - View 重复读取同一 page 时不重复分配 row wrapper。
public final class CapitalRaidRowCache {
    /// 缓存更新语义（由 AppModel 在状态转换点调用）。
    public enum Update: Sendable {
        /// 冷启动 / 持久化 lastGood 恢复：新 generation，不做 previous 匹配。
        case initial(page: OfficialCapitalRaidPage)
        /// 首屏刷新成功（同 parser 版本）：尝试 reconcile，歧义则 reset。
        case refreshSuccess(page: OfficialCapitalRaidPage)
        /// 加载更多成功：prefix 匹配则 append，否则 reset。
        case loadMoreSuccess(page: OfficialCapitalRaidPage)
        /// 跨 parser 版本重建：明确 bump generation。
        case parserRebuild(page: OfficialCapitalRaidPage)
        /// 请求失败保留 last-good：row state 不变。
        case failureRetain
        /// 清除该 tag 的 ephemeral row state。
        case clear
    }

    public private(set) var generation: UInt64 = 0
    public private(set) var rows: [CapitalRaidSeasonRow] = []
    public private(set) var buildCount = 0
    public private(set) var hitCount = 0

    private var nextSequenceByTriple: [String: Int] = [:]
    private var cachedPage: OfficialCapitalRaidPage?

    public init() {}

    /// View 读取路径：同一 `OfficialCapitalRaidPage` 重复读取只计 hit，不重建。
    public func rows(for page: OfficialCapitalRaidPage) -> [CapitalRaidSeasonRow] {
        if let cachedPage, cachedPage == page {
            hitCount += 1
            return rows
        }
        _ = apply(.refreshSuccess(page: page))
        return rows
    }

    @discardableResult
    public func apply(_ update: Update) -> [CapitalRaidSeasonRow] {
        switch update {
        case .failureRetain:
            return rows
        case .clear:
            generation = 0
            rows = []
            nextSequenceByTriple = [:]
            cachedPage = nil
            return rows
        case .initial(let page), .parserRebuild(let page):
            resetAndBuild(from: page.items)
            cachedPage = page
            return rows
        case .refreshSuccess(let page):
            if let cachedPage, cachedPage == page {
                return rows
            }
            reconcileRefresh(with: page.items)
            cachedPage = page
            return rows
        case .loadMoreSuccess(let page):
            if let cachedPage, cachedPage == page {
                return rows
            }
            reconcileLoadMore(with: page.items)
            cachedPage = page
            return rows
        }
    }

    // MARK: - reconcile

    private func reconcileRefresh(with seasons: [OfficialCapitalRaidSeason]) {
        if rows.isEmpty {
            resetAndBuild(from: seasons)
            return
        }
        if seasons.count < rows.count {
            resetAndBuild(from: seasons)
            return
        }
        if seasons.count == rows.count {
            if canSafelyReconcile(oldRows: rows, newSeasons: seasons) {
                rows = matchedRows(oldRows: rows, newSeasons: seasons)
                buildCount += 1
                return
            }
            resetAndBuild(from: seasons)
            return
        }
        // refresh 不应返回比现有累计页更长的列表；保守 reset。
        resetAndBuild(from: seasons)
    }

    private func reconcileLoadMore(with seasons: [OfficialCapitalRaidSeason]) {
        if rows.isEmpty {
            resetAndBuild(from: seasons)
            return
        }
        if seasons.count == rows.count {
            if positionalTripleMatch(rows, seasons) {
                rows = zip(rows, seasons).map { CapitalRaidSeasonRow(id: $0.id, season: $1) }
                return
            }
            resetAndBuild(from: seasons)
            return
        }
        guard seasons.count > rows.count else {
            resetAndBuild(from: seasons)
            return
        }
        let prefix = Array(seasons.prefix(rows.count))
        guard positionalTripleMatch(rows, prefix) else {
            resetAndBuild(from: seasons)
            return
        }
        var updated = rows
        for season in seasons[rows.count...] {
            updated.append(makeRow(for: season))
        }
        rows = updated
        buildCount += 1
    }

    private func resetAndBuild(from seasons: [OfficialCapitalRaidSeason]) {
        generation &+= 1
        if generation == 0 { generation = 1 }
        nextSequenceByTriple = [:]
        rows = seasons.map(makeRow(for:))
        buildCount += 1
    }

    private func makeRow(for season: OfficialCapitalRaidSeason) -> CapitalRaidSeasonRow {
        let tripleKey = CapitalRaidRowIdentity.tripleKey(for: season)
        let seq = nextSequenceByTriple[tripleKey, default: 0]
        nextSequenceByTriple[tripleKey] = seq + 1
        let id = "raid:g\(generation):\(tripleKey)#\(seq)"
        return CapitalRaidSeasonRow(id: id, season: season)
    }

    private func positionalTripleMatch(
        _ oldRows: [CapitalRaidSeasonRow],
        _ newSeasons: [OfficialCapitalRaidSeason]
    ) -> Bool {
        guard oldRows.count == newSeasons.count else { return false }
        for (row, season) in zip(oldRows, newSeasons) {
            if CapitalRaidRowIdentity.tripleKey(for: row.season)
                != CapitalRaidRowIdentity.tripleKey(for: season) {
                return false
            }
        }
        return true
    }

    private func tripleKeyCounts(for seasons: [OfficialCapitalRaidSeason]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for season in seasons {
            let key = CapitalRaidRowIdentity.tripleKey(for: season)
            counts[key, default: 0] += 1
        }
        return counts
    }

    private func canSafelyReconcile(
        oldRows: [CapitalRaidSeasonRow],
        newSeasons: [OfficialCapitalRaidSeason]
    ) -> Bool {
        guard oldRows.count == newSeasons.count else { return false }

        let oldTriples = oldRows.map { CapitalRaidRowIdentity.tripleKey(for: $0.season) }
        let newTriples = newSeasons.map { CapitalRaidRowIdentity.tripleKey(for: $0) }
        guard oldTriples == newTriples else {
            let oldCounts = tripleKeyCounts(for: oldRows.map(\.season))
            let newCounts = tripleKeyCounts(for: newSeasons)
            guard oldCounts == newCounts else { return false }
            return oldCounts.values.allSatisfy { $0 == 1 }
        }

        let hasDuplicateTriples = tripleKeyCounts(for: newSeasons).values.contains { $0 > 1 }
        guard hasDuplicateTriples else { return true }

        // duplicate triple：若新位置的数据与另一旧行完全一致，视为重排/歧义 → fail-closed。
        for index in newSeasons.indices {
            if oldRows[index].season == newSeasons[index] { continue }
            let moved = oldRows.enumerated().contains { otherIndex, row in
                otherIndex != index
                    && CapitalRaidRowIdentity.tripleKey(for: row.season)
                        == CapitalRaidRowIdentity.tripleKey(for: newSeasons[index])
                    && row.season == newSeasons[index]
            }
            if moved { return false }
        }
        return true
    }

    private func matchedRows(
        oldRows: [CapitalRaidSeasonRow],
        newSeasons: [OfficialCapitalRaidSeason]
    ) -> [CapitalRaidSeasonRow] {
        let oldTriples = oldRows.map { CapitalRaidRowIdentity.tripleKey(for: $0.season) }
        let newTriples = newSeasons.map { CapitalRaidRowIdentity.tripleKey(for: $0) }
        if oldTriples == newTriples {
            return zip(oldRows, newSeasons).map { CapitalRaidSeasonRow(id: $0.id, season: $1) }
        }

        var idByTriple: [String: String] = [:]
        for row in oldRows {
            idByTriple[CapitalRaidRowIdentity.tripleKey(for: row.season)] = row.id
        }
        return newSeasons.map { season in
            let tripleKey = CapitalRaidRowIdentity.tripleKey(for: season)
            let id = idByTriple[tripleKey] ?? makeRow(for: season).id
            return CapitalRaidSeasonRow(id: id, season: season)
        }
    }
}
