# Swift oracle / TypeScript parity protocol v2（E0-03 #302 修订）

本协议只服务迁移期测试。`golden-oracle` 不是 Electron product、不是运行时
fallback，也不读取 Keychain、真实用户数据或网络。

> E0-03（Issue #302）撤销 oracle `inputFingerprint` / `outputFingerprint` 与 manifest
> `fixtureSha256` hash 防御；protocolVersion 提升为 2，旧 v1 响应直接视为不支持，
> 不加 v1 fallback。删除执行 #305（含 `Tests/Golden/manifest.json` 与 fixtures 重生成）。
> Git/fixture 路径已经提供版本来源，不再额外写 digest 清单。

## 请求

每次启动 oracle 通过 stdin 接收一个 JSON 对象：

```json
{
  "protocolVersion": 2,
  "caseId": "wire/json-raw-samples/nfc-precomposed-then-nfd",
  "operation": "canonical-json",
  "source": "{\"\\u00e9\":1,\"e\\u0301\":2}"
}
```

`source` 是原始 JSON 文本的字符串，不能先解析成普通 JS 对象。stdout 必须只有一个
JSON 响应；诊断只写 stderr。

## 响应（无 fingerprint）

成功响应包含 `value.canonicalHex`，拒绝响应只包含稳定的 `error.kind/code`：

```json
{
  "caseId": "wire/json-raw-samples/nfc-precomposed-then-nfd",
  "ok": true,
  "protocolVersion": 2,
  "value": { "canonicalHex": "7b..." }
}
```

- 请求/响应通过 `caseId` 关联；结果通过 `canonicalHex`、业务字段和差异 path 比较。
- 拒绝结果只含 `error.kind/code`，不含 `value`。
- comparator 必须同时检查 fixture expected、Swift output 和 TS output；不能只比较
  两侧都读取的同一份 expected。
- parity failure 必须区分 fixture、wire、parser、projection、error、ordering、time；
  未执行仍是未执行，不能因没有 hash 而变成绿色。

## 比较规则

- 对象键按照 wire 契约比较；数组位置变化是实际差异，不能全局排序后掩盖。
- 只允许 golden contract / owner test 明确定义的 normalization；例如 AccountSnapshot wire 的
  `diagnostics[].id` 随机槽位在 `parser_golden_expected.json` 与
  `maskDiagnosticIdsInWireHex()` 中掩码为 `<RANDOM_DIAGNOSTIC_UUID>`。
- 差异必须包含 `caseId`、类别和路径；类别至少区分 `fixture`、`wire`、`parser`、
  `projection`、`error`、`ordering`、`time`。
- 失败报告不得打印 source、token、Cookie、URL 或完整响应体。

## Manifest 登记（Tests/Golden/manifest.json，protocolVersion=2）

每个 fixture 条目包含 `id`、`category`、`operation`、`fixture`、
`swiftOwner`、`typescriptOwner`（🗑️ E0-03：删除 `fixtureSha256` 字段与 fixture 内容
hash 校验，#305 执行）。串线防护改由以下三项承担：manifest 登记与 `Fixtures/` 一一
对应（缺登记/孤儿 fixture 即 CI 失败）、fixture 相对路径必须位于仓库根目录内
（越界即失败）、每个 operation 的 case 必须有明确的 owner 测试消费。

| operation | 含义 | 消费方 |
|---|---|---|
| `canonical-json` | Swift oracle ↔ TS canonical JSON parity | `golden.parity.test.ts` |
| `fixture-registry` | 仅登记与测试归属，不经 oracle 驱动 | 各 owner 测试直接读取 fixture |
| `manual-queue-capacity` | 队列容量 gate/occupancy oracle parity | `manual-queue-capacity.parity.test.ts` |
| `snapshot-history-diff` | 快照历史 diff oracle parity | `snapshot-history.parity.test.ts` |
| `snapshot-history-canonicalize` | 快照历史 canonicalize oracle parity | `snapshot-history.parity.test.ts` |
| `manual-reconciliation-preview` | 对账 preview oracle parity | `manual-reconciliation.parity.test.ts` |

当前 manifest 登记 wire / parser / projection / diff 共 10 条 fixture。**error 场景
fixture 仍由 E2-06（#274）等域 issue 追加**，不在本协议中提前实现领域逻辑。
