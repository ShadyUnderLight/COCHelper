import Foundation

/// Issue #173 / #205 source coverage contract。
///
/// 来源契约(可冻结、可审计):
/// - 账号 JSON 顶层可选的 `coverage` 字段声明各 section 的完整性证明。
/// - Pasted JSON 只能产出 `declared` proof,永远不能产出 `verified`。
/// - 没有 `coverage` 字段、字段类型无效、section 未提及或声明不可解码的,
///   一律 fail-closed 为 `unavailable`。
/// - `expectedCount` 与 observed 不一致时的 partial 降级由
///   `SnapshotHistoryCanonicalizer` 在 canonicalize 时完成(仅 verified proof)。
/// - 未来受信任 adapter 通过 module/package 内部受控代码路径注入 `verified` proof。
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
        guard JSONSerialization.isValidJSONObject(declaration),
              let object = declaration as? [String: Any],
              let kind = object["kind"] as? String else {
            return .unavailable(reason: "section 完整性声明无法解析：\(section)。")
        }
        switch kind {
        case "unavailable":
            guard let reason = object["reason"] as? String else {
                return .unavailable(
                    reason: "section 完整性声明不可解码，按无证明处理：\(section)。"
                )
            }
            return .unavailable(reason: reason)
        case "verified":
            return .unavailable(
                reason: "粘贴 JSON 不能声明已验证完整性，按无证明处理：\(section)。"
            )
        case "authoritative", "declared":
            guard let source = object["source"] as? String,
                  let version = object["version"] as? String else {
                return .unavailable(
                    reason: "section 完整性声明不可解码，按无证明处理：\(section)。"
                )
            }
            let expectedCount = object["expectedCount"] as? Int
            let proof = SnapshotCoverageProof.declared(
                source: source,
                version: version,
                expectedCount: expectedCount
            )
            guard proof.isWellFormedDeclaration else {
                return .unavailable(
                    reason: "section 完整性声明格式无效，按无证明处理：\(section)。"
                )
            }
            return proof
        default:
            return .unavailable(
                reason: "section 完整性声明类型无效，按无证明处理：\(section)。"
            )
        }
    }

    private static func topLevelObject(of text: String) throws -> [String: Any] {
        let prepared = AccountSnapshotImporter.prepare(text).text
        guard let data = prepared.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SnapshotHistoryCanonicalizationError.invalidJSON("顶层必须是 JSON 对象。")
        }
        return object
    }
}
