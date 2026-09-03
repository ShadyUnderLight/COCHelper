# Wire/Data Contract v1（E0-02 冻结，E0-03 #302 修订）

> Issue #265 交付物，Issue #302 修订。本文是 TypeScript 实现数值/时间/序列化行为的**唯一验收基线**。
> 每条规则标注 Swift 出处（file:line，基于 main@f513a35）与锁定测试（如有）。
> 标注 ⚠️ 的点为已知未实证项，实现方必须先用 golden fixture 实证再编码。
> 标注 🗑️ E0-03 的条目为 Issue #302 已撤销的 hash 防御契约：新实现不得要求它们，
> 旧出处仅作删除审计保留（删除执行归属 #303/#304/#305）。
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
| 🗑️ E0-03 指纹材料层 | **已撤销 hash 形式**：旧 F1 曾把缺失 optional 显式写 `.null` 进入指纹材料（SnapshotHistoryCanonicalizer.swift:1142-1156）。内容身份改由 §WA-3.1 `ObservationIdentityMaterial` 直接比较承担，沿用旧 preimage 的全部排除与排序规则；canonical 字节层规则不变 | Issue #302，删除执行 #304 |

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
| 4 | 字符串转义：仅转义双引号、反斜杠**和 solidus `/`（强制 `\/`）**；`\b \t \n \f \r` 用短转义；其余 <0x20 控制字符用 `\u00xx`（小写 hex）；非 ASCII 一律 UTF-8 原样透传；DEL 0x7F、U+2028/2029 不转义。solidus 转义是为逐字节对齐 Apple JSONSerialization compact 输出——**冻结约束**，否则 canonical bytes 失配（旧审计文字称“旧历史 fingerprint 失配”，指同一件事，F1 撤销后改述） | SnapshotHistoryModels.swift:1236-1270（1244-1247 注释明示冻结原因）；锁定测试 `testCanonicalJSONStringEscapingMatchesJSONSerialization` |
| 5 | 标量裸 token：null/true/false/number 直接字节；string 加引号 | SnapshotHistoryModels.swift:1195-1202 |
| 6 | 解析入口允许 fragments，但进入 canonicalization 的顶层必须是 object，否则抛 `topLevelMustBeObject` | SnapshotHistoryModels.swift:1143-1146; SnapshotHistoryCanonicalizer.swift:202-204 |
| 7 | canonicalization 幂等且与输入键序无关；数组重排后 canonicalData 相等 | 锁定测试 `testFingerprintIgnoresFormattingKeyOrderArrayOrderTimestampsAndDiagnostics`（历史测试名，约束本身保留；#304/#305 更名或删测试时不得连带删除本条 canonicalization 约束） |

## WA-3 SHA-256 fingerprint 家族（🗑️ E0-03 已撤销）

> E0-03（Issue #302）决策：在本地单机 + 合作操作员威胁模型下，以下 SHA-256 /
> fingerprint / manifest 完整性防御层**不再是新契约的一部分**，新实现不得要求、
> 不得重算、不得用 digest 做信任门。§WA-2 canonical JSON 字节规范**全文保留**——
> 它是业务观察归一化与跨语言 wire parity 的基础，不是防御层。`Hashable`/`Hasher`
> 作为 Swift/集合实现机制保留，不得按关键词误删。
>
> 本节旧材料清单仅作删除审计保留（出处行号基于 main@f513a35 快照）。
> 删除执行归属：Catalog 侧 #303；Snapshot/manual/cache/coverage 侧 #304；
> golden/testkit/oracle 侧 #305。**不得用新的 digest（改名、换算法、截断 hash 等）
> 伪装替代**；替代机制只能用下表右列的显式机制。
>
> 旧统一输出格式（历史记录，新契约不再定义）：`"sha256:" + 小写十六进制（%02x）`，
> 总长 71 字符。

