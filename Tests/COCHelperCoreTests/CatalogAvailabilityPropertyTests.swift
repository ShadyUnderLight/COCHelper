import XCTest
@testable import COCHelperCore

/// Issue #98：availability 三态判定的 property-based 测试（确定性、无第三方依赖）。
///
/// 复用共享 `SeededRNG`（VillageCatalogProjectionTests.swift 顶部，同模块 internal；
/// 固定 seed 0x9E3779B97F4A7C15）：随机输入全部由 seed 派生，每次运行结果确定，无 flaky 风险。
///
/// 采样约定（关键坑点）：LCG 低 k 位周期仅 2^k，且本测试的迭代结构固定了各 draw
/// 位置 mod 4 → 直接 `% 2^k`/`% 20` 采样低位会结构性退化：`% 4` 抽 phaseCount 时因
/// 每轮 draw 总数 ≡ 0 mod 4 而永久冻结为初值（表全空、seasonal 0 命中）；`% 20` 抽 key
/// 时表 key 与查询 key 的低 2 位奇偶互斥、永不相等。因此 key 与 phaseCount 一律取
/// `next() >> 32` 高位采样（高位周期 2^33+，实际不可周期）。
final class CatalogAvailabilityPropertyTests: XCTestCase {

    // MARK: - 随机输入生成（全部由 seed 派生，确定性）

    /// 20×20=400 key 空间：表 key 与查询 key 同空间抽取（高位采样见文件头说明），
    /// 500 轮期望命中 ~3-4 次 → seasonal 路径必须被真实采样（性质 3/5 有 hitCount 断言兜底）。
    private func randomKey(_ rng: inout SeededRNG) -> String {
        "s\((rng.next() >> 32) % 20):\((rng.next() >> 32) % 20)"
    }

    private func randomDate(_ rng: inout SeededRNG) -> Date {
        Date(timeIntervalSince1970: Double(rng.next() % 5_000_000_000) - 1_000_000_000)
    }

    private func randomLifecycle(_ rng: inout SeededRNG) -> CatalogLifecycle? {
        switch rng.next() % 3 {
        case 0: return nil
        case 1: return .permanent
        default: return .seasonalCandidate
        }
    }

    /// 随机阶段表：0...3 个阶段，from < until 强制合法（畸形阶段不得进入随机宇宙）。
    private func randomTable(_ rng: inout SeededRNG) -> SeasonalPhaseTable {
        // 高位采样（见文件头）：低位 % 4 会被迭代结构冻结为初值，曾导致全部表为空。
        let phaseCount = Int((rng.next() >> 32) % 4)
        var phases: [SeasonalPhase] = []
        for _ in 0..<phaseCount {
            let from = Date(timeIntervalSince1970: Double(rng.next() % 4_000_000_000) - 2_000_000_000)
            let until = from.addingTimeInterval(Double(rng.next() % 3_000_000_000) + 1)
            let keyCount = Int(rng.next() % 3) + 1
            var keys: [String] = []
            for _ in 0..<keyCount { keys.append(randomKey(&rng)) }
            phases.append(SeasonalPhase(
                phaseID: "p\(rng.next())", name: nil,
                from: from, until: until, itemKeys: keys))
        }
        return SeasonalPhaseTable(schemaVersion: 1, phases: phases)
    }

    // MARK: - seed 确定性

    /// seed 序列确定性锚定：同 seed 生成的序列逐值相等，且首值固定
    ///（SeededRNG(seed: 0x9E3779B97F4A7C15) 首值 0x45D060C48725F6B1 = 5030627180970112689
    /// 由固定参数计算得出；漂移 → 全部性质用例不可复现，立即暴露）。
    func testPropertySeedSequenceDeterministic() {
        var first = SeededRNG(seed: 0x9E37_79B9_7F4A_7C15)
        var second = SeededRNG(seed: 0x9E37_79B9_7F4A_7C15)
        for _ in 0..<10 {
            XCTAssertEqual(first.next(), second.next(), "同 seed 序列必须逐值一致")
        }
        var probe = SeededRNG(seed: 0x9E37_79B9_7F4A_7C15)
        XCTAssertEqual(probe.next(), 5_030_627_180_970_112_689,
                       "seed 序列首值漂移（LCG 参数被改）")
    }

    // MARK: - 性质

