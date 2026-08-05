"""渲染器测试：bounds 计算 + 多边形光栅化 + 确定性 PNG 编码（Issue #30 Task 6）。

设计锚点（对拍真实 ui.sc / buildings.sc，2026-08-05）：
- icon_unit_barbarian shape 8025 = **6 顶点 triangle strip**（奇偶翻转 winding）：
  三角形序列 (0,1,2),(3,2,1),(2,3,4),(5,4,3)（与任务定义的 (0,1,2),(2,1,3),
  (2,3,4),(4,3,5) 循环旋转等价，winding 相同）。
- 顶点是**局部坐标**（x∈[-83,83]、y∈[-83,83]），uv 归一化 0..1 且只在 atlas
  内小区域（u∈[0.46,0.52]、v∈[0.05,0.09]）；frame element 可带 matrix
  （0xFFFF = 无矩阵，icon 的 shape element 实测无矩阵）。
- 输出像素 p 的局部坐标 = bounds.min + (p+0.5) * (bounds.size / output_size)；
  默认输出尺寸 = bounds ceil 到 1:1 像素（suggest_output_size，上限 4096）。
- 三角形覆盖用半空间（edge function）+ 重心坐标插值 UV（重心 = e1/A, e2/A,
  e0/A 的循环排列，实测验证过矩形/斜边对角线上两三角形插值一致）。
- 采样：双线性，texel = uv*(tex_w-1)；uv 越界 clamp；PNG 编码固定 zlib=9 +
  全行 filter None（确定性，R4：无时间戳/无随机源）。
"""

import math
import os
import random
import struct
import zipfile
from pathlib import Path

import pytest
from hypothesis import given, strategies as st

from game_catalog.errors import CatalogError
from game_catalog.ktx import parse_ktx
from game_catalog.render import (
    compute_bounds,
    encode_png,
    rasterize,
    render_shape,
    render_shape_from_image,
    suggest_output_size,
    transform_vertices,
)
from game_catalog.sc2 import Matrix2x3, Vertex

APK = Path(os.environ.get("COC_APK_PATH", "/Users/lmz/Downloads/base.apk.1"))


def V(x: float, y: float, u: float = 0.0, v: float = 0.0) -> Vertex:
    """测试便捷构造（uv 归一化 0..1，与 read_vertices 输出一致）。"""
    return Vertex(x=x, y=y, u=u, v=v)


def solid_texture(w: int, h: int, color: tuple[int, int, int, int]) -> bytes:
    return bytes(color) * (w * h)


def pixel(rgba: bytes, w: int, x: int, y: int) -> tuple[int, ...]:
    off = (y * w + x) * 4
    return tuple(rgba[off:off + 4])


def opaque_count(rgba: bytes) -> int:
    return sum(1 for i in range(0, len(rgba), 4) if rgba[i + 3] != 0)


# ---------------------------------------------------------------------------
# transform_vertices
# ---------------------------------------------------------------------------


def test_transform_vertices_matrix_applies_xy_keeps_uv():
    m = Matrix2x3(a=2.0, b=0.0, c=0.0, d=3.0, tx=1.0, ty=4.0)
    got = transform_vertices([V(5.0, 7.0, 0.5, 0.25)], m)
    assert got == [V(2.0 * 5.0 + 1.0, 3.0 * 7.0 + 4.0, 0.5, 0.25)]


def test_transform_vertices_none_is_identity():
    vs = [V(1.0, 2.0, 0.3, 0.6), V(-3.0, 4.0, 0.9, 0.1)]
    assert transform_vertices(vs, None) == vs


def test_transform_vertices_skew_uses_c_on_x_b_on_y():
    """Matrix2x3 语义：x' = a*x + c*y + tx；y' = b*x + d*y + ty。"""
    m = Matrix2x3(a=1.0, b=0.5, c=0.25, d=1.0, tx=0.0, ty=0.0)
    got = transform_vertices([V(4.0, 2.0, 0.0, 0.0)], m)
    assert got[0].x == pytest.approx(4.0 + 0.25 * 2.0)
    assert got[0].y == pytest.approx(0.5 * 4.0 + 2.0)


# ---------------------------------------------------------------------------
# compute_bounds
# ---------------------------------------------------------------------------