| # | 已撤销项（旧定义） | 替代机制（新契约） | 删除执行 |
|---|---|---|---|
| F1 | canonicalFingerprint（observation 内容指纹）：`{observationSchemaVersion, rawTopLevelFields, unknownTopLevelFields, items}` 的 canonical bytes 摘要；**display 整体剔除**；tag/timestamp 构建前剥离；v5+ 剥离 coverage 元数据；diagnostics 不在材料内 | **替换为 `ObservationIdentityMaterial` 直接比较（定义见 §WA-3.1）**：继续复用旧 F1 preimage 的全部排除与排序规则，只是把 `SHA256(material)` 换成双方材料 `canonicalData` 逐字节比较（唯一方式）。`display`（含 displayName/category/displayCategory/catalogVersion）继续持久化用于展示，但**永不参与 duplicate 身份**；catalog 展示信息变化不得使同一份游戏快照判为非 duplicate | #304 |
| F2 | integrityFingerprint（entry 完整性摘要）：JSONEncoder + .sortedKeys 对 entry 全量字段（减自身）共 18 字段做 digest；加载时重算比对 fail-closed | 删除摘要重算。加载校验保留：JSON 解码、entry 版本门精确匹配、section evidence（v2+ 必带、≤v5 禁 sourceUniverse）、rawJSON 重 canonicalize 比对、lineage/duplicate 交叉校验；其余 fail-closed 语义（§BE-1.2）不变 | #304 |
| F3 | AccountSnapshot.contentFingerprint（JSONEncoder + .sortedKeys；diagnostics 随机 id 排除在外） | 缓存改**显式失效**：AppModel/应用服务在快照导入、manual mutation/reconcile、村庄变更、Catalog epoch 变化处显式清空投影缓存；tick 内动态 timer refresh 仍可缓存，但状态变更后必须先失效再 render | #304 |
| F4 | ManualUpgradeCore 内容指纹 `{itemStates, records}`（JSONEncoder + .sortedKeys） | manual baseline 只保留 `revision + lineageID`；revision 由 snapshot ID/duplicate revision 表达，不再编码内容摘要 | #304 |
| C1 | Catalog `sourceFingerprint`（APK hash，运行时只验格式）+ `generatedFiles`（整体删除，不止其中的 sha256/size）+ `counts` + manifest 信任门（含文件存在性、manifest 登记防御） | 全部删除；manifest 只保留四字段版本/构建元数据（见 §WA-9.1 新形状，与 #303 第 31 行一致）；asset 侧保留 renderedPath null/missingReason 业务语义与正常路径解析 | #303 |
| C2 | coverage section `inputBinding` SHA-256 绑定、bundled perf fixture 内容 hash allowlist | 删除。保留 coverage 业务完整性状态（presence/completeness 四态）与 adapter 语义 | #304 |
| T1 | golden manifest `fixtureSha256`、oracle `inputFingerprint`/`outputFingerprint`、testkit 报告输入/输出 hash 与字符串摘要 hash | 保留 `caseId`、operation、canonical bytes/hex 与差异分类（fixture/wire/parser/projection/error/ordering/time）；字符串差异摘要改用 bounded length/type/path；fixture 串线防护改由 manifest 登记一一对应 + owner 测试归属承担（见 testkit-protocol-v1.md） | #305 |
| R1 | reconciliation `candidateFingerprint` / `previousSnapshotFingerprint`、lineage `lastFingerprint`、manual baseline fingerprint、display binding `catalogFingerprint` | stale preview 依赖 villageID + previousSnapshotID + lineage + manualStateUpdatedAt + §BE-5.4 `ReconciliationCandidateMaterial` 直接比较；lineage 校验经 `lastEntryID` + village/lineage/tag/time 关系；display binding 保留 catalogVersion/displayName/category | #304 |

### WA-3.1 ObservationIdentityMaterial（非 hash 内容身份材料，新契约）

旧 F1 表达的真正语义不是“整个 observation 的 hash”，而是“**除展示绑定外观察内容是否相同**”。
新契约把这份语义冻结为可直接比较的材料，TS 与 Swift 实现必须逐项复刻：

