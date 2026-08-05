"""渲染器：bounds 计算 + 多边形光栅化 + 确定性 PNG 编码（纯 stdlib）。

Issue #30 Task 6。对拍真实 ui.sc / buildings.sc（2026-08-05 实证）：

- Shape 顶点是**局部坐标**（icon_unit_barbarian shape 8025：x∈[-83,83]、
  y∈[-83,83]），uv 归一化 0..1 且只在 atlas 内小区域（u∈[0.46,0.52]、
  v∈[0.05,0.09]）；frame element 可带 matrix（0xFFFF = 无矩阵，该 icon
  的 shape element 实测无矩阵）。
- shape 是 **triangle strip**（6/8 顶点，奇偶翻转 winding）：三角形序列
  (0,1,2),(3,2,1),(2,3,4),(5,4,3)…（与 (0,1,2),(2,1,3),(2,3,4),(4,3,5)
  循环旋转等价，winding 相同）。
- 输出映射：像素 p(x,y) 的局部坐标 = bounds.min + (p+0.5) * (bounds.size /
  output_size)；默认输出尺寸 = bounds ceil 到 1:1 像素（suggest_output_size，
  上限 4096 防放大，越界抛错）。
- 覆盖判定：半空间（edge function），**winding 无关**（全部 >=0 或全部
  <=0 均视为内部）——strip 奇偶翻转后三角形可能是 CW 也可能是 CCW，
  实现必须同时接受两种取向（菱形反例：错误实现会缺一半产生空洞）。
- UV 插值：重心坐标 λ0=e1/A、λ1=e2/A、λ2=e0/A（edge function 的循环
  排列，非直觉映射——矩形斜边对角线上两三角形插值实测一致）。
- 采样：双线性，texel = uv*(tex_w-1)；uv 越界 clamp；RGBA8 行优先输出，
  未覆盖像素 alpha=0（透明背景，R3.2）。
- PNG（R3.3/R4）：RGBA8 + sRGB 声明 gAMA=45455、**无 tIME**；确定性 =
  固定 zlib 级别 9 + 全行 filter None（固定策略，无随机源）+ 无时间戳。

纹理局部解码（render_shape_from_image）：只 decode_region 形状 UV 覆盖的
纹理区域（±1 texel 双线性边距），再按区域尺寸与 remap 后的 uv 光栅化——
避免整张 4096² atlas 全解码（ASTC 块级解码，astc.py decode_region）。

一切畸形/退化数据统一抛 CatalogError（fail loud，不静默降级）。
"""

from __future__ import annotations

import math
import struct
import zlib
from typing import Sequence

from game_catalog.errors import CatalogError
from game_catalog.ktx import KtxImage, SctxImage, texture_to_rgba
from game_catalog.sc2 import Matrix2x3, Vertex

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
_PNG_MAX_DIMENSION = 16384  # encode_png 宽高上限（防放大；任务约定如 16384）
_RENDER_MAX_DIMENSION = 4096  # suggest_output_size 1:1 上限（任务约定如 4096）
# 渲染输出上限与 PNG 上限分开：rasterize 自己分配 output_w*output_h*4 字节
# 缓冲，4096² RGBA ≈ 67MB 已是渲染路径的安全上限；encode_png 只编码调用方
# 已持有的字节，上限放宽到 16384（任务约定）。
_EPSILON = 1e-6  # 像素空间三角形零面积判定（共线/退化 strip 三角形）


# ---------------------------------------------------------------------------
# 几何纯函数
# ---------------------------------------------------------------------------


def _check_vertices(vertices: Sequence[Vertex]) -> None:
    """非有限值校验（x/y/u/v 全量，fail loud）。"""
    for i, v in enumerate(vertices):
        if not (math.isfinite(v.x) and math.isfinite(v.y)
                and math.isfinite(v.u) and math.isfinite(v.v)):
            raise CatalogError(
                f"顶点[{i}] 含非有限值: ({v.x}, {v.y}, u={v.u}, v={v.v})")


