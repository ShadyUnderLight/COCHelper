# Issue #27 Render Spike 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for checking.

**Goal:** 验证 COC 18.400.13 APK 的 SC2 V6 Scaleform 资产能否解析并渲染为 PNG，冻结 `renderedPath` 输出契约，为 #25 提供「可进入/继续阻塞」决策。

**Architecture:** 纯 Python 实现 SC2 V6 容器的最小只读解析器（flatbuffer 手写解析 + zstd body 解码 + chunk 序列读取），追踪 4 类固定样本的 export→纹理引用链；渲染无关的契约文档与 validate.py 负例校验独立交付，不依赖 spike 成败。

**Tech Stack:** Python 3 stdlib + ctypes/libzstd（仅 spike 渲染模块需要）、pytest + hypothesis（测试）、Swift 不改。

---

## 背景（已确认证据，implementer 必须阅读）

### 格式事实（已对拍本地 `base.apk.1`）
- APK: `/Users/lmz/Downloads/base.apk.1`（sha256 `30be1e6b9ee7456e35262c04249b2d5ef20021b5eb795e40d1a1dcfee7300c6f`）
- `assets/sc/ui.sc`（55.8MB）文件头：`SC 06 00 | 00 00 00 00 | b0 fa 02 00 | 38 00 00 00`
  - off0-1 `SC` magic；off2-3 version=6 (u16 LE)；off4-7 跳过 4 字节；off8-11 descriptor_size=0x2FAB0=195248 (u32 LE)；off12 起 descriptor flatbuffer（root uoffset=0x38）
  - descriptor 结束 @ 12+195248=0x2FABC，其后 body 首字节 `28 b5 2f fd` = **zstd magic** → body 是 zstd 压缩
- descriptor 内（未压缩）含 metadata 区：字符串 `icon_unit_barbarian` 在 off 0x1A77C（< descriptor 区），前后有长度字段（0x13=19）与 hash 字节
- `sc/ui.sc` 的 export 名（如 `icon_unit_barbarian`）在 0x21E5A6C 被 4 字节小端引用一次
- catalog 引用的 container 全部真实存在：`sc/ui.sc`(3445 引用)、`sc/buildings.sc`(658)、`sc/buildings_cc.sc`(259)、`sc/buildings2.sc`(228)
- `.sctx` 布局（background_icons 等 599 个）：off0 u32 unk；off4 u32 unk；off8 `SCTX` magic；off12 u16 w；off14 u16 h（小尺寸 24x24/20x20 居多）；@20 u16 分布 8/10/4（语义待定）
- `ui.sc` 内嵌 4 个 JPEG 流（背景素材，非 icon 主体）

### SC2 V6 结构（sc-workshop/SupercellFlash 参考，C++）
参考实现：`https://github.com/sc-workshop/SupercellFlash`（MIT），关键文件已拉取到 `/tmp/sc-ref/`：
- `Header.fbs`：`table Header { translation_precision, scale_precision, shape_count, movie_clips_count, texture_count, text_fields_count, unk3, unk4, resources_offset, textures_length, metadata: [AssetMetaEntry{name:string, hash:[ubyte]}], compressed_size, external_matrix_bank_size }`
- 加载流程（`SupercellSWF.cpp:90-160, 205-224`）：
  1. 读 descriptor_size → 读 descriptor flatbuffer → `GetHeader`
  2. 解析 metadata（export 名 + hash 数组）
  3. `compressed = zstd_magic_check(input)`；buffer_size = compressed_size ? compressed_size : 剩余全部；若 compressed_size 或未压缩 → 读 buffer_size 字节（压缩则解压）
  4. external_matrix_bank 从压缩流后剩余 input 读
  5. 解压后 body：开头直接 `GetDataStorage`（flatbuffer，无 size 前缀；含 `strings:[string]`、`shapes_bitmap_poins:[ubyte]`、`matrix_banks:[MatrixBank]` 等）
  6. `stream.seek(resources_offset)`（相对解压后 body 开头）→ 依次 `Table::load_chunk`：ExportNames → TextFields → Shapes → MovieClips → MovieClipModifiers → Textures。每个 chunk = u32 size + flatbuffer bytes