```text
ObservationIdentityMaterial {
  observationSchemaVersion
  rawTopLevelFields
  unknownTopLevelFields
  items: [ fingerprintValue(item) ]   // 即旧 F1 的 item preimage：identity/level/count/
                                      // rawTimerEvidence/unknownFields/weapon/gearUp/
                                      // helperRecurrent，**不含 display**
}
```

- **排除规则（沿用旧 F1 preimage，不增不减）**：`display` 整体剔除；tag/timestamp 在
  observation 构建前剥离；v5+ 剥离 coverage 元数据字段，v4− 保留以复现旧字节；
  diagnostics 不在材料内（只存在于 coverage）。
- **排序规则（沿用旧 F1）**：items 按 fingerprintValue 材料对象的 canonical bytes
  字节序排序，重复元素保留不去重（§WA-2 规则 2）。
- **比较方式（唯一）**：比较双方 `ObservationIdentityMaterial` 各自的 `canonicalData`
  （§WA-2）逐字节相等。注：`canonicalData` 对**所有 array 递归排序**（如 items 内
  `nestedParentPath`），而宿主语言的结构 `==` 对 array 顺序敏感——二者不是严格等价，
  若 Swift/TS 各选一种实现就会分叉，因此**只冻结 canonicalData bytes 比较这一种**，
  不允许裸 structural `==`。**禁止**对 material 再做任何 digest 后比较
  （见 §WA-3 不得伪装替代）。
- **使用点（两处，只能是这两处）**：
  1. duplicate 身份：判定键 =（ObservationIdentityMaterial 比较结果，coverage
     duplicate key，timerSchema）（§BE-3）。
  2. history reload 校验：`rawJSON` 重 parse + 重 canonicalize（**不带 catalog**重建，
     因此重建结果天然不含 display 绑定）后，比较 ObservationIdentityMaterial；
     通过才视为同一内容（§BE-1.2）。display 差异永不触发 reload 误报。

补充规则（保留，E0-03 未动）：

- runtimeWitness 是进程内瞬态 trust 状态，**不可序列化、不进入 duplicate 身份**
  （SnapshotHistoryModels.swift:723-741; VerifiedCoverageEvidence.swift:3-8; SnapshotHistoryDiff.swift:2098）。
- 目录侧不再有「比较型」指纹：旧规则（manifest 声明 sha256 vs 文件字节重算 + size 匹配 +
  sourceFingerprint 格式校验）已随 C1 撤销。
- 篡改防护改由 journal/validator fail-closed 承担（§BE-1、§BE-2）；旧负向锁定测试
  （如 `testFullIntegrityDigestRejectsMetadataDisplayAndCoverageTampering`）在 #303/#304
  中按新校验重写，不保留“旧 hash 仍需相等”断言。

## WA-4 时间戳与日期语义

**三种纪元并存，TS 必须显式区分，不得统一：**

| # | 域 | 语义 | 使用点 | 出处 |
|---|---|---|---|---|
| T1 | Unix epoch seconds（timeIntervalSince1970） | 导出文本 `timestamp` 字段 = epoch 秒；ageSeconds 在 epoch 域计算；未来时间戳 clamp 为 0 | AccountSnapshot.swift:451, 492 | |
| T2 | Swift reference-date seconds（2001-01-01 起算的 Double） | **Swift `JSONEncoder` 默认 Date 编码策略**。所有经 Codable 持久化的 Date 字段盘上都是该 Double：VillageProfile.createdAt/updatedAt、AccountSnapshot.importedAt/capturedAt、SnapshotHistoryEntry.appliedAt/sourceTimestamp（🗑️ E0-03：不再进入任何 digest，F2 已撤销；Date 持久化策略本身保留）、history envelope 各 recordedAt/completedAt/lastSeenAt/lastAppliedAt、manual tracker 全部日期字段、OfficialEndpointState.fetchedAt | VillageProfile.swift:20-21; AccountSnapshot.swift:205-222; SnapshotHistoryModels.swift:975-977; SnapshotHistoryStore.swift:13-63; ManualTrackerStore.swift:69-82; OfficialAPIState.swift:47 | |
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
- UUID 进入指纹的字段级归属（🗑️ E0-03：F1/F2/F3 指纹已撤销，以下仅作删除审计）：
  - 旧 F2 integrityFingerprint：snapshotID / villageID / lineageID 三个 UUID **曾进入**材料
    （SnapshotHistoryCanonicalizer.swift:1213-1231）。新契约 entry 仍持久化这三个 UUID
    （lineage 校验与 revision 审计依赖它们），但不再做 digest。
  - 旧 F3 contentFingerprint：**无任何 UUID 字段进入**；`AccountDataDiagnostic.id` 是每次解析
    随机生成的 UUID，被 F3 显式排除——diagnostics 只投影 severity/path/message
    （AccountSnapshot.swift:247-253）。本条作为历史 parity 教训保留：TS 不得把随机 id
    计入任何内容身份比较，否则同一导出两次解析将互不相同。
  - 旧 F1 canonicalFingerprint：不进（observation 材料不含任何 UUID）。
