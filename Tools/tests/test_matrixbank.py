"""MatrixBank / Matrix2x3 解析与变换测试（Issue #30 Task 3，SC2 渲染链）。

实证结论（对拍真实 base.apk.1 ui.sc / buildings.sc，2026-08-05）：
- `Matrix2x3` = 24 字节 struct 连续：`a,b,c,d,tx,ty` 各 float32 LE
  （a=ScaleX, b=SkewX, c=SkewY, d=ScaleY, tx/ty=平移）。ui.sc bank[0]
  matrix0 原始字节 `0000803f 00000000 00000000 0000803f 0000e441 0000d441`
  = (1.0, 0.0, 0.0, 1.0, 28.5, 26.5)——a≈1、tx 小整数特征确认；两文件
  全量矩阵 stride 均为 24。
- `ColorTransform` = **7 字节** struct 连续（非 8）：r_mul,g_mul,b_mul,
  alpha,r_add,g_add,b_add 各 ubyte；实证 vector 元素间距 = 7。
- `HalfMatrix2x3`（12 字节 6×int16）：schema 声明但**两文件全量恒为空**
  （ui.sc/buildings.sc half 总数均为 0）→ 不解析，见 parse_matrix_banks
  docstring 限制记录。
- `MatrixBank` = DataStorage slot 6 `matrix_banks: [MatrixBank]` 的 table
  vector（4B uoffset）；`MatrixBank{matrices (slot 0), colors (slot 1)}`。
- movieclip.frame element 的 matrix_index 是 **bank 内索引**
  （bank = matrix_banks[movieclip.matrix_bank_index]；0xFFFF = 无矩阵）：
  真实文件 ui.sc 4 banks / buildings.sc 5 banks，全量 340 万+ 帧元素
  矩阵/颜色索引 0 越界；4 样本（icon_unit_barbarian / icon_spell_rage /
  fireplace_lvl1 / blacksmith_lvl1）全部走普通路径（有 frame_elements）。
- 压缩路径（frame_elements_offset=0xFFFFFFFF 但 frames 有元素）：两文件
  movieclips 共 11743 个，**0 个**命中 → 保持 fail-loud，见 parse_movieclips
  docstring。
- 顶点变换：x' = a*x + c*y + tx；y' = b*x + d*y + ty。
"""

import os
import struct
import zipfile
from pathlib import Path

import pytest
from hypothesis import given, strategies as st

from game_catalog.errors import CatalogError
from game_catalog.sc2 import (
    ColorTransform,
    Matrix2x3,
    MatrixBank,
    MovieClip,
    MovieClipFrameElement,
    ScFile,
    ScHeader,
    load_libzstd,
    load_sc,
    parse_matrix_banks,
)
from test_fbs import FbBuilder

APK = Path(os.environ.get("COC_APK_PATH", "/Users/lmz/Downloads/base.apk.1"))


# ---------------------------------------------------------------------------
# fixture 构造：手工拼装 DataStorage flatbuffer（slot 6 = matrix_banks）
# ---------------------------------------------------------------------------


def build_data_storage(banks: list[dict]) -> bytes:
    """DataStorage{ strings: [], matrix_banks: [MatrixBank] } flatbuffer。

    bank dict 键：matrices（6-float 元组列表，24B struct）/ colors（7-int
    列表，7B struct）/ half（6-int 列表，12B struct，仅合成测试验证布局）。
    """
    b = FbBuilder()
    bank_tokens = []
    for bank in banks:
        fields: dict[int, tuple] = {}
        if "matrices" in bank:
            raw = b"".join(struct.pack("<6f", *m) for m in bank["matrices"])
            fields[0] = ("uoffset", b.add_raw_vector(len(bank["matrices"]), raw))
        if "colors" in bank:
            raw = b"".join(struct.pack("<7B", *c) for c in bank["colors"])
            fields[1] = ("uoffset", b.add_raw_vector(len(bank["colors"]), raw))
        if "half" in bank:
            raw = b"".join(struct.pack("<6h", *h) for h in bank["half"])
            fields[2] = ("uoffset", b.add_raw_vector(len(bank["half"]), raw))
        bank_tokens.append(b.add_table(fields))
    mbv = b.add_vector(bank_tokens)
    sv = b.add_vector([])
    root = b.add_table({0: ("uoffset", sv), 6: ("uoffset", mbv)})
    return b.finish(root)


