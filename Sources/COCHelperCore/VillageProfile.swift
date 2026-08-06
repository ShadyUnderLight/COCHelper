import Foundation

/// One independently tracked Clash of Clans account.
///
/// The imported snapshot is the source of truth for this local tracker. The
/// old planner input field was intentionally removed; old persisted village
/// JSON remains decodable because unknown fields are ignored by Codable.
public struct VillageProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var accountSnapshot: AccountSnapshot?
    /// 官方 API 玩家快照（独立来源，与本地导入 JSON 并存，互不覆盖）。
    /// Optional 保证旧版持久化数据（无此键）仍可解码为 nil。
    public var officialAPIState: OfficialAPIState?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        accountSnapshot: AccountSnapshot? = nil,
        officialAPIState: OfficialAPIState? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.isEmpty ? "未命名村庄" : trimmedName
        self.accountSnapshot = accountSnapshot
        self.officialAPIState = officialAPIState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var tag: String? {
        accountSnapshot?.tag
    }

    /// 规范化且格式有效的官方 tag；缺 tag 或格式无效返回 nil（UI 显示为 skipped）。
    public var officialTag: String? {
        guard let normalized = OfficialTagValidator.normalized(tag),
              OfficialTagValidator.isValid(normalized) else {
            return nil
        }
        return normalized
    }

    public var identityLabel: String {
        tag ?? "尚未导入 JSON"
    }

    public var hasImportedData: Bool {
        accountSnapshot != nil
    }

    /// 应用一个新的导入快照；若账号 tag 变化（含变为缺失），官方数据不再适用于
    /// 本村庄，必须重置，避免在详情中展示旧账号的官方资料。
    public mutating func applyImportedSnapshot(_ snapshot: AccountSnapshot) {
        let tagChanged = OfficialTagValidator.normalized(tag)
            != OfficialTagValidator.normalized(snapshot.tag)
        accountSnapshot = snapshot
        if tagChanged {
            officialAPIState = nil
        }
    }

    /// 异步刷新结果写回前的竞态校验：发起请求时的 tag 必须仍与当前村庄匹配。
    /// tag 变化（重导入/清除快照）后，过期请求的结果必须丢弃。
    public func officialStateMatchesTag(at requestTimeTag: String?) -> Bool {
        officialTag == requestTimeTag
    }
}
