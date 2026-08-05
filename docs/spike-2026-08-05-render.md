# SC2/Scaleform → PNG 渲染 spike 报告（Issue #27）

> 日期：2026-08-05 ｜ 分支：`issue27-render-spike`
> 输入：`/Users/lmz/Downloads/base.apk.1`（sha256 `30be1e6b…`，与 manifest `sourceFingerprint` 一致）
> 所有数据均来自本分支代码对真实 APK 的运行输出（`Tools/render_spike.py` + 直接解析验证），可复核。
> 契约文档：`docs/rendered-path-contract.md`（R1–R12，本报告引用其条目，不重复正文）。

---

## 1. 结论摘要（TL;DR）

**verdict：继续阻塞 #25**（与契约文档 §12 一致）。

- **一句话原因**：真实数据存在**双重阻塞**——(1) export 的 object_id **全部指向 MovieClip、0 个指向 Shape**，渲染需要 MovieClip→frame→element→shape 引用链解析（本次未实现）；(2) 纹理**全部为压缩格式、无原始 RGBA 像素**（`ui.sc` 内嵌 KTX/ASTC，`buildings.sc` 外部 `.sctx`），需要 ASTC/KTX 解码器。
- **解锁条件（任一）**：实现 MovieClip 帧解析 + ASTC/KTX 解码器；或切换备选路径 C（ClashKing CDN，契约 §11）。
- **契约状态**：渲染无关条目（R1/R2/R5–R12）已冻结；PNG 规格（R3）与字节稳定性（R4）因无真实 PNG 产出标记「待 #25 前验证」。

---

## 2. 输入与指纹

| 项 | 值 |
|---|---|
| APK 路径 | `/Users/lmz/Downloads/base.apk.1` |
| APK sha256 | `30be1e6b9ee7456e35262c04249b2d5ef20021b5eb795e40d1a1dcfee7300c6f` |
| manifest `sourceFingerprint` | `sha256:30be1e6b…`（**一致**，`18.400.13/manifest.json`） |
| gameVersion | `18.400.13` |
| buildTag | `18_400_7` |
| `assets/sc/` 清单 | 共 **543** 个条目（**302** 个 `.sc` + **241** 个 `.sctx`），**无 `traps.sc`**（与 render_spike.py docstring 一致） |
| 全 APK `.sctx` | **599** 个（`assets/sc` 241、`assets/image`、`assets/sc3d`、`assets/ui/sc` 等） |

---

## 3. 解析验证结果（可复现证据）

### 3.1 `ui.sc`（真实运行，`Tools/game_catalog/sc2.py`）

| 项 | 值 | 说明 |
|---|---|---|
| magic / version | `SC` / **6**（V6） | `parse_sc_header` 通过 |
| descriptor_size | **195248** | descriptor 位于 off12 起，**未压缩**（直接 FlatBuffer 解析，root uoffset 0x38）；descriptor 结束 = 12+195248 |
| metadata | **3024** 条（export 名 + **16 字节** hash；全部有条目、无 None/空） | `AssetMetaEntry{name, hash:[ubyte]}`；3024 个 hash 长度全部恰为 16 |
| body 压缩 | 首 4 字节 `28 b5 2f fd` = **zstd magic**，`compressed_size` 字段 55597052 | `decode_body` 经 `ZSTD_findFrameCompressedSize` 裁剪帧后解压（帧后有对齐填充） |
| DataStorage strings | **7127** | 带 4 字节 size 前缀布局（`[u32 size][flatbuffer]`），对拍真实文件 |
| chunks | **6**：ExportNames / TextFields / Shapes / MovieClips / MovieClipModifiers / Textures | 固定顺序 `read_chunks` |
| exports | **3024**（name→object_id） | `export_names`；metadata ∩ exports = **3024/3024（100%）** |
| Shapes | **4053** 个，id 稀疏 0..23358（非索引对齐） | 命令为 16 字节 struct，texture_index 在 +4 偏移 |
| Textures chunk | 载荷 **95551556 B**；Header `textures_length` 字段 **95551560**（= 载荷 + 4 字节 u32 size 前缀，差恰为前缀） | 惰性 data 读取，避免 95MB 整块解引用 |
| TextureSets | **7** 个，全部仅 highres | 见 §5 阻塞 2 |

### 3.2 `buildings.sc`（真实运行）

