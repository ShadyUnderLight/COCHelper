"""Shape 命令完整解析与顶点读取测试（Issue #30 Task 2）。

实证结论（对拍 ui.sc / buildings.sc 真实字节，2026-08）：
- `ShapeDrawBitmapCommand` 16 字节 struct 连续：unk1 u32@0（**实证恒 0**，
  不保留）/ texture_index u32@4 / points_count u32@8 / points_offset u32@12。
- 顶点 12 字节布局与 sc-workshop Shape.cpp 参考**一致**：
  `x: float LE @0`、`y: float LE @4`、`u: uint16 LE @8`（/ 0xFFFF → 0..1）、
  `v: uint16 LE @10`（/ 0xFFFF → 0..1）。探测早期「u/v 在前」结论为切片
  错位 4 字节的假象：正确切片（DataStorage 带 u32 size 前缀，fb 用 body[4:]）
  下该布局产生全部非退化三角形 strip 且 UV 落在合理范围。
- points_offset 是**顶点索引**（顶点 i 字节偏移 = (offset + i) * 12，Shape.cpp
  一致）；shapes_bitmap_poins 真实大小 ui.sc 559572B（46631 顶点）/
  buildings.sc 1930932B（160911 顶点），两文件均精确 12 字节对齐。
- unk1 全量 34520 条命令（两文件）恒 0 → ShapeCommand 不保留该字段。
- 形状实证（均非 4 顶点矩形）：
  - icon_unit_barbarian 的 shape 8025（children[1]）**6 顶点多边形**：
    x∈[-83,83]、y∈[-83,83]、u∈[0.46,0.52]、v∈[0.05,0.09]
  - fireplace_lvl1 的 shape 1549（children[0]）**8 顶点多边形**：
    x∈[-40,34.8]、y∈[13.6,71.6]、u∈[0.56,0.74]、v∈[0.60,0.78]
"""

import os
import struct
import zipfile
from pathlib import Path

import pytest
from hypothesis import given, strategies as st

from game_catalog.errors import CatalogError
from game_catalog.fbs import FlatBuffer
from game_catalog.sc2 import (
    DataStorageInfo,
    ScFile,
    ScHeader,
    Shape,
    ShapeCommand,
    Vertex,
    parse_data_storage_info,
    parse_shapes,
    read_vertices,
)
from test_fbs import FbBuilder

APK = Path(os.environ.get("COC_APK_PATH", "/Users/lmz/Downloads/base.apk.1"))


# ---------------------------------------------------------------------------
# fixture 构造
# ---------------------------------------------------------------------------


def build_shapes(shapes: list[tuple[int, list[tuple[int, int, int]]]]) -> bytes:
    """Shapes{shapes: [Shape{id u16, commands: [16B struct]}]} flatbuffer。

    shapes: (shape_id, [(texture_index, points_count, points_offset), ...])。
    """
    b = FbBuilder()
    tokens = []
    for shape_id, cmds in shapes:
        fields: dict[int, tuple] = {0: ("u16", shape_id)}
        if cmds:
            raw = b"".join(struct.pack("<4I", 0, ti, cnt, off)
                           for ti, cnt, off in cmds)
            fields[1] = ("uoffset", b.add_raw_vector(len(cmds), raw))
        tokens.append(b.add_table(fields))
    vec = b.add_vector(tokens)
    root = b.add_table({0: ("uoffset", vec)})
    return b.finish(root)


def pack_vertex(x: float, y: float, u: int, v: int) -> bytes:
    """单个 12 字节顶点（实证布局：float x@0 / float y@4 / u16 u@8 / u16 v@10）。"""
    return struct.pack("<ffHH", x, y, u, v)


def build_data_storage_with_points(points: bytes) -> bytes:
    """DataStorage flatbuffer：slot 0 strings + slot 5 shapes_bitmap_poins。"""
    b = FbBuilder()
    sv = b.add_vector([])
    pv = b.add_raw_vector(len(points), points)  # [ubyte] 长度 = 字节数
    root = b.add_table({0: ("uoffset", sv), 5: ("uoffset", pv)})
    return b.finish(root)


