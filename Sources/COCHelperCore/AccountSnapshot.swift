import Foundation

public enum AccountDataDiagnosticSeverity: String, Codable, Hashable, Sendable, Identifiable {
    case info
    case warning

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .info: "提示"
        case .warning: "需要留意"
        }
    }
}

public struct AccountDataDiagnostic: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let severity: AccountDataDiagnosticSeverity
    public let path: String
    public let message: String

    public init(
        id: UUID = UUID(),
        severity: AccountDataDiagnosticSeverity,
        path: String,
        message: String
    ) {
        self.id = id
        self.severity = severity
        self.path = path
        self.message = message
    }
}

public enum AccountDurationFormatter {
    public static func label(_ seconds: Int64, zeroLabel: String = "已结束") -> String {
        guard seconds > 0 else { return zeroLabel }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return String(days) + "天 " + String(hours) + "小时" }
        if hours > 0 { return String(hours) + "小时 " + String(minutes) + "分钟" }
        if minutes > 0 { return String(minutes) + "分钟" }
        return "不足1分钟"
    }
}

public struct AccountItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let section: String
    public let dataID: Int64
    public let level: Int?
    public let count: Int?
    public let timerSeconds: Int64?
    public let remainingSeconds: Int64?
    public let helperTimerSeconds: Int64?
    public let remainingHelperSeconds: Int64?
    /// The raw value copied from the game export.
    public let helperCooldownSeconds: Int64?
    public let remainingHelperCooldownSeconds: Int64?
    public let helperRecurrent: Bool
    public let gearUp: Int?
    public let weapon: Int?
    public let types: [AccountItem]
    public let modules: [AccountItem]

    public init(
        id: String,
        section: String,
        dataID: Int64,
        level: Int? = nil,
        count: Int? = nil,
        timerSeconds: Int64? = nil,
        remainingSeconds: Int64? = nil,
        helperTimerSeconds: Int64? = nil,
        remainingHelperSeconds: Int64? = nil,
        helperCooldownSeconds: Int64? = nil,
        remainingHelperCooldownSeconds: Int64? = nil,
        helperRecurrent: Bool = false,
        gearUp: Int? = nil,
        weapon: Int? = nil,
        types: [AccountItem] = [],
        modules: [AccountItem] = []
    ) {
        self.id = id
        self.section = section
        self.dataID = dataID
        self.level = level
        self.count = count
        self.timerSeconds = timerSeconds
        self.remainingSeconds = remainingSeconds
        self.helperTimerSeconds = helperTimerSeconds
        self.remainingHelperSeconds = remainingHelperSeconds
        self.helperCooldownSeconds = helperCooldownSeconds
        self.remainingHelperCooldownSeconds = remainingHelperCooldownSeconds
        self.helperRecurrent = helperRecurrent
        self.gearUp = gearUp
        self.weapon = weapon
        self.types = types
        self.modules = modules
    }

    public var hasTimer: Bool { timerSeconds != nil }

    public var isActive: Bool {
        (remainingSeconds ?? 0) > 0
    }

    public var nestedItems: [AccountItem] {
        types + modules
    }

    public var rawIDLabel: String {
        "#" + String(dataID)
    }

    public var displayName: String? {
        AccountNameCatalog.bundled.name(for: section, dataID: dataID)
    }

    public var nameLabel: String {
        displayName ?? rawIDLabel
    }

    public var remainingTimeLabel: String? {
        guard let remainingSeconds else { return nil }
        return AccountDurationFormatter.label(remainingSeconds)
    }
}

public struct AccountSnapshot: Codable, Hashable, Sendable {
    public let tag: String?
    public let capturedAt: Date?
    public let importedAt: Date
    public let ageSeconds: Int64?
    public let originalText: String
    public let objectSections: [String: [AccountItem]]
    public let numericSections: [String: [Int64]]
    /// Values normalized to the import time; the raw export remains in `originalText`.
    public let boosts: [String: Int64]
    public let unknownTopLevelKeys: [String]
    public let diagnostics: [AccountDataDiagnostic]

