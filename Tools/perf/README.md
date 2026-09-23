# Electron Release 性能工具

当前性能路径只使用 Electron packaged app：

```bash
pnpm package
pnpm perf:release --profile=baseline --scenario=overview --repetitions=3 --warmup=1 --scroll-ms=10000
pnpm perf:gate --report=<report.json> --role=node24-ci --scenario=overview --output=<gate.json>
```

场景、fixture、采样协议和 provenance 由 `scripts/electron-perf.mjs`、
`scripts/perf-config.mjs`、`scripts/perf-provenance.mjs` 与 `e2e/fixtures/perf-manifest.json`
共同维护。旧 Swift Release App / Instruments 报告保留在 `Tools/perf/results/`，仅作为历史
证据，不是当前门禁或运行入口。

`generate_large_walls_fixture.py` 只生成匿名输入 fixture，不启动 Swift 或 Electron，输出根
目录为 `fixtures/account/`。
