# Error Matrix（E0-02 冻结）

> Issue #265 交付物。冻结错误分类、失败保留语义与展示/动作门禁。
> 每条标注 Swift 出处（file:line，基于 main@f513a35）。引用格式：§ER-x.y。

## ER-1 HTTP → CoAPIError 映射

case 定义：CoAPIError.swift:8-17；映射：CoAPIClient.swift:63-83。

| CoAPIError case | 触发 | 备注 |
|---|---|---|
| `missingCredentials` | tokenProvider 返回 nil | CoAPIClient.swift:52-54 |
| `unauthorized` | HTTP 401 | :66-67 |
| `accessDenied(reason:)` | HTTP 403，reason 取自响应体 | :68-69 |
| `notFound` | HTTP 404 | :70-71 |
| `rateLimited(retryAfterSeconds:)` | HTTP 429；未耗尽重试先 sleep 再试，耗尽才抛 | :72-78 |
| `serverError(statusCode:)` | 500..<600 原状态码透传 | :79-80 |
| `timeout` | URLError.timedOut | :105-107 |
| `network(underlying:)` | 其他 URLError / 意外状态码（脱敏仅数字码） | :81-82, 102-107 |
| `malformedResponse(detail:)` | JSON 解码失败（各 fetch 方法） | :122, 136-138 |

取消透传契约：client 层把 `CancellationError` 与 `URLError(.cancelled)` **原样 rethrow**，
绝不被误报为 network；`.cancelled` 不经 CoAPIError 传递（CoAPIClient.swift:84-97;
CoAPIError.swift:27-39 注释）。

## ER-2 failureKind 协议（唯一稳定错误协议）

`OfficialEndpointFailureKind`：10 个 String raw-value、**无 associated value**（不泄露
reason/detail/statusCode 脱敏细节）、Codable（OfficialEndpointState.swift:25-46）：

```text
missingCredentials / unauthorized(401) / accessDenied(403) / notFound(404) /
rateLimited(429) / serverError(5xx) / timeout / network / malformedResponse / cancelled
```

- 成功状态 `failureKind == nil`。
- 旧持久化缺字段 → `decodeIfPresent` 解码为 nil → 调用方走 fail-closed 兜底
  `mapFailedStateLegacy`（AppModel.swift:3957-3968，按 lastHTTPStatus + 固定文案「已取消」识别）。
- 文案（userFacingReason）只作展示不作协议。

## ER-3 失败保留语义（refreshState 分支表）

核心不变量 **retainedParserVersion**（EndpointRefresher.swift:83）：

```swift
let retainedParserVersion = previous?.lastGood != nil ? previous!.parserVersion : parserVersion
```

失败保留旧 lastGood 却写新 parserVersion → `isCurrentParserVersion` 误判 → 再 load-more 时
needsRebuild=false → 用旧 cursor 把新版本页 merge 进旧版本页（79-82 注释；锁定测试
`testLoadMoreCapitalParserRebuildFailurePreservesParserVersionAndRetriesRebuild`；
项目记忆坑点：给 state 加字段时不得覆盖 retainedParserVersion 用法）。

| 分支 | status | fetchedAt | lastGood | failureKind | parserVersion |
|---|---|---|---|---|---|
| 成功 | `.success` | now | 本次快照 | nil | 新 parserVersion |
| CoAPIError | `.failed` | **保留 previous** | **保留 previous** | error.kind | retainedParserVersion |
| CancellationError | `.failed` | 保留 | 保留 | `.cancelled` | retainedParserVersion |
| URLError(.cancelled) | `.failed` | 保留 | 保留 | `.cancelled` | retainedParserVersion |
| 其他未知错误 | `.failed` | 保留 | 保留 | `.network` | retainedParserVersion |

共同项：unrecognizedKeys 成功取快照、失败取 previous（fallback []）；lastErrorReason 成功 nil、
失败为脱敏文案。**cancellation 算失败**（status=.failed），但三保留照旧——取消后 UI 仍可继续
展示上次成功数据。合法空状态（如 notInWar）是成功快照，不是失败（OfficialEndpointState.swift:55）。