def build_scfile(data_storage: bytes) -> ScFile:
    """最小 ScFile（跳过完整 SC 头：直接构造 dataclass，仅含 DataStorage）。"""
    header = ScHeader(version=6, descriptor_size=0, shape_count=0,
                      movie_clips_count=0, texture_count=0, text_fields_count=0,
                      resources_offset=0, textures_length=0, compressed_size=0,
                      external_matrix_bank_size=0)
    return ScFile(header=header, metadata=[], strings=[], export_names={},
                  chunks={}, data_storage=data_storage)


# ---------------------------------------------------------------------------
# parse_matrix_banks：布局与基础解析
# ---------------------------------------------------------------------------


def test_parse_matrix_banks_single_bank_layout():
    """单 bank：矩阵 24B 连续 6×float32、颜色 7B 连续 7×ubyte。"""
    payload = build_data_storage([{
        "matrices": [(1.0, 0.0, 0.0, 1.0, 28.5, 26.5),
                     (2.0, 0.0, 0.0, 3.0, 5.0, 7.0)],
        "colors": [(113, 151, 31, 255, 33, 90, 0),
                   (156, 26, 51, 255, 90, 33, 0)],
    }])
    banks = parse_matrix_banks(payload)
    assert len(banks) == 1
    assert banks[0] == MatrixBank(
        matrices=[
            Matrix2x3(1.0, 0.0, 0.0, 1.0, 28.5, 26.5),
            Matrix2x3(2.0, 0.0, 0.0, 3.0, 5.0, 7.0),
        ],
        colors=[
            ColorTransform(113, 151, 31, 255, 33, 90, 0),
            ColorTransform(156, 26, 51, 255, 90, 33, 0),
        ])


def test_parse_matrix_banks_multiple_banks_and_missing_fields():
    """多 bank 按序解析；缺省字段 → 空列表；无 matrix_banks 字段 → []。"""
    payload = build_data_storage([
        {"matrices": [(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)]},
        {"colors": [(0, 0, 0, 255, 0, 0, 0)]},
    ])
    banks = parse_matrix_banks(payload)
    assert len(banks) == 2
    assert banks[0].matrices == [Matrix2x3(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)]
    assert banks[0].colors == []
    assert banks[1].matrices == []
    assert len(banks[1].colors) == 1

    # 无 matrix_banks 槽位 → 空列表（parse_shapes 同款 None/空语义）
    b = FbBuilder()
    sv = b.add_vector([])
    root = b.add_table({0: ("uoffset", sv)})
    assert parse_matrix_banks(b.finish(root)) == []


def test_parse_matrix_banks_empty_payload_returns_empty():
    assert parse_matrix_banks(b"") == []


def test_parse_matrix_banks_colors_stride_7_empirical():
    """colors vector 元素间距必须是 7（非 8）——实证对拍真实文件。"""
    payload = build_data_storage([{
        "colors": [(1, 2, 3, 4, 5, 6, 7), (8, 9, 10, 11, 12, 13, 14)],
    }])
    banks = parse_matrix_banks(payload)
    assert banks[0].colors[1] == ColorTransform(8, 9, 10, 11, 12, 13, 14)