    /// 性质 1（Issue #113 改性质）：permanent 与阶段表冲突契约——permanent + 无候选阶段
    /// → .permanent；permanent + 候选非空 → .conflict（fail-closed，不静默选边）。
    /// 独立 oracle（审计 F4）：命中判定直接从 `table.phases` 原始过滤推导——
    /// 候选 = itemKeys 包含 key 且 from < until 的集合，命中 = 候选非空；**不调用**
    /// `availability()` 内部同源的 `phase(forItemKey:at:)`，防命中/过滤/选择逻辑整体
    /// 偏移时测试镜像通过（循环引用）。availability 内部对候选的选择（active 优先等）
    /// 不影响 conflict 判定（只要非空即 conflict），故 oracle 只需判「候选非空」。
    /// hitCount > 0 断言防 randomTable 退化导致 conflict 路径空过。
    func testPropertyPermanentConflictContract() {
        var rng = SeededRNG(seed: 0x9E37_79B9_7F4A_7C15)
        var conflictHitCount = 0
        for _ in 0..<500 {
            let table = randomTable(&rng)
            let key = randomKey(&rng)
            let date = randomDate(&rng)
            // 独立 oracle：与 phase() 内部 valid 过滤同条件，但不调用它。
            let candidates = table.phases.filter { $0.itemKeys.contains(key) && $0.from < $0.until }
            let result = table.availability(forItemKey: key, lifecycle: .permanent, at: date)
            if !candidates.isEmpty {
                conflictHitCount += 1
                // 只断言形态：字段透传一致性由性质 6 以独立候选集验证（此处不镜像选择逻辑）。
                guard case .conflict = result else {
                    XCTFail("permanent + 候选阶段非空必须返回 .conflict（key=\(key)）")
                    continue
                }
            } else {
                XCTAssertEqual(
                    result, .permanent,
                    "permanent + 无候选阶段不得降级（key=\(key)）")
            }
        }
        XCTAssertGreaterThan(conflictHitCount, 0,
                             "conflict 路径必须被采样到（防参数漂移导致空过）")
    }

    /// 性质 2：纯函数确定性——同输入两次调用结果相等（500 组）。
    func testPropertyDeterministic() {
        var rng = SeededRNG(seed: 0x9E37_79B9_7F4A_7C15)
        for _ in 0..<500 {
            let table = randomTable(&rng)
            let key = randomKey(&rng)
            let date = randomDate(&rng)
            let lifecycle = randomLifecycle(&rng)
            XCTAssertEqual(
                table.availability(forItemKey: key, lifecycle: lifecycle, at: date),
                table.availability(forItemKey: key, lifecycle: lifecycle, at: date),
                "同输入两次调用必须相等")
        }
    }

    /// 性质 3：结果值域闭——{permanent, seasonal, unconfigured, conflict}；
    /// seasonal.status ∈ {notStarted, active, ended}（500 组全随机输入）。
    /// seasonal 命中必须 > 0：key 空间 400 下期望 ~3 次，断言防参数漂移导致空过。
    /// conflict（Issue #113）与 seasonal 同属阶段命中路径，在生命周期随机宇宙中被采样。
    func testPropertyResultDomain() {
        var rng = SeededRNG(seed: 0x9E37_79B9_7F4A_7C15)
        var seasonalHitCount = 0
        for _ in 0..<500 {
            let table = randomTable(&rng)
            let key = randomKey(&rng)
            let date = randomDate(&rng)
            let lifecycle = randomLifecycle(&rng)
            let result = table.availability(forItemKey: key, lifecycle: lifecycle, at: date)
            switch result {
            case .permanent, .unconfigured:
                break
            case .seasonal(_, _, let status):
                seasonalHitCount += 1
                XCTAssertTrue(
                    status == .notStarted || status == .active || status == .ended,
                    "非法 seasonal status: \(status)")
            case .conflict:
                break
            }
        }
        XCTAssertGreaterThan(seasonalHitCount, 0,
                             "seasonal 路径必须被采样到（防参数漂移导致空过）")
    }

