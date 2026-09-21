# Issue #279 第三切片：阶段 profiling 与 History commit 优化

## 范围

本切片完成两件事：

1. 在 packaged Release 的 perf fixture 中记录 Main import/history/storage、projection、IPC 现有指标和 renderer commit effect；
2. 根据同一 workload 的阶段证据，复用同一 import 生命周期已经加载的 history，并移除 encode 前会被 wire round-trip 再次完整校验的重复 envelope validation。

没有引入 UtilityProcess/worker、分页或窗口化 DTO、列表 virtualization、图片 LRU、SQLite 或增量索引。

## 阶段 profiling

`COCHELPER_PERF_TRACE_FILE` 只在 `perf:release` 启动的 packaged runner 中启用，trace 写入本次隔离 data root；生产模式不写阶段 trace，也不改变业务 DTO。

记录的 Main 阶段包括：

- import parse；
- history load、canonicalization、encode、previous/wire validation；
- reconciliation build/diff；
- transaction commit、journal/write；
- overview/detail projection、detail rows、DTO；
- renderer 的 overview/detail commit effect。

## History-24 证据

环境：macOS arm64，Node `v26.0.0`，每次 `repetitions=3`、`warmup=1`、`scrollMs=10000`。本机 Node 26 与项目声明/CI 的 Node 24 不同，以下数字是 observed 对比，不是跨环境性能门禁。

| 指标 | 优化前 `b614a6f` | 最终 head `79dd377` | 变化 |
|---|---:|---:|---:|
| History-24 总导入 p50 | 83,241 ms | 53,522 ms | 约 -35.7% |
| history.load p50 | 675 ms | 675 ms | 保持 |
| history canonicalization p50 | 9 ms | 9 ms | 保持 |
| history previous validation p50 | 502 ms | 502 ms | 保持 |
| history wire validation p50 | 537 ms | 528 ms | 保持在方差内 |
| storage.commit p50 | 2,312 ms | 1,097 ms | 约 -52.6% |
| storage.write p50 | 14 ms | 14 ms | 保持 |
| reconciliation diff p50 | 6.6 ms | 6.6 ms | 保持 |

优化前阶段显示每次 import 还有约 `551ms` 的 input envelope validation，以及事务内部再次 `history.load` 的约 `675ms`。优化后：

- `SnapshotImportService` 把同一生命周期已经加载的 `historyEnvelope` 传给事务协调器；
- 事务仍校验 previous raw history；
- 新 envelope 先编码，再从 wire bytes 解码并完整校验；
- journal、原子写入、rollback 和 recovery 语义未改变。

峰值 RSS/footprint 在两次本机 run 间没有形成可宣称的改善，故本切片不声称解决内存问题。

## 验证

```sh
pnpm test
pnpm typecheck
pnpm lint
pnpm format
pnpm package
pnpm smoke
pnpm test:e2e:packaged
pnpm perf:release --profile=baseline --scenario=history-24 --repetitions=3 --warmup=1 --scroll-ms=10000
```

性能 runner 仍按每个 scenario 独立运行；`scenario=all` 不作为验收门禁。性能数值仍保持 diagnostic-only，不能把 runner 成功误读为跨环境性能通过。