def transform_vertices(vertices: list[Vertex],
                       matrix: Matrix2x3 | None) -> list[Vertex]:
    """矩阵作用于顶点 x/y（x' = a*x + c*y + tx；y' = b*x + d*y + ty）。

    u/v 不变（仿射变换只动几何坐标）；matrix=None → 原样返回（恒等，
    调用方不得修改返回的列表）。
    """
    if matrix is None:
        return vertices
    out = []
    for v in vertices:
        nx, ny = matrix.apply(v.x, v.y)
        out.append(Vertex(x=nx, y=ny, u=v.u, v=v.v))
    return out


def compute_bounds(vertices: list[Vertex]) -> tuple[float, float, float, float]:
    """顶点局部坐标的 (min_x, min_y, max_x, max_y)（浮点）。

    空列表 / 非有限值 / 某轴零跨度（退化）→ CatalogError。顶点数下限
    是 1（bounds 是 min/max 聚合，与渲染所需的 strip >= 3 顶点无关，
    后者由 rasterize 校验）。
    """
    if not vertices:
        raise CatalogError("顶点列表为空，无法计算 bounds")
    _check_vertices(vertices)
    min_x = min(v.x for v in vertices)
    max_x = max(v.x for v in vertices)
    min_y = min(v.y for v in vertices)
    max_y = max(v.y for v in vertices)
    if not (max_x > min_x and max_y > min_y):
        raise CatalogError(
            f"bounds 退化（零面积）: x[{min_x},{max_x}] y[{min_y},{max_y}]")
    return (min_x, min_y, max_x, max_y)


def _check_bounds(bounds: tuple[float, float, float, float]) -> None:
    """调用方传入的 bounds 校验（非有限 / 零跨度 → CatalogError）。"""
    min_x, min_y, max_x, max_y = bounds
    if not all(math.isfinite(b) for b in bounds):
        raise CatalogError(f"bounds 含非有限值: {bounds}")
    if not (max_x > min_x and max_y > min_y):
        raise CatalogError(
            f"bounds 退化（零面积）: x[{min_x},{max_x}] y[{min_y},{max_y}]")


def suggest_output_size(
        bounds: tuple[float, float, float, float]) -> tuple[int, int]:
    """默认输出尺寸：bounds 尺寸 ceil 到 1:1 像素，至少 1x1。

    上限 _RENDER_MAX_DIMENSION（4096）防矩阵放大导致的输出爆炸，越界抛错
    （设计决策：输出尺寸参数化由调用方定，本函数只提供 1:1 默认策略；
    Task 7 如需固定尺寸/缩放可另行决定）。
    """
    _check_bounds(bounds)
    min_x, min_y, max_x, max_y = bounds
    w = math.ceil(max_x - min_x)
    h = math.ceil(max_y - min_y)
    w = 1 if w < 1 else w
    h = 1 if h < 1 else h
    if w > _RENDER_MAX_DIMENSION or h > _RENDER_MAX_DIMENSION:
        raise CatalogError(
            f"输出尺寸 {w}x{h} 超过上限 {_RENDER_MAX_DIMENSION}"
            "（防放大：bounds 或矩阵过大）")
    return (w, h)


# ---------------------------------------------------------------------------
# 光栅化
# ---------------------------------------------------------------------------


def _strip_triangles(count: int) -> list[tuple[int, int, int]]:
    """triangle strip 三角形序列（奇偶翻转 winding）。

    三角形 t：偶数 (t, t+1, t+2)，奇数 (t+2, t+1, t)（与任务定义的
    (0,1,2),(2,1,3),(2,3,4),(4,3,5)… 循环旋转等价，winding 一致）。
    """
    return [(t, t + 1, t + 2) if t % 2 == 0 else (t + 2, t + 1, t)
            for t in range(count - 2)]


