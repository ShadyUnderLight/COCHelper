import XCTest
@testable import COCHelperCore

/// Issue #145：本地队列类别 / 容量配置 / 占用摘要的纯模型契约。
final class LocalQueueCapacityTests: XCTestCase {
    private let villageID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // MARK: - LocalQueueKind

    func testQueueKindKnownCategories() {
        XCTAssertTrue(LocalQueueKind.builder.isKnown)
        XCTAssertTrue(LocalQueueKind.laboratory.isKnown)
        XCTAssertTrue(LocalQueueKind.hero.isKnown)
        XCTAssertTrue(LocalQueueKind.equipment.isKnown)
        XCTAssertEqual(LocalQueueKind.knownKinds, [.builder, .laboratory, .hero, .equipment])
        XCTAssertEqual(LocalQueueKind.builder.displayName, "建筑工人")
    }

    func testQueueKindUnknownRawValueIsNotKnown() {
        let kind = LocalQueueKind(rawValue: "forge")
        XCTAssertFalse(kind.isKnown)
        XCTAssertEqual(kind.rawValue, "forge")
        XCTAssertEqual(kind.description, "forge")
    }

    func testQueueKindCodableUsesRawString() throws {
        let data = try JSONEncoder().encode(LocalQueueKind.builder)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"builder\"")
        let decoded = try JSONDecoder().decode(LocalQueueKind.self, from: data)
        XCTAssertEqual(decoded, .builder)
    }

    func testQueueKindRawValueMatchesRecordFreeString() {
        // ManualUpgradeRecord.queueKind 是自由字符串（#139），必须按 rawValue 匹配。
        XCTAssertEqual(LocalQueueKind.builder.rawValue, "builder")
        XCTAssertEqual(LocalQueueKind.laboratory.rawValue, "laboratory")
        XCTAssertEqual(LocalQueueKind.hero.rawValue, "hero")
        XCTAssertEqual(LocalQueueKind.equipment.rawValue, "equipment")
    }

    // MARK: - LocalQueueCapacityConfig

    func testCapacityConfigAcceptsZeroAndPositive() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let zero = try LocalQueueCapacityConfig(
            villageID: villageID, queueKind: .builder, capacity: 0, updatedAt: now
        )
        XCTAssertEqual(zero.capacity, 0)
        let five = try LocalQueueCapacityConfig(
            villageID: villageID, queueKind: .builder, capacity: 5, updatedAt: now
        )
        XCTAssertEqual(five.capacity, 5)
    }

    func testCapacityConfigRejectsNegative() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertThrowsError(
            try LocalQueueCapacityConfig(
                villageID: villageID, queueKind: .builder, capacity: -1, updatedAt: now
            )
        ) { error in
            XCTAssertEqual(error as? LocalQueueCapacityConfigError, .invalidCapacity(-1))
        }
    }

    func testCapacityConfigRejectsTooLarge() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertThrowsError(
            try LocalQueueCapacityConfig(
                villageID: villageID,
                queueKind: .builder,
                capacity: LocalQueueCapacityConfig.maximumCapacity + 1,
                updatedAt: now
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalQueueCapacityConfigError,
                .invalidCapacity(LocalQueueCapacityConfig.maximumCapacity + 1)
            )
        }
    }

    func testCapacityConfigRejectsInvalidTimestamp() {
        XCTAssertThrowsError(
            try LocalQueueCapacityConfig(
                villageID: villageID,
                queueKind: .builder,
                capacity: 5,
                updatedAt: Date(timeIntervalSinceReferenceDate: .infinity)
            )
        ) { error in
            XCTAssertEqual(error as? LocalQueueCapacityConfigError, .invalidTimestamp)
        }
    }

    func testCapacityConfigDefaultsToUserConfigured() throws {
        let config = try LocalQueueCapacityConfig(
            villageID: villageID, queueKind: .builder, capacity: 5,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(config.source, .userConfigured)
    }

    func testCapacityConfigCodableRoundTrip() throws {
        let config = try LocalQueueCapacityConfig(
            villageID: villageID, queueKind: .laboratory, capacity: 2,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(LocalQueueCapacityConfig.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.source, .userConfigured)
        XCTAssertEqual(decoded.updatedAt, config.updatedAt)
    }

    // MARK: - LocalQueueOccupancy

    private func record(
        queueKind: String?,
        status: ManualUpgradeRecordStatus = .active
    ) throws -> ManualUpgradeRecord {
        try ManualUpgradeRecord(
            recordID: UUID(),
            itemKey: TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002),
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: Date(timeIntervalSince1970: 1_000),
            expectedEndAt: Date(timeIntervalSince1970: 3_600),
            durationSeconds: 2_600,
            durationKind: .timed,
            frozenCosts: nil,
            catalogProvenance: ManualCatalogProvenance(gameVersion: "18.400.13"),
            baselineReference: ManualBaselineReference(revision: "rev"),
            queueKind: queueKind,
            status: status
        )
    }

    private func config(capacity: Int, kind: LocalQueueKind = .builder) throws -> LocalQueueCapacityConfig {
        try LocalQueueCapacityConfig(
            villageID: villageID, queueKind: kind, capacity: capacity,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    func testOccupancyWithoutConfig() throws {
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [try record(queueKind: "builder")],
            capacityConfig: nil,
            at: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(occupancy.activeManualCount, 1)
        XCTAssertNil(occupancy.capacity)
        XCTAssertFalse(occupancy.isCapacityConfigured)
        XCTAssertFalse(occupancy.isFull)
        XCTAssertNil(occupancy.availableSlots)
    }

    func testOccupancyCountsOnlyMatchingQueueKind() throws {
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [
                try record(queueKind: "builder"),
                try record(queueKind: "builder"),
                try record(queueKind: "laboratory"),
                try record(queueKind: nil),
            ],
            capacityConfig: try config(capacity: 2),
            at: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(occupancy.activeManualCount, 2)
        XCTAssertEqual(occupancy.capacity, 2)
        XCTAssertTrue(occupancy.isCapacityConfigured)
        XCTAssertTrue(occupancy.isFull)
        XCTAssertEqual(occupancy.availableSlots, 0)
    }

    func testOccupancyBelowCapacity() throws {
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [try record(queueKind: "builder")],
            capacityConfig: try config(capacity: 5),
            at: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertFalse(occupancy.isFull)
        XCTAssertEqual(occupancy.availableSlots, 4)
    }

    func testOccupancyZeroCapacityIsAlwaysFull() throws {
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [],
            capacityConfig: try config(capacity: 0),
            at: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(occupancy.activeManualCount, 0)
        XCTAssertTrue(occupancy.isFull, "capacity 0 时不允许任何本地 active")
        XCTAssertEqual(occupancy.availableSlots, 0)
    }

    // MARK: - Issue #194 status-aware isFull / availableSlots

    func testOccupancyUnreconciledZeroCapacityDoesNotClaimFull() {
        // Issue #194：未对账（unreconciled）时占用未知，即使旧配置 capacity=0，
        // 也绝不能基于旧数字给出「容量已满」结论（0 >= 0 是假比较）。
        let occupancy = LocalQueueOccupancy(
            queueKind: .builder,
            activeManualCount: 0,
            confirmedImportedCount: 0,
            capacity: 0,
            status: .unreconciled
        )
        XCTAssertFalse(occupancy.isFull,
            "未对账时不得基于旧 capacity=0 给出「容量已满」结论")
        XCTAssertNil(occupancy.availableSlots,
            "未对账时不得返回看似可用的数字")
    }

    func testOccupancyUnreconciledPositiveCapacityDoesNotClaimFullNorSlots() {
        let occupancy = LocalQueueOccupancy(
            queueKind: .builder,
            activeManualCount: 0,
            confirmedImportedCount: 0,
            capacity: 3,
            status: .unreconciled
        )
        XCTAssertFalse(occupancy.isFull, "未对账时任何 capacity 都不得给出满结论")
        XCTAssertNil(occupancy.availableSlots)
    }

    func testOccupancyUnavailableZeroCapacityDoesNotClaimFull() {
        // Issue #194：存储/历史不可用（unavailable）时同样不得给出容量满结论。
        let occupancy = LocalQueueOccupancy(
            queueKind: .builder,
            activeManualCount: 0,
            confirmedImportedCount: 0,
            capacity: 0,
            status: .unavailable
        )
        XCTAssertFalse(occupancy.isFull,
            "不可用时不得基于旧 capacity=0 给出「容量已满」结论")
        XCTAssertNil(occupancy.availableSlots)
    }

    func testOccupancyUnavailablePositiveCapacityDoesNotClaimFullNorSlots() {
        let occupancy = LocalQueueOccupancy(
            queueKind: .builder,
            activeManualCount: 0,
            confirmedImportedCount: 0,
            capacity: 3,
            status: .unavailable
        )
        XCTAssertFalse(occupancy.isFull, "不可用时任何 capacity 都不得给出满结论")
        XCTAssertNil(occupancy.availableSlots)
    }

    func testOccupancyIgnoresNonActiveRecords() throws {
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [
                try record(queueKind: "builder", status: .completed),
                try record(queueKind: "builder", status: .cancelled),
            ],
            capacityConfig: try config(capacity: 1),
            at: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(occupancy.activeManualCount, 0)
        XCTAssertFalse(occupancy.isFull)
    }

    func testOccupancyExcludesDueButUnsettledRecords() throws {
        // review P2：已到期（expectedEndAt <= now）但尚未 settle 的记录
        // 不应占用容量——否则会误报「本地容量已满」。
        // record helper 的 expectedEndAt = 3_600。
        let now = Date(timeIntervalSince1970: 5_000)
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [try record(queueKind: "builder")],
            capacityConfig: try config(capacity: 1),
            at: now
        )
        XCTAssertEqual(occupancy.activeManualCount, 0)
        XCTAssertFalse(occupancy.isFull)
        XCTAssertEqual(occupancy.availableSlots, 1)
    }

    func testOccupancyUnknownKindMatchesRawValue() throws {
        let kind = LocalQueueKind(rawValue: "forge")
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: kind,
            activeRecords: [try record(queueKind: "forge")],
            capacityConfig: try config(capacity: 1, kind: kind),
            at: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertTrue(occupancy.isFull)
    }

    // MARK: - Issue #183 confirmedImportedCount

    private func assignment(
        queueKind: LocalQueueKind,
        status: QueueAssignmentStatus = .userAssigned,
        decidedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) throws -> QueueAssignmentDecision {
        try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_003),
            baselineReference: ManualBaselineReference(
                revision: "rev", fingerprint: "fp", lineageID: "lineage-1"),
            queueKind: queueKind,
            decidedAt: decidedAt,
            status: status
        )
    }

    func testOccupancyCountsOnlyUserAssignedAssignments() throws {
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [],
            confirmedAssignments: [
                try assignment(queueKind: .builder),
                try assignment(queueKind: .builder, status: .observedOnly),
                try assignment(queueKind: .builder, status: .unknown),
                try assignment(queueKind: .laboratory),
            ],
            capacityConfig: try config(capacity: 2),
            at: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(occupancy.activeManualCount, 0)
        XCTAssertEqual(occupancy.confirmedImportedCount, 1)
        XCTAssertEqual(occupancy.totalOccupancyCount, 1)
        XCTAssertFalse(occupancy.isFull)
        XCTAssertEqual(occupancy.availableSlots, 1)
    }

    func testOccupancyIsFullCountsManualPlusConfirmed() throws {
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [try record(queueKind: "builder")],
            confirmedAssignments: [try assignment(queueKind: .builder)],
            capacityConfig: try config(capacity: 1),
            at: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(occupancy.activeManualCount, 1)
        XCTAssertEqual(occupancy.confirmedImportedCount, 1)
        XCTAssertEqual(occupancy.totalOccupancyCount, 2)
        XCTAssertTrue(occupancy.isFull)
        XCTAssertEqual(occupancy.availableSlots, 0)
    }

    func testOccupancyDefaultConfirmedCountIsZero() throws {
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [],
            capacityConfig: try config(capacity: 1),
            at: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(occupancy.confirmedImportedCount, 0)
        XCTAssertFalse(occupancy.isFull)
    }
}
