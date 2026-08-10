# Issue 101: 部落 open 类型文案统一为「任何人都可加入」

- 日期: 2026-08-10
- 基线: origin/main @ 7a4c8e7
- 分支: `fix/issue-101-clan-open-label`
- 来源: [Issue #101](https://github.com/ShadyUnderLight/COCHelper/issues/101)（已评审，结论：现在做）

## 规格（Spec）

`ClanDisplayFormat.typeLabel(_:)` 将部落类型 raw value 映射为官方简中文案。
当前 `open` 显示「所有人均可加入」，与 Supercell 官方简中「任何人都可加入」不一致。
官方来源已核实：https://supercell.com/en/parents/cn/ 简体中文版原文——
「公会分为『不可加入』『只有被批准才能加入』和『任何人都可加入』三种类型」。

实现位置：`Sources/COCHelperApp/ClanDisplayFormat.swift`（public enum，origin/main 结构；
注意主工作区旧分支 `codex/issue-65-craft-table` 中该文件位于 `Sources/COCHelper/` 且非 public，
两分支结构不同，本计划以 origin/main 为准）。

### 验收标准

1. `typeLabel("open") == "任何人都可加入"`
2. `typeLabel("inviteOnly") == "只有被批准才能加入"`（不变）
3. `typeLabel("closed") == "不可加入"`（不变）
4. 未知 raw value 返回 `"未知"`（不变）
5. 部落卡片（ClanCardView）与添加部落预览（ContentView）共用同一 formatter，无第二套译文
6. 为 typeLabel 补齐测试（当前零覆盖）

### 非目标

- 不改 API raw value、解码、持久化
- 不改 inviteOnly / closed / 未知值文案
- 不改部落类型业务逻辑与加入权限判断
- 不重构 ClanDisplayFormat 其他部分

## 类型契约

```
typeLabel: (raw: String) -> String
```

- **total function**：对任意 `String` 输入都有定义，不 trap、不 crash
- `open` → `"任何人都可加入"`
- `inviteOnly` → `"只有被批准才能加入"`
- `closed` → `"不可加入"`
- 其他任意值 → `"未知"`（不泄漏英文 raw value）

不变量（property）：
- P1: 对已知三值，返回各自官方文案
- P2: 对任意未知输入（大小写变体、空白、空串、任意其他字符串），返回 `"未知"`
- P3: 返回值永不等于输入 raw value（绝不直接回显英文）
- P4: 返回值总属于四态集合 `{"任何人都可加入", "只有被批准才能加入", "不可加入", "未知"}`

## 设计分析（3 候选投票，最终落地）

测试可达性预判：计划初稿假设 `ClanDisplayFormat` 位于 executable target `COCHelper` 且
现有测试无法访问，据此设计了 3 候选投票。**实施时经 worktree（origin/main）实证推翻该前提**：
origin/main 上 `ClanDisplayFormat` 位于 `Sources/COCHelperApp/`（public enum），
现有测试 target `COCHelperCoreTests` **已依赖 COCHelperApp 并 `@testable import`**，
且已有 `Tests/COCHelperCoreTests/ClanDisplayFormatTests.swift` 测试文件（Issue #71/#95 遗留）。

| 候选 | 方案 | 优点 | 缺点 | 投票 |
|---|---|---|---|---|
| A | 新建 `Tests/COCHelperTests/` test target 依赖 `COCHelper` | 结构独立 | **基于错误前提**：ClanDisplayFormat 不在 COCHelper 模块，按字面无法编译；会与现有测试完全重复 | ✗ |
| B | 移动文件到 COCHelperApp + public | — | 文件已在 COCHelperApp 且已 public，无移动需求 | ✗ |
| C（实际采用） | **在现有 `ClanDisplayFormatTests.swift` 追加 typeLabel 测试**（穷举 + property），复用现有 SplitMix64Generator 与 @testable import | 零 Package.swift 改动、零重复、测试风格与文件内既有测试完全一致 | 无 | ✅ 推荐 |

**结论：候选 C。** 最小侵入，符合「少依赖、小改动、可维护」原则。

### property-based 测试策略

Swift 标准库无 property-based 框架，遵循项目「少依赖」原则不引入第三方。
采用轻量确定性穷举 + 伪随机生成：

- 已知值穷举（P1）：三态 + 断言官方文案
- 未知值确定性生成（P2/P3/P4）：固定种子伪随机生成 ~500 个字符串
  （混合大小写、空白、数字、符号、空串、类 raw 值如 `"Open"`/`" OPEN "`/`"invite_only"`），
  断言：返回值 == `"未知"` 且 `返回值 != 输入`
- 输出域封闭性（P4）：所有输入（已知 + 随机）的输出均属于四态集合

## 实现步骤

### Task 1（唯一实现任务，implementer 执行完整 SDD→TDD→CoT→Code→Reflexion）

1. **Tests/COCHelperCoreTests/ClanDisplayFormatTests.swift**（TDD RED 先行，追加）：
   - `testTypeLabelKnownValues`：三态穷举 + P3 断言
   - `testTypeLabelExactMatchNoNormalization`：大小写/空白/分隔符近失值 → 全部「未知」
   - `testTypeLabelPropertyUnknownForArbitraryStrings`：固定 seed SplitMix64 生成 600 个
     ASCII 字符串，断言 P2/P3/P4（复用文件内既有 SplitMix64Generator 风格）
2. **Sources/COCHelperApp/ClanDisplayFormat.swift**（TDD GREEN）：
   - L27 `case "open": "所有人均可加入"` → `case "open": "任何人都可加入"`（单行）
3. 全量 `swift test` 通过（预期 930 tests, 0 failures）

### 验证命令

- `swift test`（基线 927 tests, 0 failures）
- `git diff --stat` 确认改动范围

## 风险和边界

- 只改 1 行生产代码；在现有测试文件追加 3 个测试（+48 行）
- 零 Package.swift 改动、零新增测试 target、零第三方依赖
- 测试生成器复用文件内既有 SplitMix64Generator 风格（固定 seed 可复现）
- 不顺手改其他文案 / 不重构 / 不修 issue 中写错的路径描述
