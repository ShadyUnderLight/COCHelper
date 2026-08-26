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

对象键身份对齐 `JSONSerialization` → `[String: Any]`（SnapshotHistoryModels.swift:1143-1170）：
NFC 规范化等价的键合并为同一字段。相同拼写保留首次值；UTF-16 更长的拼写覆盖（NFC vs NFD
时即 NFD）；等长但拼写不同（如 Å U+212B vs Å U+00C5）保留后出现的拼写和值。TS 字段表必须用
null-prototype，否则 `{"__proto__":1}` 会被普通 `{}` 赋值吞掉。孤立 surrogate（`\uD800` /
`\uDC00`，含 JS 字符串重载里未转义的 UTF-16 代理项）拒绝，成对 `\uD800\uDC00` 接受。
锁定 fixture：`json-raw-samples.json`（source 必须是 JSON 字符串，不能写成 fixture 对象，
否则加载 fixture 时就会提前 collapse）。

### WA-1.2 数字 token 规则

- JSON 解析经 `JSONSerialization`；`NSNumber → .number(number.stringValue)`，
  **原始 token 文本不保留**：源文本 `1.0` 规范化后为数字 token 文本 `1`
  （SnapshotHistoryModels.swift:1155-1160）。
- bool 判定靠 `NSNumber.objCType ∈ {"c","B"}`，先于 number 分支（SnapshotHistoryModels.swift:1156-1159）。
- `stringValue` 分三条路径（macOS 14+ Foundation 实测，锁定于 `nsnumber-stringvalue.json`）：
  1. 落入 `Int64`/`UInt64` 的整数 token：对应 `q`/`Q` 十进制整数串（`-0` → `0`）。
  2. 更大的整数，或有效数字 ≥ 18（整数部分去掉前导零 + 小数点后全部数字含尾零）：`NSDecimalNumber`。
     尾数按 128-bit（`2^128-1`）向零截断；指数用未去掉小数尾零的 scale 校验，必须 ∈ `[-128, 127]`，
     越界则与 `JSONSerialization` 一样拒绝。Decimal 路径的零在指数合法时写出 `0`（不保留 `-0`），
     指数越界的零（如 `0.000000000000000000e-127`）同样拒绝。
  3. 其余：IEEE 754 double，再按 Darwin `%.16g`（16 位有效数字、round-ties-to-even；
     指数 `e` 至少两位数）。不得用 JS `Number.prototype.toExponential` 代替。

### WA-1.3 null 与缺失字段的三层语义

| 层 | null vs 缺失 | 出处 |
|---|---|---|
| Codable 解码层 | **等同**：`decodeIfPresent` 把 JSON null 与缺失键同样处理，全仓无例外 | ClanModels.swift:114-168 等 |
| canonical 字节层 | **区分保留**：`{"k":null} ≠ {}`（rawTopLevelFields 来自规范化后的源） | SnapshotHistoryModels.swift:1181-1191 |
| item 指纹层 | **塌缩**：缺失 optional 显式写 `.null` 进入指纹材料 | SnapshotHistoryCanonicalizer.swift:1142-1156 |

coverage 层对「缺失」有专门分级：section 缺失 → `.missing/.unavailable`；空数组 →
`.presentEmpty`；非空 section 内可选 timer 字段缺失 = `.complete`（观测到的 inactive 态）；
普通可选字段缺失 = `.unavailable`（SnapshotHistoryCanonicalizer.swift:525-579, 1084-1113）。

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

实现：`CanonicalJSONValue.canonicalData`（SnapshotHistoryModels.swift:1193-1216）。TS 必须逐字节复刻。

