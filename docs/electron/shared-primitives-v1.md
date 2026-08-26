# Electron 共享基础原语 v1

本文冻结 Electron 迁移中跨 `contracts`、`domain`、`wire`、`testkit` 和 Main/Preload
边界复用的基础语义。它不实现账号、目录、投影、历史或真实 API 服务；这些能力由
后续 E2 issue 消费本文件定义的 seam。

## 1. Result 与错误

操作结果使用以下二选一结构：

```text
{ ok: true, value: T }
{ ok: false, error: IpcError }
```

`IpcError` 的 `kind` 是稳定机器分类，`code` 是稳定错误码；`messageKey` 是本地化键，
`message` 是当前语言的安全展示文本。可选诊断包含 `severity`、`code`、`messageKey`、
`message` 和受限 `path`。

错误 envelope 不得包含 `Error`、`stack`、`cause`、URL、headers、response body、token
或其他凭据。Main 对未知异常只返回通用 `internal`，参数错误只返回静态、经清洗的
`validation` 文案。官方 API 的 `failureKind` 仍由后续 API 层按
`error-matrix.md` 映射，不与 IPC `kind` 混用。

## 2. 时间与身份 seam

`Clock.nowMs()` 唯一表示 Unix epoch 毫秒；domain 不直接读取 `Date.now()`。需要可重放
身份的操作依赖 `UuidSource.next()`，生产随机 UUID 仍使用 wire 的安全随机实现。

`StableId` 由语义组件按 Swift `TrackerItemKey.stableID` 的 `|` 分隔规则构造；组件
只能是字符串或 `bigint`，不允许数组位置、展示名称或本地化文本进入身份。`LineageId`
是带独立语义 brand 的大写连字符 UUID，必须由 `UuidSource` 注入或从已校验文本解析。

`FakeClock` 只接受安全整数毫秒，可以设置、推进或回拨时间。测试随机源固定为
SplitMix64，输出仅用于 property/fuzz 测试，不得用于生产安全随机。

## 3. 饱和算术

wire 的饱和 add/subtract/multiply 只接受 `bigint` 和显式闭区间边界，先计算精确值，
再将越界结果钳制到 `min` 或 `max`：

```text
{ value: bigint, overflowed: boolean }
```

`overflowed=false` 且 `value == max` 表示精确命中上界；`overflowed=true` 表示发生过界。
实现不得使用 JS `number`、位宽回绕或隐式浮点转换。领域聚合器必须在后续 issue 中继续
传播上游的 overflow provenance。

## 4. IPC 取消

取消不通过 Structured Clone 传递 `AbortSignal` 或 `AbortController`。Renderer/Preload
只发送：

```text
request.cancel({ requestId })
```

Main 以 `senderId + requestId` 为作用域维护 `AbortController`。开始请求时注册 signal，
取消时只允许同一 sender 触发，完成或 sender 销毁时清理。未知、迟到和重复取消都是
no-op；取消结果归类为 `cancelled`，不得降级成 `network`。

真实 fetch、retry sleep 和 single-flight 的 signal 接入由 API/并发迁移 issue 负责。

## 5. 可重放测试材料

共享测试使用固定 seed，属性失败必须记录 seed 和 iteration。算术属性测试使用独立
BigInt oracle，parser corpus 覆盖深层 JSON、长整数、`__proto__`、非法逗号、前导零、
孤立 surrogate 和非有限数字。跨语言 oracle/parity harness 仍由 #268 统一维护。
