import Foundation

/// 手动跟踪部落档案的持久化容器（Issue #41）。
///
/// 存储格式：`TrackedClanProfile` 数组，**保持添加顺序**（UI 列表按序显示）。
/// 容错契约（仿 `OfficialStateStore`）：
/// - 解码逐条容错：一条损坏只丢弃该条，不株连整库；
/// - 坏条目用 `JSONSkipper` 强制推进解码游标；
/// - 整体损坏时抛错（调用方按空库处理）。
/// `clanTag` 是唯一键：`upsert` 已存在则替换、不存在则追加；`remove` 幂等。
public struct TrackedClanStore: Codable, Hashable, Sendable {
    public private(set) var profiles: [TrackedClanProfile]

    public init(profiles: [TrackedClanProfile] = []) {
        self.profiles = profiles
    }

    /// 按 tag 替换或追加（保持原位置；不存在时追加到末尾）。
    public mutating func upsert(_ profile: TrackedClanProfile) {
        if let index = profiles.firstIndex(where: { $0.clanTag == profile.clanTag }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// 删除指定 tag（幂等）。
    public mutating func remove(tag: String) {
        profiles.removeAll { $0.clanTag == tag }
    }

    // MARK: - Codable（逐条容错）

    // 演进约定：TrackedClanProfile 新增字段必须带默认值或使用 decodeIfPresent，
    // 否则旧存储条目解码失败会被 JSONSkipper 静默丢弃（容错机制把 schema
    // 错误变成整库静默数据丢失）。
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [TrackedClanProfile] = []
        var guardCounter = 0
        let maxEntries = 10_000
        while !container.isAtEnd && guardCounter < maxEntries {
            guardCounter += 1
            if let entry = try? container.decode(TrackedClanProfile.self) {
                decoded.append(entry)
            } else {
                _ = try? container.decode(JSONSkipper.self)
            }
        }
        profiles = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for profile in profiles {
            try container.encode(profile)
        }
    }
}
