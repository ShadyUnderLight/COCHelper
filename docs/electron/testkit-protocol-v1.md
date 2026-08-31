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
- 只允许 manifest 明确列出的 normalization；当前 v1 没有随机字段掩码。
- 差异必须包含 `caseId`、类别和路径；类别至少区分 `fixture`、`wire`、`parser`、
  `projection`、`error`、`ordering`、`time`。
- 失败报告不得打印 source、token、Cookie、URL 或完整响应体。

v1 只登记 `json-raw-samples`。其它 parser fuzz、账号快照、projection、diff、storage/API
fault case 由对应领域迁移 Issue 增加 manifest entry 和 TypeScript owner，
不在本协议中提前实现领域逻辑。