    public init(
        tag: String?,
        capturedAt: Date?,
        importedAt: Date,
        ageSeconds: Int64?,
        originalText: String,
        objectSections: [String: [AccountItem]],
        numericSections: [String: [Int64]],
        boosts: [String: Int64],
        unknownTopLevelKeys: [String],
        diagnostics: [AccountDataDiagnostic]
    ) {
        self.tag = tag
        self.capturedAt = capturedAt
        self.importedAt = importedAt
        self.ageSeconds = ageSeconds
        self.originalText = originalText
        self.objectSections = objectSections
        self.numericSections = numericSections
        self.boosts = boosts
        self.unknownTopLevelKeys = unknownTopLevelKeys
        self.diagnostics = diagnostics
    }

    public var objectItemCount: Int {
        objectSections.values.reduce(0) { $0 + $1.count }
    }

    public var numericItemCount: Int {
        numericSections.values.reduce(0) { $0 + $1.count }
    }

    public var activeItemCount: Int {
        allObjectItems.filter(\.hasTimer).count
    }

    public var activeItems: [AccountItem] {
        allObjectItems.filter(\.hasTimer)
    }

    public var allObjectItems: [AccountItem] {
        objectSections.keys.sorted().flatMap { section in
            objectSections[section, default: []].flatMap(flatten)
        }
    }

    public var sectionNames: [String] {
        Set(objectSections.keys).union(numericSections.keys).sorted()
    }

    public var warningCount: Int {
        diagnostics.filter { $0.severity == .warning }.count
    }

    /// Top-level records belonging to the main village. The copied payload
    /// uses the `2` suffix for builder-base sections.
    public var mainVillageObjectItemCount: Int {
        objectSections
            .filter { !Self.isBuilderBaseSection($0.key) }
            .reduce(0) { $0 + $1.value.count }
    }

    public var builderBaseObjectItemCount: Int {
        objectSections
            .filter { Self.isBuilderBaseSection($0.key) }
            .reduce(0) { $0 + $1.value.count }
    }

    public var mainVillageActiveItemCount: Int {
        activeItems(inBuilderBase: false).count
    }

    public var builderBaseActiveItemCount: Int {
        activeItems(inBuilderBase: true).count
    }

    public func activeItems(inBuilderBase: Bool) -> [AccountItem] {
        allObjectItems.filter { item in
            item.hasTimer && Self.isBuilderBaseSection(item.section) == inBuilderBase
        }
    }

    private func flatten(_ item: AccountItem) -> [AccountItem] {
        [item] + item.nestedItems.flatMap(flatten)
    }

    private static func isBuilderBaseSection(_ section: String) -> Bool {
        section.hasSuffix("2")
    }
}

public enum AccountSnapshotImportError: Error, LocalizedError, Equatable, Sendable {
    case emptyInput
    case topLevelMustBeObject
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "没有可解析的文本。请先从游戏复制并粘贴 JSON。"
        case .topLevelMustBeObject:
            "JSON 顶层必须是对象，以 { 开头。"
        case .invalidJSON(let message):
            "JSON 解析失败：" + message
        }
    }
}

public enum AccountSnapshotImporter {
    public static let parserVersion = "account-json-0.1"

