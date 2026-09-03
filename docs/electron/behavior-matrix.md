# Behavior Matrix（E0-02 冻结，E0-03 #302 修订）

> Issue #265 交付物，Issue #302 修订。冻结启动分支、持久化行为、事务、lineage、分页、对账与并发协调的
> 用户可见语义。每条标注 Swift 出处（file:line，基于 main@f513a35）。
> 标注 🗑️ E0-03 的条目为已撤销的 hash 防御契约：新实现不得要求它们，
> 旧出处仅作删除审计保留（删除执行归属 #303/#304/#305）。
> 引用格式：§BE-x.y。

## BE-1 持久化 store 启动分支矩阵

两套并存的容错哲学，**必须分别复刻，不得统一**：

- **versioned fail-closed 组**（Villages / SnapshotHistory / ManualTracker）：schemaVersion 门、
  corrupt 保 raw 不覆盖、未来版本拒绝、错误显式上浮到 UI。
- **versionless fail-open 组**（OfficialStateStore / TrackedClanStore）：无版本、坏条静默丢、
  整库坏静默清空、超限静默截断。

### BE-1.1 VillageStore（UserDefaults blob `coc-helper.villages.v1`）

下表描述的是 `VillageStoreCodec.load` 的 **VillageStoreLoadResult** 分类（missing / loaded /
corrupt(rawData:message:) / unsupportedSchema(rawData:schemaVersion:)，VillageStore.swift:53-57,
80-96）及其 UI 状态映射；throw 出去的错误枚举见 §ER-6。

| 盘上状态 | 行为 | 出处 |
|---|---|---|
| missing（key 不存在） | 合成默认村庄（有 legacy 快照则带 tag），status=`.missing`，立即落盘 | AppModel.swift:581-592 |
| empty（`[]`） | **合法数据非 decode 失败**；规范化为单个默认村庄，不查 legacy snapshot；status=`.empty` | AppModel.swift:593-603; VillageStore.swift:78-85（注释 "An explicit empty array is valid data … not a decode failure"） |
| corrupt（畸形 JSON 或重复村庄 ID） | `.corrupt(rawData)`；raw bytes 存 recoveryData 可导出只读副本；占位村庄「需要恢复的村庄」；派生 store 不初始化；普通写入被 gate 阻断 | VillageStore.swift:79-92; AppModel.swift:610-614, 4512-4518 |
| future-schema | `.unsupportedSchema(rawData, version)`；**当前版本绝不覆盖**；且**跳过全部事务恢复写**防派生副作用；UI 提示「检测到未来村庄存储版本 N」 | VillageStore.swift:87-90, 114-121; AppModel.swift:522-537, 615-619 |
| 恢复期 journal 失败 | status 覆盖 `.readOnly`；不初始化派生 store、不落盘初始值 | AppModel.swift:622-629 |
| 初始落盘失败 | status=`.writeFailed`，停止派生 store 初始化 | AppModel.swift:691-700 |

恢复出口（全部用户显式触发，启动从不自动隔离/重置）：导出原始 bytes（AppModel.swift:2002-2019）、
从副本恢复（2025-2047，非法输入绝不覆盖现有 bytes）、重置（2097-2117，旧 bytes 先存
recovery 键）。`.readOnly/.corrupt/.unsupported/.writeFailed` 均 `isRecoveryRequired=true`
阻断普通写入（VillageStore.swift:20-27）。

### BE-1.2 SnapshotHistoryStore（文件 `snapshot-history-v1.json`）

| 盘上状态 | 行为 | 出处 |
|---|---|---|
| missing | load 返回 nil → 从当前村庄重建全新 envelope、打 migrationMarker 并保存 | SnapshotHistoryStore.swift:380-381, 515-553 |
| empty（合法空 envelope 无 marker） | 视为「未迁移的合法起点」，走迁移路径补 entries + marker | SnapshotHistoryStore.swift:212-215, 523-527 |
| corrupt | decode/校验失败即抛错；**坏文件绝不被空 envelope 覆盖**，原 bytes 原地保留 | SnapshotHistoryStore.swift:355-357, 380-389; AppModel.swift:726-728 |
| future-schema | envelope/marker/entry 任一版本不符 → `unsupportedSchema` 抛出，无覆盖 | SnapshotHistoryStore.swift:126-129, 208-211 |