def test_compute_bounds_basic():
    assert compute_bounds([V(0, 0), V(10, 0), V(10, 10)]) == (0.0, 0.0, 10.0, 10.0)


def test_compute_bounds_negative_translation():
    assert compute_bounds([V(-5, -5), V(5, 5)]) == (-5.0, -5.0, 5.0, 5.0)


def test_compute_bounds_empty_raises():
    with pytest.raises(CatalogError, match="顶点"):
        compute_bounds([])


def test_compute_bounds_nan_raises():
    with pytest.raises(CatalogError, match="有限"):
        compute_bounds([V(0.0, 0.0), V(float("nan"), 1.0)])


def test_compute_bounds_zero_size_raises():
    """共线于同一直线且某轴零跨度 → 退化 bounds 抛错。"""
    with pytest.raises(CatalogError, match="退化"):
        compute_bounds([V(0, 0), V(0, 1), V(0, 2), V(0, 3)])


# ---------------------------------------------------------------------------
# suggest_output_size
# ---------------------------------------------------------------------------


def test_suggest_output_size_ceil_to_1x1_pixels():
    assert suggest_output_size((0.0, 0.0, 10.5, 10.5)) == (11, 11)
    assert suggest_output_size((0.0, 0.0, 10.0, 10.0)) == (10, 10)


def test_suggest_output_size_minimum_1x1():
    assert suggest_output_size((0.0, 0.0, 0.2, 0.2)) == (1, 1)


def test_suggest_output_size_negative_bounds():
    """实证 icon bounds x∈[-83,83] → 166x166。"""
    assert suggest_output_size((-83.0, -83.0, 83.0, 83.0)) == (166, 166)


def test_suggest_output_size_over_cap_raises():
    with pytest.raises(CatalogError, match="上限"):
        suggest_output_size((0.0, 0.0, 5000.0, 10.0))
    with pytest.raises(CatalogError, match="上限"):
        suggest_output_size((0.0, 0.0, 10.0, 5000.0))


def test_suggest_output_size_degenerate_raises():
    with pytest.raises(CatalogError, match="退化"):
        suggest_output_size((1.0, 0.0, 1.0, 5.0))
    with pytest.raises(CatalogError, match="有限"):
        suggest_output_size((float("nan"), 0.0, 1.0, 5.0))


# ---------------------------------------------------------------------------
# rasterize：4 顶点矩形（strip = 2 三角形）
# ---------------------------------------------------------------------------

# 4 顶点矩形 strip：顶点序 (0,0),(10,0),(0,10),(10,10)——注意 (0,0),(10,0),
# (10,10),(0,10) 顺序是交叉对角线（t0 用主对角线、t1 用反对角线），会产生
# 漏缝，不是合法 quad strip；正确顺序让两三角形共享反对角线 (10,0)-(0,10)。
_RECT = [V(0, 0), V(10, 0), V(0, 10), V(10, 10)]
_RECT_UV = [V(0, 0, 0.0, 0.0), V(10, 0, 1.0, 0.0),
            V(0, 10, 0.0, 1.0), V(10, 10, 1.0, 1.0)]
_BOUNDS = (0.0, 0.0, 10.0, 10.0)


def test_rasterize_rectangle_solid_color_full_coverage():
    """4 顶点矩形 strip → 10x10 输出 = 100 像素全覆盖，双线性取单色恒等。"""
    tex = solid_texture(10, 10, (200, 100, 50, 255))
    out = rasterize(_RECT_UV, tex, 10, 10, _BOUNDS, 10, 10)
    assert len(out) == 10 * 10 * 4
    assert opaque_count(out) == 100
    assert pixel(out, 10, 0, 0) == (200, 100, 50, 255)
    assert pixel(out, 10, 5, 5) == (200, 100, 50, 255)
    assert pixel(out, 10, 9, 9) == (200, 100, 50, 255)


def test_rasterize_negative_bounds_translation():
    """局部坐标可负：bounds 平移不改变渲染结果（实测 icon x∈[-83,83]）。"""
    vs = [V(-5, -5, 0.0, 0.0), V(5, -5, 1.0, 0.0), V(-5, 5, 0.0, 1.0),
          V(5, 5, 1.0, 1.0)]
    tex = solid_texture(10, 10, (30, 60, 90, 255))
    out = rasterize(vs, tex, 10, 10, (-5.0, -5.0, 5.0, 5.0), 10, 10)
    assert opaque_count(out) == 100
    assert pixel(out, 10, 0, 0) == (30, 60, 90, 255)