    public static func parse(_ text: String, now: Date = Date()) throws -> AccountSnapshot {
        let originalText = text
        let prepared = prepare(text)
        guard !prepared.text.isEmpty else { throw AccountSnapshotImportError.emptyInput }
        guard prepared.text.first == "{" else { throw AccountSnapshotImportError.topLevelMustBeObject }

        guard let data = prepared.text.data(using: .utf8) else {
            throw AccountSnapshotImportError.invalidJSON("文本不是有效的 UTF-8。")
        }

        let raw: RawAccountDocument
        do {
            raw = try JSONDecoder().decode(RawAccountDocument.self, from: data)
        } catch {
            throw AccountSnapshotImportError.invalidJSON(describe(error))
        }

        var diagnostics: [AccountDataDiagnostic] = []
        if prepared.removedCodeFence {
            diagnostics.append(AccountDataDiagnostic(
                severity: .info,
                path: "文本",
                message: "已忽略外围 Markdown 代码块标记。"
            ))
        }
        if raw.tag?.isEmpty != false {
            diagnostics.append(AccountDataDiagnostic(
                severity: .warning,
                path: "tag",
                message: "缺少账号标签，快照仍可读取。"
            ))
        }
        if raw.timestamp == nil {
            diagnostics.append(AccountDataDiagnostic(
                severity: .warning,
                path: "timestamp",
                message: "缺少快照时间，计时器将按原始值保留，无法自动扣除文本年龄。"
            ))
        }
        if !raw.unknownTopLevelKeys.isEmpty {
            diagnostics.append(AccountDataDiagnostic(
                severity: .warning,
                path: "顶层",
                message: "发现未识别字段：" + raw.unknownTopLevelKeys.sorted().joined(separator: "、")
            ))
        }
        if raw.objectSections.isEmpty && raw.numericSections.isEmpty && raw.boosts.isEmpty {
            diagnostics.append(AccountDataDiagnostic(
                severity: .warning,
                path: "顶层",
                message: "没有发现可读取的账号数据数组或加速状态。"
            ))
        }

        let nowSeconds = Int64(now.timeIntervalSince1970.rounded(.down))
        let ageSeconds: Int64?
        if let timestamp = raw.timestamp, timestamp > 0 {
            if timestamp > nowSeconds {
                diagnostics.append(AccountDataDiagnostic(
                    severity: .warning,
                    path: "timestamp",
                    message: "快照时间晚于当前时间，计时器不会被提前扣减。"
                ))
                ageSeconds = 0
            } else {
                ageSeconds = max(0, nowSeconds - timestamp)
            }
        } else {
            if raw.timestamp != nil {
                diagnostics.append(AccountDataDiagnostic(
                    severity: .warning,
                    path: "timestamp",
                    message: "快照时间无效，计时器将按原始值保留。"
                ))
            }
            ageSeconds = nil
        }

        let normalizedSections = raw.objectSections.map { section, items in
            (
                section,
                items.enumerated().map { index, item in
                    normalize(
                        item,
                        section: section,
                        path: String(index),
                        ageSeconds: ageSeconds,
                        diagnostics: &diagnostics
                    )
                }
            )
        }

        return AccountSnapshot(
            tag: raw.tag,
            capturedAt: raw.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            importedAt: now,
            ageSeconds: ageSeconds,
            originalText: originalText,
            objectSections: Dictionary(uniqueKeysWithValues: normalizedSections),
            numericSections: raw.numericSections,
            boosts: normalizedBoosts(
                raw.boosts,
                ageSeconds: ageSeconds,
                diagnostics: &diagnostics
            ),
            unknownTopLevelKeys: raw.unknownTopLevelKeys.sorted(),
            diagnostics: diagnostics
        )
    }

    private static func normalize(
        _ item: RawAccountItem,
        section: String,
        path: String,
        ageSeconds: Int64?,
        diagnostics: inout [AccountDataDiagnostic]
    ) -> AccountItem {
        let timer = adjustedTimer(
            item.timerSeconds,
            ageSeconds: ageSeconds,
            path: section + "[" + path + "].timer",
            diagnostics: &diagnostics
        )
        let helperTimer = adjustedTimer(
            item.helperTimerSeconds,
            ageSeconds: ageSeconds,
            path: section + "[" + path + "].helper_timer",
            diagnostics: &diagnostics
        )
        let helperCooldown = adjustedDuration(
            item.helperCooldownSeconds,
            ageSeconds: ageSeconds,
            path: section + "[" + path + "].helper_cooldown",
            diagnostics: &diagnostics
        )
        let types = item.types.enumerated().map { index, child in
            normalize(
                child,
                section: section,
                path: path + ".types." + String(index),
                ageSeconds: ageSeconds,
                diagnostics: &diagnostics
            )
        }
        let modules = item.modules.enumerated().map { index, child in
            normalize(
                child,
                section: section,
                path: path + ".modules." + String(index),
                ageSeconds: ageSeconds,
                diagnostics: &diagnostics
            )
        }

        return AccountItem(
            id: section + ":" + path,
            section: section,
            dataID: item.dataID,
            level: item.level,
            count: item.count,
            timerSeconds: timer.raw,
            remainingSeconds: timer.remaining,
            helperTimerSeconds: helperTimer.raw,
            remainingHelperSeconds: helperTimer.remaining,
            helperCooldownSeconds: item.helperCooldownSeconds,
            remainingHelperCooldownSeconds: helperCooldown,
            helperRecurrent: item.helperRecurrent,
            gearUp: item.gearUp,
            weapon: item.weapon,
            types: types,
            modules: modules
        )
    }

