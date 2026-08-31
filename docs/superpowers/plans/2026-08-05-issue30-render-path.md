# Issue #30 渲染路径决策与路径 B 最小渲染链实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 #25 决策渲染路径（reject C / 选 B），并实现路径 B 的最小可复现渲染链：解析 SC2 V6 的 MovieClip→frame→element→shape 引用链，解码 ASTC（KTX 内嵌 + SCTX 外部）纹理，裁切并编码 PNG，产出 4 类固定样本，回写契约文档 R3/R4，证明「可进入 #25」。

**Architecture:** 纯 Python stdlib + ctypes/libzstd（既有依赖例外）。扩展 `Tools/game_catalog/sc2.py`（MovieClip 帧解析、完整 shape 命令/顶点、MatrixBank），新增 `astc.py`（ASTC 4x4/6x6 块级解码，局部解码避免整张 4096×4096 大纹理全解码）、`ktx.py`（KTX/SCTX 容器）、`render.py`（bounds 计算 + 多边形光栅化 + PNG 编码）。生成器入口升级产出 `GameCatalog/18.400.13/icons/<container_key>/<export_key>.png` + manifest 更新；`validate.py` 扩展 PNG 校验；Swift 侧不改契约（仅加 Bundle 读取测试）；回写 `docs/rendered-path-contract.md`。

**Tech Stack:** Python 3 stdlib、pytest + hypothesis、ctypes/libzstd（仅解码 body）、SwiftPM（只读验证 Bundle）。

---

## 已确认的事实与约束（implementer 必须阅读）

### 环境与基线（已实测）
- worktree：`.worktrees/feat-issue30-render-path`，分支 `feat/issue30-render-path`，基于 `origin/main`（含 #29 spike：`sc2.py`/`render_spike.py`/契约文档 R1–R12）
- APK：`/path/to/base.apk`（sha256 `30be1e6b9ee7456e35262c04249b2d5ef20021b5eb795e40d1a1dcfee7300c6f`）
- pytest 基线 297 passed；swift test 366 passed
- libzstd：`/opt/homebrew/lib/libzstd.dylib`
- **路径 C 决策证据（2026-08-05 实测）**：`assets.clashk.ing/manifest.json` 共 2585 资产；catalog 381 个唯一引用 vs CDN 3 种映射策略（精确/去前缀/level 归一化）全部 0 命中 → **reject C，选 B**

### 数据规模（已实测）
- catalog.json：683 item、5479 level 记录、5103 个 icon/levelVisual 引用、**381 个唯一 (container, exportName)**
- ui.sc：exports 3024（100% 指向 MovieClip）、Shapes 4053（id 稀疏 0..23358）、Textures 7 个 set（全部 KTX/ASTC 4x4，4096×4096×5、3050×3514、912×1024）
- buildings.sc：exports 3143（100% MovieClip）、Shapes 18024、Textures 71 个 set（全部 external `.sctx`，ASTC 6x6）