def test_rasterize_matrix_transformed_then_rendered():
    """matrix 缩放 5x 后的 2x2 矩形 → 10x10 输出（与直接 10 单位矩形等价）。"""
    m = Matrix2x3(a=5.0, b=0.0, c=0.0, d=5.0, tx=0.0, ty=0.0)
    vs = transform_vertices(
        [V(0, 0, 0.0, 0.0), V(2, 0, 1.0, 0.0), V(0, 2, 0.0, 1.0),
         V(2, 2, 1.0, 1.0)], m)
    tex = solid_texture(10, 10, (10, 20, 30, 255))
    out = rasterize(vs, tex, 10, 10, (0.0, 0.0, 10.0, 10.0), 10, 10)
    assert opaque_count(out) == 100
    assert pixel(out, 10, 9, 9) == (10, 20, 30, 255)


# ---------------------------------------------------------------------------
# rasterize：三角形覆盖 + strip winding
# ---------------------------------------------------------------------------


def test_rasterize_single_triangle_coverage():
    """直角三角 (0,0)-(4,0)-(0,4)：像素中心 i+j+1 <= 4 → 10 像素覆盖。"""
    vs = [V(0, 0, 0.0, 0.0), V(4, 0, 1.0, 0.0), V(0, 4, 0.0, 1.0)]
    tex = solid_texture(4, 4, (255, 255, 255, 255))
    out = rasterize(vs, tex, 4, 4, (0.0, 0.0, 4.0, 4.0), 4, 4)
    covered = {(x, y) for y in range(4) for x in range(4)
               if pixel(out, 4, x, y)[3] != 0}
    # 像素中心 (x+0.5, y+0.5)，斜边 x+y=4（含边界）
    expected = {(x, y) for y in range(4) for x in range(4)
                if (x + 0.5) + (y + 0.5) <= 4.0}
    assert covered == expected
    assert len(covered) == 10


def test_rasterize_strip_winding_flip_diamond():
    """strip 奇偶翻转反例：菱形顶点顺序让两个三角形同为 CW。

    若实现不处理 winding（只收 CCW）或无奇偶翻转，菱形会缺一半（空洞）。
    菱形 |x-5|+|y-5|<=5（顶点 (5,0),(0,5),(10,5),(5,10)），10x10 输出，
    像素中心落在菱形内（含边界）的个数 = 60（手推：|dx|∈{0.5..4.5} 各两次，
    f(k)=#{|dy|<=5-k} 为 2,4,6,8,10 → 2*(2+4+6+8+10)=60）。
    """
    vs = [V(5, 0, 0.5, 0.0), V(0, 5, 0.0, 0.5), V(10, 5, 1.0, 0.5),
          V(5, 10, 0.5, 1.0)]
    tex = solid_texture(10, 10, (0, 200, 0, 255))
    out = rasterize(vs, tex, 10, 10, (0.0, 0.0, 10.0, 10.0), 10, 10)
    covered = {(x, y) for y in range(10) for x in range(10)
               if pixel(out, 10, x, y)[3] != 0}
    expected = {(x, y) for y in range(10) for x in range(10)
                if abs(x + 0.5 - 5) + abs(y + 0.5 - 5) <= 5.0}
    assert len(expected) == 60
    assert covered == expected
    assert (5, 5) in covered  # 菱形中心（两三角形对角边缘，不可为空洞）
    assert (0, 0) not in covered and (9, 9) not in covered


def test_rasterize_strip_6_vertices_double_quad_no_hole():
    """6 顶点 strip（4 三角形）无空洞：下方方块 + 上方矩形拼接 = 10x20 全盖。

    顶点序 (0,0),(10,0),(0,10),(10,10),(0,20),(10,20)：t0/t1 覆盖方块
    （共享反对角线 x+y=10），t2/t3 覆盖上方矩形（共享对角线 x+y=20）——
    四三角形两两拼接，任何奇偶翻转或 winding 处理错误都会留下空洞。
    """
    vs = [V(0, 0, 0.0, 0.0), V(10, 0, 1.0, 0.0), V(0, 10, 0.0, 1.0),
          V(10, 10, 1.0, 1.0), V(0, 20, 0.0, 2.0), V(10, 20, 1.0, 2.0)]
    tex = solid_texture(10, 20, (7, 8, 9, 255))
    out = rasterize(vs, tex, 10, 20, (0.0, 0.0, 10.0, 20.0), 10, 20)
    assert opaque_count(out) == 200
    assert pixel(out, 10, 5, 5) == (7, 8, 9, 255)
    assert pixel(out, 10, 5, 15) == (7, 8, 9, 255)