| 项 | 值 |
|---|---|
| exports / metadata / strings | **3143** / 3143 / 3467；metadata ∩ exports = **3143/3143（100%）** |
| Shapes | **18024** 个 |
| TextureSets | **71** 个，全部 `external_texture`（`.sctx`） |

### 3.3 引用链全量对拍（阻塞 1 的核心证据）

| 容器 | export 名数 | 唯一 object_id | 落在 MovieClip ids | 落在 Shape ids |
|---|---|---|---|---|
| `ui.sc` | 3024 | 3018（6 个 id 被多名共享） | **3018 / 3018（100%）** | **0** |
| `buildings.sc` | 3143 | 3130（13 个共享） | **3130 / 3130（100%）** | **0** |

---

## 4. 4 类样本 verdict 表（真实运行输出）

运行命令：`python3 Tools/render_spike.py --apk /Users/lmz/Downloads/base.apk.1 --output /tmp/coc-spike-report-check`
（本次运行完整输出见下；`spike-report.json` 证据字段可复核）

| 样本（container / exportName） | 类别 | verdict | blocker | 证据（objectId → MovieClip 索引） |
|---|---|---|---|---|
| `sc/ui.sc` / `icon_unit_barbarian` | 单位 icon（真实 ui.sc 导出名） | **blocked** | `no_shape_command` | oid **8397** → MovieClip 索引 **1992** |
| `sc/buildings.sc` / `fireplace_lvl1` | 建筑等级外观（兵营 dataID 1000000 levelVisual） | **blocked** | `no_shape_command` | oid **1635** → MovieClip 索引 **448** |
| `sc/buildings.sc` / `blacksmith_lvl1` | 跨等级复用（铁匠铺 1000070 level1-2 共用） | **blocked** | `no_shape_command` | oid **1652** → MovieClip 索引 **456** |
| `sc/ui.sc` / `icon_spell_rage` | 法术 icon（交叉审核补充，验收 2 闭环） | **blocked** | `no_shape_command` | oid **22584**（MovieClip 命中） |
| `sc/ui.sc` / `icon_unit_does_not_exist` | 失败引用（catalog/APK 均不存在） | **missing** | `export_not_found` | objectId null，exportFound false |
| `sc/traps.sc` / `town_hall_lvl1` | container 不存在（APK 无该文件） | **missing** | `container_not_found` | containerFound false |

运行终端输出（verbatim，交叉审核后 6 样本版本）：

```
[blocked] sc/ui.sc / icon_unit_barbarian — no_shape_command export 的 object_id 不在 Shapes chunk（真实数据中 export 全部指向 MovieClip，需 MovieClip→frame→shape 解析链路）
[blocked] sc/buildings.sc / fireplace_lvl1 — no_shape_command …（同上）
[blocked] sc/buildings.sc / blacksmith_lvl1 — no_shape_command …（同上）
[blocked] sc/ui.sc / icon_spell_rage — no_shape_command …（同上）
[missing] sc/ui.sc / icon_unit_does_not_exist — export_not_found
[missing] sc/traps.sc / town_hall_lvl1 — container_not_found
--- verdict 汇总: {'blocked': 4, 'missing': 2}
写盘: /tmp/coc-spike-report-check/spike-report.json
```

退出码 0（verdict 是数据不是错误）。**6 个样本无一产出 PNG**（`success` 缺失）→ 契约 R3/R4 无法实测（见 §7）。

> **更新说明（交叉审核后）**：初版 5 样本在交叉审核中补入法术 icon 样本（`icon_spell_rage`，
> ui.sc 共 60 个 `icon_spell_*` 导出）形成 6 样本；随后修复了 R-D 结构校验
> （`rendered_path_format_ok`：两级正则 + 拒 `..`/版本段/`%` 编码段）、fail-soft
> 报告契约、zip/vector 资源上限等防御问题。核心结论（双重阻塞、继续阻塞 #25）在
> 6 样本下复跑依然成立。

---

## 5. 双重阻塞证据链

### 阻塞 1：export→object_id 全部指向 MovieClip，无 Shape 命令

