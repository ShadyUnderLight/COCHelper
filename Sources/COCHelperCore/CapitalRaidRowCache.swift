import Foundation

/// Issue #221：突袭周末 row identity 生命周期缓存（ephemeral render sidecar）。
///
/// 在 #211 轻量 `tripleKey#seq` 之上补全 UI 行 identity 生命周期：
/// - load more 增量 append，旧行 ID 不变；
/// - refresh 仅做可证明匹配并更新 payload；
/// - duplicate/reorder 歧义时 bump generation 并 fail-closed 重建；
/// - View 只读取已维护好的 `rows`，不在 render path 重算或深比较 page。
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

    private var nextSequenceByTriple: [String: Int] = [:]

    public init() {}

    @discardableResult
    public func apply(_ update: Update) -> [CapitalRaidSeasonRow] {
        switch update {
        case .failureRetain:
            return rows
        case .clear:
            generation = 0
            rows = []
            nextSequenceByTriple = [:]
            return rows
        case .initial(let page), .parserRebuild(let page):
            resetAndBuild(from: page.items)
            return rows
        case .refreshSuccess(let page):
            reconcileRefresh(with: page.items)
            return rows
        case .loadMoreSuccess(let page):
            reconcileLoadMore(with: page.items)
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
            let oldPrefix = Array(rows.prefix(seasons.count))
            if canSafelyReconcile(oldRows: oldPrefix, newSeasons: seasons) {
                rows = matchedRows(oldRows: oldPrefix, newSeasons: seasons)
                syncNextSequenceFromRows()
                buildCount += 1
                return
            }
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

    private func syncNextSequenceFromRows() {
        nextSequenceByTriple = [:]
        for row in rows {
            let tripleKey = CapitalRaidRowIdentity.tripleKey(for: row.season)
            guard let seq = parseSequence(from: row.id) else { continue }
            nextSequenceByTriple[tripleKey] = max(nextSequenceByTriple[tripleKey, default: 0], seq + 1)
        }
    }

    private func parseSequence(from id: String) -> Int? {
        guard let hashIndex = id.lastIndex(of: "#") else { return nil }
        let suffix = id[id.index(after: hashIndex)...]
        return Int(suffix)
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

    /// 可证明匹配时返回 new 顺序下的旧 row ID；歧义时 nil（fail-closed）。
    private func canSafelyReconcile(
        oldRows: [CapitalRaidSeasonRow],
        newSeasons: [OfficialCapitalRaidSeason]
    ) -> Bool {
        matchRowIDs(oldRows: oldRows, newSeasons: newSeasons) != nil
    }

    private func matchedRows(
        oldRows: [CapitalRaidSeasonRow],
        newSeasons: [OfficialCapitalRaidSeason]
    ) -> [CapitalRaidSeasonRow] {
        guard let ids = matchRowIDs(oldRows: oldRows, newSeasons: newSeasons) else {
            return newSeasons.map { CapitalRaidSeasonRow(id: makeRow(for: $0).id, season: $0) }
        }
        return zip(ids, newSeasons).map { CapitalRaidSeasonRow(id: $0, season: $1) }
    }

    /// duplicate-triple group：先锚定完全相等的 entry，再处理 1↔1 剩余；2+↔2+ 视为歧义。
    private func matchRowIDs(
        oldRows: [CapitalRaidSeasonRow],
        newSeasons: [OfficialCapitalRaidSeason]
    ) -> [String]? {
        guard oldRows.count == newSeasons.count else { return nil }
        guard tripleKeyCounts(for: oldRows.map(\.season)) == tripleKeyCounts(for: newSeasons) else {
            return nil
        }

        var oldByTriple: [String: [(index: Int, row: CapitalRaidSeasonRow)]] = [:]
        var newByTriple: [String: [(index: Int, season: OfficialCapitalRaidSeason)]] = [:]
        for (index, row) in oldRows.enumerated() {
            let key = CapitalRaidRowIdentity.tripleKey(for: row.season)
            oldByTriple[key, default: []].append((index, row))
        }
        for (index, season) in newSeasons.enumerated() {
            let key = CapitalRaidRowIdentity.tripleKey(for: season)
            newByTriple[key, default: []].append((index, season))
        }

        var assignment: [Int: String] = [:]

        for triple in oldByTriple.keys.sorted() {
            guard let oldGroup = oldByTriple[triple], let newGroup = newByTriple[triple] else {
                return nil
            }
            guard oldGroup.count == newGroup.count else { return nil }

            if oldGroup.count == 1 {
                assignment[newGroup[0].index] = oldGroup[0].row.id
                continue
            }

            var unmatchedOld = oldGroup
            var unmatchedNew = newGroup

            var newIndex = 0
            while newIndex < unmatchedNew.count {
                let newEntry = unmatchedNew[newIndex]
                if let oldIndex = unmatchedOld.firstIndex(where: { $0.row.season == newEntry.season }) {
                    assignment[newEntry.index] = unmatchedOld[oldIndex].row.id
                    unmatchedOld.remove(at: oldIndex)
                    unmatchedNew.remove(at: newIndex)
                } else {
                    newIndex += 1
                }
            }

            if unmatchedOld.count == 1, unmatchedNew.count == 1 {
                assignment[unmatchedNew[0].index] = unmatchedOld[0].row.id
                continue
            }
            if !unmatchedOld.isEmpty {
                return nil
            }
        }

        guard assignment.count == newSeasons.count else { return nil }
        return newSeasons.indices.map { assignment[$0]! }
    }
}
