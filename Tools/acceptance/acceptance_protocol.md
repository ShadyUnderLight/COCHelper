# Issue #226 手工验收协议

与 [GitHub Issue #226](https://github.com/ShadyUnderLight/COCHelper/issues/226) 对齐。审查基线：`origin/main@256c065`（#234/#235/#236 已合并）。

## 1. 数据准备

1. 两个真实村庄，各保存连续两次游戏内导出 JSON。
2. 只在本地验证；raw JSON 放入 `Tools/acceptance/local/`（已 gitignore）。
3. 记录脱敏后的 item/level/count/timer 预期。
4. 无可信完整性协议时，预期为 `unknown/insufficientCoverage`，**不得**人为添加 coverage。

## 2. 导入路由（交错 + 共同 restart）

按 Issue #226 原文“交错导入 A/B”与“A1/B1 与 A2/B2 之间各至少一次完整重启”，_runner 与手工验收均采用统一交错生命周期_：

| 步骤 | 操作 | 记录项 |
|---|---|---|
| A1 | 账号数据页完整导入（单村庄环境） | history count 1、lineage 1、trust/timeline |
| B 创建 | `addVillageForImport` + 重命名“村庄 B” | 村庄数 2，entries/lineage 不变 |
| B1 | Village Detail → 粘贴并更新（B） | 与 A1 同字段，entries 2、lineages 2 |
| 重启 | **两村同时存在后**完全退出 App 后重开 | 两边同时验证：entries/lineages/duplicate/trust/statistics/availability 均一致，lineageID 不变 |
| A2 | 账号数据页导入第二次快照（A） | Diff、changes、statistics，entries 3、lineage 不变、timeline +1 |
| B2 | 粘贴并更新第二次快照（B） | 同上，entries 4、lineage 不变 |
| A2′ | 再次导入相同 A2 | duplicate metadata +1、entries 不变、timeline 不新增、duplicateImportCount 严格 +1 |
| B2′ | 再次导入相同 B2 | 同上，严格 +1 |

- A2/B2 后目标 `villageID` 必须保持不变，同账号连续导入保持 `continued` lineage。
- 重复导入只更新 `lastSeenAt/duplicateImportCount`，不新增无意义 history row。

### 串档检查

- 上述交错 + 共同 restart 后，A/B 的 villageID、player tag、lineage、history entry、snapshotID 集合均不得交叉；同村 entry 的 `lineageID` 必须与 active lineage 一致。
- 两条入口均经 `commitImportedSnapshot` / 统一 history service（含 `FileManualTrackerStore`）。

## 3. 应用生命周期

- **交错边界**：A1/B1 均完成后共同 restart，再进行 A2/B2，确保“两村已有历史时 restart 隔离”被覆盖（单村 restart 无法证明交错不串档）。
- 重启前后：对 A/B **两边同时**检查 history count、baseline、duplicate、trust、availability、Diff diagnostics、today/7d/30d 统计一致。
- 旧历史不受当前 GameCatalog/API/UI refresh 改写。

## 4. UI / statistics

人工核对（截图/录屏须遮盖 tag 与个人信息）：

- Village Detail：最近更新时间、历史数量、时间线摘要。
- Snapshot History：trust、duplicate「最近检查」、category filter、provenance-only。
- today / 7 / 30 天：缺数据显示「数据不足」，不显示伪造 0。
- 升级开始/完成、timer changed/ended、unknown 文案边界。

## 5. 性能（Release App，paired，可展开大变化 row 且保持 fail-closed）

见 `large_walls_perf_scenario.md`。使用 **paired** `perf_account_snapshot_large_walls_before.json`（1005 段全 `Lv1`） / `perf_account_snapshot_large_walls_after.json`（1005 段全 `Lv12`，同 tag `#LARGEWALL01` 合法，同 lineage，raw histogram 偏移 1005；两步粘贴产生非 duplicate 的确定性大变化 history row，但仍为 `insufficientCoverage` 时不伪造 verified migration。单文件 `large_walls.json` 保留兼容）。

## 6. 自动化辅助

```bash
Tools/acceptance/gate.sh
swift run acceptance-runner Tools/acceptance/local
```

`acceptance-runner` 在 headless 环境复现 **A1/B1 → 共同 restart → A2/B2 交错** + duplicate + lineage 隔离，输出脱敏 JSON。**不能替代** Release UI 与真实剪贴板路径的人工验收。

- Runner 对关键 invariant 做硬校验（失败则 `exit 1`，不会“假绿”）：A2/B2 后目标 `villageID` 不变、正常二次导入 `history entries +1 / duplicate 不变 / lineage continued`、重复导入 `entries 不变 / duplicate +1 / duplicateImportCount 严格 +1 / timeline 不新增`、**共同 restart 前后对 A/B 两边同时** `history/trust/availability/statistics` 一致、同账号连续导入保持预期 lineage。`gate.sh` 仅在 runner `exit 0` 且 `working tree clean` 时标记通过。
- 重启语义：`acceptance-runner` 通过临时 `FileSnapshotHistoryStore` + `FileManualTrackerStore`（同一临时目录，跨所有 `AppModel` 实例复用）重放 `current + history + manual` 事务，比早期 `InMemoryManualTrackerStore` 更接近生产；**交错 restart**在两村已有历史后执行，覆盖单村 restart 无法发现的串档。仍不覆盖系统剪贴板与 App UI 刷新路径。
- 村庄 B 创建走正常 `AppModel.addVillageForImport()` / `renameSelectedVillage` 路径，不再直接编码 `UserDefaults`。
- 统计校验对称：`availability / today / 7d / 30d / trust / duplicateImportCount` 在 A/B restart 上均校验（抽 `assertSanitizedEqual` helper）。

## 7. 失败处理

- 记录为独立 issue，附脱敏复现步骤。
- 不得修改测试期望掩盖覆盖不足或 trust persistence 问题。