逐条容错（envelope.validated() 每次加载全量执行）：entry 版本门精确匹配（新契约
envelope=2/entry=2，旧 envelope=1/entry=1 按 §WA-7.1 标记不可用）；
observation v2+ 必带 section evidence、≤v5 禁止 sourceUniverse；🗑️ E0-03 已删除
「每 entry 重算 F2 完整性指纹」——替换为 rawJSON 重 canonicalize 比对 +
lineage/duplicate 元数据交叉校验（SnapshotHistoryStore.swift:252-316 中非 digest
部分保留，digest 行删除，执行 #304）；autoreleasepool 排空防启动峰值内存（176-178）。
旧文件 bytes 原地保留、绝不被空 envelope 覆盖的语义不变。

### BE-1.3 ManualTrackerStore（文件 `manual-tracker-v1.json`）

| 盘上状态 | 行为 | 出处 |
|---|---|---|
| missing | 未初始化而非错误：合成带 migration marker 的空 envelope 并保存 | AppModel.swift:4088-4100; ManualTrackerStore.swift:508-509（注释 "Missing storage is an uninitialized store, not an error"） |
| 空 envelope 缺 marker | 补 marker 后回存；**非空却缺 marker 是硬错误** | ManualTrackerStore.swift:396-400; AppModel.swift:4101-4105 |
| corrupt | decode/校验失败抛错，**从不被空 store 替换**；status=`.unavailable`、cores 清空；**不阻塞村庄主流程加载**（测试 `testCorruptOrFutureManualStoreDoesNotBlockVillageLoad`） | ManualTrackerStore.swift:483-485, 508-518; AppModel.swift:4124-4138 |
| future-schema | → status=`.migrationRequired`（区别于 corrupt 的 `.unavailable`） | ManualTrackerStore.swift:198-199, 360-409; AppModel.swift:4124-4126 |

结构校验清单：全部日期必须有限（100-115）；reconciliationID/recordID 跨村/villageID/
decisionID 唯一性（124-165, 405-423）；queueCapacityConfigs ≤64、queueAssignments ≤4096
（128-147）；容量/分配归属村庄匹配、单村至多一个 baseline reference、decodedBaseline ==
core 派生值、`startedAt ≤ stateUpdatedAt`（131-180, 230-234, 411-428）。

### BE-1.4 OfficialStateStore ×4（UserDefaults blobs）

missing → 空字典；empty 同；**单条 corrupt 逐条容错丢弃 + JSONSkipper 强制推进游标**
（特殊规则：`{}` 条目 decode 成功但丢弃自身、不得 skip，否则吞掉下一个好条目——历史缺陷修复，
OfficialStateStore.swift:42-52, 9-15）；顶层破损 → `try?` 吞掉整个缓存静默归零；
maxEntries=10_000 静默截断；encode 按 tag 排序输出单元素字典数组；merging 只覆盖本次请求过的
tag（OfficialStateStore.swift:24-31, 57-62）。⚠️ 无任何 schemaVersion——官方快照演进靠
`unrecognizedKeys` 审计（§WA-1.4），不靠版本门。

### BE-1.5 TrackedClanStore（UserDefaults blob）

missing → `[]`；单条 corrupt 逐条容错；顶层破损静默归 `[]`；maxEntries=10_000 截断；
数组保持添加顺序（UI 列表序）；clanTag 唯一键 upsert 原位替换/末尾追加，remove 幂等
（TrackedClanStore.swift:5-53; AppModel.swift:4039-4045）。

## BE-2 事务 journal 生命周期

实现：SnapshotImportTransaction.swift（三方事务：current+history+manual）与
ManualTrackerTransaction.swift（两方：current+manual）。

### BE-2.1 状态机

仅两相：`prepared → committed`；删除 journal 即事务终结（SnapshotImportTransaction.swift:108-111）。
没有第三态。journal 写失败归入 `journalCorrupt`（import 版 :421；manual 版单独 case
`journalWriteFailed`）。

