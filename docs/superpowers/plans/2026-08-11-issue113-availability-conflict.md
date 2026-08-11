# Issue #113：permanent 与官方 seasonal phase 冲突时禁止静默覆盖

- 基线：`origin/main@a095bde82a0c71b80daba043e10048c84e4a5516`（Issue #112 已合入）
- 类型：enhancement（防御性 fail-closed 契约硬化）
- 优先级：P2/P3，下一轮防御性修复
- Issue：[#113](https://github.com/ShadyUnderLight/COCHelper/issues/113)

## 问题陈述

`SeasonalPhaseTable.availability(forItemKey:lifecycle:at:)` 目前第一行 `if lifecycle == .permanent { return .permanent }` 短路：当声明文件把条目标为 `permanent`、而 `seasonal_phases.json` 官方阶段表同时命中该 key（数据冲突）时，官方阶段证据被静默丢弃。现有测试还把该行为锁为预期。Python 侧 #112 已有非阻断 `coverage_report()`，但 `permanent ∩ phase` 尚未成为 blocking validator error（CLI 捕获 `CatalogError` 打印 `coverage: unavailable` 后仍返回成功）。

当前真实数据：626 permanent、71 seasonalCandidate；2 phase / 13 phase keys；`permanent ∩ phase = ∅`，无实际冲突（纯防御性）。

## 设计分析（3 候选投票）

**候选 A：新增显式 `case conflict(...)`**（选中）
- 语义最强：冲突不是「未配置」，UI 可明确区分；Swift 穷举 switch 编译器强制所有消费点更新，防漏改
- 诊断字段完整：phaseID/phaseName/lifecycle/sourceURL 全部携带
- 缺点：4 个关联值 case；所有 switch 点（实际只有 `displayLabel` + 属性测试）必须更新——这是特性而非风险

**候选 B：保留 `.unconfigured` + 结构化 `AvailabilityDiagnostic`**
- 把冲突伪装成「未配置」，UI 无法区分；诊断结构需穿过投影层，改动面更大
- 不选

**候选 C：保持 `.permanent` + 日志诊断**
- 正是 issue 要禁止的静默覆盖，不满足验收标准
- 不选

**投票结果：A。**

## Swift 类型契约

```swift
public enum CatalogAvailability: Codable, Hashable, Sendable {
    case permanent
    case seasonal(phaseID: String, phaseName: String?, status: SeasonalStatus)
    case unconfigured
    /// Issue #113：声明 permanent 但阶段表命中（数据冲突，fail-closed，
    /// 不再静默返回 .permanent）。sourceURL = 官方公告来源（SeasonalPhase 透传）。
    case conflict(phaseID: String, phaseName: String?, lifecycle: CatalogLifecycle, sourceURL: String?)
}
```

`SeasonalPhaseTable.availability(forItemKey:lifecycle:at:)` 映射表：

| lifecycle | phase 命中 | 结果 |
|---|---|---|
| permanent | 否 | `.permanent`（保持，无 phase 不降级） |
| permanent | 是 | `.conflict(phaseID, name, .permanent, sourceURL)` ← 新增 |
| seasonalCandidate / nil | 是 | `.seasonal(...)`（保持） |
| seasonalCandidate / nil | 否 | `.unconfigured`（保持） |

- 多 phase 命中：复用 `phase(forItemKey:at:)` 既有确定性选择（活动取 from 最晚 → 未来取 from 最小 → 已结束取 until 最大），conflict 只带单一 phaseID
- `displayLabel`：conflict → `"限时内容声明冲突：\(name)（声明为永久内容）"`（name 回退 phaseID，与 seasonal 同风格）
- `CatalogAvailability` 是投影层类型不落盘，新增 case 无解码兼容问题

## Python 类型契约

`Tools/game_catalog/lifecycle.py` 新增纯函数：

```python
def find_lifecycle_phase_conflicts(
    declarations_path: Path = DECLARATIONS_PATH,
    phases_path: Path = PHASES_PATH,
) -> list[dict]:
    """permanent 声明 ∩ 阶段表 itemKeys → 冲突列表（每项含 key、phaseID、phaseName、
    declarationsPath、phasesPath、sourceURL）。阶段表结构校验沿用 coverage_report
    的 fail-loud 语义（phaseID 必填 str、name/sourceURL Optional[str]、itemKeys
    list[str]）；无冲突返回 []。不抛错（空列表 = 无冲突）。"""
```

`Tools/validate_game_catalog.py`：新增 blocking 收集 + 接入 errors 路径（已有 `if errors: verdict FAIL; return 1` 逻辑覆盖）：

```python
def _collect_conflict_errors(catalog_dir: Path) -> list[str]:
    """Issue #113：permanent 声明与官方阶段表冲突 → blocking error（退出码 1）。
    版本绑定与 _emit_coverage_report 同模式（_catalog_game_version 回退默认）。"""
    conflicts = find_lifecycle_phase_conflicts(phases_path=...按版本绑定...)
    return [f"lifecycle 声明永久内容与官方阶段表冲突: {c['key']}: phaseID={c['phaseID']} "
            f"声明={c['declarationsPath']} 阶段={c['phasesPath']} 来源={c.get('sourceURL') or '无'}"
            for c in conflicts]
```

**红线**：冲突必须走 errors（blocking、退出码 1），不得塞进 `coverage_report()`/`_emit_coverage_report`（非阻断路径）。

## 验收标准（对应 issue）

- [x] Swift：`permanent + phase hit` → 不再返回无诊断 `.permanent`，返回 `.conflict`（含 phaseID、lifecycle、sourceURL）
- [x] validator：冲突时报告 key、phaseID、声明文件路径、阶段文件路径、sourceURL；退出码非 0
- [x] `seasonalCandidate/nil + phase hit` 继续 `.seasonal`；无 phase + `permanent` 继续 `.permanent`
- [x] 详情页/精制台复用 `displayLabel`（自动获得 conflict 文案）；建筑组数据层已携带（`BuildingGroup.instances[].item.availability`），组卡 UI 展示不在本 PR scope（记录契约 = availability 字段本身）
- [x] `testAvailabilityPermanentWinsOverPhase` 改为冲突契约测试；property 测试 `testPropertyPermanentIsInvariant` 改性质；补 validator 负例 + CLI 负例（退出码非 0 + provenance）
- [x] 保持 #109 declaration provenance 审计，不用启发式自动改 seasonal

## 任务分解

1. **Task 1（Swift Core + 测试）**：GameCatalog.swift、GameCatalogTests.swift、CatalogAvailabilityPropertyTests.swift（+ 编译强制暴露的其他测试）
2. **Task 2（Python blocking check）**：lifecycle.py、validate_game_catalog.py、test_lifecycle.py、test_cli.py
3. **Task 3（全量验证 + 文档）**：swift test 全量、pytest 全量、diff-check、PR

## 验证命令

```bash
swift test --parallel --num-workers 1        # 基线 1026/1026（worktree 首次编译）
python3 -m pytest -q Tools/tests             # 基线 812 passed / 2 skipped
git diff --check
python3 Tools/validate_game_catalog.py --catalog <catalog> && echo OK
```

## 风险与边界

- 不自动把冲突改成 seasonal（#109 人工 provenance 保持）
- 不动 #112 的 `coverage_report()`/phaseCoverage/`load_phase_coverage` 行为（冲突检查独立函数，不改其契约）
- 不动 UI 层（LevelDetailSheet/CraftTableView 只消费 displayLabel，自动获得文案）；组卡 UI 展示明确 out of scope
- `BuildingGroupProjection` 无改动（数据层已携带 availability）
- blocking 校验生效后真实冲突数据会阻断 catalog 生成/校验流程——目的如此
- property 测试注意既有采样坑点注释（LCG 低位周期），新采样沿用 `>> 32` 高位
