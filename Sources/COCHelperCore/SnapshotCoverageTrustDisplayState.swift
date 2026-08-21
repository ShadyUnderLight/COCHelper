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
            "全部 relevant section 已通过 adapter 重验证，可打开完整比较门禁。"
        case .pendingRevalidation:
            "历史保留了 verified 元数据，但尚未完成运行时信任恢复；比较结果保持保守。"
        case .insufficientCoverage:
            "存在 rejected、无 verified 证明或 section 不完整；不得把缺失变化当作确认删除。"
        }
    }

    package static func evaluate(coverage: SnapshotObservationCoverage) -> SnapshotCoverageTrustDisplayState {
        let sections = coverage.sections
        guard !sections.isEmpty else {
            return .insufficientCoverage
        }

        // Canonicalization materializes every known section so Diff can keep
        // absence fail-closed. A source adapter's trusted proof set is the
        // frozen relevant universe: an absent section with no proof is outside
        // that source, while an explicit proof or present section is relevant
        // and must still block verified display when it is not trusted.
        let relevantSections = sections.filter { section in
            section.proof.hasVerifiedWireMetadata
                || section.proof.isWellFormedDeclaration
                || section.presence != .missing
                || section.completeness != .unavailable
        }
        guard !relevantSections.isEmpty else {
            return .insufficientCoverage
        }

        func sectionBlocksVerifiedDisplay(_ section: SnapshotSectionCoverage) -> Bool {
            if !section.proof.hasVerifiedWireMetadata { return true }
            if section.completeness != .complete { return true }
            if case .rejected = section.runtimeTrust { return true }
            return false
        }

        if relevantSections.contains(where: sectionBlocksVerifiedDisplay) {
            return .insufficientCoverage
        }

        if relevantSections.contains(where: { $0.runtimeTrust == .pending }) {
            return .pendingRevalidation
        }

        if relevantSections.allSatisfy({ $0.runtimeTrust == .trusted }) {
            return .verified
        }

        return .insufficientCoverage
    }
}
