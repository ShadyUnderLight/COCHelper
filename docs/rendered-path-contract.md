# renderedPath 输出契约（Issue #27）

> 状态：**契约冻结（渲染相关条目部分待验证）**。
> 本契约冻结 `renderedPath` 的输出规则，使 Python 生成器、manifest 校验器、
> Swift Bundle 加载与 UI 使用遵循同一语义。渲染无关的条目（路径、命名、失败
> 语义、依赖）为强制契约；PNG 规格与字节稳定性因 spike（Task 1-4）未产出真实
> PNG 而标记「待 #25 前验证」，解锁条件见 §12。
>
> 关联：issue #13（生成管线）、#27（spike + 契约）、#25（图标渲染管线 + UI 接入）。
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
| R2.2 | sanitize 规则：替换 `/`、`\` 为 `_`；拒绝空串、`.`、`..`（fail loud）；文件名长度上限 200 字节。 | 生成器负例测试（`../` 注入） |
| R2.3 | 同键恒同路径、不同键恒不同路径：若 sanitize 后不同原始名产生冲突 → 生成器 fail loud，不静默覆盖（真实数据 export 名唯一，冲突即数据异常）。 | 生成器冲突断言 + validate.py 重复条目检查 |
| R2.4 | **去重**：跨 item/level 复用同一 `(container, exportName)` 只渲染一份、manifest 记录一次，多 level 引用同一 `renderedPath`（实证：catalog 铁匠铺 dataID 1000070 level1-2 共用 `blacksmith_lvl1`）。 | manifest PNG 条目数 == 唯一键数；validate.py 断言不同 ref 可共享同一 path |
| R2.5 | **渲染变体区分策略（开放项）**：spike 未发现同键多变体需求（如 lowres/主题色/尺寸变体）。若将来需要，扩展键为 `(container, exportName, variant)`，variant 编码进文件名（如 `<export_key>__<variant>.png`），并 bump schemaVersion——本契约冻结前不允许静默引入变体。 | 无（开放项，记录在案） |

> 注：spike 临时输出（`render_spike.py`）用扁平 `<exportName>.png` 命名，仅 /tmp
> 验证用，**不代表生产契约**；#25 渲染管线必须按 R2.1 命名。

---

## 4. PNG 规格（R3，待 #25 前验证）

| # | 契约规则 | 校验方式 |
|---|---|---|
| R3.1 | 尺寸 = 源纹理尺寸（`TextureData.width/height`），**不缩放、不拉伸、不裁剪**，保持源像素比例。 | PNG IHDR 宽高 == 源纹理宽高断言 |
| R3.2 | 透明背景：RGBA 输出下背景像素 alpha=0，不做背景填充；灰度系按 pixel_type 保留 alpha 语义。pixel_type 映射参考 sc-workshop `SWFTexture.h` PixelFormat：0=RGBA8、6=LUMINANCE8_ALPHA8、10=LUMINANCE8；1=BGRA8 为社区惯例映射（**未对拍验证，spike 原始路径未触发**，进入生产前必须验证或删除）。 | 像素级抽查（alpha 通道）；pixel_type 支持表评审 |
| R3.3 | 位深 8-bit；sRGB 色彩空间，PNG 必须声明（`gAMA` chunk = 45455 或 `sRGB` chunk）；无 `tIME` 等时间戳 chunk（与 R4 联动）。 | PNG chunk 遍历断言 |
| R3.4 | **本条目整体标记「待 #25 前验证」**：spike 未产出真实 PNG（全部 blocked，见 §11），以上规格基于 stdlib 编码器现状 + PNG 规范推演，未用真实渲染图实测。解锁后须以真实渲染图核对尺寸语义、字节序、alpha 语义，并回写本契约。 | 见 §11 解锁条件；核对后更新本文档 |

---

## 5. 字节稳定性（R4，待验证）

| # | 契约规则 | 校验方式 |
|---|---|---|
| R4.1 | 生成**必须确定性**：同一 APK + 同一参数 → 字节完全一致。约束：无时间戳、固定 zlib 压缩级别、固定 filter 策略、无随机源。现有生成管线已承诺确定性（README：无时间戳，重复生成字节一致），PNG 编码继承该约定。 | 同一输入连续生成两次，`sha256` 比对必须一致 |
| R4.2 | manifest 记录的 `sha256/size` 与文件实际值一致（validate.py 已有重算机制，对 PNG 条目同样生效）。 | `validate_game_catalog.py` 重算比对 |
| R4.3 | **本条目标记「待验证」**：spike 未产出真实 PNG，无法实测编码器确定性。验证方法：解锁后对真实纹理重复生成 ≥2 次，比对 sha256 与 manifest 声明；若出现不稳定来源（如解压器非确定性输出），如实记录并修正编码器，不得放宽契约。 | 见 R4.1 的比对脚本 |

---

## 6. 失败语义（R5）

| # | 契约规则 | 校验方式 |
|---|---|---|
| R5.1 | 失败必须设置 `missingReason`（枚举域，见下表），`renderedPath` 为 null。**禁止空 PNG / 伪成功路径**：0×0 尺寸、数据长度不符、无内嵌数据、解析异常 → 一律 blocked + missingReason，绝不写占位/空文件（spike 已按此实现防御分支）。 | 生成器负例测试（0×0、长度不符 fixture） |
| R5.2 | **互斥不变量**：`renderedPath` 非空（含空串，见 R8.1）⇒ `missingReason` 为 null（`missingReason` 按 `is not None` 判定，空串也是失败原因）；`renderedPath` 为 null ⇒ 渲染失败类引用必须给 `missingReason`（不留空解释）。**空串 `renderedPath` 是非法路径**：不得绕过校验（P1-2），校验器报格式非法。 | validate.py 负例 + property-based 测试（含空串边界） |
| R5.3 | `renderedPath` 非空 ⇒ 文件必须真实存在于版本目录与 App Bundle。 | validate.py `rendered_path_file_must_exist`（含格式/`..`/版本段拒绝）；Swift 加载路径检查（#25 UI 接入时落实，当前 loadBundled 只解码 catalog.json） |

**missingReason 枚举扩展建议**（现有 `ASSET_MISSING_REASONS` = `icons_not_rendered` / `no_icon_columns` / `no_visual_columns`）：

| 建议值 | 语义 | 触发（spike 实证） |
|---|---|---|
| `sc_parse_failed` | SC2 容器解析失败（magic/version/descriptor/chunk 越界等） | `CatalogError` 路径 |
| `movieclip_not_parsed` | export→object_id 指向 MovieClip，MovieClip 帧解析链路未实现 | **真实数据中 export 全部指向 MovieClip**（spike `no_shape_command` 阻塞） |
| `texture_compressed_astc` | 内嵌 KTX/ASTC 压缩纹理，无解码器 | `ui.sc` 全部 7 个 TextureSet：fmt=8 内嵌 KTX（ASTC 系） |
| `texture_external_sctx` | 纹理存外部 `.sctx` 文件，无解码器 | `buildings.sc` 71 个 set 全部 external（599 个 .sctx；实测 `texture_format`=0 + `external_texture` 非空；`.sctx` 的 pixel_type=208，社区枚举为 ASTC 系，**待验证**） |
| `zstd_unavailable` | libzstd 无法加载（ctypes 全路径失败） | `load_libzstd` 失败 |
| `texture_unsupported` | pixel_type 不支持 / 畸形数据（0×0、长度不符、无数据、BGRA 未验证） | spike 防御分支 |

> `icons_not_rendered`（#13 现状）保留；渲染管线接入后由上述具体原因替换。
> 上表命名由 Task 6 实现时定稿，本契约冻结**语义**（触发条件 + 所属域 `ASSET_MISSING_REASONS`）。

---

## 7. manifest 记录（R6）

| # | 契约规则 | 校验方式 |
|---|---|---|
| R6.1 | `generatedFiles` 为每张 PNG 追加条目：`path`（相对版本目录）、`size`、`sha256`（`"sha256:" + 64 hex` 前缀格式，与现有 catalog.json 条目一致）；`icons/` 目录条目保留（`kind: "directory"`，`entries` 可填 PNG 数）。 | validate.py 重算 hash/size 比对 |
| R6.2 | `counts` 扩展建议（命名建议，Task 6 实现定稿）：`renderedIcons`（渲染成功且落盘的 PNG 数，**必须 == generatedFiles 中 PNG 条目数**）与 `blockedIcons`（渲染失败/阻塞的引用键数）；新增字段为 optional（`Int?`，旧 manifest 兼容，不 bump schemaVersion）。 | **待 #25 渲染管线接入后落实**（validate.py 断言 `renderedIcons == PNG 条目数` 并可重算）；当前无渲染产物，校验器不实现 |
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
| C：ClashKing CDN（assets.clashk.ing） | **备选 fallback** | 构建时下载 webp；注意 GPL 规避（其代码不并入本仓库）与 Supercell Fan Content Policy 版权声明（§13） |

决策：主路径 B；C 仅在 B 解锁失败或成本失控时启用（需另行评估与声明，不在本 Issue 实现）。

---

## 12. spike 结论与 #25 决策（R11，记录）

**spike 已证实（18.400.13，`base.apk.1`）**：
- ✅ 可解析：SC2 V6 头/descriptor/export 名（`ui.sc` exports=3024）/引用链（Shapes 4053 个、id 稀疏 0..23358；Textures 7 个 set）
- ❌ **双重阻塞**（渲染 PNG）：
  1. **export→object_id 全部指向 MovieClip**：真实数据中 export 无对应 Shape 命令，需 MovieClip→frame→shape 解析链路（当前只扫描 MovieClip id，未解析帧结构）；
  2. **纹理无原始 RGBA**：`ui.sc` 全部 7 个 set 的 `texture_format`=8（内嵌 KTX，ASTC 系）；`buildings.sc` 71 个 set 全部 `texture_format`=0 + `external_texture` 指向 `.sctx`（`.sctx` 的 pixel_type=208，社区枚举为 ASTC 系）。无原始像素可直写 PNG。

**verdict：继续阻塞 #25**（渲染相关契约条目 R3/R4 无法实测；渲染无关条目已冻结）。

**解锁条件（任一）**：
1. 实现 MovieClip 帧解析（MovieClips chunk → frame → shape 命令）+ ASTC 解码器（KTX 内嵌 + `.sctx` 外部）；
2. 切换备选路径 C（ClashKing CDN webp，见 §11）。

解锁后、#25 前必须：实测 R3（PNG 规格）与 R4（字节稳定性），回写本文档，再进入 #25 实现。

---

## 13. 免责声明与版权（R12）

| # | 契约规则 |
|---|---|
| R12.1 | 所有游戏资产版权归 Supercell 所有；本目录为游戏数据的静态快照，**仅限个人学习/非商业用途**。 |
| R12.2 | 遵循 Supercell Fan Content Policy：非商业使用、**不加免责声明不得分发**；渲染产物 PNG 不得单独分发。 |
| R12.3 | 仓库不提交任何 APK/游戏原始资产/提取的 PNG（spike 输出只进 `/tmp` 或 gitignore，plan scope 边界）。 |
