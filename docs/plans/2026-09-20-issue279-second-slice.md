# Issue #279 第二切片：运行并审查 Electron Release 性能基线

## 范围

本切片只固化 packaged Electron Release 的可复现测量协议和审查结论，不实施 virtualization、UtilityProcess/worker、图片 LRU 或窗口化 DTO。

当前基线协议由 `scripts/perf-config.mjs` 固定：

- 每个 scenario 独立运行，禁止用 `scenario=all` 作为验收门禁；
- `repetitions=3`；
- `warmup=1`，只用于 cold view 之后的 hot navigation；
- `scrollMs=10000`；
- process tree 每 `250ms` 采样；
- 主进程 footprint 每 16 个采样点强制采样；
- 每次 repetition 使用隔离的 data root、Electron user-data directory 和 fixture API；
- provenance 必须同时匹配源码 commit 和 packaged binary commit，且两者 clean。

数值容差暂不形成 green gate。原因是当前本机 pilot 使用 Node 26，而 CI 验收环境是 Node 24；同时 pilot 中出现 GPU/network service teardown 日志和 cold startup 离群值。报告继续保留 observed/unknown 语义，等待 Node 24 主干 artifact 后再决定是否形成回归容差。

## 2026-09-20 本机 pilot

来源：`origin/main@4af0300063ffaa633594a2e3ae1e7cbffab694bf`，macOS arm64，Node `v26.0.0`，`repetitions=3`、`warmup=1`、`scrollMs=10000`。四个 scenario 全部 `status=observed`，无 runner failures；这组数据是诊断证据，不是跨环境通过结论。

| 场景 | 启动 p50 | TTI p50 | Detail cold p50 | Detail DTO p95 | workload 峰值 RSS | workload 峰值 footprint |
|---|---:|---:|---:|---:|---:|---:|
| overview | 319 ms | 513 ms | 171 ms | 1,077,297 B | 780.2 MB | 223.0 MB |
| village-detail | 309 ms | 504 ms | 411 ms | 2,724,976 B | 932.7 MB | 369.5 MB |
| history-24 | 313 ms | 503 ms | 297 ms | 1,087,523 B | 1057.1 MB | 600.7 MB |
| official-lists | 312 ms | 489 ms | 169 ms | 1,077,301 B | 871.9 MB | 224.4 MB |

其他观察：1005 Wall before/after 导入 p50 为 `769/1956 ms`；History-24 总导入 p50 为 `90625 ms`；hot overview icon protocol request 为 `0`；Village Detail 和官方列表滚动 p95 大多约 `9 ms`，但部分 repetition 出现单个长帧/hitch。

## 审查结论

1. 先追踪 History-24 的 import/canonicalization/storage phase 和内存曲线；不能仅凭总 CPU/RSS 直接决定 worker。
2. Village Detail 的约 `2.72 MB` DTO 是明确的 DTO/投影审查对象；先确认其中各数组的实际占比和真实 consumer，再决定是否窗口化。
3. 当前滚动数据不足以证明 virtualization 必要；没有先改列表渲染。
4. hot icon 的 `0` 只能证明本次 protocol request probe 没观察到新请求，不能证明已有按尺寸 key 的 LRU；暂不实现图片缓存。
5. official WarLog/Capital payload 分别约 `130 KB/14 KB`，在本切片中不单独启动分页 DTO 改造。

## 复测命令

```sh
pnpm install --frozen-lockfile
pnpm package
pnpm perf:release --profile=baseline --scenario=overview --repetitions=3 --warmup=1 --scroll-ms=10000
pnpm perf:release --profile=baseline --scenario=village-detail --repetitions=3 --warmup=1 --scroll-ms=10000
pnpm perf:release --profile=baseline --scenario=history-24 --repetitions=3 --warmup=1 --scroll-ms=10000
pnpm perf:release --profile=baseline --scenario=official-lists --repetitions=3 --warmup=1 --scroll-ms=10000
```

`scenario=all` 仍可用于连续诊断，但不会被标记为 acceptance-eligible；任何缺失的 footprint、scroll 或 payload metric 都必须保持 `unknown`。