    private static func adjustedTimer(
        _ raw: Int64?,
        ageSeconds: Int64?,
        path: String,
        diagnostics: inout [AccountDataDiagnostic]
    ) -> (raw: Int64?, remaining: Int64?) {
        guard let raw else { return (nil, nil) }
        guard raw >= 0 else {
            diagnostics.append(AccountDataDiagnostic(
                severity: .warning,
                path: path,
                message: "计时器为负数，已按 0 秒处理。"
            ))
            return (raw, 0)
        }
        guard let ageSeconds else { return (raw, raw) }
        return (raw, max(0, raw - ageSeconds))
    }

    private static func normalizedBoosts(
        _ boosts: [String: Int64],
        ageSeconds: Int64?,
        diagnostics: inout [AccountDataDiagnostic]
    ) -> [String: Int64] {
        var normalized: [String: Int64] = [:]
        for key in boosts.keys.sorted() {
            normalized[key] = adjustedDuration(
                boosts[key],
                ageSeconds: ageSeconds,
                path: "boosts." + key,
                diagnostics: &diagnostics
            ) ?? 0
        }
        return normalized
    }

    private static func adjustedDuration(
        _ raw: Int64?,
        ageSeconds: Int64?,
        path: String,
        diagnostics: inout [AccountDataDiagnostic]
    ) -> Int64? {
        guard let raw else { return nil }
        guard raw >= 0 else {
            diagnostics.append(AccountDataDiagnostic(
                severity: .warning,
                path: path,
                message: "时长为负数，已按 0 秒处理。"
            ))
            return 0
        }
        guard let ageSeconds else { return raw }
        return max(0, raw - ageSeconds)
    }

    /// 去除 Markdown code fence 并清理首尾空白。
    /// internal:同时被 `SnapshotHistoryCanonicalizer` 与
    /// `JSONSnapshotCoverageAdapter` 复用,保证所有消费者对同一
    /// originalText 使用完全相同的清洗语义。
    static func prepare(_ text: String) -> (text: String, removedCodeFence: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3,
              lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespaces) == "```"
        else {
            return (trimmed, false)
        }
        return (
            lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            true
        )
    }

    private static func describe(_ error: Error) -> String {
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .keyNotFound(let key, let context):
                return "缺少字段 " + key.stringValue + "（" + context.debugDescription + "）。"
            case .typeMismatch(_, let context):
                return context.debugDescription + "。"
            case .valueNotFound(_, let context):
                return context.debugDescription + "。"
            case .dataCorrupted(let context):
                return context.debugDescription + "。"
            @unknown default:
                break
            }
        }
        return error.localizedDescription
    }
}

private struct RawAccountDocument: Decodable {
    let tag: String?
    let timestamp: Int64?
    let objectSections: [String: [RawAccountItem]]
    let numericSections: [String: [Int64]]
    let boosts: [String: Int64]
    let unknownTopLevelKeys: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var tag: String?
        var timestamp: Int64?
        var objectSections: [String: [RawAccountItem]] = [:]
        var numericSections: [String: [Int64]] = [:]
        var boosts: [String: Int64] = [:]
        var unknownTopLevelKeys: [String] = []

