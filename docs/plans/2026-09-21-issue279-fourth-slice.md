# Issue #279 第四切片：跨环境 Release 性能门禁契约

## 基线

本切片基于 `origin/main@ad9ae2fd1782dce2c91e679967f0488a49e93961`，即 #337 合并后的 exact head。主干 CI run `35559709458` 已为四个 scenario 生成 Node 24 macOS Release perf artifacts：

- `packaged-perf-overview`
- `packaged-perf-village-detail`
- `packaged-perf-history-24`
- `packaged-perf-official-lists`

现有 `perf:release` 仍然是 observed baseline，不把 runner 成功误读为性能通过。第四切片新增 `perf:gate`，用于在取得真实 Node 24 CI report 与 Node 26 本机 report 后执行跨环境 gate。

## 冻结的 gate contract

`perf:gate` 要求 reference 与 candidate 同时满足：

- 相同源码 commit、packaged binary commit、fixture manifest、platform 和 arch；
- `profile=baseline`、3 repetitions、1 warm-up、10 秒滚动、250ms process sampling、每 16 个采样点 footprint sampling；
- `status=observed`、无 runner failure、恰好 3 个 repetition；
- source/binary provenance clean；
- runner Node 与角色一致：reference 为 `node24-ci`，candidate 为 `node26-local`；
- 每个 scenario 的 required metric 均为有限数值；unknown、缺失 footprint 或失败 run 一律 fail closed。

gate 只比较同一 scenario 的 reference/candidate，不允许 `scenario=all` 充当 gate 输入。

## Metric 语义

- 启动、TTI、导入、phase、scroll、IPC 使用现有 summary 字段；
- RSS 是 Electron 进程树 RSS；footprint 是当前 runner 采集的主进程 footprint，二者不合并；
- `peakRssBytes` 与 `peakFootprintBytes` 的 p50/p95 按 repetition 的 workload peak 汇总，不把每个 250ms 采样点当作独立 repetition；
- DTO/IPC 数字是 bridge 返回 Result 的 JSON UTF-8 字节数，不声称等于 Chromium structured-clone 字节数。

## 容差输入

容差不写死未经验证的数字。`perf:gate` 要求一个版本化 policy JSON，policy 必须为每个 scenario 的 required metric 提供 `maxAbsoluteIncrease` 或 `maxRelativeIncrease`，并声明 `node24-ci`/`node26-local` 角色。

示例命令：

```sh
pnpm perf:gate \
  --reference=/path/to/node24-ci/report.json \
  --candidate=/path/to/node26-local/report.json \
  --policy=/path/to/approved-gate-policy.json \
  --scenario=history-24 \
  --output=/path/to/history-24-gate.json
```

policy 必须由相同 exact head 的真实 report 复核后提交或作为 Release evidence 保存；缺失 policy 不能自动放宽为通过。

## 非目标

本切片不引入 virtualization、UtilityProcess/worker、图片 LRU、SQLite、分页 DTO 或关闭 History validation/journal。只有当 History-24 的 exact-head 跨环境证据仍显示异常时，才进入下一项 History 生命周期优化；只有当 Detail DTO 被确认是主因时，才单独审查 DTO/consumer 边界。

## 验证

```sh
pnpm exec vitest run scripts/perf-gate.test.ts scripts/perf-metrics.test.ts
pnpm test
pnpm typecheck
pnpm lint
pnpm format
pnpm package
pnpm smoke
pnpm test:e2e:packaged
```
