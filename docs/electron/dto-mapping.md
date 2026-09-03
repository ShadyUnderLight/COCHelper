# 旧 Swift 输出 → 新 wire/DTO 映射表（E0-02 冻结）

> Issue #265 交付物。逐族列出旧 Swift 持久化/传输形态与 Electron 终态 wire 类型的对应关系。
> 「wire 类型名」是建议命名，最终由 #267/#268 在 packages/contracts 落地时定稿；
> **形状与语义以本文 + wire-contract-v1.md 为准**。

## M-1 值域基础

| Swift 形态 | 盘上形状 | 新 wire 类型 | 关键规则 |
|---|---|---|---|
| `CanonicalJSONValue` | tagged JSON（kind 标签） | `CanonicalJsonValue` | §WA-1；number 载荷保持 token 字符串 |
| `Data`（canonical bytes） | UTF-8 bytes | `Uint8Array` | §WA-2 逐字节复刻 |
| fingerprint 字符串 | 🗑️ E0-03 已删除（旧形状 `"sha256:" + 64 小写 hex`，`Sha256Fingerprint` branded string；格式门旧见 §WA-3） | 新 wire 不再定义指纹类型；删除执行 #303/#304/#305 |
| `Int64` | JSON number | `bigint`（domain 层）/ token string（wire 层） | §WA-6 三层解析分别建模 |
| `UUID` | 大写连字符字符串 | `UuidString` | §WA-5 |
| Tracker semantic printable key | `TrackerItemKey.stableID` 字符串 | `StableId`（domain branded string） | 仅由语义组件构造；复刻 deterministic printable stable ID，不替代 Swift structural persisted identity |
| snapshot lineage identity | `lineageID` UUID | `LineageId`（domain branded UUID） | 🗑️ E0-03：不再进入 digest（旧 F2 integrity material 已撤销）；来源必须可注入/可校验（lineage 校验与 revision 审计仍依赖它，执行 #304） |
| `Date` | reference-date Double（T2 域） | `RefEpochSeconds`（number） | §WA-4；与 Unix 秒显式区分 |
| 官方时间字符串 | 原样字符串 | `OfficialUtcString` | §WA-4 T3；不解析落库 |

## M-2 legacy 导入链（parserVersion `account-json-0.1`）

| Swift 类型 | 新 wire DTO | 备注 |
|---|---|---|
| `AccountSnapshot` | `AccountSnapshotWire` | 🗑️ E0-03：删除 contentFingerprint 字段与解码后重算（旧 §WA-3 F3，执行 #304） |
| `AccountItem`（objectSections 条目） | `AccountItemWire` | dataID 解析走 §WA-6c 三级规则 |
| `AccountDataDiagnostic` | `AccountDiagnosticWire` | 随机 id 不进任何内容身份比较；severity/path/message 进 |
| 导出文本 `originalText` / entry `rawJSON` | 原文逐字保留字段 | 🗑️ E0-03：rawJSON 不再是 digest 输入（旧 F2 已撤销，执行 #304）；rawJSON 重 canonicalize 比对保留。**观察身份仅由解析后的 canonical observation 派生**——原文的 whitespace/键序/数组序不属于身份（§WA-2 规则 7）。 |

## M-3 快照历史 envelope

| Swift 类型 | 新 wire DTO | 备注 |
|---|---|---|
| `SnapshotHistoryEnvelope`（schemaVersion=2 + migrationMarker + entries/lineages/duplicateMetadata，见 §WA-7；DTO 命名由 #304 定稿） | 新 envelope shape | §BE-1.2 校验全量复刻（除已撤销的 F2 摘要重算） |
| `SnapshotHistoryEntry` | 新 entry shape（envelope=2/entry=2，见 §WA-7；DTO 命名由 #304 定稿） | 🗑️ E0-03：删除 `canonicalFingerprint` / `integrityFingerprint` / `fingerprintVersion` / `integrityVersion` 四字段；lineage metadata 删除 `lastFingerprint`（执行 #304） |
| `CanonicalSnapshotObservation`（observation=6） | `ObservationV6` | v2/v3/v4/v5 版本差量见 §WA-7 |
| `SnapshotCoverage*`（proof 四态/presence/completeness/duplicate key/sourceUniverse） | `CoverageWire` 族 | runtimeWitness 永不出现在 wire（§WA-3） |
| `SnapshotLineageResolution` / lineage index | `LineageIndexV1` | append-only entry vs mutable index（§BE-3） |

## M-4 手动升级 tracker

| Swift 类型 | 新 wire DTO | 备注 |
|---|---|---|
| `ManualTrackerEnvelope`（envelope/store/village=2 + migrationMarker，见 §WA-7；DTO 命名由 #304 定稿） | 新 tracker envelope shape | 结构校验清单 §BE-1.3 |
| `ManualUpgradeRecord` / itemStates | `TrackerRecordWire` 等 | 🗑️ E0-03：删除内容指纹（旧 F4 `{itemStates, records}`，执行 #304）；baseline 只保留 revision + lineageID |
| reconciliation preview/decision 分类 | `ReconciliationClassWire`（14 值枚举） | §BE-5.1 顺序即契约 |
| QueueAssignment overlay / capacity configs | `QueueAssignmentWire` / `QueueCapacityConfigWire` | §BE-5.3 |

## M-5 官方 API 状态族（无 schemaVersion）

| Swift 类型 | 新 wire DTO | 备注 |
|---|---|---|
| `OfficialEndpointState<Snapshot>` | `EndpointStateWire<S>` | failureKind 十值协议 §ER-2；三保留语义 §ER-3 |
| `OfficialClanSnapshot` / war / warlog 页 / capital 页 | `ClanWire` / `ClanWarWire` / `WarLogPageWire` / `CapitalRaidPageWire` | decodeIfPresent + unrecognizedKeys 审计（§WA-1.4）；items 必填 §WA-8 |
| OfficialStateStore 单元素字典数组容器 | `StateStoreFileV1` | encode 按 tag 排序；maxEntries 截断 §BE-1.4 |
| `TrackedClanProfile` 数组 | `TrackedClanWire[]` | 添加顺序即 UI 序 §BE-1.5 |
| `CoAPITokenStore`（Keychain） | safeStorage secret store | token 绝不入可序列化状态 |

## M-6 村庄与投影缓存

| Swift 类型 | 新 wire DTO | 备注 |
|---|---|---|
| VillageStore 裸数组 `[VillageProfile]` | `VillageStoreFileV1`（数组 + 未来版本顶层声明识别） | §BE-1.1 四态矩阵 |
| `EffectiveVillageProjection` / `UpgradeOverviewProjection` / detail flat rows | domain 层投影类型 | 投影级 golden 由 E2-* 追加到 Tests/Golden |
| 投影 stableID | `StableId` 字符串拼接规则冻结 | 例：epoch 秒内嵌 §WA-4 |

## M-7 事务 journal

| Swift 类型 | 新 wire DTO | 备注 |
|---|---|---|
| import journal（phase + 六份 payload） | `ImportJournalV1` | 状态机与恢复顺序 §BE-2；向后兼容字段 manualIncluded 推断规则一并迁移 |
| manual journal（四份 payload） | `TrackerJournalV1` | 同上 |
| `<journalURL>.quarantined` | 同机制文件后缀 | quarantine 只在用户显式 restore/reset 发生 §BE-2.4 |