### SC2 V6 结构（来自 /tmp/sc-ref/，参考实现为 partial 支持，**以真实字节对拍为准**）
- `MovieClip { id: ushort; export_name_ref_id: uint; framerate: ubyte; frames_count: ushort; unknown_bool: ubyte; children_ids: [ushort]; children_name_ref_ids: [uint]; children_blending: [ubyte]; frames: [MovieClipFrame]; frame_elements_offset: uint = 0xFFFFFFFF; matrix_bank_index: uint; scaling_grid_index: uint; short_frames: [MovieClipShortFrame] }`
- `MovieClipFrame { used_transform: uint; label_ref_id: uint }`（struct 8 字节，连续排布）
- `MovieClipShortFrame { used_transform: ushort }`（struct 2 字节）
- `Shape { id: ushort; commands: [ShapeDrawBitmapCommand] }`
- `ShapeDrawBitmapCommand { unk1: uint; texture_index: uint; points_count: uint; points_offset: uint }`（struct 16 字节）
- `ShapeDrawBitmapCommandVertex`（12 字节，来自 DataStorage.shapes_bitmap_poins）：`x: float; y: float; u: uint16/0xFFFF; v: uint16/0xFFFF`（Shape.cpp 已对拍）
- `DataStorage { strings: [string]; unk2; unk3; rectangles; movieclips_frame_elements: [ushort]; shapes_bitmap_poins: [ubyte]; matrix_banks: [MatrixBank] }`
- `MatrixBank { matrices: [Matrix2x3]; colors: [ColorTransform]; half_matrices: [HalfMatrix2x3] }`——Matrix2x3 具体布局**未实证**（float32x6 或 half 版），Task 3 实证
- `TextureData { texture_format; pixel_type; width: ushort; height: ushort; data: [ubyte]; external_texture: string }`
- `.sctx` 布局（spike 已实测）：off0 u32 unk；off4 u32 unk；off8 `SCTX` magic；off12 u16 w；off14 u16 h；之后是带 4 字节长度前缀的 flatbuffer（参考 SupercellTexture Header.fbs + read_streaming_data），`pixel_type=208` = ASTC_RGBA8_6x6
- KTX 内嵌（spike 已实测）：magic `\xabKTX 11\xbb`，`glInternalFormat 0x93B0` = GL_COMPRESSED_RGBA_ASTC_4x4_KHR

### 未知项（Task 1/2/3 必须实证，不能猜）
1. **MovieClipFrameElement 布局**（最大未知）：元素从 `DataStorage.movieclips_frame_elements`（[ushort] 缓冲）经 `frame_elements_offset` 偏移访问；元素结构大小与字段（type/element_id/matrix_index/color_transform_index）未实证
2. **Matrix2x3 布局**：float32x6 vs half（u16x6）
3. icon export 的 MovieClip 帧数/首帧语义：取 frame 0 还是全部帧并集
4. 真实 shape 顶点形状：icon 是 4 顶点矩形还是多边形（影响光栅化策略）

