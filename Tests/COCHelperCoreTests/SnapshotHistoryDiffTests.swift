import XCTest
@testable import COCHelperCore

final class SnapshotHistoryDiffTests: XCTestCase {
    func testUniqueLevelChangeUsesStableIdentityAndHistoricalBinding() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeItem(
            identity: identity,
            level: 1,
            display: SnapshotDisplayBinding(displayName: "旧英雄", category: "heroes")
        )
        let new = makeItem(
            identity: identity,
            level: 3,
            display: SnapshotDisplayBinding(displayName: "新英雄", category: "heroes")
        )

        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", date: 100, items: [old], section: "heroes"),
            to: makeEntry(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", date: 200, items: [new], section: "heroes")
        )

        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.identity, identity)
        XCTAssertEqual(change.displayName, "新英雄")
        XCTAssertEqual(change.category, "heroes")
        XCTAssertEqual(change.changeKind, .levelIncreased)
        XCTAssertEqual(change.oldLevel, 1)
        XCTAssertEqual(change.newLevel, 3)
        XCTAssertEqual(change.levelDelta, 2)
        XCTAssertEqual(change.evidence, .confirmed)
        XCTAssertEqual(change.coverage.state, .complete)
        XCTAssertEqual(diff.algorithmVersion, SnapshotDiffAlgorithm.version)
        XCTAssertEqual(diff.comparisonState, .comparable)
    }

    func testUniqueNewAndMissingItemsRequireCompleteUniverseCoverage() throws {
        let firstIdentity = makeIdentity(section: "heroes", dataID: 1)
        let secondIdentity = makeIdentity(section: "heroes", dataID: 2)
        let oldEntry = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: firstIdentity, level: 1)],
            section: "heroes"
        )
        let newEntry = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [
                makeItem(identity: firstIdentity, level: 1),
                makeItem(identity: secondIdentity, level: 2)
            ],
            section: "heroes"
        )

        let newDiff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        let newChange = try XCTUnwrap(newDiff.changes.first { $0.identity == secondIdentity })
        XCTAssertEqual(newChange.changeKind, .newlyObserved)
        XCTAssertEqual(newChange.evidence, .confirmed)

        let missingDiff = SnapshotDiffEngine.compare(from: newEntry, to: oldEntry)
        let missingChange = try XCTUnwrap(missingDiff.changes.first { $0.identity == secondIdentity })
        XCTAssertEqual(missingChange.changeKind, .noLongerObserved)
        XCTAssertEqual(missingChange.evidence, .confirmed)

        let missingSectionEntry = makeEntry(
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            date: 300,
            items: [],
            section: nil
        )
        let insufficient = SnapshotDiffEngine.compare(from: missingSectionEntry, to: newEntry)
        let unknown = try XCTUnwrap(insufficient.changes.first { $0.identity == firstIdentity })
        XCTAssertEqual(unknown.changeKind, .unknown)
        XCTAssertEqual(unknown.evidence, .unknown)
        XCTAssertEqual(unknown.coverage.state, .insufficient)
        XCTAssertEqual(insufficient.comparisonState, .insufficientCoverage)
    }

    func testDuplicateWallHistogramUsesDeterministicMonotonicMigration() throws {
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldItems = [
            makeItem(identity: identity, level: 12, count: 100, display: wallBinding()),
            makeItem(identity: identity, level: 13, count: 50, display: wallBinding())
        ]
        let newItems = [
            makeItem(identity: identity, level: 13, count: 70, display: wallBinding()),
            makeItem(identity: identity, level: 12, count: 80, display: wallBinding())
        ]
        let oldEntry = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: oldItems,
            section: "buildings",
            states: ["cnt": .complete]
        )
        let newEntry = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: newItems,
            section: "buildings",
            states: ["cnt": .complete]
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        let migration = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(migration.changeKind, .levelIncreased)
        XCTAssertEqual(migration.evidence, .aggregateInferred)
        XCTAssertEqual(migration.oldLevel, 12)
        XCTAssertEqual(migration.newLevel, 13)
        XCTAssertEqual(migration.oldQuantity, 100)
        XCTAssertEqual(migration.newQuantity, 70)
        XCTAssertEqual(migration.movedQuantity, 20)
        XCTAssertEqual(migration.levelDelta, 1)
        XCTAssertEqual(migration.displayCategory, TrackerDisplayCategory.walls.rawValue)
        XCTAssertEqual(migration.coverage.state, .complete)
        XCTAssertTrue(diff.diagnostics.isEmpty)

        let reordered = SnapshotDiffEngine.compare(
            from: oldEntry,
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: newItems.reversed(),
                section: "buildings",
                states: ["cnt": .complete]
            )
        )
        XCTAssertEqual(reordered, diff)
    }

    func testHistogramOldSideResidualFailsClosed() throws {
        // A：Lv.10 ×1 + Lv.12 ×1 → B：Lv.11 ×1（两侧 coverage 完整）。
        // 贪心配对会消耗 10→11，但旧侧 Lv.12 ×1 无法解释：
        // 必须整体 fail-closed 为 unknown，不得保留部分 level growth，
        // 也不得把残余量偷换成 quantityChanged / noLongerObserved。
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldItems = [
            makeItem(identity: identity, level: 10, count: 1, display: wallBinding()),
            makeItem(identity: identity, level: 12, count: 1, display: wallBinding())
        ]
        let newItems = [
            makeItem(identity: identity, level: 11, count: 1, display: wallBinding())
        ]
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: oldItems,
                section: "buildings",
                states: ["cnt": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: newItems,
                section: "buildings",
                states: ["cnt": .complete]
            )
        )

        XCTAssertEqual(diff.changes.count, 1)
        let change = try XCTUnwrap(diff.changes.first)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.evidence, .unknown)
        XCTAssertEqual(change.oldQuantity, 2)
        XCTAssertEqual(change.newQuantity, 1)
        XCTAssertNil(change.movedQuantity)
        XCTAssertNil(change.levelDelta)
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .levelIncreased })
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .levelDecreased })
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .quantityChanged })
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .noLongerObserved })
        XCTAssertTrue(diff.diagnostics.contains { $0.kind == .insufficientCoverage })
    }

    func testHistogramNewSideResidualFailsClosed() throws {
        // A：Lv.11 ×1 → B：Lv.10 ×1 + Lv.12 ×1。
        // 唯一可配对的是 11→10（降级），新侧 Lv.12 也无法解释：
        // 整体 fail-closed 为 unknown。
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldItems = [
            makeItem(identity: identity, level: 11, count: 1, display: wallBinding())
        ]
        let newItems = [
            makeItem(identity: identity, level: 10, count: 1, display: wallBinding()),
            makeItem(identity: identity, level: 12, count: 1, display: wallBinding())
        ]
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: oldItems,
                section: "buildings",
                states: ["cnt": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: newItems,
                section: "buildings",
                states: ["cnt": .complete]
            )
        )

        XCTAssertEqual(diff.changes.count, 1)
        let change = try XCTUnwrap(diff.changes.first)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.oldQuantity, 1)
        XCTAssertEqual(change.newQuantity, 2)
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .levelDecreased })
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .quantityChanged })
        XCTAssertTrue(diff.diagnostics.contains { $0.kind == .insufficientCoverage })
    }

    func testHistogramNonMonotonicDistributionFailsClosed() throws {
        // Issue #174 原例：A：Lv.10 ×1 + Lv.12 ×1 → B：Lv.11 ×2。
        // 贪心配对先消耗 10→11，但 Lv.12 只能降到 Lv.11；
        // 必须整体降级为 unknown，不能保留一个看似合理的 Lv.10→Lv.11。
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldItems = [
            makeItem(identity: identity, level: 10, count: 1, display: wallBinding()),
            makeItem(identity: identity, level: 12, count: 1, display: wallBinding())
        ]
        let newItems = [
            makeItem(identity: identity, level: 11, count: 1, display: wallBinding()),
            makeItem(identity: identity, level: 11, count: 1, display: wallBinding())
        ]
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: oldItems,
                section: "buildings",
                states: ["cnt": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: newItems,
                section: "buildings",
                states: ["cnt": .complete]
            )
        )

        XCTAssertEqual(diff.changes.count, 1)
        let change = try XCTUnwrap(diff.changes.first)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.oldQuantity, 2)
        XCTAssertEqual(change.newQuantity, 2)
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .levelIncreased })
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .levelDecreased })
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .quantityChanged })
        XCTAssertTrue(diff.diagnostics.contains { $0.kind == .insufficientCoverage })
    }

    func testHistogramConservationFailureGolden() throws {
        // golden：锁定守恒失败 fail-closed 的完整输出结构（排序后的
        // change、coverage、diagnostic 与 residual 明细）。
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldItems = [
            makeItem(identity: identity, level: 10, count: 1, display: wallBinding()),
            makeItem(identity: identity, level: 12, count: 1, display: wallBinding())
        ]
        let newItems = [
            makeItem(identity: identity, level: 11, count: 1, display: wallBinding()),
            makeItem(identity: identity, level: 11, count: 1, display: wallBinding())
        ]
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: oldItems,
                section: "buildings",
                states: ["cnt": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: newItems,
                section: "buildings",
                states: ["cnt": .complete]
            )
        )

        XCTAssertEqual(diff.comparisonState, .insufficientCoverage)
        XCTAssertEqual(diff.changes.count, 1)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.identity, identity)
        XCTAssertEqual(change.displayName, "城墙")
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.evidence, .unknown)
        // 守恒失败是分布冲突而非证据不足：coverage 保持 complete。
        XCTAssertEqual(change.coverage.state, .complete)
        XCTAssertEqual(change.oldQuantity, 2)
        XCTAssertEqual(change.newQuantity, 2)
        XCTAssertNil(change.movedQuantity)
        XCTAssertNil(change.levelDelta)
        XCTAssertTrue(change.coverage.reasons.contains { $0.contains("无法守恒解释") })
        XCTAssertTrue(change.coverage.reasons.contains { $0.contains("旧侧未配对：Lv.12 ×1") })
        XCTAssertTrue(change.coverage.reasons.contains { $0.contains("新侧未配对：Lv.11 ×1") })
        XCTAssertEqual(diff.diagnostics.count, 1)
        let diagnostic = try XCTUnwrap(diff.diagnostics.single)
        XCTAssertEqual(diagnostic.kind, .insufficientCoverage)
        XCTAssertTrue(diagnostic.message.contains("无法守恒解释"))
        XCTAssertTrue(diagnostic.message.contains("旧侧未配对：Lv.12 ×1"))
        XCTAssertTrue(diagnostic.message.contains("新侧未配对：Lv.11 ×1"))
        XCTAssertEqual(diagnostic.rawSection, "buildings")
    }

    func testHistogramPureLevelDecreaseFailsClosed() throws {
        // 单调迁移规则只允许升级：Lv.13 ×1 → Lv.12 ×1 无法守恒解释，fail-closed。
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldItems = [
            makeItem(identity: identity, level: 13, count: 1, display: wallBinding())
        ]
        let newItems = [
            makeItem(identity: identity, level: 12, count: 1, display: wallBinding())
        ]
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: oldItems,
                section: "buildings",
                states: ["cnt": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: newItems,
                section: "buildings",
                states: ["cnt": .complete]
            )
        )

        XCTAssertEqual(diff.changes.count, 1)
        let change = try XCTUnwrap(diff.changes.first)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.oldQuantity, 1)
        XCTAssertEqual(change.newQuantity, 1)
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .levelDecreased })
        XCTAssertTrue(diff.diagnostics.contains { $0.kind == .insufficientCoverage })
    }

    func testHistogramResidualFailsClosedIsOrderIndependent() throws {
        // residual 反例也必须与数组顺序无关：交换两侧数组顺序后 SnapshotDiff 完全相等。
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldItems = [
            makeItem(identity: identity, level: 10, count: 1, display: wallBinding()),
            makeItem(identity: identity, level: 12, count: 1, display: wallBinding())
        ]
        let newItems = [
            makeItem(identity: identity, level: 11, count: 1, display: wallBinding())
        ]
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: oldItems,
                section: "buildings",
                states: ["cnt": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: newItems,
                section: "buildings",
                states: ["cnt": .complete]
            )
        )
        XCTAssertEqual(diff.changes.count, 1)

        let reordered = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: oldItems.reversed(),
                section: "buildings",
                states: ["cnt": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: newItems.reversed(),
                section: "buildings",
                states: ["cnt": .complete]
            )
        )
        XCTAssertEqual(reordered, diff)
    }

    func testHistogramTotalIncreaseWithResidualFailsClosed() throws {
        // total 增加 + new side residual：Lv.10 ×1 → Lv.11 ×1 + Lv.12 ×1。
        // 不得输出 quantityChanged 或 partial level growth，整体 unknown。
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldItems = [
            makeItem(identity: identity, level: 10, count: 1, display: wallBinding())
        ]
        let newItems = [
            makeItem(identity: identity, level: 11, count: 1, display: wallBinding()),
            makeItem(identity: identity, level: 12, count: 1, display: wallBinding())
        ]
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: oldItems,
                section: "buildings",
                states: ["cnt": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: newItems,
                section: "buildings",
                states: ["cnt": .complete]
            )
        )

        XCTAssertEqual(diff.changes.count, 1)
        let change = try XCTUnwrap(diff.changes.first)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.oldQuantity, 1)
        XCTAssertEqual(change.newQuantity, 2)
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .quantityChanged })
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .levelIncreased })
        XCTAssertTrue(diff.diagnostics.contains { $0.kind == .insufficientCoverage })
    }

    func testHistogramResidualFailsClosedAcrossSections() throws {
        // Issue #174 测试要求：buildings、buildings2、traps、traps2 的
        // base/section identity 隔离——每个 section 的 residual 独立 fail-closed。
        let cases: [(section: String, dataID: Int64, base: SnapshotHistoryBase)] = [
            ("buildings", 8, .home),
            ("buildings2", 1_000_033, .builder),
            ("traps", 9, .home),
            ("traps2", 12_000_011, .builder)
        ]
        for testCase in cases {
            let identity = makeIdentity(
                section: testCase.section,
                dataID: testCase.dataID,
                base: testCase.base
            )
            let binding = SnapshotDisplayBinding(
                displayName: testCase.section,
                category: testCase.section
            )
            let diff = SnapshotDiffEngine.compare(
                from: makeEntry(
                    id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                    date: 100,
                    items: [
                        makeItem(identity: identity, level: 10, count: 1, display: binding),
                        makeItem(identity: identity, level: 12, count: 1, display: binding)
                    ],
                    section: testCase.section,
                    states: ["cnt": .complete]
                ),
                to: makeEntry(
                    id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                    date: 200,
                    items: [makeItem(identity: identity, level: 11, count: 1, display: binding)],
                    section: testCase.section,
                    states: ["cnt": .complete]
                )
            )

            XCTAssertEqual(diff.changes.count, 1, testCase.section)
            let change = try XCTUnwrap(diff.changes.first, testCase.section)
            XCTAssertEqual(change.identity, identity, testCase.section)
            XCTAssertEqual(change.changeKind, .unknown, testCase.section)
            XCTAssertEqual(change.oldQuantity, 2, testCase.section)
            XCTAssertEqual(change.newQuantity, 1, testCase.section)
            XCTAssertFalse(
                diff.changes.contains { $0.changeKind == .levelIncreased },
                testCase.section
            )
            XCTAssertFalse(
                diff.changes.contains { $0.changeKind == .noLongerObserved },
                testCase.section
            )
            XCTAssertTrue(
                diff.diagnostics.contains {
                    $0.kind == .insufficientCoverage && $0.rawSection == testCase.section
                },
                testCase.section
            )
        }
    }

    func testHistogramPureQuantityDecreaseFailsClosed() throws {
        // 纯数量减少：Lv.10 ×2 → Lv.10 ×1（coverage 完整）。
        // unchanged 消除后旧侧残余 Lv.10 ×1 无法解释：
        // 不得偷换成 quantityChanged 或 noLongerObserved，整体 unknown。
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldItems = [
            makeItem(identity: identity, level: 10, count: 1, display: wallBinding()),
            makeItem(identity: identity, level: 10, count: 1, display: wallBinding())
        ]
        let newItems = [
            makeItem(identity: identity, level: 10, count: 1, display: wallBinding())
        ]
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: oldItems,
                section: "buildings",
                states: ["cnt": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: newItems,
                section: "buildings",
                states: ["cnt": .complete]
            )
        )

        XCTAssertEqual(diff.changes.count, 1)
        let change = try XCTUnwrap(diff.changes.first)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.oldQuantity, 2)
        XCTAssertEqual(change.newQuantity, 1)
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .quantityChanged })
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .noLongerObserved })
        XCTAssertTrue(diff.diagnostics.contains { $0.kind == .insufficientCoverage })
    }

    func testHistogramInvalidNegativeLevelFailsClosed() throws {
        // 非法 level（负数）使 histogram 无效：整体 unknown + diagnostic，
        // 不得产生 level growth。
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldItems = [
            makeItem(identity: identity, level: -1, count: 1, display: wallBinding())
        ]
        let newItems = [
            makeItem(identity: identity, level: 10, count: 1, display: wallBinding())
        ]
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: oldItems,
                section: "buildings",
                states: ["cnt": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: newItems,
                section: "buildings",
                states: ["cnt": .complete]
            )
        )

        XCTAssertEqual(diff.changes.count, 1)
        let change = try XCTUnwrap(diff.changes.first)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.evidence, .unknown)
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .levelIncreased })
        XCTAssertTrue(
            diff.diagnostics.contains {
                $0.kind == .insufficientCoverage && $0.message.contains("无效")
            }
        )
    }

    func testHistogramMissingCountIsUnknownAndNeverTreatedAsOne() throws {
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldEntry = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [
                makeItem(identity: identity, level: 12, display: wallBinding()),
                makeItem(identity: identity, level: 13, display: wallBinding())
            ],
            section: "buildings",
            states: ["cnt": .unavailable]
        )
        let newEntry = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [
                makeItem(identity: identity, level: 13, display: wallBinding()),
                makeItem(identity: identity, level: 14, display: wallBinding())
            ],
            section: "buildings",
            states: ["cnt": .unavailable]
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.evidence, .unknown)
        XCTAssertEqual(change.coverage.state, .insufficient)
        XCTAssertTrue(change.coverage.fields.contains { $0.field == "cnt" && $0.fromState == .unavailable })
    }

    func testSingleBuildingRecordStillRequiresHistogramCount() throws {
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldEntry = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 12, display: wallBinding())],
            section: "buildings",
            states: ["cnt": .unavailable]
        )
        let newEntry = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 13, display: wallBinding())],
            section: "buildings",
            states: ["cnt": .unavailable]
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        XCTAssertEqual(diff.changes.single?.changeKind, .unknown)
        XCTAssertEqual(diff.changes.single?.evidence, .unknown)
    }

    func testHistogramTotalOverflowFailsClosed() throws {
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let overflowingItems = [
            makeItem(identity: identity, level: 12, count: Int.max, display: wallBinding()),
            makeItem(identity: identity, level: 13, count: 1, display: wallBinding())
        ]
        let oldEntry = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: overflowingItems,
            section: "buildings",
            states: ["cnt": .complete]
        )
        let newEntry = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: overflowingItems,
            section: "buildings",
            states: ["cnt": .complete]
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        XCTAssertEqual(diff.changes.single?.changeKind, .unknown)
        XCTAssertEqual(diff.changes.single?.evidence, .unknown)
        XCTAssertEqual(diff.comparisonState, .insufficientCoverage)
    }

    func testTimerTransitionsAreGroupedWithLevelChange() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeItem(
            identity: identity,
            level: 1,
            timer: 90,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )
        let changed = makeItem(
            identity: identity,
            level: 1,
            timer: 80,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )
        let completed = makeItem(
            identity: identity,
            level: 2,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )

        let timerDiff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [old],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100)
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: [changed],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 200)
            )
        )
        XCTAssertEqual(timerDiff.changes.single?.changeKind, .timerChanged)

        let startedDiff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [makeItem(identity: identity, level: 1, display: old.display)],
                section: "heroes",
                states: ["timer": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: [old],
                section: "heroes",
                states: ["timer": .complete]
            )
        )
        XCTAssertEqual(startedDiff.changes.single?.changeKind, .upgradeStarted)

        let completionDiff = SnapshotDiffEngine.compare(
            from: makeEntry(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", date: 200, items: [old], section: "heroes", states: ["timer": .complete]),
            to: makeEntry(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", date: 300, items: [completed], section: "heroes", states: ["timer": .complete])
        )
        let completion = try XCTUnwrap(completionDiff.changes.single)
        XCTAssertEqual(completion.changeKind, .upgradeCompleted)
        XCTAssertEqual(completion.relatedChangeKinds, [.levelIncreased])
        XCTAssertEqual(completion.levelDelta, 1)
        XCTAssertEqual(completion.evidence, .confirmed)

        let ended = SnapshotDiffEngine.compare(
            from: makeEntry(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", date: 100, items: [old], section: "heroes", states: ["timer": .complete]),
            to: makeEntry(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", date: 200, items: [
                makeItem(identity: identity, level: 1, display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes"))
            ], section: "heroes", states: ["timer": .complete])
        )
        XCTAssertEqual(ended.changes.single?.changeKind, .timerEndedObserved)

        let partial = SnapshotDiffEngine.compare(
            from: makeEntry(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", date: 100, items: [old], section: "heroes", states: ["timer": .complete]),
            to: makeEntry(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", date: 200, items: [
                makeItem(identity: identity, level: 1, display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes"))
            ], section: "heroes", states: ["presence": .partial, "data": .partial, "timer": .unavailable])
        )
        XCTAssertEqual(partial.changes.single?.changeKind, .unknown)
        XCTAssertEqual(partial.changes.single?.evidence, .unknown)

        let unavailable = SnapshotDiffEngine.compare(
            from: makeEntry(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", date: 100, items: [old], section: "heroes", states: ["timer": .complete]),
            to: makeEntry(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", date: 200, items: [
                makeItem(identity: identity, level: 1, display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes"))
            ], section: "heroes", states: ["presence": .partial, "data": .partial, "timer": .unavailable])
        )
        XCTAssertEqual(unavailable.changes.single?.changeKind, .unknown)
        XCTAssertEqual(unavailable.changes.single?.evidence, .unknown)
    }

    func testSchemaMillisecondsRemainingCountdownDoesNotCreateChange() throws {
        // Issue #175：契约声明毫秒单位时，自然倒计时按 elapsed*1000 规范化。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let schema = SnapshotTimerSchema(
            version: "ms-schema",
            fields: ["timer": SnapshotTimerFieldSpec(unit: .milliseconds, semantics: .remaining)]
        )
        func item(_ timer: Int) -> SnapshotObservationItem {
            SnapshotObservationItem(
                identity: identity,
                level: 1,
                rawTimerEvidence: ["timer": .number(String(timer))],
                display: binding
            )
        }
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [item(90_000)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                timerSchema: schema
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [item(85_000)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105),
                timerSchema: schema
            )
        )
        XCTAssertTrue(diff.changes.isEmpty, "毫秒 remaining 自然倒计时（90s→85s）不得产生变化")
        XCTAssertEqual(diff.comparisonState, .comparable)
    }

    func testSchemaAbsoluteSemanticsDoesNotCountDown() throws {
        // Issue #175：absolute 语义是结束时间戳，不随时间流逝减少；
        // 值保持不变是自然状态，只有超过容差的变化才是业务变化。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let schema = SnapshotTimerSchema(
            version: "absolute-schema",
            fields: ["timer": SnapshotTimerFieldSpec(unit: .seconds, semantics: .absolute)]
        )
        func item(_ timer: Int) -> SnapshotObservationItem {
            SnapshotObservationItem(
                identity: identity,
                level: 1,
                rawTimerEvidence: ["timer": .number(String(timer))],
                display: binding
            )
        }
        let unchanged = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [item(1_700_000_900)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                timerSchema: schema
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [item(1_700_000_900)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105),
                timerSchema: schema
            )
        )
        XCTAssertTrue(unchanged.changes.isEmpty, "absolute 值不变不得产生变化")
        XCTAssertEqual(unchanged.comparisonState, .comparable)

        let changed = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [item(1_700_000_900)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                timerSchema: schema
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [item(1_700_000_500)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105),
                timerSchema: schema
            )
        )
        XCTAssertEqual(changed.changes.single?.changeKind, .timerChanged, "absolute 值明显变化应报 timerChanged")
    }

    func testSchemaFieldRangeViolationIsUnknown() throws {
        // Issue #175：契约声明取值范围，超出范围的值不可解析 → fail-closed。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let schema = SnapshotTimerSchema(
            version: "range-schema",
            fields: ["timer": SnapshotTimerFieldSpec(
                unit: .seconds,
                semantics: .remaining,
                minValue: 0,
                maxValue: 3_600
            )]
        )
        func item(_ timer: Int) -> SnapshotObservationItem {
            SnapshotObservationItem(
                identity: identity,
                level: 1,
                rawTimerEvidence: ["timer": .number(String(timer))],
                display: binding
            )
        }
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [item(90)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                timerSchema: schema
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [item(5_000)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105),
                timerSchema: schema
            )
        )
        XCTAssertEqual(diff.changes.single?.changeKind, .unknown, "超出契约范围的 timer 值必须 fail-closed")
    }

    func testSchemaMismatchBetweenEntriesIsUnknown() throws {
        // Issue #175：两侧 entry 契约字段集合/规格不一致时不得猜测。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        func item(_ timer: Int) -> SnapshotObservationItem {
            SnapshotObservationItem(
                identity: identity,
                level: 1,
                rawTimerEvidence: ["timer": .number(String(timer))],
                display: binding
            )
        }
        let secondsSchema = SnapshotTimerSchema(
            version: "seconds-schema",
            fields: ["timer": SnapshotTimerFieldSpec(unit: .seconds, semantics: .remaining)]
        )
        let millisSchema = SnapshotTimerSchema(
            version: "millis-schema",
            fields: ["timer": SnapshotTimerFieldSpec(unit: .milliseconds, semantics: .remaining)]
        )
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [item(90)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                timerSchema: secondsSchema
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [item(85)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105),
                timerSchema: millisSchema
            )
        )
        XCTAssertEqual(diff.changes.single?.changeKind, .unknown, "契约不一致必须 fail-closed")
    }

    func testSchemaMismatchBeforeStateTransitionIsUnknown() throws {
        // Issue #175 review：契约规格不一致必须在任何状态转换（含
        // active→inactive / inactive→active）前 fail-closed，不能只拦
        // active→active 的数值比较。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        func item(_ timer: Int) -> SnapshotObservationItem {
            SnapshotObservationItem(
                identity: identity,
                level: 1,
                rawTimerEvidence: ["timer": .number(String(timer))],
                display: binding
            )
        }
        let secondsSchema = SnapshotTimerSchema(
            version: "seconds-schema",
            fields: ["timer": SnapshotTimerFieldSpec(unit: .seconds, semantics: .remaining)]
        )
        let millisSchema = SnapshotTimerSchema(
            version: "millis-schema",
            fields: ["timer": SnapshotTimerFieldSpec(unit: .milliseconds, semantics: .remaining)]
        )
        // 1) active → inactive（timer 归零）：契约不一致也必须 unknown，
        //    不能输出 timerEndedObserved。
        let ended = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [item(90)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                timerSchema: secondsSchema
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [item(0)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105),
                timerSchema: millisSchema
            )
        )
        XCTAssertEqual(ended.changes.single?.changeKind, .unknown, "active→inactive 时契约不一致必须 fail-closed")
        XCTAssertEqual(ended.changes.single?.evidence, .unknown)

        // 2) inactive → active（timer 出现）：契约不一致也必须 unknown，
        //    不能输出 upgradeStarted。
        let started = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [item(0)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                timerSchema: secondsSchema
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [item(90)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105),
                timerSchema: millisSchema
            )
        )
        XCTAssertEqual(started.changes.single?.changeKind, .unknown, "inactive→active 时契约不一致必须 fail-closed")
        XCTAssertEqual(started.changes.single?.evidence, .unknown)
    }

    func testAbsoluteSemanticsExpiresAgainstSourceTimestamp() throws {
        // Issue #175 review：absolute 结束时间戳必须与观测时刻
        // （sourceTimestamp）比较判定 active/inactive；观测时刻越过
        // 结束时间戳后应产生结束事件，而不是永远 active。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let schema = SnapshotTimerSchema(
            version: "absolute-schema",
            fields: ["timer": SnapshotTimerFieldSpec(unit: .seconds, semantics: .absolute)]
        )
        func item(_ timer: Int) -> SnapshotObservationItem {
            SnapshotObservationItem(
                identity: identity,
                level: 1,
                rawTimerEvidence: ["timer": .number(String(timer))],
                display: binding
            )
        }
        // 结束时间戳 110：观测 100 时 active；观测 120 时已过期 → inactive。
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [item(110)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                timerSchema: schema
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 120,
                items: [item(110)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 120),
                timerSchema: schema
            )
        )
        XCTAssertEqual(diff.changes.single?.changeKind, .timerEndedObserved, "absolute 时间戳越过结束点必须产生结束事件")
    }

    func testV3ToV4TransitionUsesDefaultSecondsSemantics() throws {
        // Issue #175 review：v3 entry 无冻结契约，但语义 = 默认 seconds/remaining；
        // 与 v4 legacy 秒契约比较时按默认语义规范化，v3→v4 过渡不得降级 unknown。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        func item(_ timer: Int) -> SnapshotObservationItem {
            SnapshotObservationItem(
                identity: identity,
                level: 1,
                rawTimerEvidence: ["timer": .number(String(timer))],
                display: binding
            )
        }
        let v4Schema = SnapshotTimerSchema(
            version: "account-json-timer-1",
            fields: ["timer": SnapshotTimerFieldSpec(unit: .seconds, semantics: .remaining)]
        )
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [item(90)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                observationVersion: 3
                // v3 entry：timerSchema = nil
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [item(85)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105),
                timerSchema: v4Schema
            )
        )
        XCTAssertTrue(diff.changes.isEmpty, "v3→v4 平滑过渡：自然倒计时不得产生变化，也不得降级 unknown")
        XCTAssertEqual(diff.comparisonState, .comparable)
    }

    func testV4WithoutSchemaAgainstV3StaysFailClosed() throws {
        // Issue #175 review：v4 无契约时字段名不再权威，与 v3 entry 比较
        // 不得把「无 evidence」当作 timer 消失（timerEndedObserved），必须 unknown。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let v3Item = SnapshotObservationItem(
            identity: identity,
            level: 1,
            rawTimerEvidence: ["timer": .number("90")],
            display: binding
        )
        let v4NoSchemaItem = SnapshotObservationItem(
            identity: identity,
            level: 1,
            rawTimerEvidence: [:],
            display: binding
        )
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [v3Item],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                observationVersion: 3
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [v4NoSchemaItem],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105),
                timerSchema: nil,
                observationVersion: 4
            )
        )
        XCTAssertEqual(diff.changes.single?.changeKind, .unknown, "v4 无契约不得把无 evidence 推断为 timer 结束")
        XCTAssertEqual(diff.changes.single?.evidence, .unknown)
    }

    func testAbsoluteMillisecondsExpiresAgainstSourceTimestamp() throws {
        // Issue #175 review：absolute 毫秒时间戳必须按字段单位换算观测时刻。
        // 结束时间 110000ms = 110s；观测 100s→120s 已越过 → timerEndedObserved。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let schema = SnapshotTimerSchema(
            version: "absolute-ms-schema",
            fields: ["timer": SnapshotTimerFieldSpec(unit: .milliseconds, semantics: .absolute)]
        )
        func item(_ timer: Int) -> SnapshotObservationItem {
            SnapshotObservationItem(
                identity: identity,
                level: 1,
                rawTimerEvidence: ["timer": .number(String(timer))],
                display: binding
            )
        }
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [item(110_000)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                timerSchema: schema
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 120,
                items: [item(110_000)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 120),
                timerSchema: schema
            )
        )
        XCTAssertEqual(diff.changes.single?.changeKind, .timerEndedObserved, "absolute 毫秒时间戳越过结束点必须产生结束事件")
    }

    func testV3ToV4RealAdapterSchemaTransitionsSmoothly() throws {
        // Issue #175 review：v3 默认语义（非负/秒/remaining）必须与真实
        // AccountSnapshotImporter.timerSchema（minValue: 0）兼容，
        // v3→v4 过渡不得因范围表示差异降级 unknown。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        func item(_ timer: Int) -> SnapshotObservationItem {
            SnapshotObservationItem(
                identity: identity,
                level: 1,
                rawTimerEvidence: ["timer": .number(String(timer))],
                display: binding
            )
        }
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [item(90)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                observationVersion: 3
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [item(85)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105),
                timerSchema: AccountSnapshotImporter.timerSchema
            )
        )
        XCTAssertTrue(diff.changes.isEmpty, "v3→v4 真实 adapter 契约：自然倒计时不得产生变化或降级 unknown")
        XCTAssertEqual(diff.comparisonState, .comparable)
    }

    func testV3ToV4TightenedRangeIsUnknown() throws {
        // Issue #175 review：v4 契约收紧范围（minValue > 0 或显式上限）
        // 会改变可接受数值集合，与 v3 默认语义不兼容 → fail-closed。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        func item(_ timer: Int) -> SnapshotObservationItem {
            SnapshotObservationItem(
                identity: identity,
                level: 1,
                rawTimerEvidence: ["timer": .number(String(timer))],
                display: binding
            )
        }
        let tightened = SnapshotTimerSchema(
            version: "tightened-schema",
            fields: ["timer": SnapshotTimerFieldSpec(
                unit: .seconds,
                semantics: .remaining,
                minValue: 5
            )]
        )
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [item(90)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                observationVersion: 3
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [item(85)],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105),
                timerSchema: tightened
            )
        )
        XCTAssertEqual(diff.changes.single?.changeKind, .unknown, "范围收紧与 v3 默认语义不兼容必须 fail-closed")
    }

    func testProvenanceOnlyCompatibleSchemaVersionKeepsEmptyDiff() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let item = SnapshotObservationItem(
            identity: identity,
            level: 1,
            rawTimerEvidence: ["timer": .number("90")],
            display: binding
        )
        func schema(_ version: String) -> SnapshotTimerSchema {
            SnapshotTimerSchema(
                version: version,
                fields: ["timer": SnapshotTimerFieldSpec(unit: .seconds, semantics: .remaining, minValue: 0)]
            )
        }
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [item],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100),
                timerSchema: schema("timer-1")
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [item],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105),
                timerSchema: schema("timer-2")
            )
        )
        XCTAssertTrue(diff.changes.isEmpty, "兼容 version bump 不得伪造 timer/level change")
        XCTAssertEqual(diff.comparisonState, .comparable)
        XCTAssertFalse(diff.diagnostics.contains { $0.kind == .incomparableTimerSchema })
    }

    func testProvenanceOnlyIncompatibleSchemaDoesNotFabricateTimerChangeOrPoisonStatistics() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let item = SnapshotObservationItem(
            identity: identity,
            level: 1,
            rawTimerEvidence: ["timer": .number("90")],
            display: binding
        )
        let seconds = SnapshotTimerSchema(
            version: "seconds-schema",
            fields: ["timer": SnapshotTimerFieldSpec(unit: .seconds, semantics: .remaining)]
        )
        let millis = SnapshotTimerSchema(
            version: "millis-schema",
            fields: ["timer": SnapshotTimerFieldSpec(unit: .milliseconds, semantics: .remaining)]
        )
        let from = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [item],
            section: "heroes",
            states: ["timer": .complete],
            additionalSections: MetricTestSectionCoverage.heroUniverseNotApplicable,
            sourceTimestamp: Date(timeIntervalSince1970: 100),
            timerSchema: seconds
        )
        let to = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: [item],
            section: "heroes",
            states: ["timer": .complete],
            additionalSections: MetricTestSectionCoverage.heroUniverseNotApplicable,
            sourceTimestamp: Date(timeIntervalSince1970: 105),
            timerSchema: millis
        )
        let diff = SnapshotDiffEngine.compare(from: from, to: to)
        XCTAssertTrue(diff.changes.isEmpty, "observation 未变时不得输出 timerChanged/upgrade")
        XCTAssertEqual(diff.comparisonState, .comparable)
        XCTAssertEqual(diff.diagnostics.filter { $0.kind == .incomparableTimerSchema }.count, 1)
        XCTAssertFalse(diff.diagnostics.contains { $0.kind == .insufficientCoverage || $0.kind == .malformedObservation })

        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 105),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.heroLevelGrowth.state, .available)
        XCTAssertEqual(statistics.today.heroLevelGrowth.value, 0)
        XCTAssertEqual(statistics.today.buildingLevelGrowth.state, .insufficientData)
    }

    func testUniqueTimerNaturalCountdownDoesNotCreateChange() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeItem(
            identity: identity,
            level: 1,
            timer: 90,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )
        let natural = makeItem(
            identity: identity,
            level: 1,
            timer: 85,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [old],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100)
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [natural],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105)
            )
        )
        XCTAssertTrue(diff.changes.isEmpty)
        XCTAssertEqual(diff.comparisonState, .comparable)
    }

    func testUniqueTimerRestartStillReportsTimerChanged() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeItem(
            identity: identity,
            level: 1,
            timer: 90,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )
        let restarted = makeItem(
            identity: identity,
            level: 1,
            timer: 500,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [old],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100)
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [restarted],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105)
            )
        )
        XCTAssertEqual(diff.changes.single?.changeKind, .timerChanged)
    }

    func testBuildingHistogramTimerUpgradeStartedWithoutCount() throws {
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, display: binding)],
            section: "buildings",
            states: ["timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 14, timer: 900, display: binding)],
            section: "buildings",
            states: ["timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .upgradeStarted)
        XCTAssertEqual(change.evidence, .aggregateInferred)
        XCTAssertEqual(change.coverage.state, .complete)
    }

    func testBuilderBaseHistogramTimerUpgradeStarted() throws {
        let identity = makeIdentity(section: "buildings2", dataID: 1_000_033, base: .builder)
        let binding = SnapshotDisplayBinding(displayName: "建筑工人小屋", category: "buildings")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, display: binding)],
            section: "buildings2",
            states: ["timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 1, timer: 60, display: binding)],
            section: "buildings2",
            states: ["timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .upgradeStarted)
        XCTAssertEqual(change.evidence, .aggregateInferred)
    }

    func testTrapHistogramTimerChangedAfterNormalization() throws {
        let identity = makeIdentity(section: "traps", dataID: 9)
        let binding = SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 90, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .complete],
            sourceTimestamp: Date(timeIntervalSince1970: 100)
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 40, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .complete],
            sourceTimestamp: Date(timeIntervalSince1970: 105)
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .timerChanged)
        XCTAssertEqual(change.evidence, .aggregateInferred)
    }

    func testTrapHistogramNaturalCountdownCreatesNoChange() throws {
        let identity = makeIdentity(section: "traps", dataID: 9)
        let binding = SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 90, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .complete],
            sourceTimestamp: Date(timeIntervalSince1970: 100)
        )
        let natural = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 85, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .complete],
            sourceTimestamp: Date(timeIntervalSince1970: 105)
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: natural)
        XCTAssertTrue(diff.changes.isEmpty)
        XCTAssertEqual(diff.comparisonState, .comparable)
    }

    func testBuilderBaseTrapHistogramTimerChanged() throws {
        let identity = makeIdentity(section: "traps2", dataID: 12_000_011, base: .builder)
        let binding = SnapshotDisplayBinding(displayName: "弹簧陷阱", category: "traps")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 300, display: binding)],
            section: "traps2",
            states: ["cnt": .complete, "timer": .complete],
            sourceTimestamp: Date(timeIntervalSince1970: 100)
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 10, display: binding)],
            section: "traps2",
            states: ["cnt": .complete, "timer": .complete],
            sourceTimestamp: Date(timeIntervalSince1970: 105)
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .timerChanged)
        XCTAssertEqual(change.evidence, .aggregateInferred)
    }

    func testBuildingHistogramTimerCompletionWithLevelMigration() throws {
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, count: 2, timer: 90, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 15, count: 2, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let completed = try XCTUnwrap(diff.changes.first { $0.changeKind == .upgradeCompleted })
        XCTAssertEqual(completed.evidence, .aggregateInferred)
        XCTAssertEqual(completed.relatedChangeKinds, [.levelIncreased])
        XCTAssertNil(completed.levelDelta)
        XCTAssertNil(completed.movedQuantity)
        let migration = try XCTUnwrap(diff.changes.first { $0.changeKind == .levelIncreased })
        XCTAssertEqual(migration.oldLevel, 14)
        XCTAssertEqual(migration.newLevel, 15)
        XCTAssertEqual(migration.movedQuantity, 2)
    }

    func testBuildingHistogramTimerEndedWithoutLevelMigration() throws {
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, count: 2, timer: 90, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 14, count: 2, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .timerEndedObserved)
        XCTAssertEqual(change.evidence, .aggregateInferred)
    }

    func testHistogramTimerUnknownOnPartialCoverage() throws {
        let identity = makeIdentity(section: "traps", dataID: 9)
        let binding = SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 90, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .partial]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 85, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .partial]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.evidence, .unknown)
        XCTAssertTrue(change.coverage.fields.contains { $0.field == "timer" })
    }

    func testHistogramTimerUnknownOnUnparsableEvidence() throws {
        let identity = makeIdentity(section: "traps", dataID: 9)
        let binding = SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 90, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: -1, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.evidence, .unknown)
        XCTAssertEqual(diff.comparisonState, .insufficientCoverage)
    }

    func testHistogramTimerOrderIndependence() throws {
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let oldItems = [
            makeItem(identity: identity, level: 14, count: 1, timer: 90, display: binding),
            makeItem(identity: identity, level: 14, count: 1, timer: 60, display: binding)
        ]
        let newItems = [
            makeItem(identity: identity, level: 14, count: 1, timer: 10, display: binding),
            makeItem(identity: identity, level: 14, count: 1, timer: 85, display: binding)
        ]
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: oldItems,
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete],
            sourceTimestamp: Date(timeIntervalSince1970: 100)
        )
        let forward = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: newItems,
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete],
            sourceTimestamp: Date(timeIntervalSince1970: 105)
        )
        let reversed = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: newItems.reversed(),
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete],
            sourceTimestamp: Date(timeIntervalSince1970: 105)
        )
        let diffA = SnapshotDiffEngine.compare(from: old, to: forward)
        let diffB = SnapshotDiffEngine.compare(from: old, to: reversed)
        XCTAssertEqual(diffA, diffB)
        XCTAssertTrue(diffA.changes.contains { $0.changeKind == .timerChanged })
    }

    func testHistogramTimerCompletionStatisticsNotDoubleCounted() throws {
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let buildingUniverseNotApplicable = MetricTestSectionCoverage.buildingUniverseNotApplicable
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, count: 2, timer: 90, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete],
            additionalSections: buildingUniverseNotApplicable
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 15, count: 2, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete],
            additionalSections: buildingUniverseNotApplicable
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        XCTAssertTrue(diff.changes.contains { $0.changeKind == .upgradeCompleted })
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        // aggregateInferred 事件不污染 confirmed 完成数（confirmed 口径只数已确认完成）
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.value, 0)
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.state, .available)
        // 同一 aggregate 的 level migration + timer disappearance 只计 1 次聚合完成
        XCTAssertEqual(statistics.today.aggregateInferredBuildingUpgradeCompletions.value, 1)
        // level 迁移与 timer 完成是两个独立事件，各计一次
        XCTAssertEqual(statistics.today.aggregateInferredEventCount.value, 2)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingLevelGrowth.value, 2)
    }

    func testHistogramTimerStartedWithoutCountStatsDoNotShowZero() throws {
        // 缺少 cnt 时 histogram level/count 不可比；timer started 只支撑事件数，
        // 不得让建筑 completion/level growth 显示为 available(0)。
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, display: binding)],
            section: "buildings",
            states: ["timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 14, timer: 900, display: binding)],
            section: "buildings",
            states: ["timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        XCTAssertEqual(diff.changes.single?.changeKind, .upgradeStarted)
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        // timer 证据完整 → timer/event 指标可显示
        XCTAssertEqual(statistics.today.aggregateInferredEventCount.state, .available)
        XCTAssertEqual(statistics.today.aggregateInferredEventCount.value, 1)
        // 缺少 cnt → level/count 指标为数据不足，不得显示 0
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.state, .insufficientData)
        XCTAssertEqual(statistics.today.buildingLevelGrowth.state, .insufficientData)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingLevelGrowth.state, .insufficientData)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingUpgradeCompletions.state, .insufficientData)
    }

    func testTimerEndedObservedIsNotAggregateCompletion() throws {
        // timer 消失但无 level migration → timerEndedObserved，不计为聚合完成。
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let buildingUniverseNotApplicable = [
            MetricTestSectionCoverage.notApplicable("traps"),
            MetricTestSectionCoverage.notApplicable("buildings2"),
            MetricTestSectionCoverage.notApplicable("traps2")
        ]
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, count: 2, timer: 90, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete],
            additionalSections: buildingUniverseNotApplicable
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 14, count: 2, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete],
            additionalSections: buildingUniverseNotApplicable
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        XCTAssertEqual(diff.changes.single?.changeKind, .timerEndedObserved)
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.aggregateInferredEventCount.value, 1)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingUpgradeCompletions.state, .available)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingUpgradeCompletions.value, 0)
    }

    func testBuildingHistogramUnknownDoesNotPolluteHeroStatistics() throws {
        // building section 的缺 cnt unknown 只影响建筑类指标，
        // 不得污染同窗口内证据完整的 hero confirmed 增长。
        let buildingIdentity = makeIdentity(section: "buildings", dataID: 2)
        let buildingBinding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let heroIdentity = makeIdentity(section: "heroes", dataID: 1)
        let heroBinding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")

        // 缺 cnt + timer started 的 building diff（level/count 不可比）
        let buildingOld = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: buildingIdentity, level: 14, display: buildingBinding)],
            section: "buildings",
            states: ["timer": .complete]
        )
        let buildingNew = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: buildingIdentity, level: 14, timer: 900, display: buildingBinding)],
            section: "buildings",
            states: ["timer": .complete]
        )
        let buildingDiff = SnapshotDiffEngine.compare(from: buildingOld, to: buildingNew)
        XCTAssertEqual(buildingDiff.changes.single?.changeKind, .upgradeStarted)

        // 证据完整的 hero confirmed 增长 diff
        let heroOld = makeEntry(
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            date: 100,
            items: [makeItem(identity: heroIdentity, level: 1, display: heroBinding)],
            section: "heroes",
            additionalSections: MetricTestSectionCoverage.heroUniverseNotApplicable,
            sourceTimestamp: Date(timeIntervalSince1970: 1)
        )
        let heroNew = makeEntry(
            id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            date: 200,
            items: [makeItem(identity: heroIdentity, level: 2, display: heroBinding)],
            section: "heroes",
            additionalSections: MetricTestSectionCoverage.heroUniverseNotApplicable,
            sourceTimestamp: Date(timeIntervalSince1970: 2)
        )
        let heroDiff = SnapshotDiffEngine.compare(from: heroOld, to: heroNew)
        XCTAssertTrue(heroDiff.changes.contains { $0.changeKind == .levelIncreased && $0.evidence == .confirmed })

        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [buildingDiff, heroDiff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.heroLevelGrowth.state, .available)
        XCTAssertEqual(statistics.today.heroLevelGrowth.value, 1)
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.state, .insufficientData)
    }

    func testWallResidualDoesNotDegradeBuildingMetrics() throws {
        // 城墙与普通建筑共享 rawSection "buildings"；城墙 histogram residual
        // fail-closed 只影响墙指标，不得把同 diff 普通建筑的合法迁移
        // 降级为 insufficientData。
        let wallIdentity = makeIdentity(section: "buildings", dataID: 8)
        let buildingIdentity = makeIdentity(section: "buildings", dataID: 1)
        let buildingBinding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let buildingUniverseNotApplicable = MetricTestSectionCoverage.buildingUniverseNotApplicable
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [
                makeItem(identity: wallIdentity, level: 12, count: 100, display: wallBinding()),
                makeItem(identity: wallIdentity, level: 13, count: 50, display: wallBinding()),
                makeItem(identity: buildingIdentity, level: 1, count: 1, display: buildingBinding)
            ],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: buildingUniverseNotApplicable
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [
                makeItem(identity: wallIdentity, level: 12, count: 80, display: wallBinding()),
                makeItem(identity: wallIdentity, level: 13, count: 70, display: wallBinding()),
                makeItem(identity: wallIdentity, level: 14, count: 1, display: wallBinding()),
                makeItem(identity: buildingIdentity, level: 2, count: 1, display: buildingBinding)
            ],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: buildingUniverseNotApplicable
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        XCTAssertTrue(diff.changes.contains { $0.changeKind == .unknown && $0.identity == wallIdentity })
        XCTAssertTrue(diff.changes.contains { $0.changeKind == .levelIncreased && $0.identity == buildingIdentity })
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        // 墙指标数据不足
        XCTAssertEqual(statistics.today.wallLevelGrowth.state, .insufficientData)
        XCTAssertEqual(statistics.today.aggregateInferredWallLevelGrowth.state, .insufficientData)
        // 普通建筑指标不受城墙 residual 影响
        XCTAssertEqual(statistics.today.aggregateInferredBuildingLevelGrowth.state, .available)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingLevelGrowth.value, 1)
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.state, .available)
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.value, 0)
    }

    func testRealisticBuildingAndTrapTimerFixtureDiffs() throws {
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        func canonicalEntry(
            _ text: String,
            id: String,
            appliedAt: TimeInterval
        ) throws -> SnapshotHistoryEntry {
            let snapshot = try AccountSnapshotImporter.parse(
                text,
                now: Date(timeIntervalSince1970: appliedAt)
            )
            return try SnapshotHistoryCanonicalizer.canonicalize(
                snapshot: snapshot,
                villageID: villageID,
                lineageID: lineageID,
                appliedAt: Date(timeIntervalSince1970: appliedAt),
                snapshotID: UUID(uuidString: id)!
            )
        }

        let idle = try canonicalEntry(
            "{\"buildings\":[{\"data\":1000001,\"lvl\":14}],\"traps\":[{\"data\":12000000,\"lvl\":1,\"cnt\":1}]}",
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            appliedAt: 100
        )
        let upgrading = try canonicalEntry(
            "{\"buildings\":[{\"data\":1000001,\"lvl\":14,\"timer\":900}],\"traps\":[{\"data\":12000000,\"lvl\":1,\"cnt\":1,\"timer\":60}]}",
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            appliedAt: 110
        )
        XCTAssertEqual(
            upgrading.observation.items.first { $0.identity.dataID == 1_000_001 }?.rawTimerEvidence["timer"],
            .number("900")
        )
        XCTAssertEqual(
            upgrading.observation.items.first { $0.identity.dataID == 12_000_000 }?.rawTimerEvidence["timer"],
            .number("60")
        )
        let started = SnapshotDiffEngine.compare(from: idle, to: upgrading)
        let buildingStarted = try XCTUnwrap(
            started.changes.first { $0.identity.dataID == 1_000_001 && $0.changeKind == .upgradeStarted }
        )
        XCTAssertEqual(buildingStarted.changeKind, .upgradeStarted)
        XCTAssertEqual(buildingStarted.evidence, .aggregateInferred)
        let trapStarted = try XCTUnwrap(
            started.changes.first { $0.identity.dataID == 12_000_000 && $0.changeKind == .upgradeStarted }
        )
        XCTAssertEqual(trapStarted.changeKind, .upgradeStarted)
        XCTAssertEqual(trapStarted.evidence, .aggregateInferred)
    }

    func testRealisticTimerDisappearanceWithoutSectionProofStaysUnknown() throws {
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        func canonicalEntry(
            _ text: String,
            id: String,
            appliedAt: TimeInterval
        ) throws -> SnapshotHistoryEntry {
            let snapshot = try AccountSnapshotImporter.parse(
                text,
                now: Date(timeIntervalSince1970: appliedAt)
            )
            return try SnapshotHistoryCanonicalizer.canonicalize(
                snapshot: snapshot,
                villageID: villageID,
                lineageID: lineageID,
                appliedAt: Date(timeIntervalSince1970: appliedAt),
                snapshotID: UUID(uuidString: id)!
            )
        }

        let upgrading = try canonicalEntry(
            "{\"buildings\":[{\"data\":1000001,\"lvl\":14,\"timer\":900}]}",
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            appliedAt: 100
        )
        let idle = try canonicalEntry(
            "{\"buildings\":[{\"data\":1000001,\"lvl\":14}]}",
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            appliedAt: 200
        )
        // 无 cnt → histogram 无效路径；timer 消失但 section proof 不完整（fixture 无
        // authoritative proof）→ 不得推断 timer 结束，保持 unknown。
        let diff = SnapshotDiffEngine.compare(from: upgrading, to: idle)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.evidence, .unknown)
        XCTAssertEqual(diff.comparisonState, .insufficientCoverage)
    }

    func testUniqueTimerNaturalCountdownWithoutSourceTimestampIsUnknown() throws {
        // active→active 但两侧 sourceTimestamp 缺失：无法规范化倒计时 → unknown。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let old = makeItem(identity: identity, level: 1, timer: 90, display: binding)
        let natural = makeItem(identity: identity, level: 1, timer: 85, display: binding)
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [old],
                section: "heroes",
                states: ["timer": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [natural],
                section: "heroes",
                states: ["timer": .complete]
            )
        )
        XCTAssertEqual(diff.changes.single?.changeKind, .unknown)
        XCTAssertEqual(diff.changes.single?.evidence, .unknown)
    }

    func testUniqueTimerSourceTimestampReversedStaysUnknown() throws {
        // sourceTimestamp 倒序（to < from）：时间证据矛盾 → unknown。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let old = makeItem(identity: identity, level: 1, timer: 90, display: binding)
        let natural = makeItem(identity: identity, level: 1, timer: 85, display: binding)
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [old],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 200)
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [natural],
                section: "heroes",
                states: ["timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100)
            )
        )
        XCTAssertEqual(diff.changes.single?.changeKind, .unknown)
        XCTAssertEqual(diff.changes.single?.evidence, .unknown)
    }

    func testHistogramTimerInstanceCountMismatchIsUnknown() throws {
        // 同一 identity 从两个 active timer 变成一个 active timer：
        // 实例数量不一致，无法稳定配对 → unknown，而不是 timerChanged。
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let oldItems = [
            makeItem(identity: identity, level: 14, count: 1, timer: 90, display: binding),
            makeItem(identity: identity, level: 14, count: 1, timer: 80, display: binding)
        ]
        let newItems = [
            makeItem(identity: identity, level: 14, count: 1, timer: 85, display: binding)
        ]
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: oldItems,
                section: "buildings",
                states: ["cnt": .complete, "timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 100)
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: newItems,
                section: "buildings",
                states: ["cnt": .complete, "timer": .complete],
                sourceTimestamp: Date(timeIntervalSince1970: 105)
            )
        )
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .timerChanged })
        XCTAssertTrue(diff.changes.contains { $0.changeKind == .unknown && $0.evidence == .unknown })
    }

    func testHistogramTimerFieldSwapIsUnknown() throws {
        // timer → helper_timer 字段切换：字段集合不一致，无法确认 → unknown。
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, count: 1, timer: 90, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete, "helper_timer": .complete],
            sourceTimestamp: Date(timeIntervalSince1970: 100)
        )
        let swapped = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: [SnapshotObservationItem(
                identity: identity,
                level: 14,
                count: 1,
                rawTimerEvidence: ["helper_timer": .number("85")],
                display: binding
            )],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete, "helper_timer": .complete],
            sourceTimestamp: Date(timeIntervalSince1970: 105)
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: swapped)
        XCTAssertFalse(diff.changes.contains { $0.changeKind == .timerChanged })
        XCTAssertTrue(diff.changes.contains { $0.changeKind == .unknown && $0.evidence == .unknown })
    }

    func testUniqueTimerFieldSwapIsUnknown() throws {
        // unique 路径同样：timer → helper_timer 字段切换 → unknown，而不是无变化。
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, timer: 90, display: binding)],
            section: "heroes",
            states: ["timer": .complete, "helper_timer": .complete],
            sourceTimestamp: Date(timeIntervalSince1970: 100)
        )
        let swapped = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: [SnapshotObservationItem(
                identity: identity,
                level: 1,
                rawTimerEvidence: ["helper_timer": .number("85")],
                display: binding
            )],
            section: "heroes",
            states: ["timer": .complete, "helper_timer": .complete],
            sourceTimestamp: Date(timeIntervalSince1970: 105)
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: swapped)
        XCTAssertEqual(diff.changes.single?.changeKind, .unknown)
        XCTAssertEqual(diff.changes.single?.evidence, .unknown)
    }

    func testCanonicalizerConfirmsTimerAbsenceAndRejectsNegativeTimer() throws {
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        func canonicalEntry(
            _ text: String,
            id: String,
            appliedAt: TimeInterval
        ) throws -> SnapshotHistoryEntry {
            let snapshot = try AccountSnapshotImporter.parse(
                text,
                now: Date(timeIntervalSince1970: appliedAt)
            )
            return try SnapshotHistoryCanonicalizer.canonicalize(
                snapshot: snapshot,
                villageID: villageID,
                lineageID: lineageID,
                appliedAt: Date(timeIntervalSince1970: appliedAt),
                snapshotID: UUID(uuidString: id)!
            )
        }

        let active = try canonicalEntry(
            "{\"heroes\":[{\"data\":1,\"lvl\":1,\"timer\":90}]}",
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            appliedAt: 100
        )
        let completed = try canonicalEntry(
            "{\"heroes\":[{\"data\":1,\"lvl\":2}]}",
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            appliedAt: 200
        )

        XCTAssertEqual(
            completed.coverage.state(base: .home, rawSection: "heroes", field: "timer"),
            .complete
        )
        let completion = SnapshotDiffEngine.compare(from: active, to: completed)
        XCTAssertEqual(completion.changes.single?.changeKind, .upgradeCompleted)
        XCTAssertEqual(completion.changes.single?.evidence, .confirmed)

        let negative = try canonicalEntry(
            "{\"heroes\":[{\"data\":1,\"lvl\":1,\"timer\":-1}]}",
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            appliedAt: 300
        )
        let restarted = try canonicalEntry(
            "{\"heroes\":[{\"data\":1,\"lvl\":1,\"timer\":90}]}",
            id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            appliedAt: 400
        )

        XCTAssertEqual(
            negative.coverage.state(base: .home, rawSection: "heroes", field: "timer"),
            .partial
        )
        let negativeDiff = SnapshotDiffEngine.compare(from: negative, to: restarted)
        XCTAssertEqual(negativeDiff.changes.single?.changeKind, .unknown)
        XCTAssertEqual(negativeDiff.changes.single?.evidence, .unknown)
    }

    func testCanonicalEmptySectionDoesNotConfirmItemDisappearance() throws {
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let oldSnapshot = try AccountSnapshotImporter.parse(
            "{\"heroes\":[{\"data\":1,\"lvl\":1}]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let emptySnapshot = try AccountSnapshotImporter.parse(
            "{\"heroes\":[]}",
            now: Date(timeIntervalSince1970: 200)
        )
        let oldEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: oldSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let emptyEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: emptySnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 200),
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: emptyEntry)

        XCTAssertEqual(diff.changes.single?.changeKind, .unknown)
        XCTAssertEqual(diff.changes.single?.evidence, .unknown)
        XCTAssertEqual(diff.changes.single?.coverage.state, .insufficient)
        XCTAssertTrue(diff.diagnostics.contains { $0.kind == .insufficientCoverage })
    }

    func testCanonicalPartialHistogramDoesNotConfirmQuantityDecrease() throws {
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let oldSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":1000001,\"lvl\":14,\"cnt\":5}]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let newSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":1000001,\"lvl\":14,\"cnt\":3}]}",
            now: Date(timeIntervalSince1970: 200)
        )
        let oldEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: oldSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let newEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: newSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 200),
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)

        XCTAssertEqual(diff.changes.single?.changeKind, .unknown)
        XCTAssertEqual(diff.changes.single?.evidence, .unknown)
        XCTAssertEqual(diff.changes.single?.coverage.state, .insufficient)
        XCTAssertTrue(diff.diagnostics.contains { $0.kind == .insufficientCoverage })
    }

    func testAuthoritativeSectionProofAllowsConfirmedDisappearance() throws {
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let oldSnapshot = try AccountSnapshotImporter.parse(
            "{\"heroes\":[{\"data\":1,\"lvl\":1}]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let emptySnapshot = try AccountSnapshotImporter.parse(
            "{\"heroes\":[]}",
            now: Date(timeIntervalSince1970: 200)
        )
        let proof: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 0)
        ]
        let oldEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: oldSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sectionProofs: [
                "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
            ]
        )
        let emptyEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: emptySnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 200),
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sectionProofs: proof
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: emptyEntry)

        XCTAssertEqual(diff.changes.single?.changeKind, .noLongerObserved)
        XCTAssertEqual(diff.changes.single?.evidence, .confirmed)
        XCTAssertEqual(diff.comparisonState, .comparable)
    }

    func testVerifiedDiffStableAcrossSaveReload() throws {
        let store = TestSnapshotHistoryStore()
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let oldSnapshot = try AccountSnapshotImporter.parse(
            "{\"heroes\":[{\"data\":1,\"lvl\":1}]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let emptySnapshot = try AccountSnapshotImporter.parse(
            "{\"heroes\":[]}",
            now: Date(timeIntervalSince1970: 200)
        )
        let proofOld: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let proofEmpty: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 0)
        ]
        let oldEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: oldSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sectionProofs: proofOld
        )
        let emptyEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: emptySnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 200),
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sectionProofs: proofEmpty
        )
        func postLoadEntry(_ entry: SnapshotHistoryEntry) throws -> SnapshotHistoryEntry {
            let decoded = try JSONDecoder().decode(
                SnapshotHistoryEntry.self,
                from: try JSONEncoder().encode(entry)
            )
            return SnapshotCoverageTrustHydration.hydrate(
                entry: decoded,
                policy: .testsAllowTestFixture
            )
        }
        let liveDiff = SnapshotDiffEngine.compare(
            from: try postLoadEntry(oldEntry),
            to: try postLoadEntry(emptyEntry)
        )
        var envelope = SnapshotHistoryEnvelope(
            entries: [oldEntry, emptyEntry],
            lineages: [
                SnapshotHistoryLineageMetadata(
                    villageID: villageID,
                    lineageID: lineageID,
                    normalizedPlayerTag: nil,
                    lastEntryID: emptyEntry.snapshotID,
                    lastFingerprint: emptyEntry.canonicalFingerprint,
                    lastAppliedAt: emptyEntry.appliedAt,
                    hasConflict: false
                )
            ],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: Date(timeIntervalSince1970: 200))
        )
        try store.save(envelope.validated())
        let reloaded = try XCTUnwrap(try store.load())
        let reloadedOld = try XCTUnwrap(reloaded.entry(id: oldEntry.snapshotID))
        let reloadedEmpty = try XCTUnwrap(reloaded.entry(id: emptyEntry.snapshotID))
        let reloadedDiff = SnapshotDiffEngine.compare(from: reloadedOld, to: reloadedEmpty)
        XCTAssertEqual(reloadedDiff, liveDiff)
    }

    func testCanonicalPresentNonEmptyWithoutProofDoesNotConfirmNewlyObserved() throws {
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let emptySnapshot = try AccountSnapshotImporter.parse(
            "{\"heroes\":[]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let nonEmptySnapshot = try AccountSnapshotImporter.parse(
            "{\"heroes\":[{\"data\":1,\"lvl\":2}]}",
            now: Date(timeIntervalSince1970: 200)
        )
        let emptyEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: emptySnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let nonEmptyEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: nonEmptySnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 200),
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )

        let diff = SnapshotDiffEngine.compare(from: emptyEntry, to: nonEmptyEntry)

        XCTAssertEqual(diff.changes.single?.changeKind, .unknown)
        XCTAssertEqual(diff.changes.single?.evidence, .unknown)
        XCTAssertEqual(diff.changes.single?.coverage.state, .insufficient)
    }

    func testCanonicalHistogramMigrationWithoutProofIsUnknown() throws {
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let oldSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":1000001,\"lvl\":12,\"cnt\":100},{\"data\":1000001,\"lvl\":13,\"cnt\":50}]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let newSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":1000001,\"lvl\":12,\"cnt\":80},{\"data\":1000001,\"lvl\":13,\"cnt\":70}]}",
            now: Date(timeIntervalSince1970: 200)
        )
        let oldEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: oldSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let newEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: newSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 200),
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)

        XCTAssertEqual(diff.changes.single?.changeKind, .unknown)
        XCTAssertEqual(diff.changes.single?.evidence, .unknown)
        XCTAssertEqual(diff.changes.single?.coverage.state, .insufficient)
    }

    func testAuthoritativeProofWithMalformedRecordDegradesToPartial() throws {
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let snapshot = AccountSnapshot(
            tag: "#ABC",
            capturedAt: nil,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            ageSeconds: nil,
            originalText: "{\"heroes\":[{\"lvl\":1}]}",
            objectSections: [:],
            numericSections: [:],
            boosts: [:],
            unknownTopLevelKeys: [],
            diagnostics: []
        )
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sectionProofs: [
                "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
            ]
        )

        let section = try XCTUnwrap(
            entry.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertEqual(section.completeness, .partial)
        XCTAssertFalse(section.isComplete)
    }

    func testAuthoritativeRootProofDoesNotConfirmNestedChildDisappearance() throws {
        // P1 反例：root section 的 authoritative proof 只覆盖根记录枚举，
        // 不能证明 nested types/modules 内容完整。B 缺 types 数组时，
        // 子项消失必须保持 unknown，不能输出 confirmed noLongerObserved。
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let proof: [String: SnapshotCoverageProof] = [
            "buildings": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let oldSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":100,\"types\":[{\"data\":200}]}]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let newSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":100}]}",
            now: Date(timeIntervalSince1970: 200)
        )
        let oldEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: oldSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sectionProofs: proof
        )
        let newEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: newSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 200),
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sectionProofs: proof
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        let childChange = try XCTUnwrap(
            diff.changes.first { $0.identity.dataID == 200 && $0.identity.nestedKind == .type }
        )

        XCTAssertEqual(childChange.changeKind, .unknown)
        XCTAssertEqual(childChange.evidence, .unknown)
        XCTAssertEqual(childChange.coverage.state, .insufficient)
    }

    func testAuthoritativeRootProofDoesNotConfirmNestedChildNewlyObserved() throws {
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let proof: [String: SnapshotCoverageProof] = [
            "buildings": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let oldSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":100}]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let newSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":100,\"types\":[{\"data\":200}]}]}",
            now: Date(timeIntervalSince1970: 200)
        )
        let oldEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: oldSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sectionProofs: proof
        )
        let newEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: newSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 200),
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sectionProofs: proof
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        let childChange = try XCTUnwrap(
            diff.changes.first { $0.identity.dataID == 200 && $0.identity.nestedKind == .type }
        )

        XCTAssertEqual(childChange.changeKind, .unknown)
        XCTAssertEqual(childChange.evidence, .unknown)
        XCTAssertEqual(childChange.coverage.state, .insufficient)
    }

    func testNestedEnumerationTruncationDoesNotConfirmChildDisappearance() throws {
        // P1 反例：types:[200,201] → types:[201] 两侧字段都可解析且
        // coverage complete，但 200 可能是被截断而非真实消失。
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let proof: [String: SnapshotCoverageProof] = [
            "buildings": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let oldSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":100,\"types\":[{\"data\":200},{\"data\":201}]}]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let newSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":100,\"types\":[{\"data\":201}]}]}",
            now: Date(timeIntervalSince1970: 200)
        )
        let oldEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: oldSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sectionProofs: proof
        )
        let newEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: newSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 200),
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sectionProofs: proof
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        let missingChild = try XCTUnwrap(
            diff.changes.first { $0.identity.dataID == 200 && $0.identity.nestedKind == .type }
        )
        XCTAssertEqual(missingChild.changeKind, .unknown)
        XCTAssertEqual(missingChild.evidence, .unknown)
        XCTAssertEqual(missingChild.coverage.state, .insufficient)
    }

    func testNestedEnumerationTruncationDoesNotConfirmChildNewlyObserved() throws {
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let proof: [String: SnapshotCoverageProof] = [
            "buildings": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let oldSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":100,\"types\":[{\"data\":201}]}]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let newSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":100,\"types\":[{\"data\":200},{\"data\":201}]}]}",
            now: Date(timeIntervalSince1970: 200)
        )
        let oldEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: oldSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sectionProofs: proof
        )
        let newEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: newSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 200),
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sectionProofs: proof
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        let newChild = try XCTUnwrap(
            diff.changes.first { $0.identity.dataID == 200 && $0.identity.nestedKind == .type }
        )
        XCTAssertEqual(newChild.changeKind, .unknown)
        XCTAssertEqual(newChild.evidence, .unknown)
        XCTAssertEqual(newChild.coverage.state, .insufficient)
    }

    func testDeepNestedModuleDisappearanceUnderRootModulesIsNotConfirmed() throws {
        // 深层反例（评审原文）：types[].modules[] 缺失时，若根级存在 modules:[]，
        // 根级 modules 字段 coverage 为 complete —— 不能据此确认深层子项消失。
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let proof: [String: SnapshotCoverageProof] = [
            "buildings": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let oldSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":100,\"types\":[{\"data\":200,\"modules\":[{\"data\":300}]}]}]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let newSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":100,\"types\":[{\"data\":200,\"modules\":[]}]}]}",
            now: Date(timeIntervalSince1970: 200)
        )
        let oldEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: oldSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sectionProofs: proof
        )
        let newEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: newSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 200),
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sectionProofs: proof
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        let moduleChange = try XCTUnwrap(
            diff.changes.first { $0.identity.dataID == 300 && $0.identity.nestedKind == .module }
        )
        XCTAssertEqual(moduleChange.changeKind, .unknown)
        XCTAssertEqual(moduleChange.evidence, .unknown)
        XCTAssertEqual(moduleChange.coverage.state, .insufficient)
    }

    func testRootLevelModulesEmptyArrayDoesNotConfirmModuleChildDisappearance() throws {
        // 评审原文反例的根级形态：modules:[{data:300}] → modules:[]（根级字段存在）。
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let proof: [String: SnapshotCoverageProof] = [
            "buildings": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let oldSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":100,\"modules\":[{\"data\":300}]}]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let newSnapshot = try AccountSnapshotImporter.parse(
            "{\"buildings\":[{\"data\":100,\"modules\":[]}]}",
            now: Date(timeIntervalSince1970: 200)
        )
        let oldEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: oldSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sectionProofs: proof
        )
        let newEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: newSnapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 200),
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sectionProofs: proof
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        let moduleChange = try XCTUnwrap(
            diff.changes.first { $0.identity.dataID == 300 && $0.identity.nestedKind == .module }
        )
        XCTAssertEqual(moduleChange.changeKind, .unknown)
        XCTAssertEqual(moduleChange.evidence, .unknown)
        XCTAssertEqual(moduleChange.coverage.state, .insufficient)
    }

    func testAuthoritativeProofWithMalformedNestedArrayDegradesToPartial() throws {
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let snapshot = AccountSnapshot(
            tag: "#ABC",
            capturedAt: nil,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            ageSeconds: nil,
            originalText: "{\"buildings\":[{\"data\":100,\"types\":\"bad\"}]}",
            objectSections: [:],
            numericSections: [:],
            boosts: [:],
            unknownTopLevelKeys: [],
            diagnostics: []
        )
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sectionProofs: [
                "buildings": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
            ]
        )

        let section = try XCTUnwrap(
            entry.coverage.section(base: .home, rawSection: "buildings")
        )
        XCTAssertEqual(section.completeness, .partial)
        XCTAssertFalse(section.isComplete)
    }

    func testMissingRequiredLevelIsUnknownInsteadOfUnchanged() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [makeItem(identity: identity, level: 1, display: SnapshotDisplayBinding(category: "heroes"))],
                section: "heroes"
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: [makeItem(identity: identity, level: nil, display: SnapshotDisplayBinding(category: "heroes"))],
                section: "heroes",
                states: ["lvl": .partial]
            )
        )
        XCTAssertEqual(diff.changes.single?.changeKind, .unknown)
        XCTAssertEqual(diff.changes.single?.evidence, .unknown)
    }

    func testCanonicalCoverageWarningsRemainStructuredDiagnostics() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, display: SnapshotDisplayBinding(category: "heroes"))],
            section: "heroes",
            diagnostics: ["heroes[0].data: unknown dataID"]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 2, display: SnapshotDisplayBinding(category: "heroes"))],
            section: "heroes"
        )

        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        XCTAssertTrue(diff.diagnostics.contains { $0.kind == .malformedObservation && $0.message.contains("unknown dataID") })
        XCTAssertEqual(diff.changes.single?.changeKind, .levelIncreased)
    }

    func testAdjacentDiffsKeepAtoBtoAAndSuppressCrossLineage() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let first = makeEntry(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", date: 100, items: [makeItem(identity: identity, level: 1)], section: "heroes")
        let second = makeEntry(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", date: 200, items: [makeItem(identity: identity, level: 2)], section: "heroes")
        let third = makeEntry(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", date: 300, items: [makeItem(identity: identity, level: 1)], section: "heroes")

        let diffs = SnapshotDiffEngine.adjacentDiffs(in: [first, second, third])
        XCTAssertEqual(diffs.count, 2)
        XCTAssertEqual(diffs.map { $0.changes.single?.levelDelta }, [1, -1])

        let otherLineage = makeEntry(
            id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            date: 400,
            items: [makeItem(identity: identity, level: 3)],
            section: "heroes",
            lineageID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let suppressed = SnapshotDiffEngine.compare(from: third, to: otherLineage)
        XCTAssertEqual(suppressed.comparisonState, .suppressed)
        XCTAssertEqual(suppressed.changes, [])
        XCTAssertEqual(suppressed.diagnostics.single?.kind, .lineageMismatch)

        let interleaved = SnapshotDiffEngine.adjacentDiffs(in: [first, otherLineage, second])
        XCTAssertEqual(interleaved, [])
    }

    func testStatisticsUseAppliedAtTimezoneAndKeepAggregateEvidenceSeparate() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        func pair(id1: String, id2: String, fromDate: Date, toDate: Date, oldLevel: Int, newLevel: Int) -> SnapshotDiff {
            let notApplicable = MetricTestSectionCoverage.heroUniverseNotApplicable
            return SnapshotDiffEngine.compare(
                from: makeEntry(id: id1, date: fromDate.timeIntervalSince1970, items: [makeItem(identity: identity, level: oldLevel, display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes"))], section: "heroes", additionalSections: notApplicable, sourceTimestamp: Date(timeIntervalSince1970: 1)),
                to: makeEntry(id: id2, date: toDate.timeIntervalSince1970, items: [makeItem(identity: identity, level: newLevel, display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes"))], section: "heroes", additionalSections: notApplicable, sourceTimestamp: Date(timeIntervalSince1970: 2))
            )
        }

        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = timeZone
        let reference = date("2024-04-10 10:00:00", calendar: calendar)
        let todayDiff = pair(
            id1: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            id2: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            fromDate: date("2024-04-09 23:00:00", calendar: calendar),
            toDate: date("2024-04-10 09:00:00", calendar: calendar),
            oldLevel: 1,
            newLevel: 2
        )
        let sevenBoundaryDiff = pair(
            id1: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            id2: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            fromDate: date("2024-04-03 23:00:00", calendar: calendar),
            toDate: date("2024-04-04 00:00:00", calendar: calendar),
            oldLevel: 1,
            newLevel: 2
        )
        let thirtyBoundaryDiff = pair(
            id1: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            id2: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            fromDate: date("2024-03-11 23:00:00", calendar: calendar),
            toDate: date("2024-03-12 00:00:00", calendar: calendar),
            oldLevel: 1,
            newLevel: 2
        )

        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [todayDiff, sevenBoundaryDiff, thirtyBoundaryDiff],
            referenceDate: reference,
            calendar: calendar,
            timeZone: timeZone
        )
        XCTAssertEqual(statistics.today.heroLevelGrowth.value, 1)
        XCTAssertEqual(statistics.last7Days.heroLevelGrowth.value, 2)
        XCTAssertEqual(statistics.last30Days.heroLevelGrowth.value, 3)
        XCTAssertEqual(statistics.timeZoneIdentifier, "Asia/Shanghai")

        let empty = SnapshotHistoryStatistics.calculate(
            diffs: [],
            referenceDate: reference,
            calendar: calendar,
            timeZone: timeZone
        )
        XCTAssertEqual(empty.today.heroLevelGrowth.state, .insufficientData)
    }

    func testStatisticsReturnZeroOnlyForCompleteComparableNoChange() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let notApplicable = [MetricTestSectionCoverage.notApplicable("heroes2")]
        let entry = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1)],
            section: "heroes",
            additionalSections: notApplicable
        )
        let same = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 1)],
            section: "heroes",
            additionalSections: notApplicable
        )
        let diff = SnapshotDiffEngine.compare(from: entry, to: same)
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(diff.changes, [])
        XCTAssertEqual(statistics.today.heroLevelGrowth.state, .available)
        XCTAssertEqual(statistics.today.heroLevelGrowth.value, 0)
    }

    func testBuildingMetricsStayInsufficientWhenTrapsSectionSilentlyMissing() throws {
        // Issue #206: buildings complete + traps unavailable + no trap change must
        // not surface available(0) for building completion/level growth metrics.
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, count: 1, display: binding)],
            section: "buildings",
            states: ["cnt": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 14, count: 1, display: binding)],
            section: "buildings",
            states: ["cnt": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        XCTAssertEqual(diff.changes, [])
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.state, .insufficientData)
        XCTAssertEqual(statistics.today.buildingLevelGrowth.state, .insufficientData)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingLevelGrowth.state, .insufficientData)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingUpgradeCompletions.state, .insufficientData)
    }

    func testBuildingMetricsAllowZeroWhenTrapsExplicitlyNotApplicable() throws {
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let notApplicable = [
            MetricTestSectionCoverage.notApplicable("traps"),
            MetricTestSectionCoverage.notApplicable("buildings2"),
            MetricTestSectionCoverage.notApplicable("traps2")
        ]
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, count: 1, display: binding)],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: notApplicable
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 14, count: 1, display: binding)],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: notApplicable
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        XCTAssertEqual(diff.changes, [])
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.state, .available)
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.value, 0)
        XCTAssertEqual(statistics.today.buildingLevelGrowth.state, .available)
        XCTAssertEqual(statistics.today.buildingLevelGrowth.value, 0)
    }

    func testBuildingMigrationStaysInsufficientWhenTrapsSilentlyMissing() throws {
        // Issue #206: observed building migration must not bypass incomplete universe.
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let notApplicable = [
            MetricTestSectionCoverage.notApplicable("buildings2"),
            MetricTestSectionCoverage.notApplicable("traps2")
        ]
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, count: 2, display: binding)],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: notApplicable
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 15, count: 2, display: binding)],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: notApplicable
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        XCTAssertTrue(diff.changes.contains { $0.changeKind == .levelIncreased && $0.identity == identity })
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.state, .insufficientData)
        XCTAssertEqual(statistics.today.buildingLevelGrowth.state, .insufficientData)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingLevelGrowth.state, .insufficientData)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingUpgradeCompletions.state, .insufficientData)
    }

    func testHeroLevelChangeStaysInsufficientWhenBuilderHeroesUnavailable() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1)],
            section: "heroes"
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 2)],
            section: "heroes"
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        XCTAssertTrue(diff.changes.contains { $0.changeKind == .levelIncreased })
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.heroLevelGrowth.state, .insufficientData)
    }

    func testBuildingWindowStaysInsufficientWhenAnyDiffHasMissingTraps() throws {
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let partialNotApplicable = [
            MetricTestSectionCoverage.notApplicable("buildings2"),
            MetricTestSectionCoverage.notApplicable("traps2")
        ]
        let completeUniverse = partialNotApplicable + [
            MetricTestSectionCoverage.complete("traps", states: ["cnt": .complete])
        ]
        let stableItem = makeItem(identity: identity, level: 14, count: 1, display: binding)

        let completeOld = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [stableItem],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: completeUniverse
        )
        let completeNew = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [stableItem],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: completeUniverse
        )
        let incompleteOld = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [stableItem],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: partialNotApplicable
        )
        let incompleteNew = makeEntry(
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            date: 300,
            items: [stableItem],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: partialNotApplicable
        )

        let completeDiff = SnapshotDiffEngine.compare(from: completeOld, to: completeNew)
        let incompleteDiff = SnapshotDiffEngine.compare(from: incompleteOld, to: incompleteNew)
        XCTAssertEqual(completeDiff.changes, [])
        XCTAssertEqual(incompleteDiff.changes, [])

        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [completeDiff, incompleteDiff],
            referenceDate: Date(timeIntervalSince1970: 300),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.state, .insufficientData)
        XCTAssertEqual(statistics.today.buildingLevelGrowth.state, .insufficientData)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingLevelGrowth.state, .insufficientData)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingUpgradeCompletions.state, .insufficientData)
    }

    func testBuildingWindowDoesNotExposeObservedGrowthAcrossIncompleteDiff() throws {
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let partialNotApplicable = [
            MetricTestSectionCoverage.notApplicable("buildings2"),
            MetricTestSectionCoverage.notApplicable("traps2")
        ]
        let completeUniverse = partialNotApplicable + [
            MetricTestSectionCoverage.complete("traps", states: ["cnt": .complete])
        ]

        let completeOld = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, count: 1, display: binding)],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: completeUniverse
        )
        let completeNew = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 14, count: 1, display: binding)],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: completeUniverse
        )
        let incompleteOld = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 14, count: 1, display: binding)],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: partialNotApplicable
        )
        let incompleteNew = makeEntry(
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            date: 300,
            items: [makeItem(identity: identity, level: 15, count: 1, display: binding)],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: partialNotApplicable
        )

        let completeDiff = SnapshotDiffEngine.compare(from: completeOld, to: completeNew)
        let incompleteDiff = SnapshotDiffEngine.compare(from: incompleteOld, to: incompleteNew)
        XCTAssertEqual(completeDiff.changes, [])
        XCTAssertTrue(incompleteDiff.changes.contains { $0.changeKind == .levelIncreased })

        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [completeDiff, incompleteDiff],
            referenceDate: Date(timeIntervalSince1970: 300),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.buildingLevelGrowth.state, .insufficientData)
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.state, .insufficientData)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingLevelGrowth.state, .insufficientData)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingUpgradeCompletions.state, .insufficientData)
    }

    func testHeroWindowStaysInsufficientWhenAnyDiffHasMissingBuilderHeroes() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let completeUniverse = [MetricTestSectionCoverage.notApplicable("heroes2")]

        let completeOld = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, display: binding)],
            section: "heroes",
            additionalSections: completeUniverse
        )
        let completeNew = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 1, display: binding)],
            section: "heroes",
            additionalSections: completeUniverse
        )
        let incompleteOld = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 1, display: binding)],
            section: "heroes"
        )
        let incompleteNew = makeEntry(
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            date: 300,
            items: [makeItem(identity: identity, level: 2, display: binding)],
            section: "heroes"
        )

        let completeDiff = SnapshotDiffEngine.compare(from: completeOld, to: completeNew)
        let incompleteDiff = SnapshotDiffEngine.compare(from: incompleteOld, to: incompleteNew)
        XCTAssertEqual(completeDiff.changes, [])
        XCTAssertTrue(incompleteDiff.changes.contains { $0.changeKind == .levelIncreased })

        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [completeDiff, incompleteDiff],
            referenceDate: Date(timeIntervalSince1970: 300),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.heroLevelGrowth.state, .insufficientData)
    }

    func testHeroWindowPoisonsWhenHomeHeroesAreCompleteEmptyAndBuilderHeroesMissing() throws {
        let heroIdentity = makeIdentity(section: "heroes", dataID: 1)
        let heroBinding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let buildingIdentity = makeIdentity(section: "buildings", dataID: 1)
        let buildingBinding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let buildingItem = makeItem(identity: buildingIdentity, level: 14, count: 1, display: buildingBinding)
        let heroUniverseNotApplicable = [MetricTestSectionCoverage.notApplicable("heroes2")]
        let buildingUniverseNotApplicable = MetricTestSectionCoverage.buildingUniverseNotApplicable

        let growthOld = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: heroIdentity, level: 1, display: heroBinding)],
            section: "heroes",
            additionalSections: heroUniverseNotApplicable
        )
        let growthNew = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: heroIdentity, level: 2, display: heroBinding)],
            section: "heroes",
            additionalSections: heroUniverseNotApplicable
        )
        let hollowOld = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [buildingItem],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: buildingUniverseNotApplicable + [
                MetricTestSectionCoverage.complete("heroes")
            ]
        )
        let hollowNew = makeEntry(
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            date: 300,
            items: [buildingItem],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: buildingUniverseNotApplicable + [
                MetricTestSectionCoverage.complete("heroes")
            ]
        )

        let growthDiff = SnapshotDiffEngine.compare(from: growthOld, to: growthNew)
        let hollowDiff = SnapshotDiffEngine.compare(from: hollowOld, to: hollowNew)
        XCTAssertTrue(growthDiff.changes.contains { $0.changeKind == .levelIncreased })
        XCTAssertEqual(hollowDiff.changes, [])

        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [growthDiff, hollowDiff],
            referenceDate: Date(timeIntervalSince1970: 300),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.heroLevelGrowth.state, .insufficientData)
    }

    func testHeroMetricsStayInsufficientWhenBuilderHeroesUnavailable() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1)],
            section: "heroes"
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 1)],
            section: "heroes"
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.heroLevelGrowth.state, .insufficientData)
    }

    func testTrapUnknownDoesNotPolluteHeroMetricsUnderAggregateApplicability() throws {
        let buildingIdentity = makeIdentity(section: "buildings", dataID: 1)
        let buildingBinding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let trapIdentity = makeIdentity(section: "traps", dataID: 9)
        let trapBinding = SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
        let heroIdentity = makeIdentity(section: "heroes", dataID: 1)
        let heroBinding = SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        let notApplicable = [
            MetricTestSectionCoverage.notApplicable("buildings2"),
            MetricTestSectionCoverage.notApplicable("traps2"),
            MetricTestSectionCoverage.notApplicable("heroes2")
        ]

        let buildingOld = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [
                makeItem(identity: buildingIdentity, level: 14, count: 1, display: buildingBinding),
                makeItem(identity: trapIdentity, level: 1, count: 1, display: trapBinding)
            ],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: notApplicable + [
                MetricTestSectionCoverage.complete("traps", states: ["cnt": .complete])
            ]
        )
        let buildingNew = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [
                makeItem(identity: buildingIdentity, level: 14, count: 1, display: buildingBinding),
                makeItem(identity: trapIdentity, level: 2, display: trapBinding)
            ],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: notApplicable + [
                MetricTestSectionCoverage.complete("traps", states: ["cnt": .partial])
            ]
        )
        let buildingDiff = SnapshotDiffEngine.compare(from: buildingOld, to: buildingNew)
        XCTAssertEqual(buildingDiff.changes.first { $0.identity == trapIdentity }?.changeKind, .unknown)

        let heroOld = makeEntry(
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            date: 100,
            items: [makeItem(identity: heroIdentity, level: 1, display: heroBinding)],
            section: "heroes",
            additionalSections: [MetricTestSectionCoverage.notApplicable("heroes2")]
        )
        let heroNew = makeEntry(
            id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            date: 200,
            items: [makeItem(identity: heroIdentity, level: 2, display: heroBinding)],
            section: "heroes",
            additionalSections: [MetricTestSectionCoverage.notApplicable("heroes2")]
        )
        let heroDiff = SnapshotDiffEngine.compare(from: heroOld, to: heroNew)

        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [buildingDiff, heroDiff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.heroLevelGrowth.state, .available)
        XCTAssertEqual(statistics.today.heroLevelGrowth.value, 1)
        XCTAssertEqual(statistics.today.buildingLevelGrowth.state, .insufficientData)
        XCTAssertEqual(statistics.today.spellLevelGrowth.state, .insufficientData)
    }

    func testStatisticsPropagateInsufficientCoverageForAffectedCategory() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1)],
            section: "heroes"
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: nil)],
            section: "heroes",
            states: ["lvl": .partial]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(diff.comparisonState, .insufficientCoverage)
        XCTAssertEqual(statistics.today.heroLevelGrowth.state, .insufficientData)
    }

    func testWallHistogramStatisticsKeepAggregateEvidenceSeparate() throws {
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let wallUniverseNotApplicable = MetricTestSectionCoverage.wallUniverseNotApplicable
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [
                makeItem(identity: identity, level: 12, count: 100, display: wallBinding()),
                makeItem(identity: identity, level: 13, count: 50, display: wallBinding())
            ],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: wallUniverseNotApplicable
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [
                makeItem(identity: identity, level: 12, count: 80, display: wallBinding()),
                makeItem(identity: identity, level: 13, count: 70, display: wallBinding())
            ],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: wallUniverseNotApplicable
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(statistics.today.wallLevelGrowth.value, 20)
        XCTAssertEqual(statistics.today.aggregateInferredWallLevelGrowth.value, 20)
        XCTAssertEqual(statistics.today.aggregateInferredEventCount.value, 1)
        XCTAssertEqual(statistics.today.buildingLevelGrowth.state, .insufficientData)
    }

    func testTrapHistogramFeedsBuildingStatisticsAndUnknownCoverage() throws {
        let identity = makeIdentity(section: "traps", dataID: 9)
        let trapUniverseNotApplicable = MetricTestSectionCoverage.trapBuildingUniverseNotApplicable
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(
                identity: identity,
                level: 1,
                count: 1,
                display: SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
            )],
            section: "traps",
            states: ["cnt": .complete],
            additionalSections: trapUniverseNotApplicable
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(
                identity: identity,
                level: 2,
                count: 1,
                display: SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
            )],
            section: "traps",
            states: ["cnt": .complete],
            additionalSections: trapUniverseNotApplicable
        )

        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        XCTAssertEqual(diff.changes.single?.evidence, .aggregateInferred)
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.aggregateInferredBuildingLevelGrowth.value, 1)
        XCTAssertEqual(statistics.today.aggregateInferredEventCount.value, 1)
        XCTAssertEqual(statistics.today.wallLevelGrowth.state, .insufficientData)

        let incomplete = makeEntry(
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            date: 300,
            items: [makeItem(
                identity: identity,
                level: 2,
                display: SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
            )],
            section: "traps"
        )
        let incompleteDiff = SnapshotDiffEngine.compare(from: old, to: incomplete)
        XCTAssertEqual(incompleteDiff.changes.single?.changeKind, .unknown)
        let incompleteStatistics = SnapshotHistoryStatistics.calculate(
            diffs: [incompleteDiff],
            referenceDate: Date(timeIntervalSince1970: 300),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(
            incompleteStatistics.today.aggregateInferredEventCount.state,
            .insufficientData
        )
    }

    func testIncompleteTrapCoverageDoesNotDegradeCompleteWallStatistics() throws {
        let wallIdentity = makeIdentity(section: "buildings", dataID: 8)
        let trapIdentity = makeIdentity(section: "traps", dataID: 9)
        let wallUniverseNotApplicable = MetricTestSectionCoverage.wallUniverseNotApplicable
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [
                makeItem(identity: wallIdentity, level: 12, count: 1, display: wallBinding()),
                makeItem(
                    identity: trapIdentity,
                    level: 1,
                    count: 1,
                    display: SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
                )
            ],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: wallUniverseNotApplicable
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [
                makeItem(identity: wallIdentity, level: 13, count: 1, display: wallBinding()),
                makeItem(
                    identity: trapIdentity,
                    level: 2,
                    display: SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
                )
            ],
            section: "buildings",
            states: ["cnt": .complete],
            additionalSections: wallUniverseNotApplicable
        )

        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(diff.changes.count, 2)
        XCTAssertTrue(diff.changes.contains { $0.identity == trapIdentity && $0.changeKind == .unknown })
        XCTAssertEqual(statistics.today.wallLevelGrowth.state, .available)
        XCTAssertEqual(statistics.today.wallLevelGrowth.value, 1)
        XCTAssertEqual(statistics.today.aggregateInferredWallLevelGrowth.value, 1)
    }

    func testBaselineHasNoPredecessorDiff() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let baseline = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1)],
            section: "heroes",
            isBaseline: true
        )
        let regular = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 2)],
            section: "heroes"
        )

        XCTAssertEqual(SnapshotDiffEngine.adjacentDiffs(in: [baseline]).count, 0)
        let reverse = SnapshotDiffEngine.compare(from: regular, to: baseline)
        XCTAssertEqual(reverse.comparisonState, .suppressed)
        XCTAssertTrue(reverse.changes.isEmpty)
        XCTAssertEqual(reverse.diagnostics.single?.kind, .baseline)
        XCTAssertEqual(SnapshotDiffEngine.adjacentDiffs(in: [baseline, regular]).count, 1)
    }

    private struct MetricTestSectionCoverage {
        let section: String
        let states: [String: SnapshotCoverageState]
        let proof: SnapshotCoverageProof
        let presence: SnapshotSectionPresence

        static func complete(
            _ section: String,
            states: [String: SnapshotCoverageState] = [:],
            proof: SnapshotCoverageProof? = nil
        ) -> MetricTestSectionCoverage {
            MetricTestSectionCoverage(
                section: section,
                states: states,
                proof: proof ?? SnapshotHistoryTestCoverage.verified(),
                presence: .presentNonEmpty
            )
        }

        static func notApplicable(_ section: String) -> MetricTestSectionCoverage {
            MetricTestSectionCoverage(
                section: section,
                states: [:],
                proof: SnapshotHistoryTestCoverage.verified(expectedCount: 0),
                presence: .presentEmpty
            )
        }

        static var buildingUniverseNotApplicable: [MetricTestSectionCoverage] {
            [notApplicable("traps"), notApplicable("buildings2"), notApplicable("traps2")]
        }

        static var heroUniverseNotApplicable: [MetricTestSectionCoverage] {
            [notApplicable("heroes2")]
        }

        static var wallUniverseNotApplicable: [MetricTestSectionCoverage] {
            [notApplicable("buildings2")]
        }

        static var trapBuildingUniverseNotApplicable: [MetricTestSectionCoverage] {
            [notApplicable("buildings"), notApplicable("buildings2"), notApplicable("traps2")]
        }
    }

    private func makeEntry(
        id: String,
        date: TimeInterval,
        items: [SnapshotObservationItem],
        section: String?,
        states: [String: SnapshotCoverageState] = [:],
        additionalSections: [MetricTestSectionCoverage] = [],
        diagnostics: [String] = [],
        villageID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        lineageID: UUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        sourceTimestamp: Date? = nil,
        isBaseline: Bool = false,
        timerSchema: SnapshotTimerSchema? = nil,
        observationVersion: Int = SnapshotHistorySchema.observation
    ) -> SnapshotHistoryEntry {
        let coverage: SnapshotObservationCoverage
        if let section {
            let defaults: [String: SnapshotCoverageState] = [
                "presence": .complete,
                "data": .complete,
                "lvl": .complete
            ]
            var sectionCoverages: [SnapshotSectionCoverage] = []
            var fields: [SnapshotCoverageField] = []

            func appendSection(_ spec: MetricTestSectionCoverage) {
                let merged = defaults.merging(spec.states) { _, new in new }
                let observedCount = items.filter { $0.identity.rawSection == spec.section }.count
                let presence = observedCount == 0 ? spec.presence : .presentNonEmpty
                let base = SnapshotHistoryBase(section: spec.section)
                sectionCoverages.append(
                    SnapshotHistoryTestCoverage.trustedSection(
                        base: base,
                        rawSection: spec.section,
                        presence: presence,
                        completeness: .complete,
                        proof: spec.proof,
                        observedCount: observedCount
                    )
                )
                fields.append(contentsOf: merged.map {
                    SnapshotCoverageField(
                        base: SnapshotHistoryBase(section: spec.section),
                        rawSection: spec.section,
                        field: $0.key,
                        state: $0.value
                    )
                })
            }

            appendSection(MetricTestSectionCoverage(
                section: section,
                states: states,
                proof: SnapshotHistoryTestCoverage.verified(),
                presence: items.filter { $0.identity.rawSection == section }.isEmpty ? .presentEmpty : .presentNonEmpty
            ))
            for spec in additionalSections {
                appendSection(spec)
            }
            coverage = SnapshotObservationCoverage(fields: fields, sections: sectionCoverages, diagnostics: diagnostics)
        } else {
            coverage = SnapshotObservationCoverage(fields: [], diagnostics: diagnostics)
        }
        return SnapshotHistoryEntry(
            observationVersion: observationVersion,
            snapshotID: UUID(uuidString: id)!,
            villageID: villageID,
            lineageID: lineageID,
            normalizedPlayerTag: "#TEST",
            appliedAt: Date(timeIntervalSince1970: date),
            sourceTimestamp: sourceTimestamp,
            parserVersion: "test",
            canonicalFingerprint: "test",
            rawJSON: "{}",
            observation: CanonicalSnapshotObservation(rawTopLevelFields: [:], items: items),
            coverage: coverage,
            isBaseline: isBaseline,
            baselineReason: isBaseline ? .initial : nil,
            timerSchema: timerSchema
        )
    }

    private func makeIdentity(
        section: String,
        dataID: Int64,
        base: SnapshotHistoryBase = .home
    ) -> SnapshotItemIdentity {
        SnapshotItemIdentity(base: base, rawSection: section, dataID: dataID)
    }

    private func makeItem(
        identity: SnapshotItemIdentity,
        level: Int?,
        count: Int? = nil,
        timer: Int? = nil,
        display: SnapshotDisplayBinding = SnapshotDisplayBinding()
    ) -> SnapshotObservationItem {
        SnapshotObservationItem(
            identity: identity,
            level: level,
            count: count,
            rawTimerEvidence: timer.map { ["timer": .number(String($0))] } ?? [:],
            display: display
        )
    }

    private func wallBinding() -> SnapshotDisplayBinding {
        SnapshotDisplayBinding(displayName: "城墙", category: "buildings", displayCategory: "walls")
    }

    private func date(_ value: String, calendar: Calendar) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)!
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