## ER-4 展示门禁

### ER-4.1 来源标签矩阵（OfficialAPISourceLabeling.swift:11-20）

| status \ hasLastGood | true | false |
|---|---|---|
| success | `official-api` | `official-api` |
| failed | `cached-official-api`（UI：「缓存的官方 API 数据」） | nil（UI 隐藏） |
| never / loading / skipped | nil | nil |

### ER-4.2 失败二分展示态

`ClanWarRefreshStatus` 七态：never/loading/success/stale/**failedWithLastGood**/
**failedWithoutLastGood**/skipped；派生规则 `state.lastGood == nil ? .failedWithoutLastGood :
.failedWithLastGood`，stale 判定复用同一 displayStatus 映射点防双实现漂移
（ClanWarDisplayProjection.swift:338-355, 594-606；issue #125 明示「失败保留上次成功数据 ≠
首次失败」是独立展示状态）。⚠️ 该投影 API 在 Swift UI 尚未接线（现卡片以 fetchedAt 有无近似
区分两态，ClanWarCardView.swift:142-157）——TS 按 Core 投影 API 实现，不复制 UI 近似。

## ER-5 数据可信度 → 动作门禁（Start 按钮全部 fail-closed）

核心：`UpgradeActionProjection.action(...)`；startable = reasons 为空且 fromLevel/targetLevel/
baseline 齐备且 duration 可用（UpgradeActionProjection.swift:176-338, 525-542）。

| 数据状态 | 门禁结果 | 出处 |
|---|---|---|
| coverage `.partial` | 「覆盖不完整，不能安全启动本地升级。」 | UpgradeActionProjection.swift:198-199 |
| coverage `.unavailable` | 「覆盖状态不可用…」 | :200-201 |
| effective.status `.conflict` | 「本地与导入状态冲突。」 | :212-213 |
| effective.status `.unknown` | 「当前等级分布未知。」 | :214-215 |
| importedCountQuality malformed/overflowed | 对应 reason | :219-226 |
| 目录不可用 | 提前返回，无 action | :229-243 |
| manualActive 行 | 无 action（Start 由 Cancel/Adjust 承接） | :245-246 |
| durationState 非 timed/instant | 「目标升级时长不可用。」 | :280-285 |
| cost unknown / 费用解析失败 | **不阻塞**，只进 diagnostics | :174-175, 287-291 |

coverage 收窄规则：整村 partial 时仅 item 自身 section（去掉 "2" 后缀）缺失才降 `.partial`，
无关类别缺失 → `.complete`（:345-360）。

执行前复核（canonical typed command）：重建 fresh action 后五字段逐一比对防陈旧动作，
不一致抛 `.staleAction`（AppModel.swift:1619-1639, 1670-1683）。

## ER-6 store 错误枚举全集

| 枚举 | case | 触发要点 |
|---|---|---|
| VillageStoreError | unavailable / corrupt(rawData,message) / unsupportedSchema(schemaVersion) / writeFailed | §BE-1.1 |
| SnapshotHistoryStoreError | unavailable / corrupt / unsupportedSchema / invalidEntry / writeFailed | §BE-1.2; SnapshotHistoryStore.swift:320-341 |
| ManualTrackerStoreError | unavailable / corrupt / unsupportedSchema / invalidEnvelope / writeFailed | §BE-1.3; ManualTrackerStore.swift:450-471 |
| SnapshotImportTransactionError | rollbackFailed / journalCorrupt（journal 写失败也归此类） | §BE-2; SnapshotImportTransaction.swift:173-185, 421 |
| ManualTrackerTransactionError | rollbackFailed / journalCorrupt / journalWriteFailed | ManualTrackerTransaction.swift:184-199 |

UI 状态枚举映射：manual tracker corrupt → `.unavailable`、future-schema → `.migrationRequired`
（§BE-1.3）；village 各态见 §BE-1.1。