- `ExportName.cpp`：ExportNames flatbuffer 有 `object_ids:[ushort]` + `name_ref_ids:[uint]`，name 通过 `storage->strings()->Get(name_ref_id)` 查 DataStorage.strings；数量相等否则异常
- `Textures.fbs`：`TextureSet{lowres, highres(required)}`；`TextureData{texture_format(bit_flags: Unk1/Unk2/Unk3/KhronosTexture), pixel_type:ubyte, width:ushort, height:ushort, data:[ubyte], external_texture:string}`；external_texture 指向外部 `.zktx/.ktx/.sctx`
- **注意**：C++ 是 "partial V6 support"，若与真实字节对拍不一致，以真实字节为准并记录差异

### 3 候选投票结论（已完成）
- **A（sc_extract Rust）**：排除。仓库已删、仅 SC1/`_tex.sc`、格式不兼容
- **B（自研 Python）**：**主选**。公开 schema + C++ 参考齐全；descriptor 未压缩（export 名可解析）；body zstd 用 ctypes+libzstd.dylib（本机 `/opt/homebrew/lib/libzstd.dylib` 已确认可加载）
- **C（ClashKing assets.clashk.ing）**：备选路径（构建时下载 webp，GPL 规避），不实现；在报告/契约文档中记录

### 仓库约定
- `Tools/game_catalog/` 现有生成管线：**零第三方运行时依赖（Python stdlib）**（README 声明）。本 spike 渲染模块允许例外（ctypes libzstd），但必须在模块 docstring 与契约文档中显式注明；校验器/生成器不引入新依赖
- 测试：pytest + hypothesis（`Tools/tests/`）；Swift 不改、`swift test` 必须仍通过
- 风格：中文注释、类型注解、ruff 兼容（现有代码风格）

---

## Task 1: FlatBuffer 只读解析器

**Files:**
- Create: `Tools/game_catalog/fbs.py`
- Test: `Tools/tests/test_fbs.py`

纯 stdlib 的 flatbuffers 只读访问器（只需要 table/string/vector/uoffset/vtable，不需要写）。

- [ ] **Step 1: 写失败测试**（合成 flatbuffer 字节 fixture，手工构造：一个含 string 字段 + int 字段 + 嵌套 table vector 的 table）

```python
def test_read_table_string_and_scalar():
    # 手工构造最小 flatbuffer: table{vtable, uoffset string, int field}
    # 构造逻辑: vtable 在 data 区后, root = uoffset(4B)
    fb = FlatBuffer(bytes)
    root = fb.root()
    assert fb.string(root.field(0)) == "hello"
    assert fb.uint(root.field(2)) == 42
```

- [ ] **Step 2: 验证失败**：`python3 -m pytest Tools/tests/test_fbs.py -q` → FAIL（ModuleNotFoundError）
- [ ] **Step 3: 实现 `fbs.py`**：`FlatBuffer` 类，方法：`root()`、`table_field(table_off, slot, default=0)`（vtable 解析）、`string(table_off)`、`vector_len(v)`、`vector_elem(v, i, elem_size, alignment)`、`struct_elem`、`uoffset/soffset` 处理。API 对齐 flatbuffers 语义：table = uoffset → vtable = table - soffset(vtable_uoffset at table-4)；slot = vtable + 4 + slot*2 → uoffset 相对 slot 位置
- [ ] **Step 4: 验证通过**：pytest 全绿
- [ ] **Step 5: 提交**

```bash
git add Tools/game_catalog/fbs.py Tools/tests/test_fbs.py
git commit -m "feat: flatbuffer 只读解析器 (Issue #27 spike)"
```

## Task 2: SC2 容器头 + Header descriptor 解析

**Files:**
- Create: `Tools/game_catalog/sc2.py`
- Test: `Tools/tests/test_sc2.py`

- [ ] **Step 1: 写失败测试**（合成 SC 头字节：`SC` + version 6 + 4B zero + descriptor_size + 最小 Header flatbuffer（用 Task 1 的 FlatBuffer 手工构造））