| # | 规则 | 出处 |
|---|---|---|
| 1 | 对象键排序：Swift `String <`（Unicode canonical-equivalence 感知）。ASCII 键下等价于 UTF-8 字节序；⚠️ 含分解序列的非 ASCII 键与「逐字节 UTF-8 序」可能分叉，TS 按 String `<` 语义实现并以 fixture 实证 | SnapshotHistoryModels.swift:1208 |
| 2 | 数组元素：各自 canonicalized 后按 canonical bytes 的**字节序**排序（`Data.lexicographicallyPrecedes`）；**重复元素保留不去重**。注意与规则 1 是两套排序依据 | SnapshotHistoryModels.swift:1204, 1179-1180；锁定测试 `testCanonicalJSONArrayOrderDuplicatesAndNestedObjectKeys` |
| 3 | 零空白：对象为 `{` + `"key":value` 无空格，分隔符 `:`(0x3A) 与 `,`(0x2C) | SnapshotHistoryModels.swift:1206-1214, 1276-1284 |
| 4 | 字符串转义：仅转义双引号、反斜杠**和 solidus `/`（强制 `\/`）**；`\b \t \n \f \r` 用短转义；其余 <0x20 控制字符用 `\u00xx`（小写 hex）；非 ASCII 一律 UTF-8 原样透传；DEL 0x7F、U+2028/2029 不转义。solidus 转义是为逐字节对齐 Apple JSONSerialization compact 输出——**冻结约束**，否则旧历史 fingerprint 失配 | SnapshotHistoryModels.swift:1236-1270（1244-1247 注释明示冻结原因）；锁定测试 `testCanonicalJSONStringEscapingMatchesJSONSerialization` |
| 5 | 标量裸 token：null/true/false/number 直接字节；string 加引号 | SnapshotHistoryModels.swift:1195-1202 |
| 6 | 解析入口允许 fragments，但进入 canonicalization 的顶层必须是 object，否则抛 `topLevelMustBeObject` | SnapshotHistoryModels.swift:1143-1146; SnapshotHistoryCanonicalizer.swift:202-204 |
| 7 | canonicalization 幂等且与输入键序无关；数组重排后 canonicalData 相等 | 锁定测试 `testFingerprintIgnoresFormattingKeyOrderArrayOrderTimestampsAndDiagnostics` |

## WA-3 SHA-256 fingerprint 家族

统一输出格式：`"sha256:" + 小写十六进制（%02x）`，总长 71 字符
（SnapshotHistoryCanonicalizer.swift:123；存储校验 SnapshotHistoryStore.swift:247-250）。
共有四套独立指纹，输入材料各不相同，TS 不得混同：

| # | 指纹 | 序列化器 | 输入材料 | 排除项 | 出处 |
|---|---|---|---|---|---|
| F1 | canonicalFingerprint（observation 内容指纹） | 自研 canonical bytes（§WA-2） | `{observationSchemaVersion, rawTopLevelFields, unknownTopLevelFields, items}`，其中 **items 按 fingerprintValue 材料对象的 canonical bytes 字节序排序**（不是 SHA 指纹序；SnapshotHistoryCanonicalizer.swift:112-113, 271-273） | display 绑定整体剔除（fingerprintValue 构造后 removeValue）；tag/timestamp 在 observation 构建前剥离；v5+ 剥离 coverage 元数据字段，v4− 必须保留以复现旧字节；diagnostics 不在材料内（只存在于 coverage） | SnapshotHistoryCanonicalizer.swift:116-122, 206-214, 1135-1163, 1159-1163 |
| F2 | integrityFingerprint（entry 完整性摘要） | **JSONEncoder + .sortedKeys**（与 F1 不同！） | `SnapshotHistoryIntegrityMaterial` 的 18 个字段 = entry 全量字段**减去 `integrityFingerprint` 本身**：四个版本号 + snapshotID/villageID/lineageID(UUID) + normalizedPlayerTag + appliedAt/sourceTimestamp(Date) + parserVersion + canonicalFingerprint + rawJSON + observation + coverage(含 diagnostics) + isBaseline/baselineReason + timerSchema（SnapshotHistoryCanonicalizer.swift:1213-1231） | **`integrityFingerprint` 自身不参与 digest**（材料结构无自引用字段）；Date 走 Swift 默认策略 = reference-date Double 进哈希字节 | SnapshotHistoryCanonicalizer.swift:146-168, 1213-1231；加载时重算比对 fail-closed：SnapshotHistoryStore.swift:252-316 |
| F3 | AccountSnapshot.contentFingerprint | JSONEncoder + .sortedKeys | tag/capturedAt/importedAt/ageSeconds/originalText/objectSections/numericSections/boosts/unknownTopLevelKeys/diagnostics(severity/path/message 投影) | diagnostics 的随机 id 排除；编码时跳过不持久化，解码后按内容重算 | AccountSnapshot.swift:233-264, 141-152 |
| F4 | ManualUpgradeCore 内容指纹 | JSONEncoder + .sortedKeys | `{itemStates, records}` | — | ManualUpgradeCore.swift:601-614 |

补充规则：

- runtimeWitness 是进程内瞬态 trust 状态，**不可序列化、不进入任何指纹或 duplicate 身份**
  （SnapshotHistoryModels.swift:723-741; VerifiedCoverageEvidence.swift:3-8; SnapshotHistoryDiff.swift:2098）。
