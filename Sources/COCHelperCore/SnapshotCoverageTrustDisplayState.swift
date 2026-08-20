import Foundation

/// UI-facing trust label for persisted verified coverage (Issue #224).
public enum SnapshotCoverageTrustDisplayState: Equatable, Sendable {
    /// Runtime trust restored; destructive gates may open when completeness allows.
    case verified
    /// Wire verified metadata present but runtime trust not yet restored.
    case pendingRevalidation
    /// No trusted verified coverage (fail-closed / coverage incomplete).
    case insufficientCoverage

    public var title: String {
        switch self {
        case .verified:
            "覆盖证据：已验证"
        case .pendingRevalidation:
            "覆盖证据：待重新验证"
        case .insufficientCoverage:
            "覆盖证据：覆盖不足"
        }
    }

    public var detail: String {
        switch self {
        case .verified:
            "历史中的 verified section 已通过 adapter 重验证，可打开完整比较门禁。"
        case .pendingRevalidation:
            "历史保留了 verified 元数据，但尚未完成运行时信任恢复；比较结果保持保守。"
        case .insufficientCoverage:
            "缺少可信 verified 覆盖或 section 不完整；不得把缺失变化当作确认删除。"
        }
    }

    package static func evaluate(coverage: SnapshotObservationCoverage) -> SnapshotCoverageTrustDisplayState {
        let verifiedSections = coverage.sections.filter { $0.proof.hasVerifiedWireMetadata }
        guard !verifiedSections.isEmpty else {
            return .insufficientCoverage
        }
        if verifiedSections.contains(where: { $0.runtimeTrust == .pending }) {
            return .pendingRevalidation
        }
        if verifiedSections.contains(where: { $0.opensTrustGates }) {
            return .verified
        }
        return .insufficientCoverage
    }
}