def _build_scfile(shapes_payload: bytes, points: bytes = b"") -> ScFile:
    """最小 ScFile（跳过完整 SC 头：直接构造 dataclass）。"""
    header = ScHeader(version=6, descriptor_size=0, shape_count=0,
                      movie_clips_count=0, texture_count=0, text_fields_count=0,
                      resources_offset=0, textures_length=0, compressed_size=0,
                      external_matrix_bank_size=0)
    return ScFile(header=header, metadata=[], strings=[],
                  export_names={}, chunks={"Shapes": shapes_payload},
                  points=points)


# ---------------------------------------------------------------------------
# parse_shapes：完整命令解析
# ---------------------------------------------------------------------------


def test_parse_shapes_full_commands():
    payload = build_shapes([
        (7, [(3, 4, 100), (5, 6, 200)]),
        (42, []),
    ])
    shapes = parse_shapes(payload)
    assert shapes == {
        7: Shape(id=7, commands=[
            ShapeCommand(texture_index=3, points_count=4, points_offset=100),
            ShapeCommand(texture_index=5, points_count=6, points_offset=200),
        ]),
        42: Shape(id=42, commands=[]),
    }


def test_parse_shapes_empty_payload_returns_empty():
    assert parse_shapes(b"") == {}
    b = FbBuilder()
    root = b.add_table({})
    assert parse_shapes(b.finish(root)) == {}


def test_parse_shapes_id_default_zero():
    """shape id 字段缺省 → 0（对拍真实 ui.sc：shape[0] id 缺省）。"""
    b = FbBuilder()
    stbl = b.add_table({})  # 无 id 字段
    vec = b.add_vector([stbl])
    root = b.add_table({0: ("uoffset", vec)})
    shapes = parse_shapes(b.finish(root))
    assert shapes[0] == Shape(id=0, commands=[])


# ---------------------------------------------------------------------------
# read_vertices：12 字节顶点解析 + u/v 归一化
# ---------------------------------------------------------------------------


def test_read_vertices_12byte_layout():
    points = (pack_vertex(1.5, -2.0, 0x8000, 0x4000)
              + pack_vertex(-3.25, 4.5, 0xFFFF, 0x0000))
    vs = read_vertices(points, 0, 2)
    assert vs == [
        Vertex(x=1.5, y=-2.0, u=0x8000 / 0xFFFF, v=0x4000 / 0xFFFF),
        Vertex(x=-3.25, y=4.5, u=1.0, v=0.0),
    ]


def test_read_vertices_uv_boundaries():
    points = pack_vertex(0.0, 0.0, 0, 0xFFFF)
    (v,) = read_vertices(points, 0, 1)
    assert v.u == 0.0
    assert v.v == 1.0  # 0xFFFF / 0xFFFF 精确 1.0


def test_read_vertices_offset_is_vertex_index():
    """points_offset 是顶点索引：顶点 i 字节偏移 = (offset + i) * 12。"""
    pad = pack_vertex(0.0, 0.0, 0, 0)          # 索引 0（被跳过）
    target = pack_vertex(7.5, 8.5, 0x8000, 0x8000)  # 索引 1
    points = pad + target
    (v,) = read_vertices(points, 1, 1)
    assert v == Vertex(x=7.5, y=8.5, u=0x8000 / 0xFFFF, v=0x8000 / 0xFFFF)


def test_shape_command_vertices_method():
    cmd = ShapeCommand(texture_index=0, points_count=2, points_offset=1)
    points = (pack_vertex(0.0, 0.0, 0, 0)      # 索引 0（被跳过）
              + pack_vertex(1.0, 2.0, 0xFFFF, 0xFFFF)   # 索引 1
              + pack_vertex(3.0, 4.0, 0x8000, 0x8000))  # 索引 2
    vs = cmd.vertices(points)
    assert vs == [Vertex(x=1.0, y=2.0, u=1.0, v=1.0),
                  Vertex(x=3.0, y=4.0, u=0x8000 / 0xFFFF, v=0x8000 / 0xFFFF)]


