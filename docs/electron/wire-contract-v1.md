# Wire/Data Contract v1（E0-02 冻结）

> Issue #265 交付物。本文是 TypeScript 实现数值/时间/序列化行为的**唯一验收基线**。
> 每条规则标注 Swift 出处（file:line，基于 main@f513a35）与锁定测试（如有）。
> 标注 ⚠️ 的点为已知未实证项，实现方必须先用 golden fixture 实证再编码。
>
> 引用格式：§WA-x.y。golden fixtures 见 `Tests/Golden/Fixtures/`（附录 A）。

## WA-1 JSON 值模型

### WA-1.1 值类型六分类

`CanonicalJSONValue` 六个 case：`null / bool / number / string / array / object`
（SnapshotHistoryModels.swift:1074-1083）。**number 的载荷是 String**——持久化形态带 `kind`
标签，数字 token 与字符串可区分。

### WA-1.2 数字 token 规则

- JSON 解析经 `JSONSerialization`；`NSNumber → .number(number.stringValue)`，
  **原始 token 文本不保留**：源文本 `1.0` 规范化后为数字 token 文本 `1`
  （Models.swift:1155-1160）。
- bool 判定靠 `NSNumber.objCType ∈ {"c","B"}`，先于 number 分支（Models.swift:1156-1159）。
- ⚠️ 待实证：大数/科学计数法经 `NSNumber.stringValue` 的渲染形态无测试钉死。
  TS 实现不得自行发明格式；以 `Tests/Golden` 数字样本的实测输出为准（Issue #267 范围）。

### WA-1.3 null 与缺失字段的三层语义

| 层 | null vs 缺失 | 出处 |
|---|---|---|
| Codable 解码层 | **等同**：`decodeIfPresent` 把 JSON null 与缺失键同样处理，全仓无例外 | ClanModels.swift:114-168 等 |
| canonical 字节层 | **区分保留**：`{"k":null} ≠ {}`（rawTopLevelFields 来自规范化后的源） | Models.swift:1181-1191 |
| item 指纹层 | **塌缩**：缺失 optional 显式写 `.null` 进入指纹材料 | Canonicalizer.swift:1142-1156 |

coverage 层对「缺失」有专门分级：section 缺失 → `.missing/.unavailable`；空数组 →
`.presentEmpty`；非空 section 内可选 timer 字段缺失 = `.complete`（观测到的 inactive 态）；
普通可选字段缺失 = `.unavailable`（Canonicalizer.swift:525-579, 1084-1113）。

### WA-1.4 未知字段

- legacy 导入器：未知顶层键收入 `unknownTopLevelKeys` + warning 诊断「发现未识别字段：…」
  （AccountSnapshot.swift:702, 436-441）。
- 官方快照：未识别键 sorted 后存入 `unrecognizedKeys` 并**随状态持久化**（审计用途）；
  round-trip 时若 JSON 已含该键则直接复用（ClanModels.swift:160-167）。
  `knownKeys` 含已知但 deferred 不建模的 `memberList` 与旧别名 `requiredTownHallLevel`，
  避免审计噪音（ClanModels.swift:99-112）。
- encode 只写官方 raw key（如 `requiredTownhallLevel`），Swift 属性名仅源码兼容
  （ClanModels.swift:182-183）。

## WA-2 canonical JSON 字节规范

实现：`CanonicalJSONValue.canonicalData`（Models.swift:1193-1216）。TS 必须逐字节复刻。

| # | 规则 | 出处 |
|---|---|---|
| 1 | 对象键排序：Swift `String <`（Unicode canonical-equivalence 感知）。ASCII 键下等价于 UTF-8 字节序；⚠️ 含分解序列的非 ASCII 键与「逐字节 UTF-8 序」可能分叉，TS 按 String `<` 语义实现并以 fixture 实证 | Models.swift:1208 |
| 2 | 数组元素：各自 canonicalized 后按 canonical bytes 的**字节序**排序（`Data.lexicographicallyPrecedes`）；**重复元素保留不去重**。注意与规则 1 是两套排序依据 | Models.swift:1204, 1179-1180；锁定测试 `testCanonicalJSONArrayOrderDuplicatesAndNestedObjectKeys` |
| 3 | 零空白：对象为 `{` + `"key":value` 无空格，分隔符 `:`(0x3A) 与 `,`(0x2C) | Models.swift:1206-1214, 1276-1284 |
| 4 | 字符串转义：仅转义双引号、反斜杠**和 solidus `/`（强制 `\/`）**；`\b \t \n \f \r` 用短转义；其余 <0x20 控制字符用 `\u00xx`（小写 hex）；非 ASCII 一律 UTF-8 原样透传；DEL 0x7F、U+2028/2029 不转义。solidus 转义是为逐字节对齐 Apple JSONSerialization compact 输出——**冻结约束**，否则旧历史 fingerprint 失配 | Models.swift:1236-1270（1244-1247 注释明示冻结原因）；锁定测试 `testCanonicalJSONStringEscapingMatchesJSONSerialization` |
| 5 | 标量裸 token：null/true/false/number 直接字节；string 加引号 | Models.swift:1195-1202 |
| 6 | 解析入口允许 fragments，但进入 canonicalization 的顶层必须是 object，否则抛 `topLevelMustBeObject` | Models.swift:1143-1146; Canonicalizer.swift:202-204 |
| 7 | canonicalization 幂等且与输入键序无关；数组重排后 canonicalData 相等 | 锁定测试 `testFingerprintIgnoresFormattingKeyOrderArrayOrderTimestampsAndDiagnostics` |