- 全量对拍：`ui.sc` 3024 个 export 名、`buildings.sc` 3143 个 export 名解析出的 object_id **100% 落在 MovieClips chunk**（唯一 id 3018 / 3130），**0 个落在 Shapes chunk**（§3.3 表）。
- 含义：`icon_unit_barbarian` 等样本的渲染需 **MovieClip→frame→element→shape 引用链**解析；本次实现仅扫描 MovieClip 的 id 字段（`_movieclip_index`），**未解析帧结构**（`render_spike.py` 与 `sc2.py` docstring 明确标注「MovieClips 完整解析是后续 task」）。
- 对应契约 missingReason 建议值：`movieclip_not_parsed`（契约 §6 表）。

### 阻塞 2：纹理全部压缩，无原始像素

| 容器 | 实测 | 解码需求 |
|---|---|---|
| `ui.sc`（7/7 set） | `texture_format=8`（= `TextureFormat` bit_flags 的 **KhronosTexture** 位，SupercellFlash `Textures.fbs`）；内嵌 **KTX 容器**（magic `\xabKTX 11\xbb…`），`glInternalFormat 0x93B0` = **GL_COMPRESSED_RGBA_ASTC_4x4_KHR**，`glBaseInternalFormat 0x1908` = GL_RGBA，faces=1、mips=1；尺寸 4096×4096×5、3050×3514、912×1024 | KTX 解容器 + **ASTC 4x4** 解码 |
| `buildings.sc`（71/71 set） | `texture_format=0`（无 KhronosTexture 位）+ 全部 `external_texture` `.sctx`；实测 `assets/sc/buildings_0.sctx`：**4 字节长度前缀 + "SCTX" 标识的 flatbuffer**（参考 sc-workshop/SupercellTexture `Header.fbs` + `read_streaming_data`），`pixel_type=208` = **ScPixel::Type ASTC_RGBA8_6x6**、608×1004 | SCTX flatbuffer 解析 + **ASTC 6x6** 解码 |

- 参考 C++ 仅 `texture_format=0(NONE)` 走原始缓冲路径（render_spike.py 判定逻辑），本 APK 两类样本均不满足。
- 对应契约 missingReason 建议值：`texture_compressed_astc` / `texture_external_sctx`（契约 §6 表）。

> **与契约文档表述的偏差记录（如实）**：契约 §6/§11 写「`buildings.sc` … fmt=4（SupercellCompressionFormat=ASTC_RGBA8_4x4）」。实测 `TextureData.texture_format` 对 buildings.sc 全为 0；当前 sc-workshop/SupercellTexture 参考代码中**不存在** `SupercellCompressionFormat` 枚举，ASTC 枚举位于 `ScPixel::Type`（ASTC_RGBA8_4x4 = **204**、ASTC_RGBA8_6x6 = 208）。建议契约文档修订时以 `.sctx` 头 `pixel_type` 为准核对并更新该表述（本次 spike 不擅改已冻结契约正文，仅记录差异）。
> **已修正**（commit `0ae7998`）：契约 §6 `texture_external_sctx` 行与 §12 已改为实测事实（`texture_format=0` + `external_texture` 指向 `.sctx`，pixel_type=208 ASTC 系）。

---

## 6. 已交付物（commit 清单，`git log` 顺序）

| commit | 内容 |
|---|---|
| `36c64f7` | flatbuffer 只读解析器（`Tools/game_catalog/fbs.py`） |
| `8690932` | vtable 越界校验（fbs 防御） |
| `49291f7` | SC2 u32 字段越界与异常契约 |
| `02a5fe2` | SC2 容器头与 Header descriptor 解析（`sc2.py`） |
| `e377bb0` | zstd body 解码与 ExportNames 解析（ctypes+libzstd） |
| `f6479ca` | parse_data_storage 错误链与 n==0 分支测试 |
| `a2081c5` | 渲染 spike CLI 与 4 类样本 verdict（`Tools/render_spike.py`，SAMPLES 定义） |
| `91729a9` | render spike 越界与 0 尺寸 PNG 防御 |
| `1cb93d4` | renderedPath 输出契约（`docs/rendered-path-contract.md`） |
| `1556e54` | renderedPath 负例校验（`validate.py` R-A/R-B/R-C/R-D） |
| `7c7ffe5` | 修复 R-B 互斥检查被 R-D 短路 |
| `7e346d5` | 契约纯函数与 property-based 测试（`contract.py` + `test_render_contract.py`） |