def test_shape_command_vertices_no_points():
    """缓冲为空且 count>0 → CatalogError（不得静默返回空）。"""
    cmd = ShapeCommand(texture_index=0, points_count=1, points_offset=0)
    with pytest.raises(CatalogError, match="越界"):
        cmd.vertices(b"")


# ---------------------------------------------------------------------------
# 负例：fail loud
# ---------------------------------------------------------------------------


def test_read_vertices_count_out_of_bounds():
    points = pack_vertex(0.0, 0.0, 0, 0)  # 只有 1 个顶点
    with pytest.raises(CatalogError, match="越界"):
        read_vertices(points, 0, 2)


def test_read_vertices_offset_out_of_bounds():
    points = pack_vertex(0.0, 0.0, 0, 0) * 2
    with pytest.raises(CatalogError, match="越界"):
        read_vertices(points, 5, 1)  # 起点 60B 越出 24B 缓冲


def test_read_vertices_partial_overlap_raises():
    """起点界内但终点越出缓冲 → CatalogError，不得截断。"""
    points = pack_vertex(0.0, 0.0, 0, 0) * 2  # 24 字节
    with pytest.raises(CatalogError, match="越界"):
        read_vertices(points, 1, 2)  # 需 36B > 24B


def test_read_vertices_count_limit_raises():
    """points_count 超上限 → CatalogError（防 O(n) 顶点物化放大）。"""
    points = pack_vertex(0.0, 0.0, 0, 0)
    with pytest.raises(CatalogError, match="上限"):
        read_vertices(points, 0, 2_000_000)


# ---------------------------------------------------------------------------
# parse_data_storage_info：shapes_bitmap_poins 缓冲
# ---------------------------------------------------------------------------


def test_data_storage_info_returns_points_buffer():
    payload = build_data_storage_with_points(b"\x01\x02\x03\x04")
    info = parse_data_storage_info(FlatBuffer(payload), payload)
    assert info == DataStorageInfo(strings=[],
                                   movieclips_frame_elements=b"",
                                   shapes_bitmap_poins=b"\x01\x02\x03\x04")


def test_data_storage_info_missing_points_returns_empty():
    b = FbBuilder()
    sv = b.add_vector([])
    root = b.add_table({0: ("uoffset", sv)})
    payload = b.finish(root)
    info = parse_data_storage_info(FlatBuffer(payload), payload)
    assert info.shapes_bitmap_poins == b""


def test_data_storage_info_points_over_64mb_raises():
    """points 声明长度超 64MB → CatalogError（只查声明长度，不分配缓冲）。"""
    b = FbBuilder()
    sv = b.add_vector([])
    pv = b.add_raw_vector(64 * 1024 * 1024 + 1, b"")
    root = b.add_table({0: ("uoffset", sv), 5: ("uoffset", pv)})
    payload = b.finish(root)
    with pytest.raises(CatalogError, match="超过上限"):
        parse_data_storage_info(FlatBuffer(payload), payload)


# ---------------------------------------------------------------------------
# ScFile.shape / shape_textures 兼容
# ---------------------------------------------------------------------------


def test_scfile_shape_lazy_and_cached():
    sc = _build_scfile(build_shapes([(7, [(3, 4, 0)])]))
    assert "shapes" not in sc._cache
    s = sc.shape(7)
    assert "shapes" in sc._cache
    assert s == Shape(id=7, commands=[ShapeCommand(3, 4, 0)])
    assert sc.shape(7) is s  # 同一缓存对象（惰性只解析一次）
    assert sc.shape(999) is None  # 非 Shape id → None