```python
def test_parse_sc_header():
    hdr = parse_sc_header(synthetic_bytes)
    assert hdr.version == 6
    assert hdr.descriptor_size == 195248
    assert hdr.metadata == [("icon_unit_barbarian", b"...16B hash...")]
```

- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现 `sc2.py`**：
  - `SC_HEADER` 常量、`parse_sc_header(data) -> ScHeader`（NamedTuple/dataclass：version, descriptor_size, header_len=12）
  - `Header` table 读取：shape_count/movie_clips_count/texture_count/text_fields_count/resources_offset/textures_length/compressed_size/external_matrix_bank_size/metadata（用 fbs.FlatBuffer）
  - `metadata_entries(fb, header_table_off) -> list[AssetMetaEntry]`（name + hash bytes）
  - 错误处理：magic 不符/descriptor 越界 → `CatalogError`（复用 `Tools/game_catalog/errors.py`）
- [ ] **Step 4: 验证通过**（合成 fixture + 单元测试）
- [ ] **Step 5: 对拍真实 APK**：临时脚本或 `python3 -c` 读 `base.apk.1` 的 `assets/sc/ui.sc`：确认 version=6、descriptor_size=195248、metadata 包含 `icon_unit_barbarian`。把对拍结果记录在 task 完成报告（截图输出粘贴即可）
- [ ] **Step 6: 提交**（`feat: SC2 容器头与 Header descriptor 解析 (Issue #27 spike)`）

## Task 3: zstd body 解码 + DataStorage + ExportNames

**Files:**
- Modify: `Tools/game_catalog/sc2.py`
- Test: `Tools/tests/test_sc2.py`

- [ ] **Step 1: 写失败测试**

```python
def test_body_zstd_roundtrip():
    # 用 libzstd 压缩合成 body，验证 decode_body 还原
    assert decode_body(compressed_bytes, compressed_size) == original
def test_export_names_mapping():
    # 合成 DataStorage(strings) + ExportNames(object_ids, name_ref_ids)
    # 验证 export -> object_id 映射正确，name_ref_ids 越界报错
```

- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现**（追加到 `sc2.py`）：
  - `load_libzstd()`：ctypes.CDLL 依次尝试 `/opt/homebrew/lib/libzstd.dylib`、`/usr/local/lib/libzstd.dylib`、`ctypes.util.find_library("zstd")`；找不到 → `CatalogError`（消息注明：spike 渲染模块需要 libzstd，见契约文档）
  - `decode_body(data, compressed_size) -> bytes`：zstd magic 检测（`28 b5 2f fd`）→ `ZSTD_decompress`（带解压输出上限保护，如 512MB）；未压缩 → 原样
  - `DataStorage` 解析：`strings: [string]`
  - `read_chunks(body, resources_offset)`：从 resources_offset 起依次读 chunk：`u32 size` + `size` 字节 flatbuffer；返回 `{name: bytes}` 字典
  - `parse_export_names(fb, chunk_data, strings) -> list[(name, object_id)]`：object_ids/name_ref_ids 数量相等校验
- [ ] **Step 4: 验证通过**
- [ ] **Step 5: 对拍真实 APK**：解 `ui.sc` body → ExportNames → 验证 `icon_unit_barbarian` 的 object_id 与 0x21E5A6C 处引用一致性（记录结果）。若真实结构对不上 C++ 参考（V6 变体），**记录差异与阻塞点，不强行 hack**；此结果直接影响 Task 4 verdict
- [ ] **Step 6: 提交**（`feat: zstd body 解码与 ExportNames 解析 (Issue #27 spike)`）

## Task 4: 纹理引用追踪 + 4 类样本 verdict

**Files:**
- Create: `Tools/render_spike.py`（CLI）
- Modify: `Tools/game_catalog/sc2.py`（如需要 Shapes/Textures chunk 读取）
- Test: `Tools/tests/test_render_spike.py`

- [ ] **Step 1: 写失败测试**（4 类样本的 verdict 输出格式测试：JSON schema 断言；样本 key 定义）

