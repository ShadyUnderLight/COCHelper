# renderedPath 输出契约（Issue #27）

> 状态：**契约冻结（渲染相关条目已实测回写，2026-08-05 Issue #30）**。
> 本契约冻结 `renderedPath` 的输出规则，使 Python 生成器、manifest 校验器、
> Swift Bundle 加载与 UI 使用遵循同一语义。渲染无关的条目（路径、命名、失败
> 语义、依赖）为强制契约；PNG 规格（R3）与字节稳定性（R4）已由 Issue #30
> 固定样本实测回写（见 §12.1 解锁状态）。
>
> 关联：issue #13（生成管线）、#27（spike + 契约）、#30（解锁 + 固定样本）、#25（图标渲染管线 + UI 接入）。
> 相关文件：`Tools/game_catalog/sc2.py`、`Tools/render_spike.py`、
> `Sources/COCHelperCore/GameCatalog.swift`、`Tools/game_catalog/validate.py`、
> `Tools/game_catalog/__init__.py`、`Sources/COCHelperCore/GameCatalog/18.400.13/manifest.json`。

---

## 1. 适用范围

| 角色 | 文件/模块 | 遵循的契约条目 |
|---|---|---|
| Python 生成器（渲染管线，#25 实现） | `Tools/game_catalog/` 渲染扩展 | 全部 |
| Python 校验器 | `Tools/validate_game_catalog.py` + `validate.py` | R1/R2/R4/R5/R6/R7/R8 |
| Swift Bundle 加载 | `Sources/COCHelperCore/GameCatalog.swift` | R1/R5/R7/R8 |
| Swift UI 使用 | `CatalogAssetRef.isRenderable` | R8 |
| spike 渲染模块（现状） | `sc2.py` + `render_spike.py` | R9 例外 |

---

## 2. renderedPath 相对根（R1）

| # | 契约规则 | 校验方式 |
|---|---|---|
| R1.1 | `renderedPath` 是**相对版本目录**的路径，语义根为 `GameCatalog/<gameVersion>/icons/`。完整 Bundle 内路径 = `Bundle.module` 下 `GameCatalog/<gameVersion>/icons/<path>`。 | Swift `Bundle.module.url(forResource:withExtension:subdirectory: "GameCatalog/<version>")` 解析后文件存在；validate.py 以 `catalog.json` 所在目录为根解析 |
| R1.2 | SwiftPM 以 `.copy("GameCatalog")` 打包，目录结构逐级保留（现有约定，README §Tools），`renderedPath` 不得假设 Bundle 内路径被扁平化。 | 打包后 Bundle 内目录结构抽查 |
| R1.3 | `renderedPath` 永不写绝对路径、不包含 `gameVersion` 段（版本由目录层级表达，见 R7）。 | validate.py 负例（`contract.rendered_path_format_ok`：`icons/<container>/<export>.png` 两级结构 + 拒绝对路径/`..` 段/版本段） |

---

## 3. 命名与去重键（R2）

**逻辑键**：`(gameVersion, buildTag, container, exportName)`。
其中 `gameVersion` 由目录层级表达（R7）、`buildTag` 由 manifest 固定（`buildTag` 字段），
故路径层只需派生自 `(container, exportName)`。