### BE-2.2 commit 序列（SnapshotImportTransaction.commit，299-409）

1. 前置：现有历史必须已存在且已迁移，否则拒。
2. 读三 store previous raw bytes。
3. **写前全量校验**：previous/new × 三份 payload 全部先验证；任一非法在**未写任何东西、
   未建 journal** 前失败。
4. 写 journal `phase=.prepared`（目录创建 + `.atomic` 写）。
5. 按 **current → history → manual** 顺序写 store。
6. 任一写失败 → in-process 回滚：restore 三者到 previous、删 journal；回滚本身失败才报
   `rollbackFailed`。
7. 改写 journal 为 `phase=.committed`（此步失败走同一回滚分支）。
8. 清理是 best-effort（`try? removeJournalIfPresent()`）：committed journal 本身是合法恢复记录，
   留盘让下次启动幂等重放，而不是报假导入失败。

### BE-2.3 恢复（recoverIfNeeded，208-297）

- journal 不存在 → 直接返回。
- **journal 自身损坏 → fail-closed 且不删证据**（抛 `journalCorrupt`，journal 留盘；
  测试 `testCorruptJournalStopsStartupRecoveryWithoutDeletingEvidence`）。
- 一致性卫兵：`manualIncluded == (newManualData != nil)` 等。
- journal 内嵌 payload 先验证再动手；previous/new 全部校验通过才执行。
- **prepared = roll-backward**：restore 三者到 previous（restore(nil) = 删文件；
  restore(data) = `.atomic` 写回旧字节；UserDefaults 版连删除都做读回验证）。
- **committed = roll-forward（幂等重放）**：writeData 三者到 new。
- 成功后删 journal 文件。

### BE-2.4 quarantine

只在**用户显式 restore/reset 路径**发生（AppModel.swift:2074, 2108），启动从不自动隔离。
实现：先把活跃 journal 字节原子写到 `<journalURL>.quarantined`，成功后才删源文件——防止陈旧
committed journal 在用户选择的恢复之上重放，同时保留证据（AppModel.swift:4395-4426）。
隔离件复活：下次 `recoverTransactionJournal` 把 quarantined 字节写回 journal URL 执行恢复，
成功后删隔离件（4428-4457）。用户触发的重放入口先备份 recovery copy，再按
**snapshotImport → manualTracker** 顺序重放（1944-1997）。

### BE-2.5 启动恢复顺序（AppModel init，520-571, 703-746）

1. 读 villages blob 分类。
2. corrupt/unsupported ⇒ **跳过下面所有恢复写**（用户选择信任源之前不得写入派生态）。
3. 健康 ⇒ **先** import 事务 recoverIfNeeded（journal 可能恢复出缺失 blob，必须先于默认村庄
   合成）→ 重读 blob。
4. 再 **后** manual 事务 recoverIfNeeded（manual 事务也可能携带村庄 payload）→ 再次重读。
5. 初始村庄落盘（如需）→ 失败 writeFailed 并停止。
6. 派生 store 加载：**manual tracker 先于 history**（两者可独立恢复）→ 投影刷新 → 自动结算 →
   legacy parser-version 迁移 → 分页缓存保留策略自愈 → 种子 row cache。

### BE-2.6 写入原子性基线

- UserDefaults 直写路径：set 后**读回逐字节比对**，不一致即 writeFailed 并回滚 previous
  （SnapshotImportTransaction.swift:86-105）。⚠️ 这是进程内一致性验证，不是 crash-durability
  保证；TS 文件存储需自行提供 fsync/原子替换等价物。
- 文件侧一律 Foundation `.atomic` 写（兄弟临时文件 + 原子替换，失败留旧字节）。
- 村庄直写路径：写前快照 + 候选字节先过 validator（含重复 ID 检查）；`writeAttempted` 标志
  区分「校验失败（无需回滚）」vs「写后失败（需回滚）」（AppModel.swift:4476-4510）。
