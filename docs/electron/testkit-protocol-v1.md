# Swift oracle / TypeScript parity protocol v1

本协议只服务迁移期测试。`golden-oracle` 不是 Electron product、不是运行时
fallback，也不读取 Keychain、真实用户数据或网络。

## 请求

每次启动 oracle 通过 stdin 接收一个 JSON 对象：

```json
{
  "protocolVersion": 1,
  "caseId": "wire/json-raw-samples/nfc-precomposed-then-nfd",
  "operation": "canonical-json",
  "source": "{\"\\u00e9\":1,\"e\\u0301\":2}"
}
```

`source` 是原始 JSON 文本的字符串，不能先解析成普通 JS 对象。stdout 必须只有一个
JSON 响应；诊断只写 stderr。

## 响应与 fingerprint

成功响应包含 `value.canonicalHex`，拒绝响应只包含稳定的 `error.kind/code`：

```json
{
  "caseId": "wire/json-raw-samples/nfc-precomposed-then-nfd",
  "inputFingerprint": "sha256:<64 lowercase hex>",
  "ok": true,
  "outputFingerprint": "sha256:<64 lowercase hex>",
  "protocolVersion": 1,
  "value": { "canonicalHex": "7b..." }
}
```

- `inputFingerprint` = `source` UTF-8 bytes 的 SHA-256。
- `outputFingerprint` = canonical bytes 的 SHA-256。
- 拒绝结果不伪造 output fingerprint。
- comparator 必须同时检查 fixture expected、Swift output 和 TS output；不能只比较
  两侧都读取的同一份 expected。

## 比较规则

- 对象键按照 wire 契约比较；数组位置变化是实际差异，不能全局排序后掩盖。
- 只允许 manifest 明确列出的 normalization；AccountSnapshot wire 的 `diagnostics[].id`
  随机槽位在 parser golden 中掩码为 `<RANDOM_DIAGNOSTIC_UUID>`。
- 差异必须包含 `caseId`、类别和路径；类别至少区分 `fixture`、`wire`、`parser`、
  `projection`、`error`、`ordering`、`time`。
- 失败报告不得打印 source、token、Cookie、URL 或完整响应体。

## Manifest 登记（Tests/Golden/manifest.json）

每个 fixture 条目包含 `id`、`category`、`operation`、`fixture`、`fixtureSha256`、
`swiftOwner`、`typescriptOwner`。`fixtureSha256` 是 fixture 文件 UTF-8 bytes 的 SHA-256，
由 `packages/testkit/src/manifest.test.ts` 在 CI 中校验。

| operation | 含义 | 消费方 |
|---|---|---|
| `canonical-json` | Swift oracle ↔ TS canonical JSON parity | `golden.parity.test.ts` |
| `fixture-registry` | 仅登记指纹与测试归属，不经 oracle 驱动 | 各 owner 测试直接读取 fixture |
| `manual-queue-capacity` | 队列容量 gate/occupancy oracle parity | `manual-queue-capacity.parity.test.ts` |
| `snapshot-history-diff` | 快照历史 diff oracle parity | `snapshot-history.parity.test.ts` |
| `snapshot-history-canonicalize` | 快照历史 canonicalize oracle parity | `snapshot-history.parity.test.ts` |
| `manual-reconciliation-preview` | 对账 preview oracle parity | `manual-reconciliation.parity.test.ts` |

当前 manifest 登记 wire / parser / projection / diff 共 10 条 fixture。**error 场景
fixture 仍由 E2-06（#274）等域 issue 追加**，不在本协议中提前实现领域逻辑。