- 目录侧完整性是「比较型」指纹：manifest 声明的 sha256 vs 文件字节重算 + size 匹配 +
  sourceFingerprint 格式校验（CraftTableCatalog.swift:37-47; GameCatalog.swift:65-103）。
- 篡改负向锁定：篡改 rawJSON/display/coverage 任一字段 → integrity 校验拒绝
  （`testFullIntegrityDigestRejectsMetadataDisplayAndCoverageTampering`）。

## WA-4 时间戳与日期语义

**三种纪元并存，TS 必须显式区分，不得统一：**

| # | 域 | 语义 | 使用点 | 出处 |
|---|---|---|---|---|
| T1 | Unix epoch seconds（timeIntervalSince1970） | 导出文本 `timestamp` 字段 = epoch 秒；ageSeconds 在 epoch 域计算；未来时间戳 clamp 为 0 | AccountSnapshot.swift:451, 492 | |
| T2 | Swift reference-date seconds（2001-01-01 起算的 Double） | **Swift `JSONEncoder` 默认 Date 编码策略**。所有经 Codable 持久化的 Date 字段盘上都是该 Double：VillageProfile.createdAt/updatedAt、AccountSnapshot.importedAt/capturedAt、SnapshotHistoryEntry.appliedAt/sourceTimestamp（**进入 F2 哈希字节**）、history envelope 各 recordedAt/completedAt/lastSeenAt/lastAppliedAt、manual tracker 全部日期字段、OfficialEndpointState.fetchedAt | VillageProfile.swift:20-21; AccountSnapshot.swift:205-222; SnapshotHistoryModels.swift:975-977; SnapshotHistoryStore.swift:13-63; ManualTrackerStore.swift:69-82; OfficialAPIState.swift:47 | |
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
- 生成点（默认参数 `UUID()`）：VillageProfile.id、`AccountDataDiagnostic.id`（诊断随机 id，
  **注意：`AccountSnapshot` 本身没有 id 字段**）、ManualUpgradeRecord.recordID、
  reconciliationID/previewID、QueueAssignmentDecision.decisionID、snapshotID、lineageID 兜底
  （VillageProfile.swift:24; AccountSnapshot.swift:18-32; ManualUpgradeCore.swift:167;
  ManualUpgradeModels.swift:636; ManualTrackerReconciliation.swift:128/185;
  QueueAssignmentModels.swift:33; SnapshotHistoryCanonicalizer.swift:19/86; SnapshotHistoryModels.swift:873-938）。
- UUID 进入指纹的字段级归属：
  - F2 integrityFingerprint：snapshotID / villageID / lineageID 三个 UUID **进入**材料
    （SnapshotHistoryCanonicalizer.swift:1213-1231）。
  - F3 contentFingerprint：**无任何 UUID 字段进入**；`AccountDataDiagnostic.id` 是每次解析
    随机生成的 UUID，被 F3 显式排除——diagnostics 只投影 severity/path/message
    （AccountSnapshot.swift:247-253）。TS 若把 diagnostic id 计入，同一导出两次解析的
    contentFingerprint 将互不相同——这是必须避免的 parity 破坏。
  - F1 canonicalFingerprint：不进（observation 材料不含任何 UUID）。
- 唯一性硬校验：snapshotID/lineageID 重复即 invalidEntry（SnapshotHistoryStore.swift:133-135,
  184-186）；reconciliationID/decisionID 重复即 invalidEnvelope（ManualTrackerStore.swift:124-127,
  162-165）；村庄 ID 重复即 corrupt（VillageStore.swift:79-84）。

## WA-6 整数与 dataID 解析规则

**三层规则刻意不一致，必须分别冻结：**

| 层 | 规则 | 出处 |
|---|---|---|
| a) catalog instanceCounts 宇宙键 | 键格式 `section:dataID`；split(":") maxSplits 1 恰两段；section 非空；`Int64` 可解析；溢出/畸形 → **整个宇宙置 nil（fail-closed）**；canonical 重序列化必须逐字符相等——**拒绝 `+0000002`/前导零等非规范格式**（陷阱：`Int64("+0000002") == 2` 会被接受但键非规范）；数组长度恒 18 且值 ≥0；全 0 键拒绝；键必须在 items 存在且正向完整覆盖 | GameCatalog.swift:840-903 |
| b) Canonicalizer.integer | 只接受 number token 且 `Int64(raw)` 成功；string/bool/null/小数全拒；失败 → 记录跳过 + 诊断「缺少有效 dataID」 | SnapshotHistoryCanonicalizer.swift:1166-1169, 602-607, 936-941, 1024-1027 |
| c) legacy importer decodeInt64 | 三级尝试：直接 Int64 → Double（须 finite 且整值且 Int64(exactly:) 成功）→ String（`Int64(value)` 成功即可）。**字符串形式接受非规范输入**（`+0000002`=2、前导零），与 a) 相反；Double 超 Int64 范围 → typeMismatch「字段必须是整数。」 | AccountSnapshot.swift:725-744 |

