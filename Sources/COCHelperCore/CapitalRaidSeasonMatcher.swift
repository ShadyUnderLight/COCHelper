import Foundation

/// Issue #230/#231：Capital Raid 赛季 identity 匹配（refresh / load-more overlap 共用）。
enum CapitalRaidSeasonMatcher {
    /// boundary overlap 候选的匹配分类（load-more 专用）。
    enum BoundaryOverlapMatch: Equatable {
        /// suffix/prefix 可证明一一映射。
        case matched
        /// 是 overlap 候选，但 duplicate-triple 等无法证明对应关系。
        case ambiguous
        /// 不是有效 overlap 窗口（如 triple multiset 不一致），可尝试更短 overlap。
        case notCandidate
    }

    /// 等长 suffix/prefix 的 boundary overlap 分类。
    static func classifyBoundaryOverlap(
        oldSeasons: [OfficialCapitalRaidSeason],
        newSeasons: [OfficialCapitalRaidSeason]
    ) -> BoundaryOverlapMatch {
        guard oldSeasons.count == newSeasons.count else { return .notCandidate }
        guard tripleKeyCounts(for: oldSeasons) == tripleKeyCounts(for: newSeasons) else {
            return .notCandidate
        }
        if matchOldIndices(oldSeasons: oldSeasons, newSeasons: newSeasons) != nil {
            return .matched
        }
        return .ambiguous
    }

    /// 等长列表能否安全建立 old ↔ new 映射。
    static func canSafelyMatch(
        oldSeasons: [OfficialCapitalRaidSeason],
        newSeasons: [OfficialCapitalRaidSeason]
    ) -> Bool {
        matchOldIndices(oldSeasons: oldSeasons, newSeasons: newSeasons) != nil
    }

    /// 可证明匹配时返回 `result[newIndex] = oldIndex`；歧义时 nil（fail-closed）。
    static func matchOldIndices(
        oldSeasons: [OfficialCapitalRaidSeason],
        newSeasons: [OfficialCapitalRaidSeason]
    ) -> [Int]? {
        guard oldSeasons.count == newSeasons.count else { return nil }
        guard tripleKeyCounts(for: oldSeasons) == tripleKeyCounts(for: newSeasons) else {
            return nil
        }

        var oldByTriple: [String: [(index: Int, season: OfficialCapitalRaidSeason)]] = [:]
        var newByTriple: [String: [(index: Int, season: OfficialCapitalRaidSeason)]] = [:]
        for (index, season) in oldSeasons.enumerated() {
            let key = CapitalRaidRowIdentity.tripleKey(for: season)
            oldByTriple[key, default: []].append((index, season))
        }
        for (index, season) in newSeasons.enumerated() {
            let key = CapitalRaidRowIdentity.tripleKey(for: season)
            newByTriple[key, default: []].append((index, season))
        }

        var assignment: [Int: Int] = [:]

        for triple in oldByTriple.keys.sorted() {
            guard let oldGroup = oldByTriple[triple], let newGroup = newByTriple[triple] else {
                return nil
            }
            guard oldGroup.count == newGroup.count else { return nil }

            if oldGroup.count == 1 {
                assignment[newGroup[0].index] = oldGroup[0].index
                continue
            }

            guard matchDuplicateTripleGroup(
                oldGroup: oldGroup,
                newGroup: newGroup,
                assignment: &assignment
            ) else {
                return nil
            }
        }

        guard assignment.count == newSeasons.count else { return nil }
        return newSeasons.indices.map { assignment[$0]! }
    }

    /// 截短 refresh matcher：new 更短时仍用完整 old 列表判断 duplicate 歧义。
    static func matchTruncatedRefreshOldIndices(
        oldSeasons: [OfficialCapitalRaidSeason],
        newSeasons: [OfficialCapitalRaidSeason]
    ) -> [Int]? {
        guard !newSeasons.isEmpty else { return nil }

        var oldByTriple: [String: [(index: Int, season: OfficialCapitalRaidSeason)]] = [:]
        var newByTriple: [String: [(index: Int, season: OfficialCapitalRaidSeason)]] = [:]
        for (index, season) in oldSeasons.enumerated() {
            let key = CapitalRaidRowIdentity.tripleKey(for: season)
            oldByTriple[key, default: []].append((index, season))
        }
        for (index, season) in newSeasons.enumerated() {
            let key = CapitalRaidRowIdentity.tripleKey(for: season)
            newByTriple[key, default: []].append((index, season))
        }

        var assignment: [Int: Int] = [:]

        for triple in newByTriple.keys.sorted() {
            guard let oldGroup = oldByTriple[triple], let newGroup = newByTriple[triple] else {
                return nil
            }
            if newGroup.count > oldGroup.count { return nil }

            if newGroup.count == oldGroup.count {
                if oldGroup.count == 1 {
                    assignment[newGroup[0].index] = oldGroup[0].index
                } else {
                    guard matchDuplicateTripleGroup(
                        oldGroup: oldGroup,
                        newGroup: newGroup,
                        assignment: &assignment
                    ) else {
                        return nil
                    }
                }
            } else {
                guard matchTruncatedDuplicateTripleGroup(
                    oldGroup: oldGroup,
                    newGroup: newGroup,
                    assignment: &assignment
                ) else {
                    return nil
                }
            }
        }

        guard assignment.count == newSeasons.count else { return nil }
        return newSeasons.indices.map { assignment[$0]! }
    }

