# Issue #226 手工验收协议

与 [GitHub Issue #226](https://github.com/ShadyUnderLight/COCHelper/issues/226) 对齐。审查基线：`origin/main@256c065`（#234/#235/#236 已合并）。

## 1. 数据准备

1. 两个真实村庄，各保存连续两次游戏内导出 JSON。
2. 只在本地验证；raw JSON 放入 `Tools/acceptance/local/`（已 gitignore）。
3. 记录脱敏后的 item/level/count/timer 预期。
4. 无可信完整性协议时，预期为 `unknown/insufficientCoverage`，**不得**人为添加 coverage。

## 2. 导入路由

### 村庄 A（账号数据页）

| 步骤 | 操作 | 记录项 |
|---|---|---|
| A1 | 账号数据页完整导入 | history count、lineage、trust、timeline |
| 重启 | 完全退出 App 后重开 | 重启前后 count/trust/statistics 一致 |
| A2 | 账号数据页导入第二次快照 | Diff、changes、statistics |
| A2′ | 再次导入相同 A2 | duplicate metadata 增加、timeline 不新增无意义 row |

### 村庄 B（详情页快捷导入）

| 步骤 | 操作 | 记录项 |
|---|---|---|
| B1 | Village Detail → 粘贴并更新 | 与 A 相同字段 |
| 重启 | 完全退出 App 后重开 | 同上 |
| B2 | 粘贴并更新第二次快照 | 同上 |
| B2′ | 再次导入相同 B2 | duplicate 行为 |

### 串档检查

- A/B 交错操作后，villageID、player tag、lineage、history entry 不得交叉。
- 两条入口均经 `commitImportedSnapshot` / 统一 history service。

## 3. 应用生命周期

- A1/B1 与 A2/B2 之间各至少一次完整重启。
- 重启前后：history count、baseline、duplicate、trust、Diff diagnostics、统计值一致。
- 旧历史不受当前 GameCatalog/API/UI refresh 改写。

## 4. UI / statistics

人工核对（截图/录屏须遮盖 tag 与个人信息）：

- Village Detail：最近更新时间、历史数量、时间线摘要。
- Snapshot History：trust、duplicate「最近检查」、category filter、provenance-only。
- today / 7 / 30 天：缺数据显示「数据不足」，不显示伪造 0。
- 升级开始/完成、timer changed/ended、unknown 文案边界。

## 5. 性能（Release App）

见 `large_walls_perf_scenario.md`。使用 `perf_account_snapshot_large_walls.json`（1005 段城墙，fixture-equivalent）。

## 6. 自动化辅助

```bash
Tools/acceptance/gate.sh
swift run acceptance-runner Tools/acceptance/local
```

`acceptance-runner` 在 headless 环境复现 A/B 双入口 + 重启 + duplicate + lineage 隔离，输出脱敏 JSON。**不能替代** Release UI 与真实剪贴板路径的人工验收。

- Runner 对关键 invariant 做硬校验（失败则 `exit 1`，不会“假绿”）：A2/B2 后目标 `villageID` 不变、正常二次导入 `history entries +1 / duplicate 不变 / lineage continued`、重复导入 `entries 不变 / duplicate +1 / timeline 不新增`、重启前后 `history/trust/statistics` 一致、同账号连续导入保持预期 lineage。`gate.sh` 仅在 runner `exit 0` 且 `working tree clean` 时标记通过。
- 重启语义：`acceptance-runner` 通过临时 `FileSnapshotHistoryStore` + `FileManualTrackerStore`（同一临时目录，跨所有 `AppModel` 实例复用）重放 `current + history + manual` 事务，比早期 `InMemoryManualTrackerStore` 更接近生产；但仍不覆盖系统剪贴板与 App UI 刷新路径。
- 村庄 B 创建走正常 `AppModel.addVillageForImport()` / `renameSelectedVillage` 路径，不再直接编码 `UserDefaults`。

## 7. 失败处理

- 记录为独立 issue，附脱敏复现步骤。
- 不得修改测试期望掩盖覆盖不足或 trust persistence 问题。