BigInt 注意：Swift `Int64` 有符号 64 位。官方数据中超出 Number safe-range 的整数
（如某些 dataID 组合运算）在 TS 侧按 §WA-1.2 的 number token 字符串透传保真，
数值域转换在 domain 层用 BigInt 完成（Issue #267 落地）。

## WA-7 schemaVersion 注册表

| Store / Envelope | 当前值 | 支持范围与未来版本处理 | 出处 |
|---|---|---|---|
| VillageStoreSchema.current | 1 | 盘上为裸 JSON 数组无 envelope；仅当按数组解码失败且顶层声明更大 schemaVersion 时判 `.unsupportedSchema`，rawData 保留绝不覆盖 | VillageStore.swift:7-8, 87-91, 114-121 |
| SnapshotHistorySchema | envelope=1 / entry=1 / observation=6 / fingerprintVersion=1 / integrityVersion=1 | validated() 全精确等值；observation ∈ 1...6 且内部一致；v2+ 必带 section evidence；≤v5 禁止 sourceUniverse；里程碑 v2 sectionEvidence / v3 timerAllowlist / v4 timerSchema / v5 去 coverage 元数据 / v6 sourceUniverse；marker.version 必须 == envelope；无 marker 不得有 entries | SnapshotHistoryModels.swift:8-31; SnapshotHistoryStore.swift:126-163, 208-215 |
| ManualTrackerSchema | envelope=1 / store=1 / village=1 | village/envelope/marker 三处精确等值否则 unsupportedSchema | ManualTrackerStore.swift:5-9, 197-200, 360-409 |
| GameCatalog manifest | 支持 1...2 | 出范围 validate() false（fail-closed 不进已验证态）；manifest 缺失时目录仍可加载（manifest=nil） | GameCatalog.swift:50, 65-66, 33-35 |
| LeagueTierCatalog.schemaVersion | ==1 | 非 1 → loadBundled 返回 nil（UI 正常降级态） | LeagueTierCatalog.swift:16, 41 |
| CraftTableCatalog.schemaVersion | ==1 | 非 1 或 manifest integrity 不过 → nil | CraftTableCatalog.swift:59, 103-118 |
| SeasonalPhaseTable.schemaVersion | ==1 | 非 1/缺文件 → 空表不报错（增强数据） | GameCatalog.swift:321-324, 412-415 |
| OfficialStateStore ×4 | 无版本 | fail-open 组（§BE-1.4） | OfficialStateStore.swift:17-63 |
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

## WA-9 catalog manifest 与资源管线契约

实现：GameCatalog.swift:31-130（`CatalogManifest` / `CatalogGeneratedFile` / `CatalogCounts` /
`validate`）。活体 fixture：仓库源路径
`Sources/COCHelperCore/GameCatalog/18.400.13/manifest.json`；运行时 bundle 路径为
`GameCatalog/18.400.13/manifest.json`（Package 以 `.copy("GameCatalog")` 保留目录结构，
`.process` 会扁平化子目录故不可用）。由 `Tools/game_catalog` Python 生成器产出，
GameCatalogTests ManifestValidation 系列锁定。

### WA-9.1 manifest 形状

```text
CatalogManifest {
  schemaVersion: Int          // 支持范围 1...2，出范围 validate() false（fail-closed）
  gameVersion: String         // ⚠️ 「与目录目录名一致」是调用方/打包约定，不是被强制的
                              //   不变量：generate(output_dir:) 接受任意目录名，
                              //   validate_catalog 也只比 manifest↔catalog 一致；
                              //   运行时 loadBundled(version:) 同样只比
                              //   manifest.gameVersion == catalog.gameVersion
                              //   （GameCatalog.swift:953），不比对传入的目录版本参数。
                              //   TS 消费侧可实施更严的目录名比对（E2-02 裁量）
  buildTag: String
  locale: String
  sourceFingerprint: String   // 格式门：sha256: + 64 hex；内容是 APK hash，
                              // 运行时无 APK 可比 → 只校验格式不校验值
  generatedFiles: [CatalogGeneratedFile]
  counts: CatalogCounts
}
CatalogGeneratedFile { path: String, sha256: String?, size: Int?, kind: String?, entries: Int? }
```