- 唯一性硬校验：snapshotID/lineageID 重复即 invalidEntry（SnapshotHistoryStore.swift:133-135,
  184-186）；reconciliationID/decisionID 重复即 invalidEnvelope（ManualTrackerStore.swift:124-127,
  162-165）；村庄 ID 重复即 corrupt（VillageStore.swift:79-84）。

TS domain 对这两类含义不同的身份使用独立 brand：`StableId` 由语义组件构造，用于
deterministic printable stable ID，不替代 structural persisted identity；`LineageId` 由
已校验的 UUID 构造或通过 `UuidSource` 注入；二者不可互换。

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

| Store / Envelope | 当前值（E0-03 新契约） | 支持范围与未来版本处理 | 出处 |
|---|---|---|---|
| VillageStoreSchema.current | 1 | 盘上为裸 JSON 数组无 envelope；仅当按数组解码失败且顶层声明更大 schemaVersion 时判 `.unsupportedSchema`，rawData 保留绝不覆盖 | VillageStore.swift:7-8, 87-91, 114-121 |
| SnapshotHistorySchema | envelope=2 / entry=2 / observation=6；🗑️ `fingerprintVersion` / `integrityVersion` 字段删除（不是 bump） | entry 精确等值匹配 envelope=2/entry=2；observation ∈ 1...6 且内部一致（observation 内容本身未变，仍为 6）；v2+ 必带 section evidence；≤v5 禁止 sourceUniverse；marker.version 必须 == envelope；无 marker 不得有 entries。**旧 envelope=1/entry=1 文件按 §WA-7.1 标记不可用** | SnapshotHistoryModels.swift:8-31; SnapshotHistoryStore.swift:126-163, 208-215；新版本决策 Issue #302，执行 #304 |
| ManualTrackerSchema | envelope=2 / store=2 / village=2 | village/envelope/marker 三处精确等值否则 unsupportedSchema。**旧全=1 文件按 §WA-7.1 标记不可用** | ManualTrackerStore.swift:5-9, 197-200, 360-409；新版本决策 Issue #302，执行 #304 |
| GameCatalog manifest | 仅接受 3（`CatalogManifestV3` 四字段：schemaVersion/gameVersion/buildTag/locale；🗑️ `sourceFingerprint` / `generatedFiles` / `counts` 整体删除） | 出范围一律 fail-closed 不进已验证态；manifest 缺失时目录仍可加载（manifest=nil）。**旧 schemaVersion 1/2 按 §WA-7.1 标记不可用，需重新生成** | GameCatalog.swift:50, 65-66, 33-35；新形状见 §WA-9，执行 #303 |
| LeagueTierCatalog.schemaVersion | ==1 | 非 1 → loadBundled 返回 nil（UI 正常降级态） | LeagueTierCatalog.swift:16, 41 |
| CraftTableCatalog.schemaVersion | ==1 | 非 1 → nil（🗑️ E0-03：删除 manifest craft-entry SHA/size 对账与 `integrityOK` 门，CraftTableCatalog.swift:103-118 中完整性行删除；保留 schema/gameVersion/buildTag 与 craft 数据解码，执行 #303） | CraftTableCatalog.swift:59, 103-118 |
| SeasonalPhaseTable.schemaVersion | ==1 | 非 1/缺文件 → 空表不报错（增强数据） | GameCatalog.swift:321-324, 412-415 |
| OfficialStateStore ×4 | 无版本 | fail-open 组（§BE-1.4） | OfficialStateStore.swift:17-63 |
| TrackedClanStore | 无版本 | fail-open 组；演进红线：新字段必须默认值/decodeIfPresent，否则容错机制把 schema 错误变成整库静默丢失（注释原文即红线） | TrackedClanStore.swift:36-53 |
| Golden manifest（Tests/Golden/manifest.json） | protocolVersion=2；🗑️ `fixtureSha256` 字段删除 | 登记与 `Fixtures/` 一一对应 + case id/operation/owner 校验承担串线防护（见 testkit-protocol-v1.md）；旧 protocolVersion=1 manifest 不再被新 testkit 接受 | 决策 Issue #302，执行 #305 |
| Golden oracle 请求/响应协议 | protocolVersion=2；🗑️ `inputFingerprint` / `outputFingerprint` 字段删除 | 旧 v1 响应直接视为不支持，不加 v1 fallback；关联靠 caseId，结果靠 canonicalHex/业务字段/差异 path 比较 | 决策 Issue #302，执行 #305 |