```python
def test_verdict_report_schema():
    # 对合成 sc 文件运行 render 追踪，输出 report dict 必须含
    # asset_key/container/exportName/status/evidence/blocker 字段
```

- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现** `Tools/render_spike.py`：
  - 固定样本（从 catalog 取真实 asset key）：
    1. 单位 icon：`sc/ui.sc` + `icon_unit_barbarian`
    2. 建筑等级外观：`sc/buildings.sc` + `town_hall_lvl1`（若不存在则从 catalog.json 查一个真实 buildings 的 levelVisual exportName）
    3. 跨等级复用：从 catalog.json 找同一 item 多个 level 的 icon/visual 引用相同 `(container, exportName)` 的样本
    4. 失败引用：catalog 中不存在的 exportName（如 `icon_does_not_exist_xyz`）或 container 不存在（如 `sc/traps.sc`）
  - 追踪链：export → object_id →（先只做 ExportNames 层，若 Task 3 已解出 chunk 序列）→ Shapes/Textures chunk 读取 → TextureData{pixel_type,w,h,data,external_texture}
  - verdict 输出：JSON 报告（每样本：asset_key、status: success/blocked/missing、evidence 字段、blocker 说明）+ 终端人类可读输出
  - 若 data 内嵌原始像素（pixel_type 简单如 RGBA8）且尺寸合理 → 写 PNG（stdlib zlib）到 `--output` 目录并记录 hash/size
  - CLI：`python3 Tools/render_spike.py --apk <path> --output <dir> [--catalog <path>]`
- [ ] **Step 4: 验证通过**（合成样本 + 单元测试；CLI 冒烟：无 APK 时报错清晰）
- [ ] **Step 5: 真实 APK 集成运行**：`python3 Tools/render_spike.py --apk /Users/lmz/Downloads/base.apk.1 --output /tmp/coc-spike-out`；记录 4 类样本 verdict。**结果如实记录**：成功样本 → PNG hash/size；失败/阻塞 → blocker 原因（格式对不上？zstd 失败？pixel_type 不支持？）
- [ ] **Step 6: 提交**（`feat: 渲染 spike CLI 与 4 类样本 verdict (Issue #27)`）

## Task 5: renderedPath 输出契约文档

**Files:**
- Create: `docs/rendered-path-contract.md`

- [ ] **Step 1: 写文档**，内容必须覆盖 issue 验收标准 5 的全部条目：
  - `renderedPath` 相对根：`GameCatalog/<gameVersion>/icons/`（相对版本目录）
  - 命名/去重键：`<gameVersion>/<buildTag>/<container>/<exportName>` → 文件名 `<stable-key>.png`；跨等级复用 → 同一 key 只生成一份，多 level 引用同一路径（去重策略）
  - PNG 规格：尺寸 = 源纹理尺寸（保持像素比例）、透明背景、sRGB、不缩放（除非 spike 证实需要）
  - 字节稳定性：生成必须确定性；若 spike 发现不稳定来源，如实记录
  - 失败语义：`missingReason` 枚举扩展（`sc_parse_failed` / `texture_unsupported` / `zstd_unavailable` 等，按 spike 实际结果定），禁止空 PNG/伪成功
  - `renderedPath` 非空 ⇒ 文件必须真实存在于版本目录与 App Bundle
  - manifest 记录 generated files 的 path/size/SHA-256 + 成功/失败计数
  - 版本隔离：目录按 `gameVersion` 分层，同名资源不互相覆盖
  - `isRenderable` 一致性：Swift 侧语义不变，Python 校验器同规则
  - 依赖声明：spike 渲染模块需要 ctypes/libzstd（本机 brew），与生成目录管线（纯 stdlib）分离
  - 记录 3 候选投票结论与备选路径（ClashKing CDN 构建时下载）作为 fallback
- [ ] **Step 2: 提交**（`docs: renderedPath 输出契约 (Issue #27)`）

## Task 6: validate.py 负例校验（TDD，独立于 spike 成败）

**Files:**
- Modify: `Tools/game_catalog/validate.py`
- Modify: `Tools/game_catalog/__init__.py`（如需要扩展 ASSET_MISSING_REASONS）
- Test: `Tools/tests/test_validate.py`