    /// 性质 4：时间边界一致性——单阶段（from < until 强制）五点采样：
    /// from-1s / from / until-1s / until / until+1s → notStarted/active/active/ended/ended
    ///（100 个随机阶段，每阶段独立 key 防多阶段干扰）。
    func testPropertyTimeBoundaryConsistency() {
        var rng = SeededRNG(seed: 0x9E37_79B9_7F4A_7C15)
        for i in 0..<100 {
            let from = Date(timeIntervalSince1970: Double(rng.next() % 4_000_000_000) - 2_000_000_000)
            let until = from.addingTimeInterval(Double(rng.next() % 3_000_000_000) + 1)
            let key = "boundary:\(i)"
            let table = SeasonalPhaseTable(schemaVersion: 1, phases: [
                SeasonalPhase(phaseID: "b\(i)", name: nil,
                              from: from, until: until, itemKeys: [key]),
            ])
            let samples: [(Date, SeasonalStatus)] = [
                (from.addingTimeInterval(-1), .notStarted),
                (from, .active),
                (until.addingTimeInterval(-1), .active),
                (until, .ended),
                (until.addingTimeInterval(1), .ended),
            ]
            for (date, expected) in samples {
                guard case .seasonal(_, _, let status) = table.availability(
                    forItemKey: key, lifecycle: .seasonalCandidate, at: date) else {
                    XCTFail("i=\(i) date=\(date.timeIntervalSince1970): 阶段必须命中并返回 seasonal")
                    continue
                }
                XCTAssertEqual(
                    status, expected,
                    "i=\(i) date=\(date.timeIntervalSince1970)（from=\(from.timeIntervalSince1970) until=\(until.timeIntervalSince1970)）")
            }
        }
    }

    /// 性质 5：seasonal 的 phaseID 必须来自该 key 的候选阶段（不得引入表外阶段；
    /// 500 组随机表/随机 key/随机日期）。seasonal 命中必须 > 0：key 空间 400 下
    /// 期望 ~3 次，计数断言防参数漂移导致路径空过（测试名不副实）。
    func testPropertySeasonalPhaseIDComesFromTable() {
        var rng = SeededRNG(seed: 0x9E37_79B9_7F4A_7C15)
        var hitCount = 0
        for _ in 0..<500 {
            let table = randomTable(&rng)
            let key = randomKey(&rng)
            let date = randomDate(&rng)
            let result = table.availability(forItemKey: key, lifecycle: .seasonalCandidate, at: date)
            guard case .seasonal(let phaseID, _, _) = result else { continue }
            hitCount += 1
            let candidates = table.phases.filter { $0.itemKeys.contains(key) }.map(\.phaseID)
            XCTAssertTrue(
                candidates.contains(phaseID),
                "phaseID \(phaseID) 不在 key \(key) 的候选阶段集 \(candidates)")
        }
        XCTAssertGreaterThan(hitCount, 0,
                             "seasonal 路径必须被采样到（防参数漂移导致空过）")
    }

    /// 性质 6（Issue #113）：conflict 的 phaseID/phaseName/sourceURL 必须来自该 key 的
    /// **候选阶段**（不得引入表外阶段、不得编造来源）——独立 oracle（审计 F4）：候选 =
    /// phases 中 itemKeys 包含 key 且 from < until 的集合，直接从原始表推导，**不调用**
    /// `phase(forItemKey:at:)`（防与实现镜像/循环引用）；availability 对候选的具体选择
    /// 不约束（仿照 testPropertySeasonalPhaseIDComesFromTable 的候选集模式）。
    /// 500 组随机表/随机 key/随机日期。hitCount > 0 断言防参数漂移导致路径空过。
    func testPropertyConflictPhaseIDComesFromTable() {
        var rng = SeededRNG(seed: 0x9E37_79B9_7F4A_7C15)
        var hitCount = 0
        for _ in 0..<500 {
            let table = randomTable(&rng)
            let key = randomKey(&rng)
            let date = randomDate(&rng)
            let result = table.availability(forItemKey: key, lifecycle: .permanent, at: date)
            guard case .conflict(let phaseID, let phaseName, _, let sourceURL) = result else { continue }
            hitCount += 1
            let candidates = table.phases.filter { $0.itemKeys.contains(key) && $0.from < $0.until }
            XCTAssertFalse(candidates.isEmpty,
                           "conflict 前提是候选阶段非空（key=\(key)）")
            XCTAssertTrue(
                candidates.contains(where: { $0.phaseID == phaseID }),
                "conflict phaseID \(phaseID) 不在 key \(key) 的候选阶段集")
            if let matched = candidates.first(where: { $0.phaseID == phaseID }) {
                XCTAssertEqual(phaseName, matched.name,
                               "conflict phaseName 必须来自候选阶段（key=\(key)）")
                XCTAssertEqual(sourceURL, matched.sourceURL,
                               "conflict sourceURL 必须来自候选阶段（key=\(key)）")
            }
        }
        XCTAssertGreaterThan(hitCount, 0,
                             "conflict 路径必须被采样到（防参数漂移导致空过）")
    }
}
