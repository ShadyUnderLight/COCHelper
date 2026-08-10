# Issue #97：英雄装备 Blacksmith/铁匠铺前置条件接入阶段上限

- 基线：`origin/main@eaefac5`（worktree `.worktrees/issue-97-blacksmith`，分支 `codex/issue-97-blacksmith`）
- 日期：2026-08-10
- 相关：Issue #67（已关闭，Requirement 图 + 阶段上限框架）、#96（universeComplete，OPEN，不依赖）、#73（多资源费用，已完结，不涉及）

## 1. 背景与目标

当前 `UpgradeRequirement` 只有 5 个 case（townHall/builderHall/laboratory/starLaboratory/heroHall），equipment 的 `requirements` 为空 → `currentStageMaxLevel` 返回 `maxLevel`（全局上限），低铁匠铺玩家装备被误判为全局满级/可升到未解锁等级。

**决定性证据（已实测验证）**：`/Users/lmz/Downloads/base.apk.1`（buildTag `18_400_7`，与 bundled 目录同源）的 `assets/logic/character_items.csv` 有 `RequiredBlacksmithLevel` 列，**1032 个等级行全部有值**（分布 1–10，如普通装备 1–9 级 BS=1、10–12 BS=3、13–15 BS=5、16–18 BS=7），且随 level 单调不减。根因：`tables.py` 的 character_items TableSpec 未声明该列 → 生成时丢弃。

目标：把铁匠铺接入统一 Requirement 图（Issue #97 建议 1–5），不特判、不硬编码、保留来源版本与生成验证。

## 2. 类型契约

### 2.1 Python（Tools/game_catalog/）

| 文件 | 契约变更 |
|---|---|
| `model.py` | `CatalogLevel` 增加 `requiredBlacksmithLevel: int \| None = None`；`to_dict`/`from_dict` 对称（恒写键，null 也写） |
| `tables.py` | `TableSpec` 增加 `blacksmith_column: str \| None = None`；`character_items` spec 声明 `blacksmith_column="RequiredBlacksmithLevel"` |
| `builders.py` | `_ParsedRow` 增加 `blacksmith: int \| None`；`_parse_row` 读取；`_level_from_row`/`_level_initial`/`_build_levels`(to_next 分支) 传递 |
| `validate.py` | equipment 每级 `requiredBlacksmithLevel` 非 None 且 ∈ 1...10（fail loud，报错含「旧产物缺少字段，请用 annotate 脚本回填」提示） |

### 2.2 Swift（Sources/COCHelperCore/）

| 文件 | 契约变更 |
|---|---|
| `GameCatalog.swift` | `UpgradeRequirement` 增加 `case blacksmith(level: Int)`；`requiredLevel`/`displayLabel` 补分支（"所需铁匠铺等级 N级"，语义固定不随 base 变）；`CatalogLevel` 增加 `requiredBlacksmithLevel: Int?`（Codable 缺键 → nil，旧目录向后兼容）；`requirements(base:)` home 分支 `if let bs = requiredBlacksmithLevel, bs > 0 { out.append(.blacksmith(level: bs)) }`（仿 heroHall `ht > 0` 防御） |
| `VillageCatalogProjection.swift` | `UnlockBuildingDataID.blacksmith = 1_000_070`；`PlayerUnlockLevels` 增加 `blacksmith: Int?`（init(snapshot:) 从 `buildings` 读，缺失 nil）+ `level(for:)` 分支 |

### 2.3 Bundled 目录更新策略（候选投票见 §3）

写 `Tools/annotate_blacksmith_levels.py`（仿 `annotate_display_categories.py` 结构）：从 APK 读 `RequiredBlacksmithLevel` 列，按 `(section, dataID, level)` 键 join 回填 bundled 目录 equipment levels + manifest 重算（catalog.json sha256/size），幂等、fail-loud、不触碰 icons/renderedPath（避免全量重渲染 1264 PNG 的耗时与回归风险）。

## 3. 设计决策 + 候选投票（CoT）

### 决策 1：catalog 字段表达
- **候选 A（选）**：显式 `requiredBlacksmithLevel: Int?` 字段 —— 与 `requiredHeroTavernLevel`（#67）完全同构，生成/解码/校验链路最短
- 候选 B：通用 requirement 对象数组 —— 过度设计，破坏 #67 既有字段惯例
- 候选 C：Swift 侧特判 if/else —— Issue 明确反对（建议 1「不写特殊 if/else」）