def test_shape_textures_returns_texture_index_list():
    """shape_textures 返回 texture_index 列表：list[int] | None（Task 2 前兼容）。"""
    sc = _build_scfile(build_shapes([
        (7, [(3, 4, 100), (5, 6, 200)]),
        (42, []),
    ]))
    assert sc.shape_textures(7) == [3, 5]
    assert sc.shape_textures(42) == []  # 有 Shape 但无命令
    assert sc.shape_textures(999) is None  # 非 Shape id


def test_shape_textures_empty_chunk_returns_none():
    sc = _build_scfile(b"")
    assert sc.shape_textures(1) is None


# ---------------------------------------------------------------------------
# property-based：往返保真 + u/v 归一化单调性
# ---------------------------------------------------------------------------


@st.composite
def _vertex_list(draw):
    """1..8 个顶点；float 用 width=32 保证 float32 打包往返精确。"""
    count = draw(st.integers(1, 8))
    vs = []
    for _ in range(count):
        x = draw(st.floats(min_value=-1e4, max_value=1e4,
                           allow_nan=False, allow_infinity=False, width=32))
        y = draw(st.floats(min_value=-1e4, max_value=1e4,
                           allow_nan=False, allow_infinity=False, width=32))
        u = draw(st.integers(0, 0xFFFF))
        v = draw(st.integers(0, 0xFFFF))
        vs.append((x, y, u, v))
    return vs


@given(_vertex_list())
def test_prop_read_vertices_roundtrip(verts):
    """pack → read_vertices → 逐字段保真（含 u/v 归一化）。"""
    points = b"".join(struct.pack("<ffHH", x, y, u, v) for x, y, u, v in verts)
    got = read_vertices(points, 0, len(verts))
    assert got == [Vertex(x=x, y=y, u=u / 0xFFFF, v=v / 0xFFFF)
                   for x, y, u, v in verts]


@given(st.lists(st.tuples(st.integers(0, 0xFFFF), st.integers(0, 0xFFFF)),
                min_size=2, max_size=128))
def test_prop_uv_normalization_monotonic(pairs):
    """read_vertices 解析后 u/v 归一化保序且落在 [0,1]（覆盖被测代码）。"""
    points = b"".join(struct.pack("<ffHH", 0.0, 0.0, u, v) for u, v in pairs)
    vs = read_vertices(points, 0, len(pairs))
    u_norm = [vert.u for vert in vs]
    v_norm = [vert.v for vert in vs]
    assert all(0.0 <= u <= 1.0 and 0.0 <= v <= 1.0
               for u, v in zip(u_norm, v_norm))
    # 归一化是严格单调映射：raw u16 排序后归一化 == 归一化值排序（保序）
    assert sorted(u_norm) == [u / 0xFFFF for u in sorted(u for u, _ in pairs)]
    assert sorted(v_norm) == [v / 0xFFFF for v in sorted(v for _, v in pairs)]


# ---------------------------------------------------------------------------
# 真实 APK 冒烟（无 APK 或无 libzstd 时跳过）
# ---------------------------------------------------------------------------

_real_apk = pytest.mark.skipif(
    not APK.is_file(),
    reason="真实 APK 不存在（设置 COC_APK_PATH 指向 base.apk.1 可启用）")


def _load_sc(container: str) -> ScFile:
    from game_catalog.sc2 import load_libzstd, load_sc
    try:
        load_libzstd()
    except CatalogError as e:
        pytest.skip(f"libzstd 不可用: {e}")
    with zipfile.ZipFile(str(APK)) as z:
        return load_sc(z.read(container))


def _shape_for_frame_element(sc: ScFile, export: str, fe_index: int) -> Shape:
    """export 的 movieclip 第 fe_index 个 frame element → children id → Shape。"""
    mc = sc.movieclip_for_export(export)
    assert mc is not None
    fe = mc.frame_elements[fe_index]
    child_id = mc.children_ids[fe.instance_index]
    shp = sc.shape(child_id)
    assert shp is not None, (
        f"{export} children[{fe.instance_index}]={child_id} 不在 Shapes")
    return shp