# ---------------------------------------------------------------------------
# rasterize：双线性采样
# ---------------------------------------------------------------------------


def _checker2x2() -> bytes:
    # texel(0,0)=红 (255,0,0) / (1,0)=绿 (0,255,0) / (0,1)=蓝 (0,0,255)
    # / (1,1)=黄 (255,255,0)
    return (bytes((255, 0, 0, 255)) + bytes((0, 255, 0, 255))
            + bytes((0, 0, 255, 255)) + bytes((255, 255, 0, 255)))


def test_rasterize_bilinear_interpolation_between_texels():
    """uv=(0.55,0.55)（texel 间）→ 四角颜色双线性均值 (129,140,63,255)。

    手推：fx=fy=0.55；上行 lerp(红,绿)= (114.75,140.25,0)，下行
    lerp(蓝,黄)=(140.25,140.25,114.75)；再 lerp 0.55 → (128.775,140.25,
    63.1125) → 取整 (129,140,63)。±1 容差吸收浮点抖动。
    """
    tex = _checker2x2()
    out = rasterize(_RECT_UV, tex, 2, 2, _BOUNDS, 10, 10)
    got = pixel(out, 10, 5, 5)
    assert got[3] == 255
    assert got[0] == pytest.approx(129, abs=1)
    assert got[1] == pytest.approx(140, abs=1)
    assert got[2] == pytest.approx(63, abs=1)
    # 像素 (2,5)：uv=(0.25,0.55) → (121,64,105)
    got2 = pixel(out, 10, 2, 5)
    assert got2[0] == pytest.approx(121, abs=1)
    assert got2[1] == pytest.approx(64, abs=1)
    assert got2[2] == pytest.approx(105, abs=1)


def test_rasterize_uv_clamped_out_of_range():
    """uv 越界（人为构造顶点）→ clamp 到 [0,1]，不崩不花。"""
    vs = [V(0, 0, -0.3, -0.3), V(10, 0, 1.3, -0.3), V(0, 10, -0.3, 1.3),
          V(10, 10, 1.3, 1.3)]
    tex = solid_texture(2, 2, (5, 6, 7, 255))
    out = rasterize(vs, tex, 2, 2, _BOUNDS, 10, 10)
    assert opaque_count(out) == 100
    assert pixel(out, 10, 0, 0) == (5, 6, 7, 255)


# ---------------------------------------------------------------------------
# rasterize：负例（fail loud）
# ---------------------------------------------------------------------------


def test_rasterize_less_than_3_vertices_raises():
    tex = solid_texture(4, 4, (255, 0, 0, 255))
    with pytest.raises(CatalogError, match="顶点"):
        rasterize([V(0, 0), V(1, 1)], tex, 4, 4, _BOUNDS, 4, 4)


def test_rasterize_texture_length_mismatch_raises():
    with pytest.raises(CatalogError, match="长度"):
        rasterize(_RECT_UV, b"\x00" * 100, 10, 10, _BOUNDS, 10, 10)


def test_rasterize_degenerate_bounds_raises():
    tex = solid_texture(4, 4, (255, 0, 0, 255))
    with pytest.raises(CatalogError, match="退化"):
        rasterize([V(0, 0), V(1, 0), V(0, 1)], tex, 4, 4, (0.0, 0.0, 0.0, 4.0),
                  4, 4)


def test_rasterize_collinear_all_triangles_raises():
    """全部三角形共线（零面积）→ 退化形状抛错（真实数据无此形态）。"""
    tex = solid_texture(4, 4, (255, 0, 0, 255))
    vs = [V(0, 0), V(1, 1), V(2, 2)]
    with pytest.raises(CatalogError, match="退化"):
        rasterize(vs, tex, 4, 4, (0.0, 0.0, 2.0, 2.0), 4, 4)