def _sample_bilinear(texture: bytes, tex_w: int, tex_h: int,
                     u: float, v: float) -> bytes:
    """双线性采样：texel = uv*(tex_w-1)/uv*(tex_h-1)，越界 clamp。

    返回 4 字节 RGBA（逐通道线性插值后 int(x+0.5) 取整——固定舍入，
    确定性）。单色纹理恒等（插值权重和为 1）。
    """
    u = 0.0 if u < 0.0 else (1.0 if u > 1.0 else u)
    v = 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)
    fx = u * (tex_w - 1)
    fy = v * (tex_h - 1)
    x0 = int(fx)
    y0 = int(fy)
    x1 = x0 + 1 if x0 + 1 < tex_w else x0
    y1 = y0 + 1 if y0 + 1 < tex_h else y0
    ax = fx - x0
    ay = fy - y0
    stride = tex_w * 4
    off00 = y0 * stride + x0 * 4
    off10 = y0 * stride + x1 * 4
    off01 = y1 * stride + x0 * 4
    off11 = y1 * stride + x1 * 4
    rgba = bytearray(4)
    for c in range(4):
        top = texture[off00 + c] + (texture[off10 + c] - texture[off00 + c]) * ax
        bot = texture[off01 + c] + (texture[off11 + c] - texture[off01 + c]) * ax
        rgba[c] = int(top + (bot - top) * ay + 0.5)
    return bytes(rgba)


def rasterize(vertices: list[Vertex], texture: bytes, tex_w: int, tex_h: int,
              bounds: tuple[float, float, float, float],
              output_w: int, output_h: int) -> bytes:
    """把 shape 顶点（triangle strip）光栅化到 output_w x output_h RGBA8。

    - 输出像素 p 的局部坐标 = bounds.min + (p+0.5) * (bounds.size / output_size)
    - 覆盖：半空间 edge function，winding 无关（CW/CCW 都收）；
      退化三角形（零面积）跳过，全部退化 → CatalogError
    - 颜色：重心坐标插值 UV → 双线性采样纹理（clamp）
    - 未覆盖像素 alpha=0（透明背景）；重叠三角形后者覆盖前者（确定性）

    畸形（顶点 < 3 / 非有限 / 纹理长度不符 / bounds 退化 / 输出尺寸
    非法或超限）→ CatalogError。
    """
    if len(vertices) < 3:
        raise CatalogError(
            f"渲染需要 >= 3 个顶点（triangle strip），实际 {len(vertices)} 个")
    _check_vertices(vertices)
    _check_bounds(bounds)
    if tex_w <= 0 or tex_h <= 0:
        raise CatalogError(f"纹理尺寸非法: {tex_w}x{tex_h}")
    if len(texture) != tex_w * tex_h * 4:
        raise CatalogError(
            f"纹理长度不符: {len(texture)}（期望 {tex_w * tex_h * 4} = "
            f"{tex_w}x{tex_h} RGBA8）")
    if output_w <= 0 or output_h <= 0:
        raise CatalogError(f"输出尺寸非法: {output_w}x{output_h}")
    if output_w > _RENDER_MAX_DIMENSION or output_h > _RENDER_MAX_DIMENSION:
        raise CatalogError(
            f"输出尺寸 {output_w}x{output_h} 超过上限 {_RENDER_MAX_DIMENSION}"
            "（防放大）")

    min_x, min_y, max_x, max_y = bounds
    scale_x = output_w / (max_x - min_x)
    scale_y = output_h / (max_y - min_y)

    # 顶点 → 像素空间坐标（像素中心 p 的局部坐标 = min + (p+0.5)*scale
    # ⇒ 像素空间坐标 = (局部 - min) * scale - 0.5）
    px = [(v.x - min_x) * scale_x - 0.5 for v in vertices]
    py = [(v.y - min_y) * scale_y - 0.5 for v in vertices]

    # 三角形装配（strip 奇偶翻转）；跳过零面积三角形。
    # 元组携带 uv（不依赖装配循环的 i0/i1/i2——它们是循环变量，渲染循环
    # 中引用会拿到**最后一条三角形**的残留索引，曾因此产生错误的 UV 插值）。
    triangles: list[tuple[float, float, float, float, float, float,
                          float, float, float, float, float, float,
                          float]] = []
    seen_area = False
    for i0, i1, i2 in _strip_triangles(len(vertices)):
        area = ((px[i1] - px[i0]) * (py[i2] - py[i0])
                - (py[i1] - py[i0]) * (px[i2] - px[i0]))
        if abs(area) <= _EPSILON:
            continue  # 退化（共线）三角形：零面积无覆盖
        seen_area = True
        triangles.append((px[i0], py[i0], px[i1], py[i1], px[i2], py[i2],
                          vertices[i0].u, vertices[i0].v,
                          vertices[i1].u, vertices[i1].v,
                          vertices[i2].u, vertices[i2].v,
                          area))

    if not seen_area:
        raise CatalogError(
            "形状退化：所有三角形零面积（顶点共线），无法光栅化")

    out = bytearray(output_w * output_h * 4)
    for (p0x, p0y, p1x, p1y, p2x, p2y,
         u0, v0, u1, v1, u2, v2, area) in triangles:
        # 三角形像素包围盒（裁剪到输出）
        bx0 = max(0, int(math.floor(min(p0x, p1x, p2x))))
        bx1 = min(output_w - 1, int(math.ceil(max(p0x, p1x, p2x))))
        by0 = max(0, int(math.floor(min(p0y, p1y, p2y))))
        by1 = min(output_h - 1, int(math.ceil(max(p0y, p1y, p2y))))
        if bx0 > bx1 or by0 > by1:
            continue
        e1dx, e1dy = p1x - p0x, p1y - p0y
        e2dx, e2dy = p2x - p1x, p2y - p1y
        e0dx, e0dy = p0x - p2x, p0y - p2y
        for y in range(by0, by1 + 1):
            for x in range(bx0, bx1 + 1):
                # 半空间 edge function（winding 无关：全 >=0 或全 <=0 都收）
                e0 = e1dx * (y - p0y) - e1dy * (x - p0x)
                e1 = e2dx * (y - p1y) - e2dy * (x - p1x)
                e2 = e0dx * (y - p2y) - e0dy * (x - p2x)
                if not ((e0 >= 0 and e1 >= 0 and e2 >= 0)
                        or (e0 <= 0 and e1 <= 0 and e2 <= 0)):
                    continue
                # 重心坐标（λ0=e1/A、λ1=e2/A、λ2=e0/A，循环排列——e0 对应
                # 对边 P1P2 即 P0 的权重），插值 UV
                u = (e1 * u0 + e2 * u1 + e0 * u2) / area
                v = (e1 * v0 + e2 * v1 + e0 * v2) / area
                off = (y * output_w + x) * 4
                out[off:off + 4] = _sample_bilinear(texture, tex_w, tex_h, u, v)
    return bytes(out)