- [ ] **Step 1: 写失败测试**（负例 fixture 目录，复用现有测试构造方式）：

```python
def test_rendered_path_file_must_exist():
    # catalog 中 icon.renderedPath="icons/barbarian.png" 但文件不存在 → error
def test_rendered_path_with_missing_reason_rejected():
    # renderedPath 非空 且 missingReason 非空 → error
def test_generated_png_hash_and_size():
    # manifest generatedFiles 含 icons/barbarian.png，hash/size 与实际不符 → error
```

- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现**（validate.py 追加规则，向后兼容）：
  - 遍历 item/level 的 icon/levelVisual：`renderedPath 非空 ⇒ 对应文件存在`（相对版本目录 `icons/<path>`）；`renderedPath 非空 && missingReason 非空` → error；`missingReason` 新枚举值加入 `ASSET_MISSING_REASONS` 域
  - 现有 `missingIcons` 计数语义不变（renderedPath is None 计数）
- [ ] **Step 4: 验证通过**（新测试 + 全部旧测试 + 对 bundled 目录跑 `validate_game_catalog.py` 仍通过）
- [ ] **Step 5: 提交**（`feat: renderedPath 负例校验 (Issue #27)`）

## Task 7: spike 报告 + property-based 契约测试 + 全量验证

**Files:**
- Create: `Tools/tests/test_render_contract.py`
- Create: `docs/spike-2026-08-05-render.md`（spike 报告）

- [ ] **Step 1: 写 property-based 契约测试**（hypothesis）：

```python
@given(rendered_path=st.one_of(st.none(), st.text(min_size=1)), missing_reason=st.one_of(st.none(), st.sampled_from(ASSET_MISSING_REASONS)))
def test_is_renderable_consistency(rendered_path, missing_reason):
    # Python 侧契约判定与 Swift isRenderable 语义一致：
    # is_renderable == (rendered_path is not None and missing_reason is None)
    # renderedPath 非空时，校验器必须要求文件存在（负例）
@given(st.lists(st.sampled_from(ASSET_MISSING_REASONS)))
def test_missing_reason_domain_closed(reasons):
    # 任何 catalog 输出中的 missingReason ∈ 枚举域
```

- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现测试使通过**（契约函数若未抽取则抽取到 `Tools/game_catalog/contract.py`：`is_renderable(ref)` + `ASSET_MISSING_REASONS` 域，validate.py 复用）
- [ ] **Step 4: 写 spike 报告** `docs/spike-2026-08-05-render.md`：输入 APK 指纹、4 类样本表（asset key、verdict、证据、阻塞点）、输出 hash/size、契约要点、verdict 结论（「可进入 #25」或「继续阻塞 #25」+ 剩余前置条件）
- [ ] **Step 5: 全量验证**：

```bash
python3 -m pytest Tools/tests -q   # 期望全绿
swift test                          # 期望全绿（Swift 未改动）
python3 Tools/validate_game_catalog.py --catalog Sources/COCHelperCore/GameCatalog/18.400.13  # 期望通过
```

- [ ] **Step 6: 提交**（`docs: spike 报告与契约测试 (Issue #27)`）

## Task 8: README Tools 章节补充（小）

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 在 Tools 章节追加** render_spike 用法一句 + 依赖说明（ctypes libzstd）+ 指向契约文档
- [ ] **Step 2: 提交**（`docs: README 补充 render spike 说明 (Issue #27)`）

---

## 明确不做（scope 边界）

- 不修改 Swift（`UpgradeDisplayRow`/`LevelDetailSheet`/`GameCatalog.swift`）
- 不实现 #25 的 UI 接入、Bundle resolver、真实 PNG 落库
- 不提交任何 APK/游戏原始资产/提取的 PNG 到仓库（spike 输出只进 `/tmp` 或 gitignore）
- 不修改账号 JSON 解码、村庄投影、升级计时语义
- 不接入 ClashKing CDN（只记录备选路径）
- 不强制「必须渲染成功」——Task 3/4 若格式对拍失败，如实记录阻塞点，verdict 按验收标准输出