`counts` 的 Swift 声明字段（GameCatalog.swift `CatalogCounts`）：items / levels 必填，
missingIcons? / missingTime? / timed? / instant? / notApplicable? / initialLevel? /
sourceMissing? / parseFailed? 可选（旧 manifest 缺键 → nil 向后兼容）。
其中 **missingIcons 是 Swift/TS 侧 decode-only 字段**：Swift `validate()` 不校验它，
但生成器校验层（`Tools/game_catalog/validate.py:639`）会将其与重算值对账。

**未知 counts 键策略（冻结，范围限定为 Swift runtime / TS 消费侧）**：活体 manifest 实测含
`blockedIcons` / `displayCategories` / `renderedIcons` 三键，Swift `CatalogCounts` 未声明 →
Codable 解码静默忽略，不参与 Swift `validate()`。⚠️ 这三键在**生成器校验层并非未知**——
`Tools/game_catalog/validate.py:665-691` 会校验 renderedIcons（== generatedFiles PNG 计数）、
blockedIcons（快照语义格式检查）与 displayCategories（Issue #75 工作流 C）。因此 TS 消费侧必须
容忍并忽略这些键（不得因未知键失败，也不得臆造语义）；若未来要把它们纳入 Swift/TS 消费契约，
须先双侧建模并 bump schemaVersion。

### WA-9.2 校验规则分层（返回 false = 漂移/篡改，fail-closed 不进「已验证」态）

Swift 运行时 `CatalogManifest.validate` 五条（GameCatalog.swift:63-130）：

| # | 规则 | 备注 |
|---|---|---|
| ① | counts 与目录内容重算一致：items/levels 必查；missingTime/timed/instant/notApplicable/initialLevel/sourceMissing/parseFailed 拆分字段**存在才查**（旧 manifest 缺键跳过）；**missingIcons 不校验**（decode-only，见 §WA-9.1） | 拆分映射走 CatalogDurationState.state 单一映射点 |
| ② | generatedFiles 中 path=="catalog.json" 条目的 sha256 与真实文件字节重算一致 | 声明缺失跳过（向后兼容）；声明存在但格式异常（无 sha256: 前缀）→ fail-closed |
| ③ | schemaVersion ∈ 1...2 | 出范围拒绝 |
| ④ | sourceFingerprint 格式合法 | 见 §WA-9.1 |
| ⑤ | fileCheck 注入时：generatedFiles 全部非 directory 条目文件存在且 size 匹配 + 目录引用全部图标 renderedPath 文件存在 | loadBundled 恒注入 Bundle 实现 |

明确**不校验**：icons 内容哈希（展示资源，size/存在性由⑤覆盖）、sourceFingerprint 内容、
missingIcons。

**生成器校验层**（`Tools/game_catalog/validate.py`，产出目录时的独立门禁，与 Swift 层互补）：
额外校验 missingIcons 对账（:639）；renderedIcons / blockedIcons / displayCategories 三键
**均为「存在才校验、缺失放行」的 optional 语义**（validate.py:664-691 显式 None 门 + 既有
测试冻结该兼容性；displayCategories 存在时必须与 catalog 实际分布一致）。⚠️ E6-01 迁移
不得把这些可选字段升级为必填。TS 消费侧**不复制**该层——它属于 E6-01 迁移的工具链。

### WA-9.3 静态资源引用与两级 missingReason（两个不同值域，不得混同）

**a) `CatalogAssetRef`（图标等静态资源，GameCatalog.swift:145-166）**

```text
CatalogAssetRef { container: String?, exportName: String?, renderedPath: String?, missingReason: String? }
```

- 字段名是 **`renderedPath`**（不是 path）。
- 可渲染判定 `isRenderable` = renderedPath 非 nil 且**非空串** && missingReason == nil
  （空串路径不可渲染——契约 R2.2/R5.3，与 Python contract.is_renderable 同语义）。
- **missingReason != nil 表示该引用不可渲染，必须原样暴露给 UI**，不得静默隐藏；
  UI 依据该属性选择 PNG 或 SF Symbol。