def test_parse_matrix_banks_half_field_ignored():
    """half_matrices（slot 2）存在时被忽略，不影响解析。

    实证：ui.sc/buildings.sc 全量 half 恒为空 → 不解析进 API（见
    MatrixBank docstring 限制记录）；合成数据带 half 字段必须静默跳过。
    """
    payload = build_data_storage([{"half": [(-1, 0, 1, 2, -32768, 32767)]}])
    banks = parse_matrix_banks(payload)
    assert banks[0].matrices == []
    assert banks[0].colors == []


def test_parse_matrix_banks_size_prefixed_data_storage():
    """真实布局：DataStorage 前有 [u32 size] 前缀时从 body[4:] 解析。"""
    payload = build_data_storage([{"matrices": [(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)]}])
    body = struct.pack("<I", len(payload)) + payload
    banks = parse_matrix_banks(body[4:])
    assert len(banks) == 1
    assert banks[0].matrices[0].tx == 0.0


# ---------------------------------------------------------------------------
# apply：变换数学
# ---------------------------------------------------------------------------


def test_apply_scale_translate():
    """x' = a*x + c*y + tx；y' = b*x + d*y + ty（缩放 + 平移）。"""
    m = Matrix2x3(2.0, 0.0, 0.0, 3.0, 5.0, 7.0)
    assert m.apply(1.0, 1.0) == (7.0, 10.0)


def test_apply_rotation_90():
    """旋转 90°（标准数学逆时针，(1,0) → (0,1)；y 向下坐标系由调用方决定）。"""
    m = Matrix2x3(0.0, 1.0, -1.0, 0.0, 0.0, 0.0)
    rx, ry = m.apply(1.0, 0.0)
    assert rx == pytest.approx(0.0)
    assert ry == pytest.approx(1.0)


def test_apply_skew_components():
    """b/c 参与交叉项：c 作用于 x'、b 作用于 y'（SkewX/SkewY 语义）。"""
    m = Matrix2x3(1.0, 2.0, 3.0, 4.0, 5.0, 6.0)
    assert m.apply(2.0, 3.0) == (1.0 * 2 + 3.0 * 3 + 5.0,
                                 2.0 * 2 + 4.0 * 3 + 6.0)


def test_apply_pure_translation():
    m = Matrix2x3(1.0, 0.0, 0.0, 1.0, 10.0, 20.0)
    assert m.apply(3.0, 4.0) == (13.0, 24.0)


# ---------------------------------------------------------------------------
# ScFile.matrix_banks / bank_for / MovieClip.element_matrix
# ---------------------------------------------------------------------------


def test_scfile_matrix_banks_lazy_and_cached():
    sc = build_scfile(build_data_storage([{"matrices": [(1.0, 0, 0, 1.0, 0, 0)]}]))
    assert "matrix_banks" not in sc._cache
    b1 = sc.matrix_banks
    assert "matrix_banks" in sc._cache
    assert sc.matrix_banks is b1  # 惰性只解析一次
    assert len(b1) == 1


def test_scfile_bank_for_valid():
    sc = build_scfile(build_data_storage([{"matrices": [(1.0, 0, 0, 1.0, 0, 0)]}]))
    mc = MovieClip(id=1, export_name_ref_id=0, frames=[], frame_elements_offset=0,
                   matrix_bank_index=0, frame_elements=[])
    assert sc.bank_for(mc) is sc.matrix_banks[0]


def test_scfile_bank_for_out_of_range_raises():
    """bank 索引越界 → CatalogError（fail loud：movieclip 引用损坏）。"""
    sc = build_scfile(build_data_storage([{"matrices": [(1.0, 0, 0, 1.0, 0, 0)]}]))
    mc = MovieClip(id=1, export_name_ref_id=0, frames=[], frame_elements_offset=0,
                   matrix_bank_index=3, frame_elements=[])
    with pytest.raises(CatalogError, match="matrix_bank_index"):
        sc.bank_for(mc)