### 决策 2：bundled 目录更新方式
- **候选 A（选）**：annotate 风格回填脚本（仿 #75 工作流 C 主路径）—— 幂等、快、不重渲染、有成熟先例
- 候选 B：全量 generate + render_generator 重渲染 —— 正统但需渲染 1264 PNG（耗时未知、依赖 libzstd 环境），diff 巨大
- 候选 C：手写 JSON patch —— 违反生成管线哲学，易漂移

### 决策 3：validate 严格度
- **候选 A（选）**：equipment 每级 BS 必须非 None 且 1...10（fail loud）—— 与 displayCategory P1-B「旧产物缺字段报错」先例一致，报错提示回填路径
- 候选 B：仅字段存在时校验（旧目录静默通过）—— 与 Issue 验收标准 3「validator 能报告缺失」矛盾
- 注意：**不做单调性校验**（与现有 TH/Lab 校验对称——validate.py 对它们也无单调检查；Swift 注释的单调性由数据源保证）

## 4. 任务拆分（TDD）

### Task 1：Python 生成器 + 测试
1. RED：`test_model.py` 断言 `CatalogLevel(requiredBlacksmithLevel=3).to_dict()["requiredBlacksmithLevel"] == 3`、`from_dict` 缺键 → None
2. RED：`test_builders.py` `_character_items_rows` fixture 增加 `RequiredBlacksmithLevel` 列 → 断言 levels 携带
3. GREEN：model.py / tables.py / builders.py 实现
4. RED→GREEN：`test_validate.py` equipment BS 缺失 → 报错；BS=11 → 报错；合法 → 通过

### Task 2：annotate 回填脚本 + bundled 目录
1. 写 `Tools/annotate_blacksmith_levels.py`（从 APK 读列回填 + manifest 重算）
2. 跑脚本回填 `Sources/COCHelperCore/GameCatalog/18.400.13`
3. `python3 Tools/validate_game_catalog.py --catalog ...` 通过
4. 抽样断言：野蛮人木偶 level 10 BS=3、level 16 BS=7；manifest catalog.json 哈希已更新
5. 幂等验证：重跑脚本 diff 为空

### Task 3：Swift Core + 单元测试
1. RED：`RequirementTests` 新增 `.blacksmith(level:)` 的 displayLabel/requiredLevel/requirements(base:) 用例
2. RED：`VillageCatalogProjectionTests` stageCatalog 的 equipment 条目加 BS 门槛（lvl2 BS=2, lvl3 BS=3），新增三档 fixture：
   - 低铁匠铺（BS=1）→ stageMax < maxLevel，阶段满级 `.maxed` + `currentStageMaxLevel < maxLevel`
   - 缺铁匠铺 → `nil` stageMax + `.unverified`
   - 高铁匠铺（BS=3）→ stageMax == maxLevel
3. RED：`RequirementTests` 真实目录锚点：bundled 目录野蛮人木偶 `currentStageMaxLevel(for:unlocks: blacksmith: 1) == 9`（maxLevel 18）
4. GREEN：GameCatalog.swift / VillageCatalogProjection.swift 实现
5. property-based：`testPropertyStageMaxLevelInvariants` 扩展 BS 维度（或新增：随机 BS 门槛 + 随机铁匠铺 → 断言 stageMax ≤ maxLevel、解锁满足时 == maxLevel、解锁缺失时 nil）

### Task 4：既有测试修复 + 全量验证
- 检查 `test_validate.py` 既有 fixture 是否含 equipment 无 BS → 补齐
- Swift 既有「equipment stageMax == maxLevel」锚点测试（VillageCatalogProjectionTests L925 附近）→ 若 stageCatalog equipment 加了门槛，相关测试断言需同步

## 5. 验证命令

```bash
python3 -m pytest -q Tools/tests
python3 Tools/validate_game_catalog.py --catalog Sources/COCHelperCore/GameCatalog/18.400.13
swift build
swift test --filter RequirementTests
swift test --filter VillageCatalogProjectionTests
swift test --filter VillageProgressMetricsTests
swift test   # 全量
git diff --check
```

## 6. 风险与边界

- 不做 `RequiredCharacterLevel`（当前全 1 无信息量）；不硬编码装备表；不修 #96；不动 API snapshot 原始字段
- Swift Codable 缺键兼容：新增字段必须 `Int?` 且缺键 → nil（旧目录仍可读）
- equipment 从「无门槛」变「有门槛」：所有消费 requirements/currentStageMaxLevel 的 UI 展示变化是预期修复；既有「stageMax == maxLevel」测试锚点需同步
- 15 件 maxLevel=1 装备（UNUSED*/Deadly Dash2 等 deprecated）：BS 值 1/6/7 都会回填，deprecated 项同样校验（源数据有值）
- 回填脚本不触碰 renderedPath/icons（validate 的 renderedIcons 计数不变）