@_real_apk
def test_real_apk_icon_unit_barbarian_shape_vertices():
    """icon 实证：shape=8025（children[1]），6 顶点多边形（非 4 顶点矩形）。

    顶点 x∈[-83,83]、y∈[-83,83]、u∈[0.46,0.52]、v∈[0.05,0.09]
    （实证锚点，18.400.13）。
    """
    sc = _load_sc("assets/sc/ui.sc")
    mc = sc.movieclip_for_export("icon_unit_barbarian")
    assert mc is not None
    assert mc.children_ids == [7753, 8025]  # 0=textfield、1=shape（实证）
    fe = mc.frame_elements[1]  # instance_index=1 → children[1]=8025
    shp = _shape_for_frame_element(sc, "icon_unit_barbarian", 1)
    assert shp.id == 8025
    assert len(shp.commands) == 1
    cmd = shp.commands[0]
    assert cmd.texture_index == 5
    vs = cmd.vertices(sc.points)
    assert len(vs) == 6  # 多边形（6 顶点 strip），非 4 顶点矩形
    xs = [v.x for v in vs]
    ys = [v.y for v in vs]
    assert min(xs) <= -80 and max(xs) >= 80
    assert min(ys) <= -80 and max(ys) >= 80
    assert all(0.0 <= v.u <= 1.0 and 0.0 <= v.v <= 1.0 for v in vs)
    print(f"icon shape {shp.id}: {len(vs)} 顶点 x[{min(xs):.1f},{max(xs):.1f}] "
          f"y[{min(ys):.1f},{max(ys):.1f}] "
          f"u[{min(v.u for v in vs):.4f},{max(v.u for v in vs):.4f}] "
          f"v[{min(v.v for v in vs):.4f},{max(v.v for v in vs):.4f}]")


@_real_apk
def test_real_apk_fireplace_lvl1_shape_vertices():
    """fireplace 实证：shape=1549（children[0]），8 顶点多边形。

    x∈[-40,34.8]、y∈[13.6,71.6]、u∈[0.56,0.74]、v∈[0.60,0.78]
    （实证锚点，18.400.13）。
    """
    sc = _load_sc("assets/sc/buildings.sc")
    mc = sc.movieclip_for_export("fireplace_lvl1")
    assert mc is not None
    assert mc.children_ids == [1549, 1607]  # 0=shape、1=movieclip（实证）
    shp = _shape_for_frame_element(sc, "fireplace_lvl1", 0)
    assert shp.id == 1549
    assert len(shp.commands) == 1
    cmd = shp.commands[0]
    assert cmd.texture_index == 3
    vs = cmd.vertices(sc.points)
    assert len(vs) == 8  # 多边形，非 4 顶点矩形
    xs = [v.x for v in vs]
    ys = [v.y for v in vs]
    assert min(xs) <= -35 and max(xs) >= 30
    assert min(ys) >= 10 and max(ys) >= 70
    assert all(0.0 <= v.u <= 1.0 and 0.0 <= v.v <= 1.0 for v in vs)
    print(f"fireplace shape {shp.id}: {len(vs)} 顶点 x[{min(xs):.1f},{max(xs):.1f}] "
          f"y[{min(ys):.1f},{max(ys):.1f}] "
          f"u[{min(v.u for v in vs):.4f},{max(v.u for v in vs):.4f}] "
          f"v[{min(v.v for v in vs):.4f},{max(v.v for v in vs):.4f}]")


@_real_apk
def test_real_apk_points_buffer_alignment():
    """shapes_bitmap_poins 大小 12 字节对齐（46631 / 160911 顶点）。"""
    for container, expected_vertices in (("assets/sc/ui.sc", 46631),
                                         ("assets/sc/buildings.sc", 160911)):
        sc = _load_sc(container)
        n = len(sc.points)
        assert n % 12 == 0
        assert n // 12 == expected_vertices
        print(f"{container} shapes_bitmap_poins: {n} 字节 = {n // 12} 顶点")
