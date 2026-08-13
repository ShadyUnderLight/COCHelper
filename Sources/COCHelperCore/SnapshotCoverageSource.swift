import Foundation

/// Issue #173 source coverage contract。
///
/// 来源契约(可冻结、可审计):
/// - 账号 JSON 顶层可选的 `coverage` 字段声明各 section 的完整性证明,
///   值为 `SnapshotCoverageProof` 的 Codable 编码:
///   `{"kind": "authoritative", "source": ..., "version": ..., "expectedCount": ...}`
///   或 `{"kind": "unavailable", "reason": ...}`。
/// - 没有 `coverage` 字段、字段类型无效、section 未提及或声明不可解码的,
///   一律 fail-closed 为 `unavailable`。adapter 不根据数组存在、空数组、
///   当前目录或当前时间推断完整性;expectedCount 与 observed 不一致时的
///   partial 降级由 `SnapshotHistoryCanonicalizer` 在 canonicalize 时完成。
/// - 未来官方 API snapshot adapter 复用同一 `[String: SnapshotCoverageProof]`
///   输出契约,由各自来源显式产生证明。
public enum JSONSnapshotCoverageAdapter {
    /// 顶层声明字段名。
    public static let contractField = "coverage"

    /// 从账号 JSON 提取各 section 的 coverage proof。
    ///
    /// 返回的字典覆盖全部 known sections;未声明或声明无效的 section
    /// 返回带诊断的 `unavailable`(fail-closed)。
    public static func proofs(for snapshot: AccountSnapshot) -> [String: SnapshotCoverageProof] {
        let fallback = "账号 JSON 未声明 section 完整性协议(缺少顶层 coverage 字段)。"
        guard let topLevel = try? topLevelObject(of: snapshot.originalText) else {
            return unavailableProofs(reason: fallback)
        }
        guard let rawCoverage = topLevel[contractField] else {
            return unavailableProofs(reason: fallback)
        }
        guard let coverage = rawCoverage as? [String: Any] else {
            return unavailableProofs(
                reason: "账号 JSON 顶层 coverage 字段类型无效，无法作为完整性协议使用。"
            )
        }

        var proofs: [String: SnapshotCoverageProof] = [:]
        for section in SnapshotHistoryKnownSections.all.sorted() {
            guard let declaration = coverage[section] else {
                proofs[section] = .unavailable(
                    reason: "来源未声明 section 的完整性：\(section)。"
                )
                continue
            }
            proofs[section] = decode(declaration, section: section)
        }
        return proofs
    }

    private static func unavailableProofs(reason: String) -> [String: SnapshotCoverageProof] {
        var proofs: [String: SnapshotCoverageProof] = [:]
        for section in SnapshotHistoryKnownSections.all.sorted() {
            proofs[section] = .unavailable(reason: reason)
        }
        return proofs
    }

    private static func decode(
        _ declaration: Any,
        section: String
    ) -> SnapshotCoverageProof {
        guard JSONSerialization.isValidJSONObject(declaration) else {
            return .unavailable(reason: "section 完整性声明无法解析：\(section)。")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: declaration)
            return try JSONDecoder().decode(SnapshotCoverageProof.self, from: data)
        } catch {
            return .unavailable(
                reason: "section 完整性声明不可解码，按无证明处理：\(section)。"
            )
        }
    }

    private static func topLevelObject(of text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SnapshotHistoryCanonicalizationError.invalidJSON("顶层必须是 JSON 对象。")
        }
        return object
    }
}