- 跨 store 变更一律走事务协调器（村庄创建/删除 = 两方事务；快照导入 = 三方事务）；
  手动升级单 store 命令不走事务（candidate-then-save）。

## BE-3 lineage / duplicate import / baseline

| 规则 | 出处 |
|---|---|
| lineage resolution 纯函数：同 village + 同合法 tag → `.continued`（复用 lineageID，可比较）；tag 变化 → `.newLineage`（新 UUID、baseline、禁止比较）；tag 缺失/无效/village 变化/前序 conflict → `.unknown`（baseline，禁止比较）——未确认身份永不 join 前序记录 | SnapshotHistoryModels.swift:871-943（注释 :915-917） |
| entry append-only immutable；active lineage 是可变索引 metadata；每次推进先把该村其他 lineage 全部 isActive=false 再 upsert lastEntryID/lastAppliedAt/hasConflict（🗑️ E0-03：删除 `lastFingerprint` 字段，lineage 校验改经 `lastEntryID` + village/lineage/tag/time 关系确认索引，执行 #304） | SnapshotHistoryModels.swift:55-56; SnapshotHistoryStore.swift:660-689 |
| 导入门 fail-closed：当前村庄 tag 与 active lineage 的 normalizedPlayerTag 不一致 → 整个 import 抛 `lineageConflict` | SnapshotHistoryStore.swift:572-578 |
| duplicate 定义 =「Diff 解释不变」，判定键 =（canonical observation 直接结构/canonical-bytes 比较结果，coverage duplicate key，timerSchema）；appliedAt/source timestamp/parserVersion/runtimeTrust 均不进身份（🗑️ E0-03：判定键不再含 `canonicalFingerprint`，执行 #304） | SnapshotHistoryStore.swift:463-484 |
| 同 observation 内容再导入：不 append 新 entry，只更新 duplicateMetadata（lastSeenAt=appliedAt、lastSourceTimestamp=capturedAt、duplicateImportCount+1），返回 appended:false/duplicate:true | SnapshotHistoryStore.swift:605-623 |
| 反例：同 observation 内容但 coverage 声明变化 → DuplicateKey 不同 → 正常 append 新 entry（锁定测试 `testV5IdenticalBuildingsDifferentCoverageDeclarationAppends`） | SnapshotHistoryStoreTests.swift:1480-1520 |
| baseline entry：isBaseline/baselineReason 由 resolution 决定（initial/unknown/newLineage → true；🗑️ E0-03：不再参与 F2 指纹）；对账侧 UI「账号或 lineage 已变化，禁止自动匹配旧手动记录」 | SnapshotHistoryModels.swift:983-984, 835-855; ContentView.swift:1850-1854 |

## BE-4 分页契约

### BE-4.1 页结构

见 §WA-8。items 必填 fail-loud。

### BE-4.2 游标与合并（ClanPaginationModels.swift）

- 终结判定 `PaginationLogic.hasMore`：responseAfter nil → false；`responseAfter != requestedCursor`
  才 true——游标未前进即终结，防无限循环（ClanPaginationModels.swift:452-455）。
- 累计合并 `PaginationMerge.mergedPage`：首屏直接采用 fetched；续页 items Equatable 去重合并 +
  after 推进为最新响应值；**游标停滞（双非 nil 且相等）→ after 清空视为末页终止**；
  before 保留最新响应值（476-492, 462-468, 481-486）。
- load-more 入口 guard：`.success || .failed` 且有 cursor——**失败保留 last-good 时按钮仍可
  重试**（Issue #124 契约；AppModel.swift:3124-3171）。
- 跨 parser 版本 `needsRebuild` → 丢弃累计页重新拉首页（无游标）。

### BE-4.3 retention cap（Issue #253/#262）

- 上限：warlog 200 条/tag、capital 240 赛季/tag（CacheRetentionPolicy.swift:23, 27）。
- **保头裁尾**：累计列表最新在前，只裁最旧尾部；头不动保证 row identity seq 按 head 计数、
  存留行 ID 不漂移（CacheRetentionPolicy.swift:14, 31-34）。