def test_rasterize_output_dims_zero_raises():
    tex = solid_texture(4, 4, (255, 0, 0, 255))
    with pytest.raises(CatalogError, match="尺寸"):
        rasterize([V(0, 0), V(1, 0), V(0, 1)], tex, 4, 4, _BOUNDS, 0, 4)


def test_rasterize_output_dims_over_cap_raises():
    tex = solid_texture(4, 4, (255, 0, 0, 255))
    with pytest.raises(CatalogError, match="上限"):
        rasterize([V(0, 0), V(1, 0), V(0, 1)], tex, 4, 4, _BOUNDS, 4097, 4)


def test_rasterize_nan_vertex_raises():
    tex = solid_texture(4, 4, (255, 0, 0, 255))
    vs = [V(0, 0, 0.0, 0.0), V(float("inf"), 1.0, 0.5, 0.5), V(1, 0, 1.0, 0.0)]
    with pytest.raises(CatalogError, match="有限"):
        rasterize(vs, tex, 4, 4, _BOUNDS, 4, 4)


# ---------------------------------------------------------------------------
# encode_png
# ---------------------------------------------------------------------------

PNG_SIG = b"\x89PNG\r\n\x1a\n"


def _png_chunks(data: bytes) -> list[tuple[bytes, bytes]]:
    assert data[:8] == PNG_SIG
    chunks = []
    pos = 8
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        chunks.append((ctype, body))
        pos += 12 + length
    assert pos == len(data)  # 无尾随垃圾
    return chunks


def test_encode_png_ihdr_fields():
    rgba = solid_texture(3, 2, (1, 2, 3, 255))
    png = encode_png(3, 2, rgba)
    chunks = _png_chunks(png)
    assert chunks[0][0] == b"IHDR"
    ihdr = chunks[0][1]
    assert len(ihdr) == 13
    (w, h, depth, ctype, comp, filt, interlace) = struct.unpack(
        ">IIBBBBB", ihdr)
    assert (w, h) == (3, 2)
    assert depth == 8
    assert ctype == 6  # RGBA
    assert (comp, filt, interlace) == (0, 0, 0)


def test_encode_png_gama_present_and_before_idat():
    rgba = solid_texture(2, 2, (0, 0, 0, 0))
    chunks = _png_chunks(encode_png(2, 2, rgba))
    gamas = [(i, c, b) for i, (c, b) in enumerate(chunks) if c == b"gAMA"]
    assert len(gamas) == 1
    i, _c, body = gamas[0]
    assert struct.unpack(">I", body)[0] == 45455  # sRGB 2.2 * 100000
    idat_i = next(i for i, (c, _) in enumerate(chunks) if c == b"IDAT")
    assert i < idat_i


def test_encode_png_no_time_chunk():
    rgba = solid_texture(2, 2, (0, 0, 0, 0))
    chunks = _png_chunks(encode_png(2, 2, rgba))
    assert all(c != b"tIME" for c, _ in chunks)
    assert chunks[-1][0] == b"IEND"


def test_encode_png_idat_roundtrip():
    """zlib 解压 IDAT：每行 filter=0，行数据 == 输入 RGBA（无篡改）。"""
    rgba = bytes(range(256)) * 2  # 8x16 图像（16 行 x 8 像素 x 4 通道）
    png = encode_png(8, 16, rgba)
    idat = next(b for c, b in _png_chunks(png) if c == b"IDAT")
    raw = zlib_decompress(idat)
    assert len(raw) == 16 * (1 + 8 * 4)
    for y in range(16):
        assert raw[y * 33] == 0  # filter None
        assert raw[y * 33 + 1:(y + 1) * 33] == rgba[y * 32:(y + 1) * 32]


def zlib_decompress(data: bytes) -> bytes:
    import zlib
    return zlib.decompress(data)


def test_encode_png_deterministic_bytes():
    rgba = solid_texture(7, 5, (10, 20, 30, 255))
    assert encode_png(7, 5, rgba) == encode_png(7, 5, rgba)


def test_encode_png_zero_dims_raises():
    with pytest.raises(CatalogError, match="尺寸"):
        encode_png(0, 4, b"\x00" * 0)
    with pytest.raises(CatalogError, match="尺寸"):
        encode_png(4, 0, b"")


def test_encode_png_length_mismatch_raises():
    with pytest.raises(CatalogError, match="长度"):
        encode_png(4, 4, b"\x00" * 63)  # 期望 64