- **测试**：`python3 -m pytest Tools/tests -q` → **297 passed**（交叉审核后实测），含 hypothesis property-based（`is_renderable` 一致性 + R5.2 互斥不变量）。
- **契约规则**：R-A 文件存在 / R-B 互斥（独立轴，不被 R-D 短路）/ R-C manifest 登记 / R-D 格式（`icons/` 前缀 + `.png` 后缀），纯函数 `contract.py:check_rendered_path_contract`。

---

## 7. 未验证项（诚实记录）

| 契约条目 | 内容 | 状态与原因 |
|---|---|---|
| R3（PNG 规格） | 尺寸/alpha/位深/sRGB chunk 语义（R3.1–R3.4） | **未实测**：spike 无 success 样本，无真实 PNG 产出；方法已在契约 §4 给出（IHDR 断言、chunk 遍历、pixel_type 支持表） |
| R4（字节稳定性） | 确定性生成 + manifest sha256 重算（R4.1–R4.3） | **未实测**：同 R3；方法已在契约 §5 给出（同一输入重复生成比对 sha256） |
| pixel_type 1=BGRA8 映射 | 社区惯例，未对拍 | spike 原始路径未触发（render_spike.py docstring 已注明） |

以上均待解锁（§8）后、进入 #25 前按契约回写验证。

---

## 8. 决策与解锁条件

**决策：继续阻塞 #25**（渲染无关契约条目已冻结，渲染相关 R3/R4 待解锁后验证）。

| 路径 | 内容 | 预估工作量（**估算**，非承诺） |
|---|---|---|
| 主路径 B 解锁 | ① MovieClip 帧解析（MovieClips chunk → frame → element → shape 命令）② ASTC 解码器（KTX 内嵌 + `.sctx` 外部，两者共用 ASTC 解码核心）③ sprite 裁剪（Shape 命令 points → 贴图矩形裁剪） | 参考前期调研估算：ASTC 纯 Python 解码 **5–10 人日**、sprite 裁剪 **3–5 人日**；MovieClip 帧解析未单独估算（本次 spike 已完成 chunk 定位与 id 扫描基础）。注：该估算未在仓库/vault 存档可查来源，仅为口径记录 |
| 备选路径 C | ClashKing CDN（`assets.clashk.ing`）构建时下载 webp | 需另行评估；注意 GPL 规避（其代码不并入本仓库）与 Supercell Fan Content Policy 版权声明（契约 §10/§13） |

---

## 9. 依赖与边界

| 项 | 说明 |
|---|---|
| 依赖例外 | spike 渲染模块（`sc2.py` zstd body 解码 + `render_spike.py`）需 **ctypes + libzstd**（brew 本机 `/opt/homebrew/lib/libzstd.dylib` 已确认可加载；候选顺序：`/opt/homebrew/lib` → `/usr/local/lib` → `find_library`；全失败 → `CatalogError` = `zstd_unavailable`）。与纯 stdlib 生成/校验管线**分离**（契约 R9），生成器 `generate_game_catalog.py` 不引入该依赖 |
| 解压保护 | body 解压上限 512MB（`ZSTD_decompressBound` 超限拒绝，防 zip bomb，契约 R9.4） |
| 边界 | spike 输出只进 `/tmp`（本次：`/tmp/coc-spike-report-check/`）；`git ls-files` 无 `.apk/.sc/.sctx/.ktx`，无 spike 产出的 PNG 被跟踪（`Resources/COCHelperAppIcon.png` 为既有 App 图标资产，非 spike 产物）。契约 R12.3 遵守 |
| 可复核性 | 复跑命令：`cd Tools && python3 render_spike.py --apk /Users/lmz/Downloads/base.apk.1 --output /tmp/coc-spike-report-check`；契约测试：`python3 -m pytest Tools/tests -q`（297 passed） |

---

## 附：参考源码（仅引用，未并入仓库）

- sc-workshop/SupercellFlash（MIT）：`sc2_schemas/Header.fbs`、`Textures.fbs`（`TextureFormat : ubyte(bit_flags)`，KhronosTexture=8）、`Shapes.fbs` 等
- sc-workshop/SupercellTexture（MIT）：`sctx_schemas/Header.fbs`（file_identifier `SCTX`，Header.pixel_type 为 ScPixel::Type）、`ScPixel.hpp`（ASTC_RGBA8_4x4=204、ASTC_RGBA8_6x6=208）、`SupercellTexture.cpp read_streaming_data`（`[u32 length][flatbuffer]` 布局）