### WA-7.1 E0-03 数据与兼容策略（硬切换）

沿用 Issue #265 数据策略决策门（默认不做长期兼容层、双写或双读），E0-03 四组协议
硬切换规则如下：

- Snapshot History envelope/entry、Manual Tracker、Catalog manifest、Golden Oracle 协议
  按上表提升版本或替换为新 shape；**不增加长期双读、双写、fallback 或迁移兼容层**。
- 旧 Application Support/UserDefaults 等价数据文件**原文件保留、不静默重写为空**，
  但按旧 schema 标记不可用（unsupportedSchema/不可用态 + 显式中文提示）；用户需要
  重新导入/重建。若产品要保留旧数据并迁移，另开一次性 importer Issue（importer 不得
  进入正常运行路径）。
- Catalog 旧 manifest（schemaVersion 1/2）需经生成器管线重新生成（#303）；Snapshot
  History / Manual 旧文件需用户重新导入/重建（#304）；parity fixtures 按新协议重新
  生成（#305）。
- 历史 perf 报告和已完成 Issue 的原始审计文字不在本 Issue 中重写；活动契约文档
  （本目录）必须同步到新 shape——即本节与 §WA-3/§WA-9 的修订。

## WA-8 官方 API wire 形状要点

- 分页结构 `{items, paging.cursors.after/before}`：**items 必填**，缺失/null → 解码失败 →
  保留 last-good，「不得静默当作成功空页」（ClanPaginationModels.swift:21-22, 51-52）。
- paging/cursors 全可选；after=向后翻页游标（末页 nil）；before 未使用仅透传；
  两者皆 nil 时 encode 不写 paging 键（ClanPaginationModels.swift:83-88）。
- 终结判定：responseAfter 为 nil → 无更多；`responseAfter != requestedCursor` 才继续——
  游标未前进即终结（§BE-4.2）。
- 官方快照 decode 全字段 optional + 任意字符串 CodingKey 遍历（§WA-1.4）。
- HTTP → CoAPIError 映射与取消透传见 error-matrix.md §ER-1。

## WA-9 catalog manifest 与资源管线契约（🗑️ E0-03 已撤销完整性防御）

实现（旧）：GameCatalog.swift:31-130（`CatalogManifest` / `CatalogGeneratedFile` / `CatalogCounts` /
`validate`）。活体 fixture：仓库源路径
`Sources/COCHelperCore/GameCatalog/18.400.13/manifest.json`；运行时 bundle 路径为
`GameCatalog/18.400.13/manifest.json`（Package 以 `.copy("GameCatalog")` 保留目录结构，
`.process` 会扁平化子目录故不可用）。由 `Tools/game_catalog` Python 生成器产出，
GameCatalogTests ManifestValidation 系列锁定。