    private static func tripleKeyCounts(for seasons: [OfficialCapitalRaidSeason]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for season in seasons {
            let key = CapitalRaidRowIdentity.tripleKey(for: season)
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// duplicate triple 在截短 refresh 中数量减少：仅唯一 exact payload anchor 可保留映射。
    private static func matchTruncatedDuplicateTripleGroup(
        oldGroup: [(index: Int, season: OfficialCapitalRaidSeason)],
        newGroup: [(index: Int, season: OfficialCapitalRaidSeason)],
        assignment: inout [Int: Int]
    ) -> Bool {
        guard newGroup.count < oldGroup.count else { return false }

        var unmatchedOld = oldGroup
        var unmatchedNew = newGroup

        while true {
            var foundAnchor = false
            var stillUnmatchedNew: [(index: Int, season: OfficialCapitalRaidSeason)] = []

            for newEntry in unmatchedNew {
                let season = newEntry.season
                let newOccurrences = occurrenceCount(of: season, in: unmatchedNew.map(\.season))
                guard newOccurrences == 1 else {
                    stillUnmatchedNew.append(newEntry)
                    continue
                }
                let oldMatchIndices = unmatchedOld.indices.filter {
                    unmatchedOld[$0].season == season
                }
                guard oldMatchIndices.count == 1 else {
                    stillUnmatchedNew.append(newEntry)
                    continue
                }
                assignment[newEntry.index] = unmatchedOld[oldMatchIndices[0]].index
                unmatchedOld.remove(at: oldMatchIndices[0])
                foundAnchor = true
            }
            unmatchedNew = stillUnmatchedNew
            if !foundAnchor { break }
        }

        return unmatchedNew.isEmpty
    }

    /// duplicate triple group：位置全等则按位保留；否则仅唯一 exact payload 可 anchor。
    private static func matchDuplicateTripleGroup(
        oldGroup: [(index: Int, season: OfficialCapitalRaidSeason)],
        newGroup: [(index: Int, season: OfficialCapitalRaidSeason)],
        assignment: inout [Int: Int]
    ) -> Bool {
        let oldSorted = oldGroup.sorted { $0.index < $1.index }
        let newSorted = newGroup.sorted { $0.index < $1.index }
        if oldSorted.count == newSorted.count,
           zip(oldSorted, newSorted).allSatisfy({
               $0.index == $1.index && $0.season == $1.season
           }) {
            for (oldEntry, newEntry) in zip(oldSorted, newSorted) {
                assignment[newEntry.index] = oldEntry.index
            }
            return true
        }

        var unmatchedOld = oldGroup
        var unmatchedNew = newGroup

        while true {
            var foundAnchor = false
            var stillUnmatchedNew: [(index: Int, season: OfficialCapitalRaidSeason)] = []

            for newEntry in unmatchedNew {
                let season = newEntry.season
                let newOccurrences = occurrenceCount(of: season, in: unmatchedNew.map(\.season))
                guard newOccurrences == 1 else {
                    stillUnmatchedNew.append(newEntry)
                    continue
                }
                let oldMatchIndices = unmatchedOld.indices.filter {
                    unmatchedOld[$0].season == season
                }
                guard oldMatchIndices.count == 1 else {
                    stillUnmatchedNew.append(newEntry)
                    continue
                }
                assignment[newEntry.index] = unmatchedOld[oldMatchIndices[0]].index
                unmatchedOld.remove(at: oldMatchIndices[0])
                foundAnchor = true
            }
            unmatchedNew = stillUnmatchedNew
            if !foundAnchor { break }
        }

        if unmatchedOld.isEmpty, unmatchedNew.isEmpty { return true }
        if unmatchedOld.count == 1, unmatchedNew.count == 1 {
            assignment[unmatchedNew[0].index] = unmatchedOld[0].index
            return true
        }
        return false
    }

    /// overlap suffix/prefix 是否存在唯一 exact payload boundary anchor（可跳过 prior-count 防误判）。
    static func hasUniqueExactPayloadBoundaryAnchor(
        oldSeasons: [OfficialCapitalRaidSeason],
        newSeasons: [OfficialCapitalRaidSeason],
        overlap: Int
    ) -> Bool {
        guard overlap > 0,
              oldSeasons.count >= overlap,
              newSeasons.count >= overlap else {
            return false
        }
        let suffixStart = oldSeasons.count - overlap
        let prefix = Array(newSeasons.prefix(overlap))
        for (prefixIndex, newSeason) in prefix.enumerated() {
            let exactMatchIndices = oldSeasons.indices.filter { oldSeasons[$0] == newSeason }
            guard exactMatchIndices.count == 1 else { continue }
            let matchedIndex = exactMatchIndices[0]
            guard matchedIndex == suffixStart + prefixIndex else { continue }
            return true
        }
        return false
    }

    private static func occurrenceCount(
        of season: OfficialCapitalRaidSeason,
        in seasons: [OfficialCapitalRaidSeason]
    ) -> Int {
        var count = 0
        for candidate in seasons where candidate == season {
            count += 1
        }
        return count
    }
}