def test_element_matrix_ffff_returns_none():
    """matrix_index=0xFFFF → None（无矩阵的合法状态）。"""
    sc = build_scfile(build_data_storage([{"matrices": [(1.0, 0, 0, 1.0, 0, 0)]}]))
    mc = MovieClip(id=1, export_name_ref_id=0, frames=[], frame_elements_offset=0,
                   matrix_bank_index=0, frame_elements=[])
    elem = MovieClipFrameElement(instance_index=0, matrix_index=0xFFFF,
                                 color_transform_index=0xFFFF)
    assert mc.element_matrix(elem, sc.matrix_banks) is None


def test_element_matrix_valid_returns_matrix():
    sc = build_scfile(build_data_storage([{"matrices": [(1.0, 0, 0, 1.0, 0, 42.0)]}]))
    mc = MovieClip(id=1, export_name_ref_id=0, frames=[], frame_elements_offset=0,
                   matrix_bank_index=0, frame_elements=[])
    elem = MovieClipFrameElement(instance_index=0, matrix_index=0,
                                 color_transform_index=0xFFFF)
    assert mc.element_matrix(elem, sc.matrix_banks) == Matrix2x3(1, 0, 0, 1, 0, 42.0)


def test_element_matrix_index_out_of_range_raises():
    """矩阵索引 ≥ bank 矩阵数 → CatalogError（fail loud）。"""
    sc = build_scfile(build_data_storage([{"matrices": [(1.0, 0, 0, 1.0, 0, 0)]}]))
    mc = MovieClip(id=1, export_name_ref_id=0, frames=[], frame_elements_offset=0,
                   matrix_bank_index=0, frame_elements=[])
    elem = MovieClipFrameElement(instance_index=0, matrix_index=5,
                                 color_transform_index=0xFFFF)
    with pytest.raises(CatalogError, match="矩阵索引"):
        mc.element_matrix(elem, sc.matrix_banks)


def test_element_matrix_bank_out_of_range_raises():
    """bank 越界 → CatalogError（fail loud）。"""
    sc = build_scfile(build_data_storage([{"matrices": [(1.0, 0, 0, 1.0, 0, 0)]}]))
    mc = MovieClip(id=1, export_name_ref_id=0, frames=[], frame_elements_offset=0,
                   matrix_bank_index=9, frame_elements=[])
    elem = MovieClipFrameElement(instance_index=0, matrix_index=0,
                                 color_transform_index=0xFFFF)
    with pytest.raises(CatalogError, match="matrix_bank_index"):
        mc.element_matrix(elem, sc.matrix_banks)


# ---------------------------------------------------------------------------
# 畸形数据：fail loud
# ---------------------------------------------------------------------------


def test_parse_matrix_banks_struct_vector_out_of_bounds_raises():
    """声明 5 个矩阵但数据只有 1 个 → struct vector 越界 CatalogError。"""
    payload = build_data_storage([
        {"matrices": [(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)]}])
    # 把长度字段从 1 改成 5（数据区只有 24B，元素 4 越界）
    data = bytearray(payload)
    root_pos = struct.unpack("<I", data[:4])[0]
    mb_field = root_pos + _slot_rel(data, root_pos, 6)
    mb_vec = mb_field + struct.unpack("<I", data[mb_field:mb_field + 4])[0]
    bank_tbl = mb_vec + 4 + struct.unpack("<I", data[mb_vec + 4:mb_vec + 8])[0]
    m_field = bank_tbl + _slot_rel(data, bank_tbl, 0)
    m_vec = m_field + struct.unpack("<I", data[m_field:m_field + 4])[0]
    data[m_vec:m_vec + 4] = struct.pack("<I", 5)
    with pytest.raises(CatalogError, match="越界|解析失败"):
        parse_matrix_banks(bytes(data))