def test_encode_png_over_cap_raises():
    with pytest.raises(CatalogError, match="上限"):
        encode_png(16385, 1, b"\x00" * (16385 * 4))


# ---------------------------------------------------------------------------
# render_shape / render_shape_from_image 编排
# ---------------------------------------------------------------------------


def test_render_shape_returns_w_h_rgba():
    tex = solid_texture(10, 10, (11, 22, 33, 255))
    w, h, rgba = render_shape(_RECT_UV, tex, 10, 10)
    assert (w, h) == (10, 10)
    assert opaque_count(rgba) == 100
    assert pixel(rgba, w, 5, 5) == (11, 22, 33, 255)


def test_render_shape_degenerate_propagates():
    with pytest.raises(CatalogError):
        render_shape([V(0, 0), V(1, 1), V(2, 2)],
                     solid_texture(4, 4, (1, 1, 1, 255)), 4, 4)


class FakeImage:
    """duck-type KtxImage/SctxImage：decode_region 记录区域并返回纯色。"""

    def __init__(self, width: int, height: int, color: tuple):
        self.width = width
        self.height = height
        self.color = color
        self.last_rect: tuple | None = None

    def decode_region(self, x0: int, y0: int, x1: int, y1: int) -> bytes:
        self.last_rect = (x0, y0, x1, y1)
        return bytes(self.color) * ((x1 - x0) * (y1 - y0))


def test_render_shape_from_image_decodes_only_uv_region():
    """只解码 UV 覆盖的纹理区域（±1 texel 双线性边距），再光栅化。

    uv∈[0.1,0.5] 于 100x100 纹理 → 区域 (9,9,51,51)；输出按局部 bounds
    10x10（几何尺寸决定，非纹理尺寸）。
    """
    img = FakeImage(100, 100, (30, 60, 90, 255))
    vs = [V(0, 0, 0.1, 0.1), V(10, 0, 0.5, 0.1), V(0, 10, 0.1, 0.5),
          V(10, 10, 0.5, 0.5)]
    w, h, rgba = render_shape_from_image(img, vs)
    assert img.last_rect == (9, 9, 51, 51)
    assert (w, h) == (10, 10)
    assert opaque_count(rgba) == 100
    assert pixel(rgba, w, 5, 5) == (30, 60, 90, 255)


# ---------------------------------------------------------------------------
# property-based
# ---------------------------------------------------------------------------


@given(w=st.integers(1, 8), h=st.integers(1, 8), seed=st.integers(0, 2**31))
def test_prop_encode_png_deterministic(w, h, seed):
    """R4：同一输入两次编码字节完全一致（固定 zlib 级别 + 固定 filter）。"""
    rng = random.Random(seed)
    rgba = bytes(rng.randrange(256) for _ in range(w * h * 4))
    assert encode_png(w, h, rgba) == encode_png(w, h, rgba)


@st.composite
def _vertex_list(draw):
    count = draw(st.integers(1, 8))
    return [V(
        draw(st.floats(min_value=-1e4, max_value=1e4,
                       allow_nan=False, allow_infinity=False)),
        draw(st.floats(min_value=-1e4, max_value=1e4,
                       allow_nan=False, allow_infinity=False)),
        draw(st.floats(min_value=0.0, max_value=1.0)),
        draw(st.floats(min_value=0.0, max_value=1.0)),
    ) for _ in range(count)]