- 游标指向服务端翻页位置不属于本地数据 → **裁剪不动游标**；`limit <= 0` 视为配置异常
  no-op——不借 retention 清空数据（15-16, 30-32, 37-47）。
- 统一写入收敛 `retentionNormalized` 覆盖 refresh 首屏 / load-more merge / rebuild /
  perf seed 全部共享层写入点 + 启动自愈幂等回写（AppModel.swift:3341-3398；教训：
  invariant 必须覆盖所有写入路径而非只嵌主要路径——#262 P2）。
- 裁剪 × row cache 交互：首次突破上限页缩短触发 row cache fail-closed reset（generation bump），
  稳态在 cap 处条目不变 ID 不漂移（已知取舍非 bug）。

### BE-4.4 capital row cache 与 identity 歧义

- generation UInt64 从 0 起、resetAndBuild 每次 bump（wrap 到 0 强制 1）；row id 内嵌世代号
  `raid:g<generation>:<tripleKey>#<seq>` 防跨代碰撞（CapitalRaidRowCache.swift:131-143）。
- Update 六态：initial/parserRebuild/refreshSuccess/loadMoreSuccess/failureRetain(rows 不变)/clear
  （12-28）。
- reconcileLoadMore：rows 空 → reset；等长经 matcher 可证明匹配 → 保旧 ID 仅更新 payload；
  更短 → reset；更长且 prefix 可证明匹配 → 旧行保 ID + 尾部 append；**歧义一律 generation bump
  reset，绝不静默复用旧 ID 去重丢记录**（100-129, 176-185）。
- 截短 refresh 特例：基于完整旧缓存判断 duplicate 歧义，「不得先用 prefix 丢掉被截掉行的身份
  证据」，仅唯一 exact anchor 可保留 ID（71-86, 187-196）。

## BE-5 手动升级对账与队列容量

### BE-5.1 对账分类（ManualTrackerReconciliation.swift:699-769，按序短路）

1. duplicate → `.duplicate`
2. !lineageComparable && hasExistingState → `.lineageMismatch`
3. sourceTimestampConflict && hasExistingState → `.staleImport`
4. observation 有 timer + active record 存在 + confirmedRecordIDs 空 → `.possibleDuplicate`
   （不能与本地 active 自动合并）
5. observation 无 distributionComplete → `.unknown`
6. 无本地可保护状态 → `.newObservation`
7. sectionTrustGatesOpen == false → `.unknown`（trust gate 关闭时不得断言 exact/conflict）
8. timer 消失 + 两侧 timer coverage complete + 分布未变 + 有 active → `.observedTimerEnded`
   （不能据此声称完成）
9. timeConfidence ∈ {sourceTimestampAbsent, localAppliedAtOnly} → `.unknown`
10. observed == previousDistribution → `.exactMatch`
11. dominates(observed, previous) → `.observedAhead`（active 无 confirmed → unknown）
12. dominates(previous, observed) → `.manualAhead`
13. 相关 change 任一侧 coverage.state ≠ complete → `.unknown`（缺失不能解释为删除）
14. 否则 `.conflict`

配套：preview 携带稳定身份 newNormalizedPlayerTag（不依赖随机 UUID）；apply 的 stale 保护 =
expectedPreview 五字段全匹配否则 `.stalePreview`；decision adopt 矩阵（keepLocal 只采纳
duplicate/newObservation；applyNonConflicting 对 observedAhead+active 且无 confirmed 不采纳）。

### BE-5.2 内容不变防重复结算（五层机制，🗑️ E0-03：去 fingerprint 版）

1. history 层 duplicate 分支 appended:false（§BE-3，新判定键：observation 结构比较 +
   coverage duplicate key + timerSchema）。
2. revision 可审计递进而非重置：duplicate 时 revision = `snapshotID + ":observation:" + count`
   （revision + lineageID 即 manual baseline 身份，不再编码内容摘要）。
3. classification 第一条短路 `.duplicate`。
4. 结算是一次性状态迁移：confirmed 只考虑 `status == .active`；settleDue 幂等
   （completed 不再 eligible；ManualUpgradeCore.swift:219-231）。
