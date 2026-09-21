# Issue #279 第五切片：跨环境报告比较与 numeric acceptance

## 范围

本切片只实现 Release 性能报告的可比性校验、fail-closed `perf:gate`、测试和证据文档。

不修改产品性能路径，不引入 worker/UtilityProcess、列表 virtualization、DTO 窗口化、图片 LRU、SQLite 或新的缓存层。

## Acceptance contract v1

`perf:gate` 保留两种接口：CI 使用 single-report contract-only 校验；最终 numeric acceptance 使用同一 exact head 的两组四场景报告。

最终 numeric acceptance 的输入是：

- reference：Node 24 CI；
- candidate：Node 26 本机；
- 四个独立 scenario 必须全部存在：`overview`、`village-detail`、`history-24`、`official-lists`；
- 每个报告必须是 `baseline` profile、3 次 repetition、1 次 warm-up、10 秒 scroll、250ms process sampling、每 16 个采样点 footprint sampling；
- source commit、packaged binary commit、fixture manifest、platform 和 arch 必须匹配；
- `status` 必须为 `observed`，`failures` 必须为空，缺失 numeric metric 或 sample count 不足必须失败；
- reference/candidate 的 Node major 必须分别为 24/26；
- 四个 scenario 的目录名必须与 `report.options.scenario` 一致，不能把同一份 `history-24` 报告复制到其他目录；
- 四组 reference 报告之间、四组 candidate 报告之间，以及每个 reference/candidate pair 的 commit、binary provenance、manifest、platform 和 arch 必须一致；
- numeric gate 当前只针对 `history-24`：总导入 p50、峰值 RSS、峰值 footprint；其他指标仍必须有有限值，但不自动成为本切片的 numeric blocker。

每个 numeric metric 必须同时具有：

1. 明确的报告路径和最小 sample count；
2. 相对 tolerance；
3. 绝对上限。

candidate 只有在同时满足以下条件时才通过：

```text
candidate <= reference × (1 + relativeTolerance)
candidate <= absoluteLimit
```

contract 缺失、role 错误、manifest/schema 错误、status 失败、runtime/RSS/footprint repetition sample 缺失、tolerance/上限不是有限数值时，`perf:gate` 失败。

本仓库目前没有足够的 Node 24/Node 26 同 head 数值证据来填写这些数值，因此不在代码中猜测默认阈值。实际 tolerance 和绝对上限必须由 exact head 的真实报告计算并经过审查后，作为 versioned frozen contract 输入；未冻结前不能关闭 #279。

## 使用方式

报告目录布局：

```text
reports/node24/<scenario>/report.json
reports/node26/<scenario>/report.json
```

CI contract-only 接口保持为：

```sh
pnpm perf:gate \
  --report=e2e-artifacts/perf-history-24/report.json \
  --role=node24-ci \
  --scenario=history-24 \
  --output=e2e-artifacts/perf-history-24/gate.json
```

它只证明单份报告满足采集 contract，`acceptanceEligible` 必须保持 false。

冻结 numeric contract 后运行：

```sh
pnpm perf:gate \
  --contract=docs/plans/issue279-fifth-slice-contract.json \
  --reference-dir=reports/node24 \
  --candidate-dir=reports/node26 \
  --output=reports/perf-gate-result.json
```

命令退出码为 0 才表示 numeric acceptance 通过；任何缺失、unknown、provenance 不一致、报告失败或数值超限均为非零退出码。

## 当前证据边界

当前 slice 基于 `origin/main@717c8c3`；主干已有的 CI contract-only 参数与 `perf-gate` 实现保持一致。Node 24/Node 26 同一 exact head 的 numeric reports 仍需在后续阶段取得，现有 Node 26 文档数字仍是 observed evidence，不能替代 candidate reports，也不能单独形成 acceptance。

CI job 成功只表示报告采集流程完成；它不等于 `perf:gate` 通过，也不是关闭 #279 的依据。
