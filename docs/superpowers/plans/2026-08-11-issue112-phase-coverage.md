# Issue #112 seasonalCandidate phase coverage 报告与已知官方阶段数据

日期：2026-08-11
分支：codex/issue-112-phase-coverage
依据：issue #112 + 评审修正（① note 非结构化不可分类；② coverage 报告不得混入 validate_catalog errors；③ 不锁死 71=4+67 为契约；④ 需结构化 phaseCoverage 字段）

## 1. 范围

- **数据补录**：`seasonal_phases.json` 新增 Party Wizard 独立 phase（官方公告已核实：Sound of Clash Medal Event 2026-04-08 08:00 UTC ~ 2026-04-29 08:00 UTC，Party Wizard 为 temporary troop）
- **结构化声明**：`lifecycle_declarations.json` 为每条 seasonalCandidate 增加 `phaseCoverage: "required" | "unknown"`（required = 有可靠官方日期、必须命中 phase；unknown = 暂无可靠日期、允许 `.unconfigured` fail-closed）
- **反向对账**：required 候选必须命中 phase 表（缺 → 报告/测试失败）；保留现有 phase key → seasonalCandidate 单向校验
- **coverage 报告**：独立 `coverage_report()`（不动 `validate_catalog()` errors 语义——`generate_game_catalog.py:45` 非空 errors 即失败）
- **测试**：Python 单测 + hypothesis property 测试 + Swift bundled 测试更新（phases.count 1→2 + Party Wizard 三态/边界）

**不做**：给其余候选编造日期（#109 负责外部核实）；改 `.unconfigured`/`permanent` 语义；改 manifest 门禁；改精工防御现有 phase 日期。

## 2. 现状证据（已验证）

| 项 | 现状 |
|---|---|
| lifecycle_declarations.json | 697 条声明：71 seasonalCandidate + 626 permanent；note 全部非空（自由文本，无日期状态语义） |
| seasonal_phases.json | 1 phase（crafted-defenses-2026-04-sound-of-clash）、12 keys；from=796694400 until=807148800（Cocoa 纪元 = 2026-04-01 ~ 2026-07-31） |
| 声明∩阶段 | 仅 3 条（buildings:103000008/9/10）；9 个 module keys（102000024-032）不在声明表（test_lifecycle.py:131 `if key in decl` 跳过） |
| validate.py | 696 行，零 phase 校验；`validate_catalog()` 返回 errors，消费方非空即失败 |
| lifecycle.py | `load_declarations()` 返回 `dict[str, str]`（只取 lifecycle，丢弃 note）；fail loud |
| Swift | `SeasonalPhaseTable.availability()` 三态已实现（GameCatalog.swift:352-366）；Cocoa reference date 契约（:282-288）；bundled 测试断言 phases.count == 1（GameCatalogTests.swift:927） |
| 官方公告 | https://supercell.com/en/games/clashofclans/blog/news/sound-of-clash-medal-event-is-here/ 已实测：2026-04-08 08:00 UTC ~ 2026-04-29 08:00 UTC |

## 3. 类型契约（定稿）

### Python（声明层）

```python
# lifecycle.py 新增
PHASE_COVERAGE_VALUES: frozenset[str] = frozenset({"required", "unknown"})

def load_phase_coverage() -> dict[str, str]:
    """返回 {key: "required"|"unknown"}。
    - seasonalCandidate 缺 phaseCoverage / 未知值 → CatalogError（fail loud）
    - permanent 带 phaseCoverage → CatalogError（防误标）
    - key = "section:dataID"，与 load_declarations 同源文件
    """
```

声明条目结构：
```json
{"lifecycle": "seasonalCandidate", "phaseCoverage": "required", "note": "..."}
```

### Swift（不变，只加测试）

`SeasonalPhase` 结构不变（phaseID/name/from/until/itemKeys/sourceURL，Codable、Cocoa 纪元）。

## 4. 数据变更

### seasonal_phases.json 新增 phase

```json
{
  "phaseID": "sound-of-clash-medal-event-2026-04",
  "name": "Sound of Clash Medal Event",
  "from": 797328000,
  "until": 799142400,
  "itemKeys": ["units:4000072"],
  "sourceURL": "https://supercell.com/en/games/clashofclans/blog/news/sound-of-clash-medal-event-is-here/"
}
```

秒数已验算：797328000 = 2026-04-08 08:00 UTC、799142400 = 2026-04-29 08:00 UTC（Cocoa 纪元），差 21 天。

### lifecycle_declarations.json

- 4 条 required：buildings:103000008/9/10（精工防御）+ units:4000072（Party Wizard）
- 其余 67 条 seasonalCandidate：unknown

## 5. 测试计划

### Python（test_lifecycle.py + 新增 test_phase_coverage.py）

1. `test_phase_coverage_declaration_wellformed`：required+unknown 总数 == seasonalCandidate 总数；required 集合 == {4 条已知清单}；permanent 无 phaseCoverage
2. `test_phase_coverage_required_hits_phase_table`：反向对账——每条 required 必须命中 seasonal_phases.json（新增，填补单向缺口）
3. `test_phase_coverage_load_failure_paths`：seasonalCandidate 缺 phaseCoverage / 未知值 / permanent 带 phaseCoverage → CatalogError（monkeypatch，仿 test_lifecycle.py:254）
4. `test_coverage_report_summary`：对真实目录，`coverage_report()` 返回结构化统计（seasonalCandidates / required / requiredWithPhase / requiredMissingPhase / unknown / phaseKeys / phaseKeysNotDeclared）
5. hypothesis property：`compute_coverage(decl, phase_table)` 纯函数不变量——required = requiredWithPhase + requiredMissingPhase；phaseKeys = 命中 required + 未声明（模组）+ 命中非候选（错标）分类和守恒；随机生成声明与阶段表不崩溃、分类互斥

### Swift（GameCatalogTests.swift）

6. `testSeasonalPhaseTableLoadsBundledOfficialPhase` 更新：phases.count 1→2；新增 Party Wizard phase 断言（phaseID/from/until/itemKeys/sourceURL）
7. `testPartyWizardAvailabilityAcrossPhaseBoundaries`：注入 Date（Cocoa 纪元秒数）——before→.notStarted、==from→.active、==until→.ended、after→.ended；未命中 key → .unconfigured

### 验证命令

```
python3 -m pytest -q Tools/tests
swift test
git diff --check
```

## 6. 实施顺序（SDD 任务）

| # | 任务 | 文件 |
|---|---|---|
| T1 | 声明层：phaseCoverage 字段 + load_phase_coverage + 失败路径单测 | lifecycle.py、lifecycle_declarations.json、test_lifecycle.py |
| T2 | 数据：seasonal_phases.json 新增 phase + Swift bundled/三态测试更新 | seasonal_phases.json、GameCatalogTests.swift |
| T3 | 报告：coverage_report + 对账测试 + hypothesis property | validate.py（或 lifecycle.py）、test_phase_coverage.py |
| T4 | README 同步 | README.md |
| T5 | 全量验证 + commit | — |

## 7. 风险与边界

- **不顺手做**：不给 67 条 unknown 编造日期；不改 availability 语义；不改 manifest；不改精工防御日期
- **回归风险**：Swift bundled 测试 count==1 断言必须与数据同 T2 更新；coverage_report 不得 append 到 errors（消费方非空即失败）；`load_declarations` 签名保持兼容（craft 生成器依赖）
- **CI 兼容**：新增 phase 后 Swift 测试若不同步 → 红；T2 原子完成即可