| # | 契约规则 | 校验方式 |
|---|---|---|
| R2.1 | 文件名派生规则（确定性）：`icons/<container_key>/<export_key>.png`，其中 `container_key` = container 去掉 `sc/` 前缀与 `.sc` 后缀（`sc/ui.sc` → `ui`，`sc/buildings_cc.sc` → `buildings_cc`）；`export_key` = sanitize(exportName)。 | 对照表抽查：`sc/ui.sc` + `icon_unit_barbarian` ⇒ `icons/ui/icon_unit_barbarian.png` |
| R2.2 | sanitize 规则：替换 `/`、`\` 为 `_`；拒绝空串、`.`、`..`（fail loud）；文件名长度上限 200 字节。 | validate.py 负例（`rendered_path_format_ok`：拒 `.`/`..` 段、文件名 >200 字节） |
| R2.3 | 同键恒同路径、不同键恒不同路径：若 sanitize 后不同原始名产生冲突 → 生成器 fail loud，不静默覆盖（真实数据 export 名唯一，冲突即数据异常）。 | 生成器冲突断言 + validate.py 重复条目检查 |
| R2.4 | **去重**：跨 item/level 复用同一 `(container, exportName)` 只渲染一份、manifest 记录一次，多 level 引用同一 `renderedPath`（实证：catalog 铁匠铺 dataID 1000070 level1-2 共用 `blacksmith_lvl1`）。 | manifest PNG 条目数 == 唯一键数；validate.py 断言不同 ref 可共享同一 path |
| R2.5 | **渲染变体区分策略（开放项）**：spike 未发现同键多变体需求（如 lowres/主题色/尺寸变体）。若将来需要，扩展键为 `(container, exportName, variant)`，variant 编码进文件名（如 `<export_key>__<variant>.png`），并 bump schemaVersion——本契约冻结前不允许静默引入变体。 | 无（开放项，记录在案） |

> 注：spike 临时输出（`render_spike.py`）用扁平 `<exportName>.png` 命名，仅 /tmp
> 验证用，**不代表生产契约**；#25 渲染管线必须按 R2.1 命名。

---

## 4. PNG 规格（R3，待 #25 前验证）

| # | 契约规则 | 校验方式 |
|---|---|---|
| R3.1 | 尺寸 = shape 顶点屏幕空间 bounds（应用 frame element matrix 变换后），按 1:1 像素 ceil 取整、至少 1x1、上限 4096。**2026-08-05 实测回写**：原「尺寸 = 源纹理尺寸」被真实数据否定——icon 是从大 atlas（4096² 等）裁切的小区域，输出尺寸由几何 bounds 决定（icon_unit_barbarian=166x166、fireplace_lvl1=75x58、blacksmith_lvl1=110x126）。 | PNG IHDR 宽高 == `suggest_output_size(compute_bounds(transform_vertices(...)))` |
| R3.2 | 透明背景：RGBA 输出下未覆盖像素 alpha=0，不做背景填充。**实测回写**：真实纹理全部为 ASTC 系（ui.sc 内嵌 KTX 4x4/6x6/8x8；buildings.sc 外部 .sctx 6x6，pixel_type=208=ASTC_RGBA8_6x6），无灰度/原始 RGBA 路径触发；ASTC 解码输出恒 RGBA8。原 BGRA8 社区惯例映射条目删除（无真实样本，不保留未验证语义）。 | 像素级抽查（alpha 通道）；ASTC 解码单测 |
| R3.3 | 位深 8-bit；sRGB 色彩空间，PNG 声明 `gAMA` chunk = 45455；无 `tIME` 等时间戳 chunk（与 R4 联动）。**2026-08-05 实测**：`encode_png`（render.py）实现 IHDR/IDAT/IEND + gAMA、filter=0 全行、zlib level=9，已对拍 sips 可读。 | PNG chunk 遍历断言（合成 fixture） |
| R3.4 | **已实测回写（2026-08-05）**：以上规格基于真实渲染图核对完成——4 个固定样本 PNG 全部可被 sips/PNG 解码器打开、尺寸与 bounds 语义一致、alpha 语义正确（非覆盖像素透明）、字节序 RGBA8。原「待 #25 前验证」标记解除。 | 样本 PNG 断言 + 人工视觉验收（#25 入口） |

---

## 5. 字节稳定性（R4，待验证）

| # | 契约规则 | 校验方式 |
|---|---|---|
| R4.1 | 生成**必须确定性**：同一 APK + 同一参数 → 字节完全一致。约束：无时间戳、固定 zlib 压缩级别、固定 filter 策略、无随机源。现有生成管线已承诺确定性（README：无时间戳，重复生成字节一致），PNG 编码继承该约定。 | 同一输入连续生成两次，`sha256` 比对必须一致 |
| R4.2 | manifest 记录的 `sha256/size` 与文件实际值一致（validate.py 已有重算机制，对 PNG 条目同样生效）。 | `validate_game_catalog.py` 重算比对 |
| R4.3 | **已实测回写（2026-08-05）**：4 个固定样本（icon_unit_barbarian/icon_spell_rage/fireplace_lvl1/blacksmith_lvl1）连续生成 3 次，PNG 字节 sha256 完全一致（确定性成立）。约束不变：无时间戳、固定 zlib 级别（9）、固定 filter（0）、无随机源。 | 生成器集成测试（`test_render_generator.py` 确定性断言） |

---

## 6. 失败语义（R5）

| # | 契约规则 | 校验方式 |
|---|---|---|
| R5.1 | 失败必须设置 `missingReason`（枚举域，见下表），`renderedPath` 为 null。**禁止空 PNG / 伪成功路径**：0×0 尺寸、数据长度不符、无内嵌数据、解析异常 → 一律 blocked + missingReason，绝不写占位/空文件（spike 已按此实现防御分支）。 | 生成器负例测试（0×0、长度不符 fixture） |
| R5.2 | **互斥不变量**：`renderedPath` 非空（含空串，见 R8.1）⇒ `missingReason` 为 null（`missingReason` 按 `is not None` 判定，空串也是失败原因）；`renderedPath` 为 null ⇒ 渲染失败类引用必须给 `missingReason`（不留空解释）。**空串 `renderedPath` 是非法路径**：不得绕过校验（P1-2），校验器报格式非法。 | validate.py 负例 + property-based 测试（含空串边界） |
| R5.3 | `renderedPath` 非空 ⇒ 文件必须真实存在于版本目录与 App Bundle。 | validate.py `rendered_path_file_must_exist`（含格式/`..`/版本段拒绝）；Swift 加载路径检查（#25 UI 接入时落实，当前 loadBundled 只解码 catalog.json） |

**missingReason 枚举（Issue #30 Task 7 实现定稿，`ASSET_MISSING_REASONS` 域）**：

| 值 | 语义 | 触发（实测） |
|---|---|---|
| `icons_not_rendered` / `no_icon_columns` / `no_visual_columns` | #13 遗留：未渲染 / 无列 | catalog 生成器（保留） |
| `sc_parse_failed` | SC2 容器解析失败（magic/version/descriptor/chunk 越界等） | `CatalogError` 路径 |
| `movieclip_not_parsed` | export 的 object_id 既非 Shape 也非 MovieClip（引用损坏）——**发射于 export 非 shape 非 movieclip 的引用**；嵌套 movieclip 会递归展开，textfield 等非图形子项仍记录在 `skippedElements`，**不发射** | `_collect_renders` 防御分支 |
| `texture_compressed_astc` | 内嵌 KTX/ASTC 压缩纹理，无解码器 | 已解决（astc.py）——保留枚举向后兼容 |
| `texture_external_sctx` | 纹理存外部 `.sctx` 文件，无解码器 | 已解决（ktx.py）——保留枚举向后兼容 |
| `zstd_unavailable` | libzstd 无法加载（ctypes 全路径失败） | `load_libzstd` 失败 |
| `container_not_found` | APK 无此容器（assets/sc/*.sc 缺失） | 样本 `sc/traps.sc`（APK 无该文件） |
| `export_not_found` | exportNames 无此导出名 | 样本 `icon_unit_does_not_exist` |
| `astc_unsupported` | KTX/SCTX 容器解析失败或 ASTC 格式不支持（HDR 等） | `.sctx` 非 variant-36 / pixel_type≠208、KTX 未知 glInternalFormat、HDR 解码（AstcError） |
| `texture_missing` | 纹理无内嵌数据 / 外部 .sctx 缺失或读取失败（含 zip 条目超防炸弹上限，读取前拒绝） | `td.data` 为空、外部 `.sctx` zip 条目不存在、texture_data 索引越界 |
| `render_failed` | 渲染链失败（bounds/光栅化/PNG 编码/引用越界/容器 zip 条目超上限） | MovieClip 无帧、帧 0 无可渲染 shape 元素、shape 无 draw 命令、其余 `CatalogError` 兜底 |

> 上表为**实现定稿**（Task 7 实际使用的枚举）；原「建议扩展」表被本表取代。
> 生成器规则：成功 → `renderedPath` 非空 + `missingReason=null`；失败 → `renderedPath=null` + 上述枚举。不写空 PNG、不写伪造路径（样本负例已锁）。

---

## 7. manifest 记录（R6）

### 精制台模组 UI 图标

精制台 `types/modules` 的 9 个模组 ID 不参与 `GameCatalog` 的 item/level join，
但其升级属性图标仍由 APK `sc/ui.sc` 直接解析并作为独立 Bundle 资源提供。当前版本
由 `ModuleUpgradeIconCatalog` 固定映射：102000033/036/039 → `info_icon_hp`，
102000034/037/040 → `info_icon_damage`，102000035/038/041 →
`info_icon_time_boosted`。三张 PNG 位于 `icons/ui/`，并在 manifest 的
`generatedFiles` 中登记；`VillageItemState.preferredAssetURLs` 将其置于普通目录
资产候选链之前。

| # | 契约规则 | 校验方式 |
|---|---|---|
| R6.1 | `generatedFiles` 为每张 PNG 追加条目：`path`（相对版本目录）、`size`、`sha256`（`"sha256:" + 64 hex` 前缀格式，与现有 catalog.json 条目一致）；`icons/` 目录条目保留（`kind: "directory"`，`entries` 可填 PNG 数）。 | validate.py 重算 hash/size 比对 |
| R6.2 | `counts` 扩展（**已落实，2026-08-05 Issue #30 外部评审 R3**）：`renderedIcons`（渲染成功且落盘的 PNG 数，**必须 == generatedFiles 中 PNG 条目数**，validate 重算断言）与 `blockedIcons`（本次生成器运行的失败样本键数，**快照语义**——validate 只校验存在性/类型/非负，不重算，因失败键数只有生成器知道）；新增字段为 optional（`Int?`，旧 manifest 兼容，不 bump schemaVersion）。**校验方式**：validate.py 重算 `renderedIcons == generatedFiles PNG 条目数`；`blockedIcons` 非 int/负值报错；两者缺失不报错。生成器侧由 `_refresh_manifest_content` 维护（`renderedIcons` 从 catalog 最终 renderedPath 集合推导，`blockedIcons` 由 write_rendered_outputs 从 verdicts 统计）。 | validate.py counts 校验扩展 + `test_validate.py`/`test_render_generator.py` 负例/集成断言 |
| R6.3 | 既有 `missingIcons` 计数语义不变（`levels[i].icon.renderedPath is None` 计数，validate.py 现状）。 | validate.py 既有重算 |

---

## 8. 版本隔离（R7）

| # | 契约规则 | 校验方式 |
|---|---|---|
| R7.1 | 目录按 `gameVersion` 分层：`GameCatalog/<gameVersion>/`；`renderedPath` 永远相对版本目录，**跨版本无共享路径、同名资源不互相覆盖**（现有结构已支持）。 | 多版本目录并存时 validate.py 各自独立校验通过 |
| R7.2 | Bundle 内同构：`GameCatalog/<version>/icons/<path>`，`loadBundled(version:)` 解析对应版本，绝不回退到其他版本目录。 | Swift 测试（不存在的版本 → nil，不串目录） |

---

## 9. isRenderable 一致性（R8）

| # | 契约规则 | 校验方式 |
|---|---|---|
| R8.1 | 单一语义：`isRenderable ⇔ renderedPath 非空（非 nil 且非空串）∧ missingReason == nil`。**空串路径不可渲染**（交叉审核 P1-2：空路径不得被视为可渲染资源；Swift `isRenderable` 与 Python `contract.is_renderable` 同规则）。 | Swift 属性 + Python property-based 测试（真值表含空串） |
| R8.2 | Python 校验器同一规则：任何 ref 的 `renderedPath`/`missingReason` 组合必须满足互斥不变量（R5.2，`missingReason` 按 `is not None` 判定，空串也是失败原因），且渲染失败必须落 `ASSET_MISSING_REASONS` 域（空串 reason → "未知 missingReason"）。 | property-based 测试（域闭合 + 空串边界） |
| R8.3 | UI 使用侧不得自行发明判定（如只查 `renderedPath` 存在性）；必须消费 `isRenderable`（Swift）或同规则校验器输出（Python）。 | 代码评审 + 契约测试 |

---

## 10. 依赖声明（R9）

| # | 契约规则 | 校验方式 |
|---|---|---|
| R9.1 | 现有生成目录管线（`generate_game_catalog.py` + `game_catalog` 非渲染部分 + `validate_game_catalog.py`）：**纯 stdlib，零第三方运行时依赖**（README 声明），**不变**。 | import 检查（无 ctypes 加载副作用） |
| R9.2 | **例外**：spike 渲染模块（`sc2.py` 的 zstd body 解码 + `render_spike.py`）需要 `ctypes + libzstd`（brew/系统库，非 pip 包）。加载顺序：`/opt/homebrew/lib/libzstd.dylib` → `/usr/local/lib/libzstd.dylib` → `ctypes.util.find_library("zstd")`；全失败 → `CatalogError`（→ `zstd_unavailable`）。 | 无 libzstd 环境下运行 spike → 明确报错；模块 docstring 注明例外 |
| R9.3 | 该例外必须在模块 docstring 与 README §Tools 显式声明；#25 渲染管线入库时保持该分离或显式升级依赖声明，**不得静默扩散**到生成器/校验器。 | README/文档评审 |
| R9.4 | 解压保护：body 解压上限 512MB（防 zip bomb，`ZSTD_decompressBound` 超限拒绝）。 | 负例测试（伪造超大 bound 帧） |

---

## 11. 候选投票结论与备选路径（R10，记录）

| 候选 | 结论 | 理由（已确认） |
|---|---|---|
| A：sc_extract（Rust） | **排除** | 仓库已删、仅支持 SC1/`_tex.sc`、格式不兼容 |
| B：自研 Python | **主选（当前实现）** | 公开 schema + C++ 参考齐全；descriptor 未压缩（export 名可解析）；body zstd 用 ctypes+libzstd（本机已确认可加载）。spike 已验证 export 名/引用链解析可行 |
| C：ClashKing CDN（assets.clashk.ing） | **rejected（2026-08-05 Issue #30 Task 0）** | 实测 catalog 381 个唯一引用对 CDN manifest（2585 资产）3 种映射策略 **0 命中**（精确/去前缀/level 归一化）；命名体系不兼容（display_name vs 内部 export 名）；版本对应未声明；覆盖度不足（troops 96/heroes 8/pets 12 vs 游戏全集） |

决策：**reject C，选 B（已实现并通过固定样本验证）**，详见 `docs/render-path-decision.md`。

---

## 12. spike 结论与 #25 决策（R11，记录）

**spike 已证实（18.400.13，`base.apk.1`）**：
- ✅ 可解析：SC2 V6 头/descriptor/export 名（`ui.sc` exports=3024）/引用链（Shapes 4053 个、id 稀疏 0..23358；Textures 7 个 set）
- ❌ **双重阻塞**（渲染 PNG）：
  1. **export→object_id 全部指向 MovieClip**：真实数据中 export 无对应 Shape 命令，需 MovieClip→frame→shape 解析链路（当前只扫描 MovieClip id，未解析帧结构）；
  2. **纹理无原始 RGBA**：`ui.sc` 全部 7 个 set 的 `texture_format`=8（内嵌 KTX，ASTC 系）；`buildings.sc` 71 个 set 全部 `texture_format`=0 + `external_texture` 指向 `.sctx`（`.sctx` 的 pixel_type=208，社区枚举为 ASTC 系）。无原始像素可直写 PNG。

**verdict：继续阻塞 #25**（渲染相关契约条目 R3/R4 无法实测；渲染无关条目已冻结）。

---

## 12.1 Issue #30 解锁状态（2026-08-05 回写）

**双重阻塞已解除**（`feat/issue30-render-path`，PR #32）：

| 阻塞 | 解法（本分支提交） |
|---|---|
| 阻塞 1：MovieClip 引用链 | `sc2.py` 帧解析（Task 1 实证：MovieClipFrameElement = 6 字节 3×u16，instance_index→children_ids[i]→shape 全局 id；单帧为主）；Shape 命令/顶点完整解析（Task 2：12 字节顶点 x/y float + u/v u16/0xFFFF，**实证 icon 为 6-8 顶点多边形非矩形**）；MatrixBank/Matrix2x3（Task 3：24B float32x6，half 未使用） |
| 阻塞 2：ASTC/KTX/SCTX | `astc.py`（Task 4：**与官方 astcenc 5.7.0 全图逐像素对拍 diff=0**，4x4+6x6，LDR only，HDR→AstcError）；`ktx.py`（Task 5：KTX 1.x + SCTX 布局实证，ASTC 4x4/6x6/8x8 格式映射） |
| 渲染/编码 | `render.py`（Task 6：bounds 1:1 + 多边形光栅化（edge function + 重心 UV + 双线性采样）+ 确定性 PNG（gAMA 45455、filter 0、zlib 9）） |
| 生成/验收 | `render_generator.py`（Task 7：4 成功样本 PNG + 2 失败样本 missingReason；catalog.json 105 引用回写；validate verdict OK）；`validate.py` PNG 魔数校验（Task 8）；Swift Bundle 读取断言（Task 9，380 测试全绿）。**manifest generatedFiles 由 `render_generator.py` 自动刷新**（`refresh_manifest`：重算 counts + generatedFiles 的 catalog.json sha256/size、icons/ 目录条目 entries、PNG 条目追加/去重，事务性落盘；`--no-refresh-manifest` 可关闭；R6.2 已落实——counts 含 `renderedIcons`/`blockedIcons`）。**外部评审 R3（2026-08-05）**：png_relpaths 来源统一为 catalog 最终 renderedPath 集合（去重、icons/ 内），generatedFiles 与实际引用一致；事务提交后清理孤儿 PNG（旧成功→本次失败：PNG 删除 + generatedFiles 条目消失 + catalog 引用置 null），清理失败不阻断（记录 cleaned/cleanupFailed） |

**固定样本实测**（sha256 三次生成一致，R4 成立）：
- `icons/ui/icon_unit_barbarian.png` 166x166（64,039B）、`icons/ui/icon_spell_rage.png` 166x166（79,083B）、`icons/buildings/fireplace_lvl1.png` 75x58（9,146B）、`icons/buildings/blacksmith_lvl1.png` 110x126（26,696B）
- 失败样本：`icon_unit_does_not_exist`→`export_not_found`、`traps.sc/town_hall_lvl1`→`container_not_found`（无空 PNG、无伪造路径）

**verdict：可进入 #25**。R3/R4 已实测回写（§4/§5）。

**#25 UI 接入与全量渲染清单（2026-08-06 已完成）**：
1. `UpgradeDisplayRow` 图标列：`isRenderable` 时渲染 PNG，否则 SF Symbol + 缺失角标（预留注释已就位）
2. `LevelDetailSheet` 逐级行：接入 `levelVisual/icon`
3. 共享 Bundle asset resolver（`Bundle.module.url(forResource:...)` 模式已由 Task 9 测试锁定）
4. 全量渲染：真实 APK 已处理 1269 个唯一键（R2.4 去重），当前成功 1258、失败 11；**口径注**：381 = item 级唯一引用键（决策文档沿用此数）；level 级（逐级 `icon`/`levelVisual` 引用）唯一键为 1269（5479 条 level 记录去重后）——全量渲染按实际引用集合为准
5. 嵌套 MovieClip（动画/阴影层）递归渲染（**已在 2026-08-06 完成**；父子矩阵合成，退化占位层在有其它有效图层时忽略）
6. 多帧 MovieClip 取帧 0（当前行为，契约注明）
7. 视觉人工验收：逐项核对图标朝向/形变/双线性边缘

**已知限制（契约标注）**：HDR 端点拒绝（真实纹理零出现）；3D 块不支持；SCTX 非 variant-36 头（28/32，`assets/sc/` 150 个）不支持（fail loud）；variant-36 引用容器除 buildings.sc（71 纹理）外，**buildings_cc.sc（13 纹理）、buildings2.sc（5 纹理）同为 SCTX variant-36 可解**（合计 91 个中 89 个可解；building_bases_0/1.sctx 2 个 data_len 声明超文件大小被拒绝，fail-closed 正确）；多命令合成已支持（blacksmith 5 命令实测）。

**#25 全量渲染与 UI 接入完成（2026-08-06 回写）**：
- 全量渲染 1269 个唯一键 → 成功 1258 / 失败 11；唯一 renderedPath 1258 个，
  全部 PNG 在 Bundle 内可解析（`testBundledURLResolvesRenderableRefsToExistingFiles` 锁定）
- 2026-08-06 重新从真实 `base.apk.1` 递归展开 MovieClip 后，
  `sc/buildings.sc / firespitter_lvl1` 由 1 个 shape 扩展为 37 个 shape 元素，输出完整蓝金炮塔图，
  不再是只有紫色圆球的局部图标。
- missingReason 分布：export_not_found 10（`sc/buildings2.sc` push_trap_lvl1-10_idle 全族）、
  render_failed 1（`sc/buildings_cc.sc` playerhouse_dummy 帧 0 无可渲染 shape 元素；全部 ∈
  ASSET_MISSING_REASONS）
- `UpgradeDisplayRow` 图标列 / `LevelDetailSheet` 逐级行已接入
  （levelVisual 优先、icon 兜底、SF Symbol 最后；缺失角标语义不变）
- 图标优先级按组件区分：`LevelDetailSheet`（逐级行与头部同规则）=
  levelVisual 优先 → icon 兜底；`UpgradeDisplayRow` 行级 = 仅 item.icon
  （行级不承载逐级外观，plan Task 3 决策）
- 数据源注：push_trap_lvl1-10_idle（export_not_found）因 APK export 实际为
  `push_trap_lvlX_idle_0..3` 方向后缀变体、无裸名而失败——失败键全部 fail loud
  标记，不做静默回退（后续如需修复应核对投影层 export 命名来源，超出 #25 范围）

---

## 13. 免责声明与版权（R12）

| # | 契约规则 |
|---|---|
| R12.1 | 所有游戏资产版权归 Supercell 所有；本目录为游戏数据的静态快照，**仅限个人学习/非商业用途**。 |
| R12.2 | 遵循 Supercell Fan Content Policy：非商业使用、**不加免责声明不得分发**；渲染产物 PNG 仅作为应用 Bundle 内部资源随私有分发使用（SwiftPM `.copy("GameCatalog")` 打包），**不单独分发**。 |
| R12.3 | 仓库不提交 APK 与游戏原始资源（`.sc`/`.sctx`/`.zktx` 等）；**渲染产物 PNG 为例外**——为满足 SwiftPM `.copy("GameCatalog")` 打包与 #25 Bundle 读取（Issue #30 验收标准 8），渲染 PNG 可提交入库。当前仓库为 **private**、个人学习/非商业用途，符合 Supercell Fan Content Policy；若仓库转为 public 或对外分发应用，须重新评估（免责声明 + 非商业限制）。 |