# ---------------------------------------------------------------------------
# 高层编排（Task 7 生成器直接调用）
# ---------------------------------------------------------------------------


def render_shape(vertices: list[Vertex], texture_bytes: bytes,
                 tex_w: int, tex_h: int) -> tuple[int, int, bytes]:
    """完整形状渲染：bounds + 默认输出尺寸（1:1 ceil）+ 光栅化。

    返回 (w, h, rgba)；调用方自行决定后续尺寸策略时可用
    compute_bounds + suggest_output_size + rasterize 组合。
    """
    bounds = compute_bounds(vertices)
    w, h = suggest_output_size(bounds)
    rgba = rasterize(vertices, texture_bytes, tex_w, tex_h, bounds, w, h)
    return (w, h, rgba)


def _texture_region(vertices: list[Vertex], tex_w: int,
                    tex_h: int) -> tuple[int, int, int, int]:
    """形状 UV 覆盖的纹理像素区域 (x0, y0, x1, y1)，±1 texel 双线性边距。

    边距保证 uv 落在区域边界时双线性第二个 tap 仍在区域内（见
    render_shape_from_image 文档）；区域钳制到纹理范围。
    """
    u_min = min(v.u for v in vertices)
    u_max = max(v.u for v in vertices)
    v_min = min(v.v for v in vertices)
    v_max = max(v.v for v in vertices)
    x0 = max(0, int(math.floor(u_min * tex_w)) - 1)
    x1 = min(tex_w, int(math.ceil(u_max * tex_w)) + 1)
    y0 = max(0, int(math.floor(v_min * tex_h)) - 1)
    y1 = min(tex_h, int(math.ceil(v_max * tex_h)) + 1)
    return (x0, y0, x1, y1)