### 契约要点（R1–R12，回写时用）
- R2.1 命名：`icons/<container_key>/<export_key>.png`（`sc/ui.sc`→`ui`，去掉 `sc/` 前缀与 `.sc` 后缀；export sanitize：`/`、`\`→`_`，拒绝 `.`/`..`，≤200 字节）
- R2.4 去重：381 个唯一键只渲染一次
- R3（PNG 规格，待实测回写）：尺寸=源纹理尺寸？——**本计划修正**：实际渲染是「shape 顶点屏幕空间 bounds」，尺寸由几何决定（写入契约回写任务）
- R4（字节稳定）：无时间戳、固定 zlib 级别、固定 filter → 重复生成 sha256 一致
- R5 失败语义：`missingReason` 稳定枚举（如 `movieclip_not_parsed`/`astc_unsupported_mode`/`texture_missing` 等），不写空 PNG/伪造路径
- 失败样本负例：validate.py 已实现（R-B 互斥等），扩展 PNG 校验

### 决策（Task 0 正式产出，证据已齐）
- **路径 C reject**：0/381 覆盖率、display_name vs export 名体系不兼容、版本对应未验证、外部依赖不可控
- **路径 B 选中**：公开 schema + C++ 参考 + spike 已打通容器解析；381 唯一键渲染量可控

### 项目约定
- Tools/game_catalog/ 生成管线零第三方运行时依赖（stdlib），仅 ctypes/libzstd 是已批准例外（spike 渲染模块）；新增 astc/ktx/render 模块**必须**纯 stdlib
- 中文注释、类型注解、ruff 兼容
- 一切畸形数据 fail loud（CatalogError），不静默降级
- 测试：pytest + hypothesis；Swift 不改（除测试）

---

## Task 0: 渲染路径决策记录（reject C / 选 B）

**Files:**
- Create: `docs/render-path-decision.md`
- Create: `Tools/tests/test_path_decision.py`（决策文档中引用的覆盖率数字用测试固化？不——覆盖率是外部 CDN 数据，不可进测试；改为在文档中记录实测方法与数字）

- [ ] **Step 1: 写决策文档**（含：候选 3 项 A=C / B=完整 / B'=B 简化；每项依据；投票结论 reject C 选 B；实测数字：381 唯一引用、CDN 2585 资产、3 策略 0 命中；非目标清单）

```markdown
# 渲染路径决策（Issue #30 Task 0）
## 候选与依据
- A 路径 C（ClashKing CDN）：…（0/381 覆盖率证据）
- B 路径 B（仓库内渲染链）：…（spike 已打通容器；381 键可控）
- B' 仅 UI icon 子集 + 建筑 deferred：…（拒绝：建筑/陷阱等级外观是 #25 验收必需，拆分不省成本）
## 投票结论：reject A，选 B
## 复现证据
（记录 /tmp/cdn_coverage.py 方法、数字、日期）
```

- [ ] **Step 2: 提交**

```bash
git add docs/render-path-decision.md
git commit -m "docs: 渲染路径决策——reject ClashKing CDN、选择仓库内渲染链 (Issue #30)"
```

---

## Task 1: MovieClip chunk 解析 + frame element 布局实证

**Files:**
- Modify: `Tools/game_catalog/sc2.py`（新增 MovieClip 解析）
- Create: `Tools/tests/test_movieclips.py`

- [ ] **Step 1: 写探测脚本（临时，不提交）实证 MovieClipFrameElement 布局**

```python
# /tmp/probe_frame_elements.py —— 用 sc2.load_sc + FlatBuffer 读 MovieClips chunk
# 1) 解析 MovieClips flatbuffer：movieclips vector → 每个 MovieClip table
#    slot: id=0, export_name_ref_id=1, framerate=2, frames_count=3, unknown_bool=4,
#    children_ids=5, children_name_ref_ids=6, children_blending=7, frames=8,
#    frame_elements_offset=9, matrix_bank_index=10, scaling_grid_index=11, short_frames=12
# 2) 对 ui.sc 的 icon_unit_barbarian（export→object_id=8397→movieclip 索引 1992）：
#    - frames vector：读出 frames_count、每个 MovieClipFrame{used_transform,label_ref_id}
#    - frame_elements_offset：ushort 数组中的字节偏移？（对拍：offset*2 是否落在缓冲内）
#    - 按候选元素大小 8/12/16 字节解析 frames[0] 的 used_transform 个元素
#    - 每个候选：检查 element 的 element_id 是否命中 Shapes id 集合 / MovieClips id 集合
#    - 输出各候选命中率 → 确定真实布局
# 3) 对 buildings.sc 的 fireplace_lvl1 重复验证
```

预期输出格式（记录到 task 完成报告）：
```
icon_unit_barbarian: frames=1? used_transform=N? layout=12B? type=1? element_id->shape_id=X?
```

- [ ] **Step 2: 写失败测试**（基于实证布局；若布局与预期不同，先写探测结论再写测试）

```python
def test_parse_movieclips_ui_sc():
    sc = load_sc(zipfile.ZipFile(APK).read("assets/sc/ui.sc"))
    mc = sc.movieclip_for_export("icon_unit_barbarian")
    assert mc is not None
    assert len(mc.frames) >= 1
    assert mc.frame_elements(mc.frames[0])  # 返回 [MovieClipFrameElement]
    el = mc.frame_elements(mc.frames[0])[0]
    assert el.element_id in sc.shape_ids  # 实证后确定断言
```

- [ ] **Step 3: 验证失败**（RED）
- [ ] **Step 4: 实现**（sc2.py 扩展：`parse_movieclips()`、`ScFile.movieclip_for_export()`、`MovieClipFrameElement` dataclass、`movieclips_frame_elements` 缓冲读取；需在 `parse_data_storage` 暴露缓冲区——现函数只返回 strings，**需扩展返回结构** `DataStorageInfo{strings, frame_elements_bytes, points_bytes, matrix_banks}`，注意保持现有调用兼容）
- [ ] **Step 5: 验证通过**（GREEN）+ 真实数据冒烟（4 个样本 export 都能解析出 frame elements）
- [ ] **Step 6: 提交**

```bash
git add Tools/game_catalog/sc2.py Tools/tests/test_movieclips.py
git commit -m "feat: MovieClip 帧解析与 frame element 实证 (Issue #30)"
```

---

## Task 2: Shape 命令完整解析 + 顶点读取

**Files:**
- Modify: `Tools/game_catalog/sc2.py`（parse_shapes 返回完整命令；DataStorage 顶点访问）
- Create: `Tools/tests/test_shape_vertices.py`

- [ ] **Step 1: 写失败测试**

```python
def test_shape_vertices_12byte_layout():
    # 合成 DataStorage：构造 2 个顶点 (x,y,u,v)
    # 断言 vertices() 返回 [Vertex(x=1.5, y=-2.0, u=0.5, v=0.25)]
    ...

