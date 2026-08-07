import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

/// Issue #61 数据层：按显式 villageID 的快捷快照导入
/// （`prepareQuickImport(for:)` / `applyQuickImport(_:)`）。
///
/// 类级不标 @MainActor——XCTest 的 setUp/tearDown 是 nonisolated override；
/// 访问 AppModel（@MainActor）的测试方法与 helper 单独标注（与 AppModelTests 一致）。
final class AppModelQuickImportTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppModelQuickImportTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        // 按 suite 名清理测试域（UserDefaults 无公开 suiteName getter，
        // 由 setUp 记录；避免每次运行泄漏一个 plist）。
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSnapshot(
        tag: String?,
        originalText: String = "{}",
        unknownTopLevelKeys: [String] = [],
        diagnostics: [AccountDataDiagnostic] = []
    ) -> AccountSnapshot {
        AccountSnapshot(
            tag: tag, capturedAt: nil, importedAt: Date(), ageSeconds: nil,
            originalText: originalText, objectSections: [:], numericSections: [:],
            boosts: [:], unknownTopLevelKeys: unknownTopLevelKeys,
            diagnostics: diagnostics
        )
    }

    @MainActor
    private func makeModel(
        villages: [VillageProfile],
        clipboardReader: @escaping () -> String? = { nil }
    ) -> AppModel {
        defaults.set(try! JSONEncoder().encode(villages), forKey: "coc-helper.villages.v1")
        return AppModel(defaults: defaults, clipboardReader: clipboardReader)
    }

    private func persistedVillagesData() -> Data? {
        defaults.data(forKey: "coc-helper.villages.v1")
    }

    // MARK: - 确定性用例

    /// 有效 JSON（tag 与目标村庄相同）→ 成功预览：ID/名称/标题/同 tag 判定/描述。
    @MainActor
    func testPrepareSuccessCapturesTargetIDAndName() async {
        let a = VillageProfile(
            name: "A",
            accountSnapshot: makeSnapshot(tag: "#ABC"),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let clipboard: String? = ##"{"tag":"#ABC","buildings":[]}"##
        let model = makeModel(villages: [a]) { clipboard }
        let targetID = model.villages[0].id

        let result = model.prepareQuickImport(for: targetID)

        guard case .success(let preview) = result else {
            return XCTFail("应成功，实际失败: \(result)")
        }
        XCTAssertEqual(preview.targetVillageID, targetID)
        XCTAssertEqual(preview.targetVillageName, "A")
        XCTAssertEqual(preview.targetVillageTag, "#ABC")
        XCTAssertEqual(preview.isFirstImport, false)
        XCTAssertEqual(preview.replacesSameTag, true)
        XCTAssertEqual(preview.confirmationTitle, "更新「A」")
        XCTAssertTrue(preview.destinationDescription.contains("更新"),
                      "同 tag 导入描述应含「更新」: \(preview.destinationDescription)")
    }

    /// 目标村庄无快照 → isFirstImport、描述为「建立」分支。
    @MainActor
    func testPrepareFirstImportDescription() async {
        let a = VillageProfile(name: "A")
        let clipboard: String? = ##"{"tag":"#NEW","buildings":[]}"##
        let model = makeModel(villages: [a]) { clipboard }

        let result = model.prepareQuickImport(for: model.villages[0].id)

        guard case .success(let preview) = result else {
            return XCTFail("应成功，实际失败: \(result)")
        }
        XCTAssertNil(preview.targetVillageTag)
        XCTAssertEqual(preview.isFirstImport, true)
        XCTAssertEqual(preview.targetVillageHasSnapshot, false)
        XCTAssertEqual(preview.replacesSameTag, false)
        XCTAssertEqual(preview.destinationDescription, "将建立「A」的账号快照并导入")
        XCTAssertTrue(preview.destinationDescription.contains("建立"))
    }

    /// P2：目标村庄已有快照但快照无 Tag（targetVillageTag 为 nil）时，
    /// 不得误判为首次导入（isFirstImport=false、hasSnapshot=true、描述走
    /// 「JSON 未提供账号 Tag」分支而非「建立」分支）。
    @MainActor
    func testPrepareHasSnapshotWithoutTagIsNotFirstImport() async {
        let a = VillageProfile(
            name: "A",
            accountSnapshot: makeSnapshot(tag: nil, originalText: "{\"buildings\":[]}")
        )
        let clipboard: String? = ##"{"buildings":[]}"##
        let model = makeModel(villages: [a]) { clipboard }

        let result = model.prepareQuickImport(for: model.villages[0].id)

        guard case .success(let preview) = result else {
            return XCTFail("应成功，实际失败: \(result)")
        }
        XCTAssertNil(preview.targetVillageTag)
        XCTAssertEqual(preview.targetVillageHasSnapshot, true)
        XCTAssertEqual(preview.isFirstImport, false, "有快照但无 Tag 不是首次导入")
        XCTAssertFalse(preview.destinationDescription.contains("建立"),
                       "有快照时描述不得进入「建立」分支: \(preview.destinationDescription)")
        XCTAssertTrue(preview.destinationDescription.contains("JSON 未提供账号 Tag"),
                      "JSON 无 tag 应走缺失分支: \(preview.destinationDescription)")
    }

    /// P2 补充：目标村庄有快照但无 Tag、JSON 带 Tag → 描述走「Tag 变化被重置」
    /// 分支（从无 tag 变为有 tag），不得进入「建立」分支。
    @MainActor
    func testPrepareHasSnapshotWithoutTagWithJSONTag() async {
        let a = VillageProfile(
            name: "A",
            accountSnapshot: makeSnapshot(tag: nil, originalText: "{\"buildings\":[]}")
        )
        let clipboard: String? = ##"{"tag":"#NEW","buildings":[]}"##
        let model = makeModel(villages: [a]) { clipboard }

        let result = model.prepareQuickImport(for: model.villages[0].id)

        guard case .success(let preview) = result else {
            return XCTFail("应成功，实际失败: \(result)")
        }
        XCTAssertEqual(preview.targetVillageHasSnapshot, true)
        XCTAssertEqual(preview.isFirstImport, false)
        XCTAssertFalse(preview.destinationDescription.contains("建立"))
        XCTAssertTrue(preview.destinationDescription.contains("Tag 变化被重置"),
                      "目标无 tag → JSON 有 tag 应走变化分支: \(preview.destinationDescription)")
    }

    /// P2 边界：空字符串 Tag 保留原样（UI 层负责「未提供」展示），
    /// 数据层承诺 targetVillageTag 是「原样、未规范化」。
    @MainActor
    func testPrepareEmptyTagKeptAsIs() async {
        let a = VillageProfile(
            name: "A",
            accountSnapshot: makeSnapshot(tag: "  ", originalText: "{\"buildings\":[]}")
        )
        let clipboard: String? = ##"{"tag":"#NEW","buildings":[]}"##
        let model = makeModel(villages: [a]) { clipboard }

        let result = model.prepareQuickImport(for: model.villages[0].id)

        guard case .success(let preview) = result else {
            return XCTFail("应成功，实际失败: \(result)")
        }
        XCTAssertEqual(preview.targetVillageTag, "  ", "targetVillageTag 保持原样")
        XCTAssertEqual(preview.targetVillageHasSnapshot, true)
    }

    /// 剪贴板为 nil → .emptyClipboard。
    @MainActor
    func testPrepareEmptyClipboardFails() async {
        let a = VillageProfile(name: "A", accountSnapshot: makeSnapshot(tag: "#A"))
        let model = makeModel(villages: [a]) { nil }

        let result = model.prepareQuickImport(for: model.villages[0].id)

        guard case .failure(let error) = result else {
            return XCTFail("应失败，实际成功: \(result)")
        }
        XCTAssertEqual(error, .emptyClipboard)
        XCTAssertEqual(error.errorDescription, "系统剪贴板中没有可用的文本。")
    }

    /// 剪贴板仅空白 → .emptyClipboard。
    @MainActor
    func testPrepareBlankClipboardFails() async {
        let a = VillageProfile(name: "A", accountSnapshot: makeSnapshot(tag: "#A"))
        let model = makeModel(villages: [a]) { "   \n" }

        let result = model.prepareQuickImport(for: model.villages[0].id)

        guard case .failure(.emptyClipboard) = result else {
            return XCTFail("空白剪贴板应视为空: \(result)")
        }
    }

    /// 非 JSON 文本 → .parseFailed。
    @MainActor
    func testPrepareMalformedJSONFails() async {
        let a = VillageProfile(name: "A", accountSnapshot: makeSnapshot(tag: "#A"))
        let model = makeModel(villages: [a]) { "not json" }

        let result = model.prepareQuickImport(for: model.villages[0].id)

        guard case .failure(.parseFailed(let parseError)) = result else {
            return XCTFail("应解析失败: \(result)")
        }
        XCTAssertEqual(parseError.errorDescription, "JSON 顶层必须是对象，以 { 开头。")
        // QuickImportError.errorDescription 透传 parseFailed 的文案。
        guard case .failure(let error) = result else { return XCTFail("不应成功") }
        XCTAssertEqual(error.errorDescription, "JSON 顶层必须是对象，以 { 开头。")
    }

    /// 顶层非对象（数组）→ .parseFailed(.topLevelMustBeObject)。
    @MainActor
    func testPrepareNonObjectTopLevelFails() async {
        let a = VillageProfile(name: "A", accountSnapshot: makeSnapshot(tag: "#A"))
        let model = makeModel(villages: [a]) { "[1,2]" }

        let result = model.prepareQuickImport(for: model.villages[0].id)

        guard case .failure(.parseFailed(.topLevelMustBeObject)) = result else {
            return XCTFail("顶层数组应报 topLevelMustBeObject: \(result)")
        }
    }

    /// A 页面粘贴 B 的 tag JSON → 拦截，且 A/B 数据均不变（prepare 无副作用）。
    @MainActor
    func testPrepareTagBelongsToAnotherVillageBlocks() async {
        let a = VillageProfile(name: "A", accountSnapshot: makeSnapshot(tag: "#A"))
        let b = VillageProfile(name: "B", accountSnapshot: makeSnapshot(tag: "#B"))
        let clipboard: String? = ##"{"tag":"#B","buildings":[]}"##
        let model = makeModel(villages: [a, b]) { clipboard }
        let aID = model.villages[0].id
        let villagesBefore = model.villages
        let persistedBefore = persistedVillagesData()

        let result = model.prepareQuickImport(for: aID)

        guard case .failure(.tagBelongsToAnotherVillage(let tag, let name)) = result else {
            return XCTFail("应拦截他村 tag: \(result)")
        }
        XCTAssertEqual(tag, "#B")
        XCTAssertEqual(name, "B")
        guard case .failure(let error) = result else { return XCTFail("不应成功") }
        XCTAssertEqual(error.errorDescription,
                       "剪贴板 JSON 的账号 Tag（#B）属于另一档案「B」。为避免误覆盖，请到「账号数据」页手动导入。")
        XCTAssertEqual(model.villages, villagesBefore, "拦截后村庄数据不得变化")
        XCTAssertEqual(persistedVillagesData(), persistedBefore, "拦截后持久化数据不得变化")
    }

    /// H1（Issue #61 修复）：拦截必须大小写不敏感——A(#ABC)、B(#ABC) 同 tag 两档案，
    /// A 页粘贴小写变体 {"tag":"#abc"} → 必须拦截（否则 apply 后 A 被 B 的账号数据覆盖）。
    @MainActor
    func testPrepareLowercaseTagVariantBlocked() async {
        let a = VillageProfile(name: "A", accountSnapshot: makeSnapshot(tag: "#ABC"))
        let b = VillageProfile(name: "B", accountSnapshot: makeSnapshot(tag: "#ABC"))
        let clipboard: String? = ##"{"tag":"#abc","buildings":[]}"##
        let model = makeModel(villages: [a, b]) { clipboard }
        let aID = model.villages[0].id
        let villagesBefore = model.villages
        let persistedBefore = persistedVillagesData()

        let result = model.prepareQuickImport(for: aID)

        guard case .failure(.tagBelongsToAnotherVillage(let tag, let name)) = result else {
            return XCTFail("小写 tag 变体必须被拦截（大小写不敏感）: \(result)")
        }
        XCTAssertEqual(tag, "#abc", "错误信息应展示剪贴板原始 tag")
        XCTAssertEqual(name, "B")
        XCTAssertEqual(model.villages, villagesBefore, "拦截后村庄数据不得变化")
        XCTAssertEqual(persistedVillagesData(), persistedBefore, "拦截后持久化数据不得变化")
    }

    /// H2（Issue #61 修复）：拦截必须容忍缺 # 变体——A(#ABC)、B(#ABC)，
    /// A 页粘贴 {"tag":"ABC"} → 必须拦截（normalized 不补 #，比较时须归一）。
    @MainActor
    func testPrepareMissingHashVariantBlocked() async {
        let a = VillageProfile(name: "A", accountSnapshot: makeSnapshot(tag: "#ABC"))
        let b = VillageProfile(name: "B", accountSnapshot: makeSnapshot(tag: "#ABC"))
        let clipboard: String? = ##"{"tag":"ABC","buildings":[]}"##
        let model = makeModel(villages: [a, b]) { clipboard }
        let aID = model.villages[0].id
        let villagesBefore = model.villages
        let persistedBefore = persistedVillagesData()

        let result = model.prepareQuickImport(for: aID)

        guard case .failure(.tagBelongsToAnotherVillage(let tag, let name)) = result else {
            return XCTFail("缺 # tag 变体必须被拦截: \(result)")
        }
        XCTAssertEqual(tag, "ABC", "错误信息应展示剪贴板原始 tag")
        XCTAssertEqual(name, "B")
        XCTAssertEqual(model.villages, villagesBefore, "拦截后村庄数据不得变化")
        XCTAssertEqual(persistedVillagesData(), persistedBefore, "拦截后持久化数据不得变化")
    }

    /// 目标村庄 ID 不存在 → .targetVillageMissing。
    @MainActor
    func testPrepareMissingTargetVillageFails() async {
        let a = VillageProfile(name: "A", accountSnapshot: makeSnapshot(tag: "#A"))
        let model = makeModel(villages: [a]) { ##"{"tag":"#A","buildings":[]}"## }

        let result = model.prepareQuickImport(for: UUID())

        guard case .failure(.targetVillageMissing) = result else {
            return XCTFail("随机 ID 应报目标村庄缺失: \(result)")
        }
        guard case .failure(let error) = result else { return XCTFail("不应成功") }
        XCTAssertEqual(error.errorDescription, "目标村庄已不存在，请刷新后重试。")
    }

    /// 无 tag 的有效 JSON → 成功（无 tag 不匹配任何村庄，走「应用到」分支）。
    @MainActor
    func testPrepareNoTagJSONAllowed() async {
        let a = VillageProfile(name: "A", accountSnapshot: makeSnapshot(tag: "#OLD"))
        let b = VillageProfile(name: "B", accountSnapshot: makeSnapshot(tag: "#B"))
        let clipboard: String? = ##"{"buildings":[]}"##
        let model = makeModel(villages: [a, b]) { clipboard }
        let targetID = model.villages[0].id

        let result = model.prepareQuickImport(for: targetID)

        guard case .success(let preview) = result else {
            return XCTFail("无 tag JSON 应允许导入: \(result)")
        }
        XCTAssertEqual(preview.targetVillageID, targetID)
        XCTAssertEqual(preview.replacesSameTag, false, "无 tag 不构成同 tag 更新")
        XCTAssertEqual(preview.destinationDescription,
                       "导入目标：按当前详情页应用到「A」。JSON 未提供账号 Tag，将按当前目标处理，原官方数据将因 Tag 缺失被重置")
    }

    /// 锁定（Issue #61 修复）：replacesSameTag 保持大小写敏感——单档案 A(#ABC)
    /// 粘贴 {"tag":"#abc"} → 成功且 replacesSameTag == false（与
    /// applyImportedSnapshot 的 tagChanged 判定同基准，避免「预览说同 Tag 更新、
    /// 实际官方状态被清」的语义矛盾），预览描述走「Tag 变化被重置」分支。
    @MainActor
    func testPrepareLowercaseTagSingleVillageNotSameTag() async {
        let a = VillageProfile(
            name: "A",
            accountSnapshot: makeSnapshot(tag: "#ABC"),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let clipboard: String? = ##"{"tag":"#abc","buildings":[]}"##
        let model = makeModel(villages: [a]) { clipboard }
        let aID = model.villages[0].id

        let result = model.prepareQuickImport(for: aID)

        guard case .success(let preview) = result else {
            return XCTFail("单档案小写变体不应被拦截: \(result)")
        }
        XCTAssertEqual(preview.targetVillageID, aID)
        XCTAssertFalse(preview.replacesSameTag,
                       "replacesSameTag 必须保持大小写敏感（与 applyImportedSnapshot 契约一致）")
        XCTAssertTrue(preview.destinationDescription.contains("Tag 变化被重置"),
                      "大小写变体应按 Tag 变化分支描述: \(preview.destinationDescription)")
    }

    /// 锁定（Issue #61 修复）：目标已有快照 + JSON 无 tag → 成功，描述走独立的
    /// 「Tag 缺失」分支（区分「缺失」与「变化」——缺失 ≠ 变化，文案不得混用）。
    @MainActor
    func testPrepareNoTagWhenTargetHasSnapshotDescription() async {
        let a = VillageProfile(
            name: "A",
            accountSnapshot: makeSnapshot(tag: "#OLD"),
            officialAPIState: OfficialAPIState(status: .success),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let clipboard: String? = ##"{"buildings":[]}"##
        let model = makeModel(villages: [a]) { clipboard }
        let aID = model.villages[0].id

        let result = model.prepareQuickImport(for: aID)

        guard case .success(let preview) = result else {
            return XCTFail("无 tag JSON 应成功: \(result)")
        }
        XCTAssertEqual(preview.targetVillageID, aID)
        XCTAssertFalse(preview.replacesSameTag)
        XCTAssertTrue(preview.destinationDescription.contains("未提供账号 Tag"),
                      "无 tag 分支应说明 Tag 缺失: \(preview.destinationDescription)")
        XCTAssertTrue(preview.destinationDescription.contains("按当前目标处理"),
                      "无 tag 分支应说明按当前目标处理: \(preview.destinationDescription)")
    }

    /// apply 只更新目标村庄：A 的快照 tag 更新、B 完全不变、updatedAt 更新。
    @MainActor
    func testApplyUpdatesOnlyTargetVillage() async {
        let a = VillageProfile(
            name: "A",
            accountSnapshot: makeSnapshot(tag: "#A"),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let b = VillageProfile(name: "B", accountSnapshot: makeSnapshot(tag: "#B"))
        let clipboard: String? = ##"{"tag":"#A2","buildings":[]}"##
        let model = makeModel(villages: [a, b]) { clipboard }
        let aID = model.villages[0].id

        guard case .success(let preview) = model.prepareQuickImport(for: aID) else {
            return XCTFail("prepare 应成功")
        }
        let updatedAtBefore = model.villages[0].updatedAt
        let bBefore = model.villages[1]
        try? await Task.sleep(nanoseconds: 5_000_000)  // 保证 Date() 前进，updatedAt 严格更新

        model.applyQuickImport(preview)

        XCTAssertEqual(model.villages[0].accountSnapshot?.tag, "#A2", "A 的快照 tag 必须更新")
        XCTAssertEqual(model.villages[0].accountSnapshot?.originalText, ##"{"tag":"#A2","buildings":[]}"##)
        XCTAssertGreaterThan(model.villages[0].updatedAt, updatedAtBefore, "A 的 updatedAt 必须更新")
        XCTAssertEqual(model.villages[1], bBefore, "B 不得有任何变化")
        XCTAssertEqual(model.villages[1].accountSnapshot?.tag, "#B")
    }

    /// 同 tag 导入 → 官方状态保留（applyImportedSnapshot 契约）。
    @MainActor
    func testApplyKeepsOfficialStateOnSameTag() async {
        let a = VillageProfile(
            name: "A",
            accountSnapshot: makeSnapshot(tag: "#SAME"),
            officialAPIState: OfficialAPIState(status: .success),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let clipboard: String? = ##"{"tag":"#SAME","buildings":[]}"##
        let model = makeModel(villages: [a]) { clipboard }

        guard case .success(let preview) = model.prepareQuickImport(for: model.villages[0].id) else {
            return XCTFail("prepare 应成功")
        }
        XCTAssertTrue(preview.replacesSameTag)

        model.applyQuickImport(preview)

        XCTAssertNotNil(model.villages[0].officialAPIState, "同 tag 导入必须保留官方数据")
    }

    /// tag 变化导入 → 官方状态清空。
    @MainActor
    func testApplyClearsOfficialStateOnTagChange() async {
        let a = VillageProfile(
            name: "A",
            accountSnapshot: makeSnapshot(tag: "#OLD"),
            officialAPIState: OfficialAPIState(status: .success),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let clipboard: String? = ##"{"tag":"#NEW","buildings":[]}"##
        let model = makeModel(villages: [a]) { clipboard }

        guard case .success(let preview) = model.prepareQuickImport(for: model.villages[0].id) else {
            return XCTFail("prepare 应成功")
        }
        XCTAssertFalse(preview.replacesSameTag)

        model.applyQuickImport(preview)

        XCTAssertNil(model.villages[0].officialAPIState, "tag 变化导入必须重置官方数据")
    }

    /// round-trip：apply 后新建 AppModel 从同一 defaults 加载，
    /// 快照 originalText / diagnostics / unknownTopLevelKeys / tag 完全相等。
    @MainActor
    func testApplyRoundTripPreservesOriginalTextAndDiagnostics() async {
        let a = VillageProfile(name: "A", updatedAt: Date(timeIntervalSince1970: 0))
        let json = ##"{"tag":"#RT","future_field":{"value":true},"buildings":[]}"##
        let clipboard: String? = json
        let model = makeModel(villages: [a]) { clipboard }
        let aID = model.villages[0].id

        guard case .success(let preview) = model.prepareQuickImport(for: aID) else {
            return XCTFail("prepare 应成功")
        }
        XCTAssertEqual(preview.snapshot.unknownTopLevelKeys, ["future_field"],
                       "解析器应记录未知顶层键")
        XCTAssertTrue(preview.snapshot.diagnostics.contains { $0.path == "顶层" && $0.severity == .warning })

        model.applyQuickImport(preview)

        let reloaded = AppModel(defaults: defaults)
        let reloadedSnapshot = reloaded.villages[0].accountSnapshot
        XCTAssertEqual(reloadedSnapshot?.tag, preview.snapshot.tag)
        XCTAssertEqual(reloadedSnapshot?.originalText, preview.snapshot.originalText)
        XCTAssertEqual(reloadedSnapshot?.unknownTopLevelKeys, preview.snapshot.unknownTopLevelKeys)
        XCTAssertEqual(reloadedSnapshot?.diagnostics, preview.snapshot.diagnostics)
        XCTAssertEqual(reloadedSnapshot?.diagnostics.count, preview.snapshot.diagnostics.count)
    }

    /// preview 期间选中村庄被切换：apply 仍按 preview.targetVillageID 更新 A，
    /// 并把选中切回 A；B 不受影响。
    @MainActor
    func testApplyWhenSelectionChangedDuringPreview() async {
        let a = VillageProfile(name: "A", accountSnapshot: makeSnapshot(tag: "#A"))
        let b = VillageProfile(name: "B", accountSnapshot: makeSnapshot(tag: "#B"))
        let clipboard: String? = ##"{"tag":"#A2","buildings":[]}"##
        let model = makeModel(villages: [a, b]) { clipboard }
        let aID = model.villages[0].id
        let bID = model.villages[1].id

        guard case .success(let preview) = model.prepareQuickImport(for: aID) else {
            return XCTFail("prepare 应成功")
        }

        // 预览后用户切换到 B
        model.selectVillage(id: bID)
        XCTAssertEqual(model.selectedVillageID, bID)

        model.applyQuickImport(preview)

        XCTAssertEqual(model.villages[0].accountSnapshot?.tag, "#A2", "A 必须被更新")
        XCTAssertEqual(model.villages[1].accountSnapshot?.tag, "#B", "B 不得变化")
        XCTAssertEqual(model.selectedVillageID, aID, "apply 后选中必须回到目标村庄 A")
        XCTAssertEqual(model.accountSnapshot?.tag, "#A2", "accountSnapshot 属性必须刷新为新快照")
    }

    /// prepare 是纯函数：villages / accountSnapshot / importText / pending 状态 /
    /// UserDefaults 持久化数据均不变。
    @MainActor
    func testPrepareHasNoSideEffects() async {
        let a = VillageProfile(name: "A", accountSnapshot: makeSnapshot(tag: "#A"))
        let b = VillageProfile(name: "B", accountSnapshot: makeSnapshot(tag: "#B"))
        let clipboard: String? = ##"{"tag":"#C","buildings":[]}"##
        let model = makeModel(villages: [a, b]) { clipboard }
        let aID = model.villages[0].id

        let villagesBefore = model.villages
        let snapshotBefore = model.accountSnapshot
        let importTextBefore = model.importText
        let pendingBefore = model.pendingAccountSnapshot
        let persistedBefore = persistedVillagesData()

        let result = model.prepareQuickImport(for: aID)
        guard case .success = result else {
            return XCTFail("prepare 应成功: \(result)")
        }

        XCTAssertEqual(model.villages, villagesBefore)
        XCTAssertEqual(model.accountSnapshot, snapshotBefore)
        XCTAssertEqual(model.importText, importTextBefore)
        XCTAssertEqual(model.pendingAccountSnapshot, pendingBefore)
        XCTAssertEqual(persistedVillagesData(), persistedBefore)
    }

    /// apply 的 no-op guard：prepare 后目标村庄被删除 → apply 安全 no-op，
    /// 不崩溃、其余村庄不变、UserDefaults 数据不变。
    @MainActor
    func testApplyNoOpWhenTargetVillageDeleted() async {
        let a = VillageProfile(name: "A", accountSnapshot: makeSnapshot(tag: "#A"))
        let b = VillageProfile(name: "B", accountSnapshot: makeSnapshot(tag: "#B"))
        let clipboard: String? = ##"{"tag":"#A2","buildings":[]}"##
        let model = makeModel(villages: [a, b]) { clipboard }
        let aID = model.villages[0].id

        guard case .success(let preview) = model.prepareQuickImport(for: aID) else {
            return XCTFail("prepare 应成功")
        }

        // 预览后目标村庄被删除（选中自动顶替为 B）
        model.deleteVillage(id: aID)
        XCTAssertEqual(model.villages.map(\.name), ["B"], "前置条件：A 已删除")
        let bBefore = model.villages[0]
        let persistedBefore = persistedVillagesData()

        // apply 必须安全 no-op：不崩溃、其余村庄不变、持久化数据不变
        model.applyQuickImport(preview)

        XCTAssertEqual(model.villages, [bBefore], "apply 不得触碰剩余村庄")
        XCTAssertEqual(model.villages[0].accountSnapshot?.tag, "#B")
        XCTAssertEqual(persistedVillagesData(), persistedBefore, "apply no-op 不得写 UserDefaults")
    }

    /// 占位名改名分支：name 为「村庄 N」或 placeholderName 时，
    /// apply 后替换为 normalized(snapshot.tag)；实名村庄名字不变。
    @MainActor
    func testApplyReplacesPlaceholderName() async {
        let v1 = VillageProfile(name: "村庄 1", accountSnapshot: makeSnapshot(tag: "#V1"))
        let v2 = VillageProfile(name: "未命名村庄", accountSnapshot: makeSnapshot(tag: "#V2"))
        let v3 = VillageProfile(name: "A", accountSnapshot: makeSnapshot(tag: "#A"))
        let model = makeModel(villages: [v1, v2, v3]) { nil }
        let ids = model.villages.map(\.id)

        // 构造 preview：snapshot 必须带有效 tag（normalized 后替换占位名）
        let snapshot = makeSnapshot(tag: "#RENAMED")
        let preview1 = QuickImportPreview(
            snapshot: snapshot, targetVillageID: ids[0], targetVillageName: "村庄 1",
            targetVillageTag: "#V1", targetVillageHasSnapshot: true,
            replacesSameTag: false, destinationDescription: "测试"
        )
        let preview2 = QuickImportPreview(
            snapshot: snapshot, targetVillageID: ids[1], targetVillageName: "未命名村庄",
            targetVillageTag: "#V2", targetVillageHasSnapshot: true,
            replacesSameTag: false, destinationDescription: "测试"
        )
        let preview3 = QuickImportPreview(
            snapshot: snapshot, targetVillageID: ids[2], targetVillageName: "A",
            targetVillageTag: "#A", targetVillageHasSnapshot: true,
            replacesSameTag: false, destinationDescription: "测试"
        )

        model.applyQuickImport(preview1)
        model.applyQuickImport(preview2)
        model.applyQuickImport(preview3)

        XCTAssertEqual(model.villages[0].name, "#RENAMED", "「村庄 N」占位名必须替换为规范化 tag")
        XCTAssertEqual(model.villages[1].name, "#RENAMED", "placeholderName 必须替换为规范化 tag")
        XCTAssertEqual(model.villages[2].name, "A", "实名村庄不得被改名")
    }

    // MARK: - property-based 用例（手写确定性生成器，无外部框架）

    /// 随机村庄集合 × 随机剪贴板（nil / 坏 JSON / 有效 JSON）：路由不变式——
    /// 成功时 preview.targetVillageID 恒等于传入 ID；失败时错误必为四个 case 之一；
    /// prepare 前后 villages 数组与 UserDefaults 数据完全相等。
    @MainActor
    func testRoutingInvariantAcrossRandomVillageSets() async {
        var rng = QuickImportSeededGenerator(seed: 0x61)
        for iteration in 0..<50 {
            let count = rng.int(in: 1...4)
            var villages: [VillageProfile] = []
            for i in 0..<count {
                let hasSnapshot = rng.bool()
                let tag: String?
                if hasSnapshot {
                    // 含大小写/缺 # 变体：拦截比较必须归一后才判定（Issue #61 修复）。
                    tag = rng.unit(from: ["#V\(i)", " #V\(i) ", "", "#DUP", "#abc", "ABC"])
                } else {
                    tag = nil
                }
                villages.append(VillageProfile(
                    name: rng.unit(from: ["V\(i)", "村庄 1", "未命名村庄"]),
                    accountSnapshot: tag == nil ? nil : makeSnapshot(tag: tag)
                ))
            }
            let targetIndex = rng.int(in: 0...(count - 1))
            let targetID = villages[targetIndex].id

            // 剪贴板：0 = nil，1 = 坏 JSON，2 = 有效 JSON（随机 tag 或缺失），3 = 有效 JSON 无 tag
            var clipboard: String?
            switch rng.int(in: 0...3) {
            case 0:
                clipboard = nil
            case 1:
                clipboard = rng.unit(from: ["not json", "[1,2]", "{", ##"{"tag":"#X","buildings":["##])
            case 2:
                // 含大小写/缺 # 变体：剪贴板非 canonical tag 同样必须被拦截（Issue #61 修复）。
                let tag = rng.unit(from: [nil, "#V\(rng.int(in: 0...(count - 1)))", "#FRESH", "#  #V0", "#abc", "ABC"])
                clipboard = tag.map { ##"{"tag":"\##($0)","buildings":[]}"## } ?? ##"{"tag":null,"buildings":[]}"##
            default:
                clipboard = ##"{"buildings":[]}"##
            }

            let model = makeModel(villages: villages) { clipboard }
            let villagesBefore = model.villages
            let persistedBefore = persistedVillagesData()

            let result = model.prepareQuickImport(for: targetID)

            switch result {
            case .success(let preview):
                XCTAssertEqual(preview.targetVillageID, targetID,
                               "迭代 \(iteration)：成功路由必须指向传入 ID")
            case .failure(let error):
                switch error {
                case .emptyClipboard, .targetVillageMissing, .tagBelongsToAnotherVillage, .parseFailed:
                    break  // 四个合法 case
                }
            }

            XCTAssertEqual(model.villages, villagesBefore,
                           "迭代 \(iteration)：prepare 不得改变 villages")
            XCTAssertEqual(persistedVillagesData(), persistedBefore,
                           "迭代 \(iteration)：prepare 不得写 UserDefaults")
        }
    }

    /// 官方状态契约不变式（AppModel.applyQuickImport 层面）：
    /// 随机 100 组 tag 对 → 规范化相同则官方状态保留，不同（或新 tag 为 nil）则清空。
    @MainActor
    func testOfficialStateContractInvariantAcrossRandomTags() async {
        var rng = QuickImportSeededGenerator(seed: 0x1700)
        for iteration in 0..<100 {
            let oldTag = rng.unit(from: [nil, "", "  ", "#SAME", " #SAME ", "#OLD", "#other"])
            let newTag = rng.unit(from: [nil, "", "  ", "#SAME", "#NEW", "#other", "#OTHER"])
            let village = VillageProfile(
                name: "V",
                accountSnapshot: oldTag == nil ? nil : makeSnapshot(tag: oldTag),
                officialAPIState: OfficialAPIState(status: .success),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
            let model = makeModel(villages: [village])

            let snapshot = makeSnapshot(tag: newTag)
            let preview = QuickImportPreview(
                snapshot: snapshot,
                targetVillageID: village.id,
                targetVillageName: "V",
                targetVillageTag: oldTag,
                targetVillageHasSnapshot: true,
                replacesSameTag: OfficialPlayerTagValidator.normalized(newTag)
                    == OfficialPlayerTagValidator.normalized(oldTag),
                destinationDescription: "测试"
            )

            model.applyQuickImport(preview)

            let sameTag = OfficialPlayerTagValidator.normalized(oldTag)
                == OfficialPlayerTagValidator.normalized(newTag)
            if sameTag {
                XCTAssertNotNil(model.villages[0].officialAPIState,
                                "迭代 \(iteration)：规范化相同（\(oldTag ?? "nil") → \(newTag ?? "nil")）必须保留官方状态")
            } else {
                XCTAssertNil(model.villages[0].officialAPIState,
                             "迭代 \(iteration)：tag 变化（\(oldTag ?? "nil") → \(newTag ?? "nil")）必须清空官方状态")
            }
        }
    }
}

// MARK: - 确定性伪随机生成器（property-based 测试专用，可复现）

private struct QuickImportSeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int(next() % UInt64(range.count)) + range.lowerBound
    }

    mutating func bool() -> Bool {
        next() & 1 == 0
    }

    mutating func unit<T>(from choices: [T]) -> T {
        choices[int(in: 0...(choices.count - 1))]
    }
}