def _remap_uvs(vertices: list[Vertex], x0: int, y0: int, region_w: int,
               region_h: int, tex_w: int, tex_h: int) -> list[Vertex]:
    """顶点 uv 从全纹理坐标系 remap 到区域坐标系（x/y 与 u/v 其余不变）。

    u_local = (u*tex_w - x0) / region_w —— 区域 [x0,x1) 映射到 0..1，
    与 rasterize 的 texel = uv_local*(region_w-1) 约定自洽。
    """
    out = []
    for v in vertices:
        ul = (v.u * tex_w - x0) / region_w
        vl = (v.v * tex_h - y0) / region_h
        out.append(Vertex(x=v.x, y=v.y, u=ul, v=vl))
    return out


def render_shape_from_image(img: KtxImage | SctxImage,
                            vertices: list[Vertex]) -> tuple[int, int, bytes]:
    """从已解析纹理图像渲染：只局部解码 UV 覆盖区域，再光栅化。

    - bounds + 默认输出尺寸（同 render_shape）
    - 纹理区域 = 顶点 UV 范围 ±1 texel（双线性边距），经
      ktx.texture_to_rgba → decode_region 块级局部解码（避免整张 atlas
      解码；真实 ui.sc set5 为 3050x3514 ASTC 4x4）
    - 顶点 uv remap 到区域坐标系后交给 rasterize（区域采样约定与全纹理
      采样自洽；区域边界外 clamp）

    返回 (w, h, rgba)。
    """
    bounds = compute_bounds(vertices)
    w, h = suggest_output_size(bounds)
    x0, y0, x1, y1 = _texture_region(vertices, img.width, img.height)
    region_w = x1 - x0
    region_h = y1 - y0
    region = texture_to_rgba(img, x0, y0, x1, y1)
    if len(region) != region_w * region_h * 4:
        raise CatalogError(
            f"decode_region 输出长度不符: {len(region)}（期望 "
            f"{region_w * region_h * 4} = {region_w}x{region_h} RGBA8）")
    mapped = _remap_uvs(vertices, x0, y0, region_w, region_h,
                        img.width, img.height)
    rgba = rasterize(mapped, region, region_w, region_h, bounds, w, h)
    return (w, h, rgba)