## WA-3 SHA-256 fingerprint 家族

统一输出格式：`"sha256:" + 小写十六进制（%02x）`，总长 71 字符
（Canonicalizer.swift:123；存储校验 SnapshotHistoryStore.swift:247-250）。
共有四套独立指纹，输入材料各不相同，TS 不得混同：

| # | 指纹 | 序列化器 | 输入材料 | 排除项 | 出处 |
|---|---|---|---|---|---|
| F1 | canonicalFingerprint（observation 内容指纹） | 自研 canonical bytes（§WA-2） | `{observationSchemaVersion, rawTopLevelFields, unknownTopLevelFields, items(按各自指纹值排序)}` | display 绑定整体剔除；tag/timestamp 在 observation 构建前剥离；v5+ 剥离 coverage 元数据字段，v4− 必须保留以复现旧字节；diagnostics 不在材料内（只存在于 coverage） | Canonicalizer.swift:116-122, 206-214, 1135-1163, 1159-1163 |
| F2 | integrityFingerprint（entry 完整性摘要） | **JSONEncoder + .sortedKeys**（与 F1 不同！） | 全量 entry 字段：四个版本号 + snapshotID/villageID/lineageID(UUID) + normalizedPlayerTag + appliedAt/sourceTimestamp(Date) + parserVersion + canonicalFingerprint + rawJSON + observation + coverage(含 diagnostics) + isBaseline/baselineReason + timerSchema | 无（全量）；Date 走 Swift 默认策略 = reference-date Double 进哈希字节 | Canonicalizer.swift:146-168, 1213-1231；加载时重算比对 fail-closed：SnapshotHistoryStore.swift:252-316 |
| F3 | AccountSnapshot.contentFingerprint | JSONEncoder + .sortedKeys | tag/capturedAt/importedAt/ageSeconds/originalText/objectSections/numericSections/boosts/unknownTopLevelKeys/diagnostics(severity/path/message 投影) | diagnostics 的随机 id 排除；编码时跳过不持久化，解码后按内容重算 | AccountSnapshot.swift:233-264, 141-152 |
| F4 | ManualUpgradeCore 内容指纹 | JSONEncoder + .sortedKeys | `{itemStates, records}` | — | ManualUpgradeCore.swift:601-614 |

补充规则：

- runtimeWitness 是进程内瞬态 trust 状态，**不可序列化、不进入任何指纹或 duplicate 身份**
  （Models.swift:723-741; VerifiedCoverageEvidence.swift:3-8; SnapshotHistoryDiff.swift:2098）。
- 目录侧完整性是「比较型」指纹：manifest 声明的 sha256 vs 文件字节重算 + size 匹配 +
  sourceFingerprint 格式校验（CraftTableCatalog.swift:37-47; GameCatalog.swift:65-103）。
- 篡改负向锁定：篡改 rawJSON/display/coverage 任一字段 → integrity 校验拒绝
  （`testFullIntegrityDigestRejectsMetadataDisplayAndCoverageTampering`）。

## WA-4 时间戳与日期语义

**三种纪元并存，TS 必须显式区分，不得统一：**