def test_shape_command_points():
    # 合成 Shapes chunk：shape{id=7, commands:[{texture_index=3, points_count=2, points_offset=0}]}
    # 断言 commands 完整字段
```

- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现**：`parse_shapes` 返回 `dict[int, list[ShapeCommand]]`（dataclass：texture_index/points_count/points_offset）；`ShapeCommand.vertices(storage_points: bytes)` 按 12 字节顶点解析（x/y float LE、u/v u16 LE / 0xFFFF）；修改 `shape_textures()` 保持返回 texture_index 列表（兼容 render_spike.py）
- [ ] **Step 4: 验证通过** + 真实数据冒烟（icon_unit_barbarian 的 shape 命令：顶点数、uv 范围、xy 范围——**实证 icon 是矩形还是多边形**，记录到完成报告）
- [ ] **Step 5: 提交**

```bash
git add Tools/game_catalog/sc2.py Tools/tests/test_shape_vertices.py
git commit -m "feat: Shape 命令完整解析与顶点读取 (Issue #30)"
```

---

## Task 3: MatrixBank 解析（矩阵/颜色变换）

**Files:**
- Modify: `Tools/game_catalog/sc2.py`
- Create: `Tools/tests/test_matrixbank.py`

- [ ] **Step 1: 探测实证 Matrix2x3 布局**（/tmp 脚本）：解析 MatrixBank table（slot0 matrices、slot1 colors、slot2 half_matrices），对真实 ui.sc 数据 dump 前几个 matrix 的原始字节，判断 float32x6（24B）还是 half u16x6（12B）或混合；half_matrix 语义（通常 8.8 定点）
- [ ] **Step 2: 写失败测试**（合成 24B float 矩阵与 12B half 矩阵 fixture）
- [ ] **Step 3: 验证失败**
- [ ] **Step 4: 实现**：`Matrix2x3` dataclass（a,b,c,d,tx,ty）+ `apply(x,y)->(x',y')`；`parse_matrix_banks()`；`MovieClip.matrix(mc_index)` 与 `frame_element.matrix` 解析链
- [ ] **Step 5: 验证通过** + 真实冒烟：icon 元素矩阵类型（单位矩阵？平移？）记录
- [ ] **Step 6: 提交**

```bash
git add Tools/game_catalog/sc2.py Tools/tests/test_matrixbank.py
git commit -m "feat: MatrixBank/Matrix2x3 解析 (Issue #30)"
```

---

## Task 4: ASTC 解码器（块级，纯 stdlib）

**Files:**
- Create: `Tools/game_catalog/astc.py`
- Create: `Tools/tests/test_astc.py`

**说明**：ASTC 块解码（ISO/IEC 23003-3:2017 附录）。纯 Python 实现全部模式成本高，**策略：实现通用框架 + 常见模式（dual-plane 除外的 0–10 号模式），未支持模式抛 `AstcUnsupportedMode`（由生成器转 missingReason）**；4x4 与 6x6 块尺寸。

- [ ] **Step 1: 写失败测试**（合成块，手工可推演）：
  - 恒定颜色块（weight 全 0、端点相等）→ 全部像素同色
  - 简单 weight 块（模式 0，weight 0/1 二分）→ 两色插值
  - 6x6 块边界尺寸
  - BISE 解压单元（trivial 权重 0/1 序列）
  - `AstcUnsupportedMode` 负例
- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现 `astc.py`**：
  - `decode_block(data: bytes, block_w: int, block_h: int) -> list[tuple[int,int,int,int]]`（RGBA8）
  - `decode_region(texture: AstcImage, x0,y0,x1,y1) -> ...`：**局部解码**——只解码 uv bounds 覆盖的块
  - BISE 解压、权重双线性插值、端点解压（UNORM16/LDR）、颜色插值、bit-replication
  - 常量块快速路径
- [ ] **Step 4: 验证通过** + 真实冒烟：解码 ui.sc 纹理 1 个块区域（64×64）输出字节不崩溃、非全零（放到 /tmp 验证）
- [ ] **Step 5: 提交**

```bash
git add Tools/game_catalog/astc.py Tools/tests/test_astc.py
git commit -m "feat: ASTC 块级解码器 (Issue #30)"
```

---

## Task 5: KTX / SCTX 容器解析

**Files:**
- Create: `Tools/game_catalog/ktx.py`
- Create: `Tools/tests/test_ktx.py`

- [ ] **Step 1: 写失败测试**（合成 KTX 头 + SCTX 头 fixture；负例：错误 magic）
- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现**：
  - `parse_ktx(data) -> KtxImage{width,height,internal_format,level0: bytes}`：KTX 1.x 头（12×4B key-value 区 + 3×4B 头字段 + 8×4B 纹理头 + level size + data；注意 4096 对齐到 4 的 padding）
  - `parse_sctx(data) -> SctxImage{width,height,block_w,block_h,level0: bytes}`：spike 已实测布局（off0 u32 unk、off4 u32 unk、off8 SCTX magic、off12 u16 w、off14 u16 h、@20 分布 8/10/4 语义待实证——8 可能是 format/pixel_type，10 可能是 block size，4 是 mip count？**实证后写死**；数据区 = 4B 长度前缀 + flatbuffer（`read_streaming_data` 语义：length + bytes，多流时依次读取）
  - 与 `sc2.TextureData` 对接：texture_format=8 → KTX；external_texture 非空 → 从 APK zip 读 `.sctx` 文件
- [ ] **Step 4: 验证通过** + 真实冒烟：解析 ui.sc set0 的 KTX 数据与 buildings_0.sctx，打印 w/h/format/level0 长度
- [ ] **Step 5: 提交**

```bash
git add Tools/game_catalog/ktx.py Tools/tests/test_ktx.py
git commit -m "feat: KTX/SCTX 纹理容器解析 (Issue #30)"
```

---

## Task 6: 渲染器（bounds + 光栅化 + PNG）

**Files:**
- Create: `Tools/game_catalog/render.py`
- Create: `Tools/tests/test_render.py`

- [ ] **Step 1: 写失败测试**：
  - 合成 shape 顶点（屏幕坐标矩形 + uv 矩形）→ 断言输出 RGBA 像素正确（含 UV 子区域采样、透明背景）
  - bounds 计算：顶点 xy 范围 → 输出尺寸（含负坐标平移）
  - 顶点应用矩阵变换
  - PNG 编码：`encode_png(width, height, rgba) -> bytes`，断言 IHDR/IDAT/IEND、gAMA chunk、RGBA8、确定性（两次编码字节一致）
  - 非矩形多边形（三角形）光栅化
- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现**：
  - `RasterImage` 或纯函数 `rasterize(vertices, texture_pixels, tex_w, tex_h) -> rgba`
  - 光栅化：边缘函数（edge function）填充 + UV 双线性插值（重心坐标）；顶点裁剪
  - `encode_png()`：stdlib zlib，固定 compression=9、无 tIME、加 gAMA chunk（45455）
  - 输出尺寸 = bounds 取整；无 0 尺寸防御
- [ ] **Step 4: 验证通过** + 真实冒烟：对 icon_unit_barbarian 全链路（MovieClip→shape→vertices→texture→PNG）产出 /tmp 样本，人工检查（用 `sips` 或打开）
- [ ] **Step 5: 提交**

```bash
git add Tools/game_catalog/render.py Tools/tests/test_render.py
git commit -m "feat: 渲染器——bounds/光栅化/确定性 PNG 编码 (Issue #30)"
```

---

## Task 7: 生成器集成（4 类样本 → icons/ + manifest）

**Files:**
- Create: `Tools/render_generator.py`（或升级 `Tools/render_spike.py`——**升级现有文件**，保持 spike 报告兼容）
- Modify: `Tools/game_catalog/builders.py`（renderedPath 写回逻辑）
- Create: `Tools/tests/test_render_generator.py`

- [ ] **Step 1: 写失败测试**：
  - 4 类样本（真实 APK，参数化 fixture，标记 slow）：
    1. `sc/ui.sc`/`icon_unit_barbarian`（单位 icon）→ 产出真实 PNG（文件存在、可打开、非空）
    2. `sc/buildings.sc`/`fireplace_lvl1`（建筑等级外观）→ 同上
    3. `sc/buildings.sc`/`blacksmith_lvl1`（跨等级复用，catalog 中多个 level 引用同一 exportName）→ 只渲染一次、manifest 记录一次、多 level 引用同 path
    4. `sc/ui.sc`/`icon_unit_does_not_exist`（缺失引用）→ `missingReason=export_not_found`、无 PNG、无伪造 path
  - 失败样本：不写空 PNG、`missingReason` 稳定
  - 确定性：同一 APK 连续生成两次 → 全部 PNG sha256 一致
  - manifest 条目：path/size/sha256/buildTag 完整
- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现**：`render_generator.py` CLI：`--apk --output --samples`（样本清单支持 4 类）；对每个样本：export→movieclip→frames[0] elements→shape→commands→vertices→matrix→texture(KTX/SCTX)→astc 局部解码→光栅化→PNG（R2.1 命名）；成功写 `icons/<key>.png`、失败写 `missingReason`；**更新 catalog.json 的 renderedPath 与 GameCatalog 目录**（或先输出独立 manifest，Task 8 决策合并方式——**默认：直接更新 bundled catalog.json + icons/ 目录**，因为 #25 需要 bundled 资产）
- [ ] **Step 4: 验证通过**（样本 PNG 存在 + sha256 稳定）+ 人工打开样本核对（视觉验收记录）
- [ ] **Step 5: 提交**

```bash
git add Tools/render_generator.py Tools/game_catalog/builders.py Tools/tests/test_render_generator.py
git commit -m "feat: 渲染生成器与 4 类固定样本 (Issue #30)"
```

---

## Task 8: 校验器扩展（PNG 存在/size/hash + 负例）

**Files:**
- Modify: `Tools/game_catalog/validate.py`
- Modify: `Tools/validate_game_catalog.py`
- Create: `Tools/tests/test_validate_png.py`

- [ ] **Step 1: 写失败测试**：
  - renderedPath 指向不存在文件 → 校验失败
  - PNG size 与 manifest 不符 → 失败
  - PNG sha256 与 manifest 不符 → 失败
  - 成功字段与 missingReason 同时存在 → 失败（已有 R-B 互斥，补 PNG 场景）
  - 错误版本路径（renderedPath 含版本段）→ 失败（已有）
  - 合法样本 → 通过（合成 fixture：真实小 PNG 字节）
- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现**：validate.py 增加 PNG 条目校验（以 catalog 目录为根解析相对路径、重算 size/sha256）；`validate_game_catalog.py` 输出 PNG 检查统计
- [ ] **Step 4: 验证通过** + 对 Task 7 产出的真实目录跑完整校验
- [ ] **Step 5: 提交**

```bash
git add Tools/game_catalog/validate.py Tools/validate_game_catalog.py Tools/tests/test_validate_png.py
git commit -m "feat: renderedPath PNG 校验与负例 (Issue #30)"
```

---

## Task 9: Swift Bundle 读取测试

**Files:**
- Modify: `Tests/COCHelperCoreTests/GameCatalogTests.swift`
- （不修改 Sources/COCHelperCore——契约已冻结）

- [ ] **Step 1: 写失败测试**（若 bundled 目录有 PNG 则断言）：

```swift
func testBundledRenderedIconLoadable() throws {
    let catalog = try XCTUnwrap(GameCatalog.loadBundled())
    let renderable = catalog.items.flatMap { [$0.icon, $0.levelVisual].compactMap { $0 } }
        .filter { $0.isRenderable }
    // 断言至少存在一个 isRenderable（样本 4 类已渲染）
    XCTAssertGreaterThan(renderable.count, 0)
    for ref in renderable.prefix(10) {
        let path = ref.renderedPath!  // 已由 isRenderable 保证非 nil
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: nil, withExtension: nil,
            subdirectory: "GameCatalog/18.400.13/" + (path as NSString).deletingLastPathComponent
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent((path as NSString).lastPathComponent).path))
    }
}
```

- [ ] **Step 2: 验证失败**（bundled 目录当前无 PNG）
- [ ] **Step 3: 通过**（Task 7 产出 PNG 进目录后 → 验证通过）——**本 Task 依赖 Task 7 的产物已提交**；若 PNG 体积过大（>50MB）则改为「测试从 catalog 读取 renderedPath 且目标文件存在于 Bundle 的抽样断言」
- [ ] **Step 4: 验证通过**：`swift test` 全绿 + `swift build`
- [ ] **Step 5: 提交**

```bash
git add Tests/COCHelperCoreTests/GameCatalogTests.swift
git commit -m "test: Swift Bundle 读取 renderedPath PNG 断言 (Issue #30)"
```

---

## Task 10: 契约文档回写（R3/R4 实测 + 决策）

**Files:**
- Modify: `docs/rendered-path-contract.md`
- Create: `docs/render-path-decision.md` 已在 Task 0 创建（此处引用）

- [ ] **Step 1: 回写 R3**：PNG 规格改为实测值——尺寸=shape 顶点屏幕空间 bounds（记录 4 样本的实际输出尺寸）、RGBA8、gAMA/sRGB、无时间戳；删除「待验证」标记
- [ ] **Step 2: 回写 R4**：字节稳定性实测结论（4 样本两次生成 sha256 一致）；记录 ASTC 未支持模式 → missingReason 枚举扩展（如 `astc_unsupported_mode`）
- [ ] **Step 3: 更新 §12**：spike 结论「继续阻塞」→ 本 issue 解锁状态；「可进入 #25」+ 剩余前置（#25 UI 接入清单）
- [ ] **Step 4: 提交**

```bash
git add docs/rendered-path-contract.md
git commit -m "docs: 契约 R3/R4 实测回写与解锁状态 (Issue #30)"
```

---

## Task 11: 全量复跑 + 验收 + PR

- [ ] **Step 1: 完整验证**：

```bash
python3 -m pytest Tools/tests -q          # 期望全绿
swift test                                 # 期望全绿
./scripts/build_app.sh                     # 期望构建成功
```

- [ ] **Step 2: 固定样本复跑**（记录输入指纹、asset key、输出 hash/size、Bundle 读取证据）到 `docs/render-path-decision.md` 或 spike 报告
- [ ] **Step 3: 对照 issue #30 验收清单**逐条确认（10 条）
- [ ] **Step 4: 开 PR**（标题：`feat: 渲染路径决策与最小渲染链——4 类固定样本产出 PNG (Issue #30)`，说明路径决策证据、样本清单、验收对照）

---

## 自查清单（Reflexion，每 Task 完成后）

- [ ] 类型契约：新增 dataclass/签名与计划一致，命名描述性
- [ ] property-based 测试：`Tools/tests/test_property.py` 覆盖新纯函数（命名/sanitize/bounds 计算），hypothesis 策略补充
- [ ] 无第三方依赖新增（stdlib + libzstd 例外）
- [ ] 无 .gitignore 资产泄漏（APK 不提交、/tmp 输出不提交）
- [ ] 失败路径全部 fail loud（CatalogError）或稳定 missingReason
- [ ] ruff/格式符合现有风格（中文注释）
