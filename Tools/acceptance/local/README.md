# 本地真实村庄数据（不提交仓库）

将两个真实村庄的连续导出 JSON 放在此目录，文件名固定如下：

| 文件 | 用途 |
|---|---|
| `village-a-1.json` | 村庄 A 第一次导出（账号数据页导入） |
| `village-a-2.json` | 村庄 A 第二次导出 |
| `village-b-1.json` | 村庄 B 第一次导出（详情页快捷导入） |
| `village-b-2.json` | 村庄 B 第二次导出 |

约束：

- 不得提交 raw JSON、账号 tag、token、cookie 或 JWT。
- 若来源没有可信 coverage 协议，验收预期为 `unknown/insufficientCoverage`，不得人为添加 coverage 字段。
- 运行脱敏验收记录器：

```bash
swift build --product acceptance-runner
.build/debug/acceptance-runner Tools/acceptance/local > Tools/acceptance/results/$(date +%Y-%m-%d)/real-village-acceptance.json
```

输出仅含 history count、lineage、duplicate、trust、统计状态等脱敏字段，不含原文 JSON。