E0-03（Issue #302）撤销 `sourceFingerprint`、`generatedFiles`（整体删除）、`counts` 及基于它们的
manifest 信任门；manifest 只保留实际消费的版本/构建元数据（四字段，见 §WA-9.1）。
删除执行 #303（含生成器管线改造与 `manifest.json` 重生成；在 #303 落地前，仓库内活体
`manifest.json` 仍为旧形状，不得按新契约解读）。

### WA-9.1 manifest 形状（新契约，schemaVersion=3）

```text
CatalogManifestV3 {
  schemaVersion: Int          // 新契约仅接受 3；1/2 为旧 schema，按 §WA-7.1 标记不可用，需重新生成
  gameVersion: String         // ⚠️ 「与目录目录名一致」是调用方/打包约定，不是被强制的
                              //   不变量：generate(output_dir:) 接受任意目录名，
                              //   validate_catalog 也只比 manifest↔catalog 一致；
                              //   运行时 loadBundled(version:) 同样只比
                              //   manifest.gameVersion == catalog.gameVersion
                              //   （GameCatalog.swift:953），不比对传入的目录版本参数。
                              //   TS 消费侧可实施更严的目录名比对（E2-02 裁量）
  buildTag: String
  locale: String
}
```

🗑️ E0-03：删除 `sourceFingerprint`、`generatedFiles`（整体删除，不止其中的
sha256/size）、`counts`。**不能为校验而保留无消费者字段**（与 #303 第 31 行一致；
本 PR 初版曾保留 generatedFiles/counts，已按 #303 收敛）。旧 `CatalogCounts`
未知键兼容策略（blockedIcons/displayCategories/renderedIcons）随 counts 整体删除而失效，
生成器侧同步清理归 #303。

> 以下两段为旧形状审计存档（schemaVersion 1/2 manifest 的历史行为，新契约不再要求）：

`counts` 的 Swift 声明字段（GameCatalog.swift `CatalogCounts`，旧形状审计存档）：items / levels 必填，
missingIcons? / missingTime? / timed? / instant? / notApplicable? / initialLevel? /
sourceMissing? / parseFailed? 可选（旧 manifest 缺键 → nil 向后兼容）。
其中 **missingIcons 是 Swift/TS 侧 decode-only 字段**：Swift `validate()` 不校验它，
但生成器校验层（`Tools/game_catalog/validate.py:639`）会将其与重算值对账。

**未知 counts 键策略（冻结，范围限定为 Swift runtime / TS 消费侧）**：活体 manifest 实测含
`blockedIcons` / `displayCategories` / `renderedIcons` 三键，Swift `CatalogCounts` 未声明 →
Codable 解码静默忽略，不参与 Swift `validate()`。⚠️ 这三键在**生成器校验层并非未知**——
`Tools/game_catalog/validate.py:665-691` 会校验 renderedIcons（== generatedFiles PNG 计数）、
blockedIcons（快照语义格式检查）与 displayCategories（Issue #75 工作流 C）。以上均为旧形状
（schemaVersion 1/2）审计存档：counts 整体删除后，新消费侧不再解码 counts（未知键问题不复存在），
旧生成器对账项同步撤销（#303）。

### WA-9.2 校验规则分层（新契约）

新契约消费侧校验只剩版本门（🗑️ E0-03：counts 重算、hash、size、文件存在性、
generatedFiles 登记门随字段删除而整体撤销，不再有 validate 五规则）：

| # | 规则 | 备注 |
|---|---|---|
| ① | schemaVersion == 3 | 旧 1/2 按 §WA-7.1 标记不可用，需重新生成；出范围拒绝（fail-closed 不进「已验证」态） |
| ② | manifest 缺失时目录仍可加载（manifest=nil） | 旧行为保留（GameCatalog.swift:33-35），不是新增 fallback |

资源引用语义（保留，见 §WA-9.3）：`isRenderable` 判定、missingReason 原样暴露给 UI、
renderedPath 正常路径解析；renderedPath **不必**出现在任何登记中（R-C 登记门已随
generatedFiles 删除而撤销，#303 同步删 `asset-ref.ts` 对应门）。