def _blend_src_over(canvas: bytearray, layer: bytes) -> None:
    """canvas = layer over canvas（非预乘 alpha src-over，纯整数确定性）。

    outA = sa + da*(1-sa)；outRGB = (srcRGB*sa + dstRGB*da*(1-sa)) / outA。
    整数除法无浮点舍入差异，同一输入两次混合字节一致（R4）。
    """
    for i in range(0, len(layer), 4):
        sa = layer[i + 3]
        if sa == 0:
            continue  # 完全透明：无影响
        if sa == 255:
            canvas[i:i + 4] = layer[i:i + 4]
            continue
        da = canvas[i + 3]
        out_a = sa + da * (255 - sa) // 255
        if out_a == 0:
            continue
        for c in range(3):
            canvas[i + c] = ((layer[i + c] * sa
                              + canvas[i + c] * da * (255 - sa) // 255)
                             // out_a)
        canvas[i + 3] = out_a


def composite_shapes(
    shapes: Sequence[tuple[KtxImage | SctxImage, list[Vertex]]],
) -> tuple[int, int, bytes]:
    """多 shape 命令合成：全部画到同一输出画布（共享 bounds/输出尺寸）。

    - 所有命令的顶点在同一局部坐标系（同一 movieclip 帧元素），union bounds
      决定画布尺寸 = suggest_output_size(union)（上限 4096 防放大）
    - 每命令独立纹理 → 各自 region 解码 + 光栅化，再 **src-over 混合**（后画
      覆盖先画，与 SWF painter's algorithm 一致；不同命令可不同纹理，
      不能合并顶点一次光栅化）
    - 单一 shape 时输出与 render_shape_from_image 完全一致（同 bounds、
      同输出尺寸；混合恒等）

    空列表 / 任一 shape 畸形 → CatalogError（fail loud）。
    """
    if not shapes:
        raise CatalogError("composite_shapes: 无任何 shape 命令可合成")
    all_vertices: list[Vertex] = []
    for _, vs in shapes:
        all_vertices.extend(vs)
    bounds = compute_bounds(all_vertices)
    w, h = suggest_output_size(bounds)
    canvas = bytearray(w * h * 4)
    for img, vs in shapes:
        x0, y0, x1, y1 = _texture_region(vs, img.width, img.height)
        region_w = x1 - x0
        region_h = y1 - y0
        region = texture_to_rgba(img, x0, y0, x1, y1)
        if len(region) != region_w * region_h * 4:
            raise CatalogError(
                f"decode_region 输出长度不符: {len(region)}（期望 "
                f"{region_w * region_h * 4} = {region_w}x{region_h} RGBA8）")
        mapped = _remap_uvs(vs, x0, y0, region_w, region_h,
                            img.width, img.height)
        layer = rasterize(mapped, region, region_w, region_h, bounds, w, h)
        _blend_src_over(canvas, layer)
    return (w, h, bytes(canvas))


# ---------------------------------------------------------------------------
# 确定性 PNG 编码（R3.3 / R4）
# ---------------------------------------------------------------------------


def _png_chunk(ctype: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + ctype + data
            + struct.pack(">I", zlib.crc32(ctype + data) & 0xFFFFFFFF))


def encode_png(width: int, height: int, rgba: bytes) -> bytes:
    """RGBA8 像素 → PNG 字节（IHDR + gAMA + IDAT + IEND，无 tIME）。

    规格（契约 R3.3）：位深 8、颜色类型 6（RGBA）、sRGB 声明 gAMA=45455
    （2.2 * 100000）。字节确定性（R4）：固定 zlib 压缩级别 9 + 全行 filter
    None（filter 0）——固定 filter 策略让 deflate 输入字节恒定，级别固定
    让 deflate 输出恒定；无时间戳 chunk、无随机源 ⇒ 同一输入两次编码字节
    完全一致。

    尺寸 0 / rgba 长度与 w*h*4 不符 / 宽高超上限 16384 → CatalogError。
    """
    if width <= 0 or height <= 0:
        raise CatalogError(f"PNG 尺寸必须 > 0: {width}x{height}")
    if width > _PNG_MAX_DIMENSION or height > _PNG_MAX_DIMENSION:
        raise CatalogError(
            f"PNG 尺寸 {width}x{height} 超过上限 {_PNG_MAX_DIMENSION}"
            "（防放大）")
    expected = width * height * 4
    if len(rgba) != expected:
        raise CatalogError(
            f"PNG 像素长度不符: {len(rgba)}（期望 {expected} = "
            f"{width}x{height} RGBA8）")

    # 每行 filter 0（None）：固定 filter 策略（确定性）；PNG 规范允许
    # 任意行 filter，压缩率差异不改变解码正确性
    raw = bytearray(height * (1 + width * 4))
    stride = width * 4
    for y in range(height):
        base = y * (1 + stride)
        raw[base] = 0
        raw[base + 1:base + 1 + stride] = rgba[y * stride:(y + 1) * stride]

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    gama = struct.pack(">I", 45455)  # sRGB 伽马 2.2 * 100000
    idat = zlib.compress(bytes(raw), 9)  # 固定级别 9 → 确定性
    return (PNG_SIGNATURE
            + _png_chunk(b"IHDR", ihdr)
            + _png_chunk(b"gAMA", gama)
            + _png_chunk(b"IDAT", idat)
            + _png_chunk(b"IEND", b""))