def test_parse_matrix_banks_matrices_count_limit_raises():
    """矩阵条目数超上限 → CatalogError（防 O(n) 放大）。"""
    payload = bytearray(build_data_storage([{"matrices": [(1.0, 0, 0, 1.0, 0, 0)]}]))
    data = bytes(payload)
    root_pos = struct.unpack("<I", data[:4])[0]
    mb_field = root_pos + _slot_rel(data, root_pos, 6)
    mb_vec = mb_field + struct.unpack("<I", data[mb_field:mb_field + 4])[0]
    bank_tbl = mb_vec + 4 + struct.unpack("<I", data[mb_vec + 4:mb_vec + 8])[0]
    m_field = bank_tbl + _slot_rel(data, bank_tbl, 0)
    m_vec = m_field + struct.unpack("<I", data[m_field:m_field + 4])[0]
    payload[m_vec:m_vec + 4] = struct.pack("<I", 2_000_000)
    with pytest.raises(CatalogError, match="上限"):
        parse_matrix_banks(bytes(payload))


def test_parse_matrix_banks_bank_count_limit_raises():
    """bank 条目数超上限 → CatalogError（防 O(n) 放大）。"""
    payload = bytearray(build_data_storage([{"matrices": [(1.0, 0, 0, 1.0, 0, 0)]}]))
    data = bytes(payload)
    root_pos = struct.unpack("<I", data[:4])[0]
    mb_field = root_pos + _slot_rel(data, root_pos, 6)
    mb_vec = mb_field + struct.unpack("<I", data[mb_field:mb_field + 4])[0]
    payload[mb_vec:mb_vec + 4] = struct.pack("<I", 2_000_000)
    with pytest.raises(CatalogError, match="上限"):
        parse_matrix_banks(bytes(payload))


def _slot_rel(data: bytes, table_off: int, slot: int) -> int:
    """table 的 vtable 中某 slot 的相对偏移（0 = 缺省）。"""
    soffset = struct.unpack("<i", data[table_off:table_off + 4])[0]
    vtable = table_off - soffset
    return struct.unpack(
        "<H", data[vtable + 4 + 2 * slot:vtable + 6 + 2 * slot])[0]


# ---------------------------------------------------------------------------
# property-based：apply 与公式手算一致
# ---------------------------------------------------------------------------


@given(st.floats(-1000, 1000), st.floats(-1000, 1000),
       st.floats(-1000, 1000), st.floats(-1000, 1000),
       st.floats(-10000, 10000), st.floats(-10000, 10000),
       st.floats(-10000, 10000), st.floats(-10000, 10000))
def test_prop_apply_matches_formula(a, b, c, d, tx, ty, x, y):
    """apply 与 x'=a*x+c*y+tx / y'=b*x+d*y+ty 位级一致。"""
    m = Matrix2x3(a, b, c, d, tx, ty)
    assert m.apply(x, y) == (a * x + c * y + tx, b * x + d * y + ty)


@given(st.lists(st.tuples(st.floats(-5, 5), st.floats(-5, 5),
                          st.floats(-5, 5), st.floats(-5, 5),
                          st.floats(-100, 100), st.floats(-100, 100)),
                min_size=1, max_size=8))
def test_prop_parse_roundtrip_matrices(matrices):
    """合成 bank 解析往返：矩阵值保真（float32 存储，approx 容差）。"""
    payload = build_data_storage([{"matrices": matrices}])
    banks = parse_matrix_banks(payload)
    got = [(m.a, m.b, m.c, m.d, m.tx, m.ty) for m in banks[0].matrices]
    assert len(got) == len(matrices)  # 顺序保真
    # 逐元素 approx（pytest.approx 对「list 内 tuple」嵌套比较不可靠；
    # abs 容差覆盖 float64 次正规数在 float32 下溢为 0 的情况，如 5e-324）
    for got_m, exp_m in zip(got, matrices):
        assert pytest.approx(exp_m, rel=1e-6, abs=1e-9) == got_m


# ---------------------------------------------------------------------------
# 真实 APK 冒烟（无 APK 或无 libzstd 时跳过）
# ---------------------------------------------------------------------------