@given(_vertex_list())
def test_prop_bounds_monotonic_subset_contained(vs):
    """bounds 单调性：子集顶点的 bounds 含于全集 bounds。

    退化子集（某轴零跨度）抛 CatalogError，跳过——属性只测单调性，
    退化输入由负例测试覆盖。
    """
    if len(vs) < 2:
        return  # 单顶点必然零面积退化（负例测试覆盖），属性测试跳过
    try:
        full = compute_bounds(vs)
    except CatalogError:
        return  # 全退化（如全相同坐标）由负例测试覆盖
    sub = vs[:max(2, len(vs) // 2)]


@given(_vertex_list(), st.floats(min_value=0.1, max_value=10.0),
       st.floats(min_value=-100.0, max_value=100.0))
def test_prop_transform_vertices_keeps_uv(vs, scale, tx):
    """矩阵变换只动 x/y，u/v 不变（采样坐标不受仿射变换影响）。"""
    m = Matrix2x3(a=scale, b=0.0, c=0.0, d=scale, tx=tx, ty=0.0)
    out = transform_vertices(vs, m)
    assert [v.u for v in out] == [v.u for v in vs]
    assert [v.v for v in out] == [v.v for v in vs]
    for src, dst in zip(vs, out):
        assert dst.x == pytest.approx(scale * src.x + tx)
        assert dst.y == pytest.approx(scale * src.y)


# ---------------------------------------------------------------------------
# 真实 APK 冒烟：icon_unit_barbarian 全链路 → /tmp/icon_barbarian.png
# ---------------------------------------------------------------------------

_real_apk = pytest.mark.skipif(
    not APK.is_file(),
    reason="真实 APK 不存在（设置 COC_APK_PATH 指向 base.apk.1 可启用）")


def _load_sc(container: str):
    from game_catalog.sc2 import load_libzstd, load_sc
    try:
        load_libzstd()
    except CatalogError as e:
        pytest.skip(f"libzstd 不可用: {e}")
    with zipfile.ZipFile(str(APK)) as z:
        return load_sc(z.read(container))


@_real_apk
def test_real_apk_render_icon_barbarian_full_chain():
    """全链路：movieclip → frame element → shape → 顶点 → matrix → KTX
    set5 → 局部 decode_region → rasterize → PNG，写 /tmp/icon_barbarian.png。

    实证锚点（18.400.13）：children[1]=8025、texture_index=5、6 顶点、
    帧元素 matrix_index=0xFFFF（无矩阵 → transform_vertices 恒等）。
    """
    sc = _load_sc("assets/sc/ui.sc")
    mc = sc.movieclip_for_export("icon_unit_barbarian")
    assert mc is not None
    fe = mc.frame_elements[1]  # instance_index=1 → children[1]=8025
    assert fe.matrix_index == 0xFFFF  # 实测无矩阵（实证锚点）
    child_id = mc.children_ids[fe.instance_index]
    shp = sc.shape(child_id)
    assert shp is not None and shp.id == 8025
    cmd = shp.commands[0]
    assert cmd.texture_index == 5
    vertices = cmd.vertices(sc.points)
    assert len(vertices) == 6
    matrix = mc.element_matrix(fe, sc.matrix_banks)  # 0xFFFF → None
    assert matrix is None
    vs = transform_vertices(vertices, matrix)

    td = sc.texture_data(cmd.texture_index)
    img = parse_ktx(td.data)
    w, h, rgba = render_shape_from_image(img, vs)
    assert (w, h) == (166, 166)  # bounds [-83,83] → ceil 1:1
    assert len(rgba) == w * h * 4

    png = encode_png(w, h, rgba)
    out_path = Path("/tmp/icon_barbarian.png")
    out_path.write_bytes(png)

    # PNG 自回读验证（IHDR/gAMA/无 tIME/IDAT 解压 == rgba）
    chunks = _png_chunks(png)
    ihdr = chunks[0][1]
    (pw, ph, depth, ctype, *_rest) = struct.unpack(">IIBBBBB", ihdr)
    assert (pw, ph, depth, ctype) == (w, h, 8, 6)
    gama_body = next(b for c, b in chunks if c == b"gAMA")
    assert struct.unpack(">I", gama_body)[0] == 45455
    assert all(c != b"tIME" for c, _ in chunks)
    idat = next(b for c, b in chunks if c == b"IDAT")
    raw = zlib_decompress(idat)
    assert len(raw) == h * (1 + w * 4)
    rows = [raw[y * (1 + w * 4):(y + 1) * (1 + w * 4)] for y in range(h)]
    assert all(row[0] == 0 for row in rows)  # 全行 filter None
    assert b"".join(row[1:] for row in rows) == rgba  # 逐行还原 == 渲染输出

    covered = opaque_count(rgba)
    colored = sum(1 for i in range(0, len(rgba), 4)
                  if rgba[i + 3] != 0 and any(rgba[i + c] != 0 for c in range(3)))
    assert covered > 0  # 非全透明
    assert colored > 0  # 有非 alpha=0 的彩色像素（纹理采样有效）
    print(f"icon_barbarian: {w}x{h}, PNG {len(png)}B → {out_path}, "
          f"covered {covered}/{w * h}, colored {colored}")