5. 守恒兜底：显式 rebase 无法保留 active 源数量 → fail-closed 抛 invalidObservation；
   持久化 replay ledger 必须精确复现 materialized state。

reconciliation preview 替代（执行 #304）：用已有 `manualStateUpdatedAt`、previous
snapshot ID 和 preview 语义材料直接比较替代 candidate fingerprint；stale preview
继续依赖 villageID、previousSnapshotID、lineage、manualStateUpdatedAt。

### BE-5.3 队列分配与容量（Issue #183/#194）

- QueueAssignmentStatus：userAssigned（占容量）/ observedOnly（保留不占）/ unknown；
  无记录 = unassigned 不持久化（QueueAssignmentModels.swift:11-15）。
- overlay 对账只降级从不创建/删除；绑定可审计观察身份（itemKey + baseline revision/
  lineage）（QueueAssignmentModels.swift:17-59; ManualTrackerReconciliation.swift:462-503；🗑️ E0-03：绑定不再含 fingerprint，执行 #304）。
- LocalQueueKind 映射：buildings/traps/heroes→builder，troops/spells/siege→laboratory，
  equipment/pets/guardians→nil（fail-closed）；即时动作不占容量（LocalQueueCapacity.swift:8-86）。
- capacity ∈ [0,10000]，0 合法；占用投影 = active manual（expectedEndAt > now）+ userAssigned
  overlay；可信度三态 available/unreconciled/unavailable——**未知占用不得压成 0 或「空闲」**
  （isFull=false、availableSlots=nil）（LocalQueueCapacity.swift:99-136, 170-177, 234-284）。

## BE-6 并发协调（single-flight，Issue #250）

- resolve 路径同 Tag single-flight：Task 共享注册表，**含失败/404/malformed 等不写缓存的路径
  也 single-flight 为 1 次**；等待刷新批次用 lastAttemptAt 变化判定是否复用批次结果；
  等待结束后创建 Task 前再 acquire 一次防双 Task 竞态（AppModel.swift:3803-3874）。
- 显式 refresh 永不 join、只排队补发强制刷新（refreshClan → pendingClanRefreshTags）；
  批次占用时同样入队——重复请求是故意的，不属于 single-flight 范围（3051-3071, 3062-3064）。
- 排队 drain：仍在解析的 Tag 留在 pending；pendingAll 需村庄 tags 无阻塞才全量消费；
  空 drain 也清 pendingAll 防 phantom pending（3518-3558）。
- C1 防回退：批次失败时若 `existing.status == .success && existing.fetchedAt > batchStart`
  （严格大于）→ 跳过覆盖——防止刚看到的解析成功预览被陈旧批次失败抹掉（3566-3575）。
- 取消契约：任意 waiter 取消 → 共享飞行取消，所有 joiner 得到同一 `.cancelled`
  （3876-3886；ref-counted 取消需另开 issue）。
- 刷新循环开头检查 Task.isCancelled，未处理 tag 不进 result 由调用方决定保留
  （EndpointRefresher.swift:37-38）。

## BE-7 旧 UI 历史实现 vs 必须保留的用户可见语义

| 类别 | 内容 | 处置 |
|---|---|---|
| 历史实现（不必保留） | 快照历史浏览 UI 已移除（#259，main@a821332），内部 history/对账能力保留；SwiftUI 具体布局/动画/文案措辞 | TS 重写按 E4 功能切片重做 |
| 必须保留（数据语义） | §BE-1…§BE-6 全部行为契约；§ER 全部错误展示语义 | 下游 issue 引用本文 |
| 必须保留（用户可见文案锚点） | 「检测到未来村庄存储版本 N」「村庄数据无法解码，原始 bytes 已保留」「快照内容未变化；不会重新开始或重复结算手动记录」（🗑️ E0-03：原文案「canonical fingerprint 未变化；…」随指纹撤销改写，错误类别不变）「账号或 lineage 已变化，禁止自动匹配旧手动记录」「已取消」（legacy failureKind 识别锚）等——这些字符串是错误路径的行为标识 | 文案本身可改写，但**每个错误类别必须有可辨识的中文提示**这一语义保留 |
