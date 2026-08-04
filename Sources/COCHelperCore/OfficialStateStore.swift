import Foundation

/// 官方共享数据层的**泛型持久化容器**（Issue #7 stage 3c 泛化前置承诺）。
///
/// 3a/3b 的 `ClanStateStore`/`ClanWarStateStore` 是同构拷贝，泛化为单一实现；
/// 旧类型保留为 typealias（**编码格式完全一致**：单元素字典数组 + 逐条容错，
/// 旧持久化数据兼容）。
///
/// 容错契约（与旧实现逐字一致）：
/// - 存储格式为单元素字典数组（`[ [tag: state], ... ]`），解码时**逐条容错**：
///   一条记录损坏只丢弃该条，不株连整库。
/// - 坏条目时用 `JSONSkipper`（任意 JSON 值都解码成功）强制推进解码游标
///   （JSONDecoder 在元素解码失败时不推进游标）。
/// - 空字典条目 `{}` 是 decode 成功但无有效键：丢弃自身，不得执行 skip
///   （否则会吞掉下一个好条目——3a 修复过的缺陷）。
/// - `merging` 语义：只覆盖本次请求过的 tag，未请求的旧数据保留。
public struct OfficialStateStore<State: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public private(set) var states: [String: State]

    public init(states: [String: State] = [:]) {
        self.states = states
    }

    /// 覆盖 `refreshed` 中的 tag，其余保留。
    public func merging(_ refreshed: [String: State]) -> OfficialStateStore<State> {
        var merged = states
        for (tag, state) in refreshed {
            merged[tag] = state
        }
        return OfficialStateStore(states: merged)
    }

    // MARK: - Codable（逐条容错）

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [String: State] = [:]
        var guardCounter = 0
        let maxEntries = 10_000
        while !container.isAtEnd && guardCounter < maxEntries {
            guardCounter += 1
            if let entry = try? container.decode([String: State].self) {
                // decode 成功（游标已推进）：空字典条目 `{}` 丢弃自身，
                // 不得执行 skip（会吞掉下一个好条目）。
                if let (tag, state) = entry.first {
                    decoded[tag] = state
                }
            } else {
                // 坏条目：JSONDecoder 在元素解码失败时不推进游标，
                // 用 JSONSkipper 强制消费该元素。
                _ = try? container.decode(JSONSkipper.self)
            }
        }
        states = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for tag in states.keys.sorted() {
            try container.encode([tag: states[tag]!])
        }
    }
}

// MARK: - 各端点 store typealias（保持既有 API）

public typealias ClanStateStore = OfficialStateStore<ClanAPIState>
public typealias ClanWarStateStore = OfficialStateStore<ClanWarAPIState>
public typealias ClanWarLogStateStore = OfficialStateStore<ClanWarLogAPIState>
public typealias ClanCapitalStateStore = OfficialStateStore<ClanCapitalAPIState>

/// 任意 JSON 值（bool/string/number/array/object/null）都能解码成功的哨兵类型，
/// 用于跳过损坏条目时保证解码游标推进。
struct JSONSkipper: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode([String: JSONSkipper].self)) != nil { return }
        if (try? container.decode([JSONSkipper].self)) != nil { return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "无法识别的 JSON 值"
        )
    }
}
