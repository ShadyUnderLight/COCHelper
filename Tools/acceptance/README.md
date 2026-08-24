# Issue #226：真实村庄连续导入与历史统计验收门禁

本目录交付 **release 前真实数据与 UI 验收** 的可审计脚手架，不重复实现 source coverage contract（#173），也不修改 production 语义。

## 范围

| 类别 | 内容 |
|---|---|
| 真实村庄验收 | 两个村庄 A1→A2、B1→B2，双入口、重启、lineage 隔离（需本地 JSON） |
| 自动化回归 | `AppModelSnapshotHistoryTests` + 全量 `swift test` |
| Release 性能 | 1000+ 城墙 fixture-equivalent + Release App 人工交互（见 `large_walls_perf_scenario.md`） |

## 快速开始

```bash
# 1. 自动化门禁（无需真实 JSON）
chmod +x Tools/acceptance/gate.sh
Tools/acceptance/gate.sh

# 2. 真实村庄脱敏记录（可选，需本地 JSON）
# 将 village-a-1.json … village-b-2.json 放入 Tools/acceptance/local/
swift run acceptance-runner Tools/acceptance/local > Tools/acceptance/results/$(date +%Y-%m-%d)/real-village-acceptance.json
```

## 文件索引

- `acceptance_protocol.md` — 与 Issue #226 对齐的手工验收步骤
- `record_template.md` — 脱敏证据记录模板
- `large_walls_perf_scenario.md` — 1000+ 城墙 Release 性能场景
- `gate.sh` — 自动化门禁脚本
- `generate_large_walls_fixture.py` — 生成匿名大城墙 fixture
- `local/` — 本地真实 JSON 放置区（gitignore）
- `results/` — 验收证据（脱敏）

## 红线

- 不提交 raw 账号 JSON、tag、token、cookie、JWT。
- 无可信协议时，`insufficientCoverage/数据不足` 是正确结果，不是失败。
- 不把 synthetic fixture 或单元测试当作真实用户验收。
- 真实验收暴露 bug 时另开 issue，不在本门禁放宽 fail-closed。