| # | 域 | 语义 | 使用点 | 出处 |
|---|---|---|---|---|
| T1 | Unix epoch seconds（timeIntervalSince1970） | 导出文本 `timestamp` 字段 = epoch 秒；ageSeconds 在 epoch 域计算；未来时间戳 clamp 为 0 | AccountSnapshot.swift:451, 492 | |
| T2 | Swift reference-date seconds（2001-01-01 起算的 Double） | **Swift `JSONEncoder` 默认 Date 编码策略**。所有经 Codable 持久化的 Date 字段盘上都是该 Double：VillageProfile.createdAt/updatedAt、AccountSnapshot.importedAt/capturedAt、SnapshotHistoryEntry.appliedAt/sourceTimestamp（**进入 F2 哈希字节**）、history envelope 各 recordedAt/completedAt/lastSeenAt/lastAppliedAt、manual tracker 全部日期字段、OfficialEndpointState.fetchedAt | VillageProfile.swift:20-21; AccountSnapshot.swift:205-222; Models.swift:975-977; SnapshotHistoryStore.swift:13-63; ManualTrackerStore.swift:69-82; OfficialAPIState.swift:47 | |
| T3 | 官方 API UTC 紧凑字符串 | startTime/endTime/preparationStartTime 等**保持官方字符串原样解码原样持久化**，不是 epoch 数字 | ClanWarModels.swift:22-23; ClanPaginationModels.swift:151, 298-299 | |

配套规则：

- 非有限时间兜底：`Date(timeIntervalSinceReferenceDate: 0)`；有限性守卫见
  ManualTrackerStore.swift:100-164, 261-263, 331-333。
- timer absolute 语义比较基准按 schema unit 取 epoch 秒或毫秒
  （SnapshotHistoryDiff.swift:1952-1954）。
- T3 字符串解析契约（WarLogTimeFormatter）：格式
  `yyyyMMdd'T'HHmmss[.SSS]'Z'` 正则锚定串尾；**Foundation Calendar 对越界组件是溢出归一化
  而非拒绝**（month=13 → 次年 1 月），必须先做显式组件范围校验（含闰年当月天数）；
  年份下限 1992（ICU 历史历法失真防线）；Z 视为 UTC；展示固定 Asia/Shanghai，
  绝不使用本机时区（WarLogTimeFormatter.swift:15-22, 38, 91-103；
  锁定测试 WarLogTimeFormatterTests 全套 + 项目记忆坑点 1/2/3）。
- 投影 stable ID 内嵌 epoch 秒文本（UpgradeOverviewProjection.swift:351）——属投影层标识，
  非 Date 持久化。

## WA-5 UUID 语义

- 格式：Swift 标准**大写连字符** uuidString 进入持久化 JSON；duplicateMetadata 字典键显式走
  uuidString 并用 `UUID(uuidString:)` 回读校验（SnapshotHistoryStore.swift:198-199）。
- 生成点（默认参数 `UUID()`）：VillageProfile.id、AccountSnapshot.id、ManualUpgradeRecord.recordID、
  reconciliationID/previewID、QueueAssignmentDecision.decisionID、snapshotID、lineageID 兜底
  （VillageProfile.swift:24; AccountSnapshot.swift:25; ManualUpgradeCore.swift:167;
  ManualUpgradeModels.swift:636; ManualTrackerReconciliation.swift:128/185;
  QueueAssignmentModels.swift:33; Canonicalizer.swift:19/86; Models.swift:873-938）。
- UUID 进 F2/F3 类指纹材料（Canonicalizer.swift:151-153），不进 F1 canonicalFingerprint。
- 唯一性硬校验：snapshotID/lineageID 重复即 invalidEntry（SnapshotHistoryStore.swift:133-135,
  184-186）；reconciliationID/decisionID 重复即 invalidEnvelope（ManualTrackerStore.swift:124-127,
  162-165）；村庄 ID 重复即 corrupt（VillageStore.swift:79-84）。

## WA-6 整数与 dataID 解析规则

**三层规则刻意不一致，必须分别冻结：**

| 层 | 规则 | 出处 |
|---|---|---|
| a) catalog instanceCounts 宇宙键 | 键格式 `section:dataID`；split(":") maxSplits 1 恰两段；section 非空；`Int64` 可解析；溢出/畸形 → **整个宇宙置 nil（fail-closed）**；canonical 重序列化必须逐字符相等——**拒绝 `+0000002`/前导零等非规范格式**（陷阱：`Int64("+0000002") == 2` 会被接受但键非规范）；数组长度恒 18 且值 ≥0；全 0 键拒绝；键必须在 items 存在且正向完整覆盖 | GameCatalog.swift:840-903 |
| b) Canonicalizer.integer | 只接受 number token 且 `Int64(raw)` 成功；string/bool/null/小数全拒；失败 → 记录跳过 + 诊断「缺少有效 dataID」 | Canonicalizer.swift:1166-1169, 602-607, 936-941, 1024-1027 |
| c) legacy importer decodeInt64 | 三级尝试：直接 Int64 → Double（须 finite 且整值且 Int64(exactly:) 成功）→ String（`Int64(value)` 成功即可）。**字符串形式接受非规范输入**（`+0000002`=2、前导零），与 a) 相反；Double 超 Int64 范围 → typeMismatch「字段必须是整数。」 | AccountSnapshot.swift:725-744 |

