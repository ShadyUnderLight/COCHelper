# 脱敏验收记录模板

复制下表，每步填写一行。不得包含 raw JSON、完整 tag、token。

## 环境

| 字段 | 值 |
|---|---|
| commit SHA | |
| Release build 日期 | |
| macOS 版本 / arch | |
| 机器型号 | |
| catalog fingerprint | |

## 村庄 A（账号数据页）

| 步骤 | history entries | lineage 稳定 | duplicate count | trust display | timeline rows | today stat | 7d stat | 30d stat | 备注 |
|---|---:|---|---:|---|---:|---|---|---|---|
| A1 导入 | | | | | | | | | |
| 重启后 | | | | | | | | | |
| A2 导入 | | | | | | | | | |
| A2 重复 | | | | | | | | | |

## 村庄 B（详情页快捷导入）

| 步骤 | history entries | lineage 稳定 | duplicate count | trust display | timeline rows | today stat | 7d stat | 30d stat | 备注 |
|---|---:|---|---:|---|---:|---|---|---|---|
| B1 导入 | | | | | | | | | |
| 重启后 | | | | | | | | | |
| B2 导入 | | | | | | | | | |
| B2 重复 | | | | | | | | | |

## 串档检查

- [ ] A/B villageID 无交叉
- [ ] A/B lineage entry 无交叉
- [ ] A/B tag 无误覆盖

## Diff / coverage 摘要（脱敏）

| 村庄 | 步骤 | 有可信 proof | 预期 trust | 实际 trust | Wall/建筑 | 备注 |
|---|---|---|---|---|---|---|
| A | | yes/no | | | | |
| B | | yes/no | | | | |

## 性能（1000+ 城墙 Release）

| 场景 | 卡顿 | 内存异常 | UI 状态漂移 | 备注 |
|---|---|---|---|---|
| Village Detail 滚动 | | | | |
| Snapshot History 滚动 | | | | |
| 展开大变化 row | | | | |
| category filter 切换 | | | | |
| today/7/30 切换 | | | | |
