import Foundation
@testable import COCHelperApp
@testable import COCHelperCore

/// In-memory adapters keep AppModel tests isolated from the user's real
/// Application Support directory while preserving the production contracts.
final class TestSnapshotHistoryStore: SnapshotHistoryStore, @unchecked Sendable {
    var transactionJournalURL: URL?
    var rawData: Data?
    var writeCount = 0
    var restoreCount = 0
    var failLoad = false
    var failRead = false
    var failWrite = false
    var writeBeforeFailure = false
    var failRestore = false

    init(
        envelope: SnapshotHistoryEnvelope? = nil,
        transactionJournalURL: URL? = nil
    ) {
        self.transactionJournalURL = transactionJournalURL
        self.rawData = envelope.flatMap { try? $0.encodedData() }
    }

    func load() throws -> SnapshotHistoryEnvelope? {
        if failLoad {
            throw SnapshotHistoryStoreError.unavailable("测试历史读取失败")
        }
        guard let rawData else { return nil }
        do {
            return try JSONDecoder().decode(SnapshotHistoryEnvelope.self, from: rawData)
                .validated()
                .hydratingVerifiedCoverage(policy: .testsAllowTestFixture)
        } catch let error as SnapshotHistoryStoreError {
            throw error
        } catch {
            throw SnapshotHistoryStoreError.corrupt(error.localizedDescription)
        }
    }

    func save(_ envelope: SnapshotHistoryEnvelope) throws {
        try writeRawData(envelope.encodedData())
    }

    func readRawData() throws -> Data? {
        if failRead {
            throw SnapshotHistoryStoreError.unavailable("测试历史原文读取失败")
        }
        return rawData
    }

    func writeRawData(_ data: Data) throws {
        writeCount += 1
        if failWrite {
            if writeBeforeFailure { rawData = data }
            throw SnapshotHistoryStoreError.writeFailed("测试历史写入失败")
        }
        rawData = data
    }

    func restoreRawData(_ data: Data?) throws {
        restoreCount += 1
        if failRestore {
            throw SnapshotHistoryStoreError.writeFailed("测试历史回滚失败")
        }
        rawData = data
    }
}

final class TestCurrentVillagePersistence: CurrentVillagePersistence, @unchecked Sendable {
    var data: Data?
    var writeCount = 0
    var restoreCount = 0
    var failWrite = false
    var writeBeforeFailure = false
    var failRestore = false

    init(data: Data? = nil) {
        self.data = data
    }

    func readData() -> Data? { data }

    func writeData(_ data: Data) throws {
        writeCount += 1
        if failWrite {
            if writeBeforeFailure { self.data = data }
            throw SnapshotHistoryStoreError.writeFailed("测试当前状态写入失败")
        }
        self.data = data
    }

    func restoreData(_ data: Data?) throws {
        restoreCount += 1
        if failRestore {
            throw SnapshotHistoryStoreError.writeFailed("测试当前状态回滚失败")
        }
        self.data = data
    }
}

enum SnapshotHistoryTestCoverage {
    static func verified(
        source: String = "test-export",
        expectedCount: Int? = nil
    ) -> SnapshotCoverageProof {
        SnapshotCoverageVerifier.issueTestFixture(
            source: source,
            expectedCount: expectedCount
        )
    }

    static func testFixtureUniverse(
        requiredSections: Set<String>
    ) -> SnapshotCoverageSourceUniverse {
        SnapshotCoverageSourceUniverseIssuer.issueTestFixture(requiredSections: requiredSections)
    }

    static func testFixtureUniverse(
        for sectionProofs: [String: SnapshotCoverageProof]
    ) -> SnapshotCoverageSourceUniverse {
        let required = Set(
            sectionProofs.compactMap { section, proof in
                SnapshotCoverageVerifier.validatesModuleIssuedProof(proof) ? section : nil
            }
        )
        return testFixtureUniverse(requiredSections: required)
    }

    /// Test helper: module-issued verified section with runtime trust restored.
    static func trustedSection(
        base: SnapshotHistoryBase,
        rawSection: String,
        presence: SnapshotSectionPresence,
        completeness: SnapshotCoverageState,
        proof: SnapshotCoverageProof? = nil,
        observedCount: Int
    ) -> SnapshotSectionCoverage {
        let resolvedProof = proof ?? verified()
        return SnapshotSectionCoverage.moduleIssued(
            base: base,
            rawSection: rawSection,
            presence: presence,
            completeness: completeness,
            proof: resolvedProof,
            observedCount: observedCount
        )
    }
}