- 资源域值域 = Python 生成器 `ASSET_MISSING_REASONS`（Tools/game_catalog/__init__.py:20）
  全集 13 值：icons_not_rendered / no_icon_columns / no_visual_columns / sc_parse_failed /
  movieclip_not_parsed / texture_compressed_astc / texture_external_sctx / zstd_unavailable /
  container_not_found / export_not_found / astc_unsupported / texture_missing / render_failed。
  各活体版本实际出现的子集可随 APK 渲染结果变化——**契约以 producer 词表为准，不冻结单版本
  观测统计**。工具链当前没有权威的资源观测统计输出（validate_game_catalog.py 只输出
  coverage / audit / verdict）；如需该类统计，须按明确口径自行重算（唯一非空 renderedPath 数、
  缺失键分布），或后续在工具链补充输出后再引用。

**b) `CatalogLevel.missingReason`（逐级时长缺失原因，GameCatalog.swift:203-240）**

- 与资源无关的**时间域**值域，映射到 `CatalogDurationState`（唯一映射点
  `state(durationSeconds:missingReason:)`）：
  - `min_level_initial_no_upgrade` → `.initialLevel`
  - `no_time_source` → `.notApplicable`（仅数据源无时长列，不得推断为游戏内无需时间）
  - `time_invalid` → `.parseFailed`
  - `time_missing` / `upgrade_data_missing` → `.sourceMissing`
  - durationSeconds > 0 → `.timed`；== 0 → `.instant`；< 0 → `.unknownReason("negative_duration")`（防御）
  - 契约外 reason → `.unknownReason(reason)` 防御分支，不修改值域契约
- 值域定义在 Python 生成器 LEVEL_MISSING_REASONS 与 Swift 映射点两处，双侧同步。
- 相邻的 item/base 域词表（同文件 `ITEM_MISSING_REASONS`=deprecated_in_source、
  `BASE_MISSING_REASONS`=capital_has_no_base）与资源域 a) 分属不同对象层级，
  合集 `MISSING_REASONS` 仅用于生成器侧总校验，TS 消费侧按对象层级分别取词表。

## 附录 A：golden fixtures 索引（Tests/Golden/Fixtures/，本 PR 实际现状）

| fixture | 冻结内容 | 消费测试 |
|---|---|---|
| canonical-json-samples.json + canonical-json-expected.json | §WA-2 转义/排序/数字 token 的正例+边界例（solidus、控制字符、CJK、emoji、0x7F、U+2028/2029、大数、重复数组元素）+ 期望 canonical bytes hex | GoldenContractTests/CanonicalJSONGoldenTests |
| json-raw-samples.json | §WA-1 原始 JSON 源文本：同一 object 内 NFC 等价重复键、`__proto__` 键保留、孤立 surrogate 拒绝；source 为 JSON 字符串以免 fixture 加载时提前 collapse | GoldenContractTests/JsonRawSourceGoldenTests |
| nsnumber-stringvalue.json | §WA-1.2 `JSONSerialization` → `NSNumber.stringValue`：整数 / NSDecimalNumber / Darwin `%.16g` 三条路径 | GoldenContractTests/NSNumberStringValueGoldenTests |
| primitive-fuzz-corpus.json | 共享 parser 边界 corpus：深层 JSON、长整数、`__proto__`、非法逗号/前导零、孤立 surrogate、非有限数字 | packages/wire/src/parser-fuzz.test.ts |
| account_snapshot_golden.json + parser_golden_expected.json | 匿名 legacy 导出文本 → §WA-6c 解析。冻结四类输出：F3 contentFingerprint / F1 canonicalFingerprint / F2 integrityFingerprint 三重硬编码 + **AccountSnapshot 与 HistoryEntryV1 的 JSONEncoder(.sortedKeys) encoded bytes hex（wire shape：Date 编码策略、optional omission、键序）**。⚠️ AccountSnapshot wire 含 `diagnostics[].id`（每次解析随机生成的 UUID），golden 中该槽位掩码为 `<RANDOM_DIAGNOSTIC_UUID>`——TS 必须把它当作不透明随机值，其余字节逐字节复刻 | GoldenContractTests/ParserGoldenTests |
| official_war_log_page.json 等 | 复用 `Tests/COCHelperCoreTests/Fixtures/` 既有匿名分页/官方快照 fixtures（不复制），映射见 dto-mapping.md；catalog 侧活体 fixture 见 §WA-9（仓库源路径 + 运行时 bundle 路径） | 既有 ClanPaginationDecodeTests / GameCatalogTests |

尚未覆盖（见 target-architecture.md §6 关闭门）：projection / diff / error 场景 fixture，
由 E2-* 按域增量追加。