BigInt 注意：Swift `Int64` 有符号 64 位。官方数据中超出 Number safe-range 的整数
（如某些 dataID 组合运算）在 TS 侧按 §WA-1.2 的 number token 字符串透传保真，
数值域转换在 domain 层用 BigInt 完成（Issue #267 落地）。

## WA-7 schemaVersion 注册表

| Store / Envelope | 当前值 | 支持范围与未来版本处理 | 出处 |
|---|---|---|---|
| VillageStoreSchema.current | 1 | 盘上为裸 JSON 数组无 envelope；仅当按数组解码失败且顶层声明更大 schemaVersion 时判 `.unsupportedSchema`，rawData 保留绝不覆盖 | VillageStore.swift:7-8, 87-91, 114-121 |
| SnapshotHistorySchema | envelope=1 / entry=1 / observation=6 / fingerprintVersion=1 / integrityVersion=1 | validated() 全精确等值；observation ∈ 1...6 且内部一致；v2+ 必带 section evidence；≤v5 禁止 sourceUniverse；里程碑 v2 sectionEvidence / v3 timerAllowlist / v4 timerSchema / v5 去 coverage 元数据 / v6 sourceUniverse；marker.version 必须 == envelope；无 marker 不得有 entries | Models.swift:8-31; SnapshotHistoryStore.swift:126-163, 208-215 |
| ManualTrackerSchema | envelope=1 / store=1 / village=1 | village/envelope/marker 三处精确等值否则 unsupportedSchema | ManualTrackerStore.swift:5-9, 197-200, 360-409 |
| GameCatalog manifest | 支持 1...2 | 出范围 validate() false（fail-closed 不进已验证态）；manifest 缺失时目录仍可加载（manifest=nil） | GameCatalog.swift:50, 65-66, 33-35 |
| LeagueTierCatalog.schemaVersion | ==1 | 非 1 → loadBundled 返回 nil（UI 正常降级态） | LeagueTierCatalog.swift:16, 41 |
| CraftTableCatalog.schemaVersion | ==1 | 非 1 或 manifest integrity 不过 → nil | CraftTableCatalog.swift:59, 103-118 |
| SeasonalPhaseTable.schemaVersion | ==1 | 非 1/缺文件 → 空表不报错（增强数据） | GameCatalog.swift:321-324, 412-415 |
| OfficialStateStore ×4 | 无版本 | fail-open 组（§BE-1.5） | OfficialStateStore.swift:17-63 |
| TrackedClanStore | 无版本 | fail-open 组；演进红线：新字段必须默认值/decodeIfPresent，否则容错机制把 schema 错误变成整库静默丢失（注释原文即红线） | TrackedClanStore.swift:36-53 |

## WA-8 官方 API wire 形状要点

- 分页结构 `{items, paging.cursors.after/before}`：**items 必填**，缺失/null → 解码失败 →
  保留 last-good，「不得静默当作成功空页」（ClanPaginationModels.swift:21-22, 51-52）。
- paging/cursors 全可选；after=向后翻页游标（末页 nil）；before 未使用仅透传；
  两者皆 nil 时 encode 不写 paging 键（ClanPaginationModels.swift:83-88）。
- 终结判定：responseAfter 为 nil → 无更多；`responseAfter != requestedCursor` 才继续——
  游标未前进即终结（§BE-4.2）。
- 官方快照 decode 全字段 optional + 任意字符串 CodingKey 遍历（§WA-1.4）。
- HTTP → CoAPIError 映射与取消透传见 error-matrix.md §ER-1。

## 附录 A：golden fixtures 索引（Tests/Golden/Fixtures/）

| fixture | 冻结内容 | 消费测试 |
|---|---|---|
| canonical-json-samples.json | §WA-2 转义/排序/数字 token 的正例+边界例（solidus、控制字符、CJK、emoji、0x7F、U+2028/2029、负零、大数、重复数组元素）+ 期望 canonical bytes hex | GoldenContractTests/CanonicalJSONGoldenTests |
| account_snapshot_golden.json | 匿名 legacy 导出文本 → §WA-6c 解析 + F3 contentFingerprint 硬编码锁定（钉死 importedAt 输入） | GoldenContractTests/ParserGoldenTests |
| history_entry_golden_v6.json | 同一快照 canonicalize 为 observation v6 entry → F1 canonicalFingerprint + F2 integrityFingerprint 双硬编码锁定 | GoldenContractTests/ParserGoldenTests |
| official_war_log_page.json 等 | 复用 `Tests/COCHelperCoreTests/Fixtures/` 既有匿名分页/官方快照 fixtures（不复制），映射见 dto-mapping.md | 既有 ClanPaginationDecodeTests 等 |

