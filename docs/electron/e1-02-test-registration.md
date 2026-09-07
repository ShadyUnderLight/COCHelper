# E1-02（#268）测试登记与差异处置

本文件是 Issue #268 剩余验收的人工可读台账。机器可校验来源：

- `Tests/Golden/manifest.json`（caseId / operation / owner）
- `packages/testkit/src/registration.baseline.test.ts`
- `pnpm check:oracle-isolation`
- `pnpm test:fault-replay`（含 storage fault 与 replay token）

## 领域回链（#269–#275）

| Issue | 能力 | Manifest caseId | TypeScript owner | 证据类型 | 处置 |
|---|---|---|---|---|---|
| #269 | 账号解析 | `parser/account-snapshot-golden`、`parser/golden-expected` | `account-parser.parity.test.ts` / `canonicalizer.golden.test.ts` | frozen hex / fixture-registry | 通过；跨语言 Swift oracle 非本 case 驱动 |
| #270 | Catalog | `projection/catalog-contract` | `catalog.contract.test.ts` + domain catalog tests | fixture-registry | 通过 |
| #271 | 村庄投影 | `projection/village-projection-contract` | `village-projection.contract.test.ts` + domain village tests | fixture-registry | **deferred**：village Swift oracle（见 fixture dispositions） |
| #272 | Manual | `projection/manual-queue-capacity`、`projection/manual-reconciliation-preview` | `manual-queue-capacity.parity.test.ts` / `manual-reconciliation.parity.test.ts` | Swift oracle parity | 通过 |
| #273 | Snapshot History | `diff/snapshot-history-contract` | `snapshot-history.parity.test.ts` | Swift oracle parity | 通过 |
| #274 | Official API | `error/error-scenarios-contract` | `error-scenarios.contract.test.ts` | fixture-registry + fake server | 通过 |
| #275 | Storage | `error/storage-fault-contract` | `storage-fault.contract.test.ts` + persistence fault tests | fixture-registry + fault-replay | 通过 |

## 独立证据面

| Suite | 命令 | 含义 |
|---|---|---|
| unit | `pnpm test` | 默认单测（排除 `*.parity.test.ts`） |
| parity | `pnpm test:parity` | Swift oracle / 领域 parity |
| fault-replay | `pnpm test:fault-replay` | replay token + storage write fault |
| packaged smoke | `pnpm smoke` | 打包后进程冒烟（不等于完整 E2E；完整 E2E 归 #278） |
| oracle isolation | `pnpm check:oracle-isolation` | desktop 不依赖/不打包 oracle |

## 基线回读

```bash
pnpm baseline:e1-02
E1_02_BASELINE_SUITES=parity,fault-replay pnpm baseline:e1-02  # 未知名 / 空选择 fail-closed
```

产出 `docs/electron/e1-02-baseline-latest.json`。状态只允许 `pass` / `fail` / `not_run`；
`not_run` 不得被解释为通过。

## 非目标（不要顺手做）

- 不机械搬迁全部 XCTest
- 不把 Swift oracle 做成运行时 fallback
- 不在本 Issue 吞并 #276 IPC / #278 packaged E2E