_real_apk = pytest.mark.skipif(
    not APK.is_file(),
    reason="真实 APK 不存在（设置 COC_APK_PATH 指向 base.apk.1 可启用）")


def _load_sc(container: str) -> ScFile:
    try:
        load_libzstd()
    except CatalogError as e:
        pytest.skip(f"libzstd 不可用: {e}")
    with zipfile.ZipFile(str(APK)) as z:
        return load_sc(z.read(container))


@_real_apk
def test_real_apk_ui_banks_and_barbarian_matrix():
    """ui.sc：4 banks；icon_unit_barbarian 元素 0 的矩阵有效且特征合理。"""
    sc = _load_sc("assets/sc/ui.sc")
    banks = sc.matrix_banks
    assert len(banks) == 4
    assert all(len(b.matrices) > 0 for b in banks)
    mc = sc.movieclip_for_export("icon_unit_barbarian")
    assert mc is not None
    assert mc.matrix_bank_index == 0
    m0 = mc.element_matrix(mc.frame_elements[0], banks)
    m1 = mc.element_matrix(mc.frame_elements[1], banks)
    assert m1 is None  # 锚点：元素 1 matrix_index=0xFFFF
    assert m0 is not None
    # 实证锚点：(0.79, 0, 0, 0.869, -81.4, -81.25) —— a≈1、tx 小整数特征
    assert m0.a == pytest.approx(0.7900390625)
    assert m0.b == 0.0
    assert m0.c == 0.0
    assert m0.d == pytest.approx(0.869140625)
    x, y = m0.apply(100.0, 100.0)
    # 手算：x' = 0.7900390625*100 − 81.4 ≈ −2.396；y' = 0.869140625*100 − 81.25
    assert x == pytest.approx(-2.3961, abs=0.001)
    assert y == pytest.approx(5.6641, abs=0.001)
    assert x == x and y == y  # 非 NaN


@_real_apk
def test_real_apk_fireplace_matrix_and_vertex_apply():
    """buildings.sc fireplace_lvl1：矩阵作用于真实 shape 顶点坐标特征。"""
    sc = _load_sc("assets/sc/buildings.sc")
    banks = sc.matrix_banks
    assert len(banks) == 5
    mc = sc.movieclip_for_export("fireplace_lvl1")
    assert mc is not None
    e0 = mc.frame_elements[0]
    m0 = mc.element_matrix(e0, banks)
    assert m0 is not None
    # 锚点：元素 0 矩阵 = (1,0,0,1,0,42) 纯平移；child 1549 是 shape
    assert (m0.a, m0.b, m0.c, m0.d) == (1.0, 0.0, 0.0, 1.0)
    assert m0.ty == pytest.approx(42.0)
    shape = sc.shape(mc.children_ids[e0.instance_index])
    assert shape is not None
    pts = shape.commands[0].vertices(sc.points)
    assert pts
    # 纯平移：apply 后 = 顶点 + (0, 42)；坐标保持有限且不放大
    for v in pts[:8]:
        x, y = m0.apply(v.x, v.y)
        assert x == pytest.approx(v.x + m0.tx)
        assert y == pytest.approx(v.y + m0.ty)
        assert abs(x) < 10000 and abs(y) < 10000


@_real_apk
def test_real_apk_all_samples_matrix_indexes_valid():
    """4 样本全部走普通路径且矩阵索引有效（无 0xFFFF 之外的越界）。"""
    for container, name in (
        ("assets/sc/ui.sc", "icon_spell_rage"),
        ("assets/sc/buildings.sc", "blacksmith_lvl1"),
    ):
        sc = _load_sc(container)
        banks = sc.matrix_banks
        mc = sc.movieclip_for_export(name)
        assert mc is not None
        assert mc.frame_elements  # 普通路径（有元素）
        for e in mc.frame_elements:
            m = mc.element_matrix(e, banks)  # 越界会抛 CatalogError
            assert m is not None or e.matrix_index == 0xFFFF
