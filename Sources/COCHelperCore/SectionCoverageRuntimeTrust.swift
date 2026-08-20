import Foundation

/// Runtime trust state for one section coverage record (Issue #224).
///
/// Not serialized on the wire and not part of integrity material. Persisted
/// `.verified` wire metadata alone never opens destructive gates.
public enum SectionCoverageRuntimeTrust: Equatable, Sendable {
    case notApplicable
    case pending
    case trusted
    case rejected(String)

    public var opensTrustGates: Bool {
        self == .trusted
    }
}

/// Policy for which adapter revalidators may run during history load hydration.
public enum SnapshotCoverageRevalidationPolicy: Sendable {
    /// Production load: only adapters with replayable provenance (bundled perf fixtures).
    case production
    /// Test store: additionally allow controlled `test-fixture` revalidation.
    case testsAllowTestFixture
}