明确**不存在**（🗑️ E0-03）：`sourceFingerprint`、icons/文件内容哈希、声明 size、
文件存在性门、generatedFiles 登记覆盖、counts 对账、missingIcons。

**生成器校验层**（`Tools/game_catalog/validate.py`，产出目录时的独立门禁，与消费层互补；
E0-03 改造归 #303）：`manifest.json` 重新生成成最小可消费 shape（只保留上节四字段）；
不再写入/重算 source SHA、generatedFiles hash/size 与 counts，删除无消费者的
fingerprint helper（`catalog.py` / `fingerprint.py` / `validate.py` / `contract.py`
删除 generatedFiles 登记依赖，保留路径/资源引用的实际消费规则）；
`annotate_blacksmith_levels.py` 删除 APK SHA 与 sourceFingerprint 绑定及 hash 前置条件，
**保留 APK buildTag/版本和表结构校验**（防不同版本数据静默套入当前目录）；
`generate_craft_table_catalog.py` 删除 craft hash/size 写入，保留版本/结构校验；
`render_generator.py` / `render_spike.py` 删除 PNG hash 写入，保留渲染结果、
missingReason、路径回写和原子写入（报告字节大小如仅为测量信息可保留，
但不得再作为加载门）。

旧生成器校验层行为（历史记录）：曾校验 missingIcons 对账（:639）与 renderedIcons /
blockedIcons / displayCategories 三键「存在才校验、缺失放行」（validate.py:664-691）。
counts 整体删除后，这些对账项同步撤销，不迁移为新必填项。

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
| account_snapshot_golden.json + parser_golden_expected.json | 匿名 legacy 导出文本 → §WA-6c 解析。🗑️ E0-03：删除 F3 contentFingerprint / F1 canonicalFingerprint / F2 integrityFingerprint 三重硬编码（#305 重新生成，只保留业务结果和 encoded wire bytes/hex）。保留：**AccountSnapshot 的 JSONEncoder(.sortedKeys) encoded bytes hex（wire shape：Date 编码策略、optional omission、键序；AccountSnapshot 持久化形状未变）**。🗑️ E0-03：History entry 的 encoded bytes 改为**新 entry shape（envelope=2/entry=2）**，由 #305 重生成；旧 `HistoryEntryV1` bytes 随旧 shape 废弃，不再冻结。⚠️ AccountSnapshot wire 含 `diagnostics[].id`（每次解析随机生成的 UUID），golden 中该槽位掩码为 `<RANDOM_DIAGNOSTIC_UUID>`——TS 必须把它当作不透明随机值，其余字节逐字节复刻 | GoldenContractTests/ParserGoldenTests；manifest `parser/*` |
| manual-queue-capacity-contract.json | §BE-5.3 队列容量 start gate / occupancy 投影契约；startGateCases + occupancyCases | packages/testkit/src/manual-queue-capacity.parity.test.ts；manifest `projection/manual-queue-capacity` |
| snapshot-history-diff-contract.json | §BE-3 diff 引擎三类冻结场景：level increased / B→A comparable no change / partial coverage 不产删除；每个 case 含静态 `expected`（`comparisonState` / `changeCount` / `encodedJSONHex` / `canonicalHex`；🗑️ E0-03：删除 `outputFingerprint`，#305 同步重生成） | packages/testkit/src/snapshot-history.parity.test.ts；manifest `diff/snapshot-history-contract` |
| official_war_log_page.json 等 | 复用 `Tests/COCHelperCoreTests/Fixtures/` 既有匿名分页/官方快照 fixtures（不复制），映射见 dto-mapping.md；catalog 侧活体 fixture 见 §WA-9（仓库源路径 + 运行时 bundle 路径） | 既有 ClanPaginationDecodeTests / GameCatalogTests |

尚未覆盖（见 target-architecture.md §6 关闭门）：**error 场景 fixture**，
由 E2-06（#274）等域 issue 按 error-matrix.md 增量追加。全量 fixture 登记见 `Tests/Golden/manifest.json`。