        for key in container.allKeys {
            let name = key.stringValue
            switch name {
            case "tag":
                tag = try container.decodeIfPresent(String.self, forKey: key)
            case "timestamp":
                timestamp = try Self.decodeInt64(container, forKey: key)
            case "boosts":
                boosts = try container.decodeIfPresent([String: Int64].self, forKey: key) ?? [:]
            default:
                if Self.objectSectionNames.contains(name) {
                    objectSections[name] = try container.decodeIfPresent([RawAccountItem].self, forKey: key) ?? []
                } else if Self.numericSectionNames.contains(name) {
                    numericSections[name] = try container.decodeIfPresent([Int64].self, forKey: key) ?? []
                } else {
                    unknownTopLevelKeys.append(name)
                }
            }
        }

        self.tag = tag
        self.timestamp = timestamp
        self.objectSections = objectSections
        self.numericSections = numericSections
        self.boosts = boosts
        self.unknownTopLevelKeys = unknownTopLevelKeys
    }

    private static let objectSectionNames: Set<String> = [
        "helpers", "guardians", "buildings", "traps", "decos", "obstacles", "units",
        "siege_machines", "heroes", "spells", "pets", "equipment", "buildings2", "traps2",
        "decos2", "obstacles2", "units2", "heroes2"
    ]

    private static let numericSectionNames: Set<String> = [
        "house_parts", "skins", "sceneries", "skins2", "sceneries2"
    ]

    private static func decodeInt64(
        _ container: KeyedDecodingContainer<DynamicCodingKey>,
        forKey key: DynamicCodingKey
    ) throws -> Int64? {
        guard container.contains(key) else { return nil }
        if let value = try? container.decode(Int64.self, forKey: key) { return value }
        if let value = try? container.decode(Double.self, forKey: key),
           value.isFinite,
           value.rounded() == value,
           let parsed = Int64(exactly: value) {
            return parsed
        }
        if let value = try? container.decode(String.self, forKey: key), let parsed = Int64(value) {
            return parsed
        }
        throw DecodingError.typeMismatch(
            Int64.self,
            DecodingError.Context(codingPath: container.codingPath + [key], debugDescription: "字段必须是整数。")
        )
    }
}

private struct RawAccountItem: Decodable {
    let dataID: Int64
    let level: Int?
    let count: Int?
    let timerSeconds: Int64?
    let helperTimerSeconds: Int64?
    let helperCooldownSeconds: Int64?
    let helperRecurrent: Bool
    let gearUp: Int?
    let weapon: Int?
    let types: [RawAccountItem]
    let modules: [RawAccountItem]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dataID = try container.decode(Int64.self, forKey: .data)
        level = try container.decodeIfPresent(Int.self, forKey: .level)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
        timerSeconds = try container.decodeIfPresent(Int64.self, forKey: .timer)
        helperTimerSeconds = try container.decodeIfPresent(Int64.self, forKey: .helperTimer)
        helperCooldownSeconds = try container.decodeIfPresent(Int64.self, forKey: .helperCooldown)
        helperRecurrent = try container.decodeIfPresent(Bool.self, forKey: .helperRecurrent) ?? false
        gearUp = try container.decodeIfPresent(Int.self, forKey: .gearUp)
        weapon = try container.decodeIfPresent(Int.self, forKey: .weapon)
        types = try container.decodeIfPresent([RawAccountItem].self, forKey: .types) ?? []
        modules = try container.decodeIfPresent([RawAccountItem].self, forKey: .modules) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case data
        case level = "lvl"
        case count = "cnt"
        case timer
        case helperTimer = "helper_timer"
        case helperCooldown = "helper_cooldown"
        case helperRecurrent = "helper_recurrent"
        case gearUp = "gear_up"
        case weapon
        case types
        case modules
    }
}

private struct DynamicCodingKey: CodingKey, Hashable {
    let stringValue: String

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    let intValue: Int? = nil

    init?(intValue: Int) {
        return nil
    }
}
