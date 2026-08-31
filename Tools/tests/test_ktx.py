"""KTX / SCTX 纹理容器解析测试（Issue #30 Task 5）。

策略：
- 合成 KTX 1.x 容器（magic + 13 u32 头 + kvb + imageSize 前缀 + 像素），
  断言 parse_ktx 字段与 level0（含 kvb>0、mips>1 变体）
- 合成 SCTX（52 字节固定头 + 元数据 blob + ASTC 数据），按实证布局
  （u32@0+52 为数据起点、u16@48/50 为宽高、u32@44 为 pixel_type、
  u32@56 为数据长度）断言 parse_sctx
- 负例：magic 错误 / 尺寸 0 / 数据截断 / 未支持格式 / 超上限 → CatalogError
- decode_region 冒烟：合成 const 块区域解码 + 真实 APK 小区域非全零
- 真实冒烟：ui.sc 7 个内嵌 KTX 全字段断言（0x93B0=ASTC 4x4、level0 长度
  =ceil(w/4)*ceil(h/4)*16）；buildings.sc 71 个 .sctx 全量一致性断言
  （buildings_0: 608x1004、level0=274176）
"""

import os
import struct
import zipfile
from pathlib import Path

import pytest

from game_catalog.astc import AstcError
from game_catalog.errors import CatalogError
from game_catalog.ktx import (
    KtxImage,
    SctxImage,
    parse_ktx,
    parse_sctx,
    texture_to_rgba,
)

APK = Path(os.environ.get("COC_APK_PATH", "/path/to/base.apk"))

_real_apk = pytest.mark.skipif(
    not APK.is_file(), reason="真实 APK 不存在（设置 COC_APK_PATH 可启用）"
)

KTX_MAGIC = b"\xabKTX 11\xbb\r\n\x1a\n"
# 实证（真实 APK 全量）：0x93B0=4x4（ui.sc）、0x93B4=6x6（绝大多数）、
# 0x93B7=8x8（debug.sc）——与 GL_COMPRESSED_RGBA_ASTC_*_KHR 官方枚举一致
_BLOCK = {0x93B0: (4, 4), 0x93B4: (6, 6), 0x93B7: (8, 8)}


# ---------------------------------------------------------------------------
# 合成 fixture 构造器
# ---------------------------------------------------------------------------


def _const_block(r: int, g: int, b: int, a: int) -> bytes:
    """ASTC const U16 块（0xFC 家族 + 4×16bit 颜色，可解码为整块同色）。"""
    head = bytes([0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    return head + struct.pack("<4H", r, g, b, a)


def _make_ktx(width: int, height: int, gif: int = 0x93B0, kvb: bytes = b"",
              pixel: bytes | None = None, mips: int = 1, faces: int = 1,
              endian: int = 0x04030201, pixel_depth: int = 0,
              array_elements: int = 0) -> bytes:
    """构造 KTX 1.x 容器（level0 = pixel；mips>1 时 level0 后补 16 字节）。"""
    bw, bh = _BLOCK.get(gif, (1, 1))  # 未知格式仅构造容器（解析应失败）
    expected = ((width + bw - 1) // bw) * ((height + bh - 1) // bh) * 16
    if pixel is None:
        pixel = _const_block(0xFF00, 0, 0, 0xFF00) * (expected // 16)
    assert len(pixel) == expected, "合成像素长度必须与块尺寸一致"
    header = struct.pack(
        "<13I", endian, 0, 1, 0, gif, 6408, width, height, pixel_depth,
        array_elements, faces, mips, len(kvb))
    body = struct.pack("<I", len(pixel)) + pixel
    if mips > 1:
        body += struct.pack("<I", 16) + b"\x00" * 16  # level1（不校验）
    return KTX_MAGIC + header + kvb + body


def _make_sctx(width: int, height: int, pixel_type: int = 208,
               blob_size: int = 100, data: bytes | None = None,
               magic: bytes = b"SCTX", u32_at4: int = 36,
               data_len_field: int | None = None) -> bytes:
    """构造 buildings 风格 SCTX（52 字节固定头 + blob + 数据；实证布局）。"""
    bw, bh = (6, 6) if pixel_type == 208 else (1, 1)
    expected = ((width + bw - 1) // bw) * ((height + bh - 1) // bh) * 16
    if data is None:
        data = _const_block(0, 0, 0xFF00, 0xFF00) * (expected // 16)
    assert len(data) == expected, "合成数据长度必须与 6x6 块尺寸一致"
    header = (
        struct.pack("<I", blob_size)            # off0: 数据起点 = blob_size + 52
        + struct.pack("<I", u32_at4)            # off4: 头变体标记（36=buildings）
        + magic                                 # off8
        + struct.pack("<5H", 0, 26, 28, 0, 4)   # off12-21: 实证常量
        + struct.pack("<H", 8)                  # off22
        + struct.pack("<I", 10)                 # off24
        + struct.pack("<2H", 0, 12)             # off28
        + struct.pack("<I", 16)                 # off32
        + struct.pack("<2H", 23, 24)            # off36
        + struct.pack("<I", 26)                 # off40
        + struct.pack("<I", pixel_type)         # off44
        + struct.pack("<2H", width, height)     # off48/50
        + struct.pack("<I", 12)                 # off52
        + struct.pack("<I", data_len_field if data_len_field is not None
                      else len(data))           # off56: 数据长度
    )
    assert len(header) == 60
    blob = b"\x00" * (blob_size - 8)  # 60..(blob_size+52) 为元数据 blob
    return header + blob + data


# ---------------------------------------------------------------------------
# parse_ktx 合成用例
# ---------------------------------------------------------------------------


def test_ktx_parse_astc_4x4():
    """16x16 ASTC 4x4（16 块）：字段与 level0 正确。"""
    img = parse_ktx(_make_ktx(16, 16))
    assert isinstance(img, KtxImage)
    assert img.width == 16 and img.height == 16
    assert img.internal_format == 0x93B0
    assert (img.block_w, img.block_h) == (4, 4)
    assert len(img.level0) == 16 * 16
    assert img.level0 == _const_block(0xFF00, 0, 0, 0xFF00) * 16


def test_ktx_parse_astc_6x6():
    """glInternalFormat=0x93B4 → 6x6 块（真实 APK 绝大多数纹理的格式）。"""
    img = parse_ktx(_make_ktx(12, 12, gif=0x93B4))
    assert (img.block_w, img.block_h) == (6, 6)
    assert len(img.level0) == 4 * 16


def test_ktx_parse_astc_8x8():
    """glInternalFormat=0x93B7 → 8x8 块（真实 debug.sc 纹理的格式）。"""
    img = parse_ktx(_make_ktx(16, 24, gif=0x93B7))
    assert (img.block_w, img.block_h) == (8, 8)
    assert len(img.level0) == 2 * 3 * 16


def test_ktx_kvb_skipped():
    """bytesOfKeyValueData>0：kv 区被跳过，level0 定位正确。"""
    kvb = b"\x0b\x00\x00\x00KTXOrientation" + b"\x00" * 4
    img = parse_ktx(_make_ktx(8, 8, kvb=kvb))
    assert img.level0 == _const_block(0xFF00, 0, 0, 0xFF00) * 4


def test_ktx_multi_mip_level0_only():
    """mips>1：只取 level0，不解析后续 mip（合法 KTX 变体）。"""
    img = parse_ktx(_make_ktx(8, 8, mips=2))
    assert img.level0 == _const_block(0xFF00, 0, 0, 0xFF00) * 4


def test_ktx_bad_magic():
    with pytest.raises(CatalogError, match="magic"):
        parse_ktx(b"\xabKTX 12\xbb" + b"\x00" * 64)


def test_ktx_too_short():
    with pytest.raises(CatalogError, match="过短"):
        parse_ktx(b"short")


def test_ktx_zero_dimension():
    with pytest.raises(CatalogError, match="尺寸"):
        parse_ktx(_make_ktx(0, 16))


def test_ktx_unsupported_format():
    with pytest.raises(CatalogError, match="格式"):
        parse_ktx(_make_ktx(16, 16, gif=0x9999))


def test_ktx_big_endian_rejected():
    with pytest.raises(CatalogError, match="字节序"):
        parse_ktx(_make_ktx(16, 16, endian=0x01020304))


def test_ktx_cubemap_rejected():
    with pytest.raises(CatalogError, match="cube|立方体"):
        parse_ktx(_make_ktx(16, 16, faces=6))


def test_ktx_3d_rejected():
    with pytest.raises(CatalogError, match="3D|三维"):
        parse_ktx(_make_ktx(16, 16, pixel_depth=4))


def test_ktx_array_rejected():
    with pytest.raises(CatalogError, match="数组"):
        parse_ktx(_make_ktx(16, 16, array_elements=2))


def test_ktx_image_size_mismatch():
    """imageSize 与 width*height*块大小不一致 → CatalogError（fail loud）。"""
    raw = _make_ktx(16, 16)
    raw = raw[:64] + struct.pack("<I", 999) + raw[68:]  # 改 imageSize
    with pytest.raises(CatalogError, match="一致"):
        parse_ktx(raw)


def test_ktx_truncated_data():
    """imageSize 超出缓冲 → CatalogError（数据截断）。"""
    raw = _make_ktx(16, 16)[:-8]
    with pytest.raises(CatalogError, match="越界|截断"):
        parse_ktx(raw)


def test_ktx_kvb_beyond_buffer():
    """声明的 kv 区超出缓冲 → CatalogError（字节被截断）。"""
    raw = _make_ktx(16, 16)
    raw = raw[:60] + struct.pack("<I", 1024) + raw[64:]  # 声明 1024 字节 kv
    with pytest.raises(CatalogError, match="越界"):
        parse_ktx(raw)


def test_ktx_oversized_level0():
    """声明的 level0 超过 256MB 上限 → 在切片前拒绝（防放大）。"""
    raw = _make_ktx(16, 16)
    raw = raw[:64] + struct.pack("<I", 300 * 1024 * 1024) + raw[68:]
    with pytest.raises(CatalogError, match="上限"):
        parse_ktx(raw)


# ---------------------------------------------------------------------------
# parse_sctx 合成用例
# ---------------------------------------------------------------------------


def test_sctx_parse_astc_6x6():
    """12x12 SCTX（pixel_type=208 → 6x6，4 块）：字段与 level0 正确。"""
    img = parse_sctx(_make_sctx(12, 12))
    assert isinstance(img, SctxImage)
    assert img.width == 12 and img.height == 12
    assert img.pixel_type == 208
    assert (img.block_w, img.block_h) == (6, 6)
    assert img.level0 == _const_block(0, 0, 0xFF00, 0xFF00) * 4


def test_sctx_non_multiple_dimensions():
    """宽高非 6 倍数：块数向上取整（ceil），数据长度按实块数。"""
    img = parse_sctx(_make_sctx(13, 7))  # ceil(13/6)=3, ceil(7/6)=2 → 6 块
    assert len(img.level0) == 6 * 16
    assert img.width == 13 and img.height == 7


def test_sctx_bad_magic():
    with pytest.raises(CatalogError, match="magic"):
        parse_sctx(_make_sctx(12, 12, magic=b"SCTZ"))


def test_sctx_too_short():
    with pytest.raises(CatalogError, match="过短"):
        parse_sctx(b"SCTX")


def test_sctx_unsupported_variant():
    """u32@4 非 36 的 sctx 变体（实测 28/32 = 其他头布局）→ CatalogError。"""
    with pytest.raises(CatalogError, match="变体"):
        parse_sctx(_make_sctx(12, 12, u32_at4=28))


def test_sctx_unsupported_pixel_type():
    with pytest.raises(CatalogError, match="pixel_type|像素类型"):
        parse_sctx(_make_sctx(12, 12, pixel_type=5))


def test_sctx_zero_dimension():
    with pytest.raises(CatalogError, match="尺寸"):
        parse_sctx(_make_sctx(0, 12))


def test_sctx_data_size_mismatch():
    """u32@56 与 width*height*块大小不一致 → CatalogError（fail loud）。"""
    raw = _make_sctx(12, 12, data_len_field=1234)
    with pytest.raises(CatalogError, match="一致"):
        parse_sctx(raw)


def test_sctx_truncated_data():
    """数据起点/长度超出缓冲 → CatalogError（数据截断）。"""
    raw = _make_sctx(12, 12)[:-8]
    with pytest.raises(CatalogError, match="越界|截断"):
        parse_sctx(raw)


def test_sctx_data_overlap_header():
    """blob_size 过小 → 数据起点压进固定头 → CatalogError。"""
    with pytest.raises(CatalogError, match="越界"):
        parse_sctx(_make_sctx(12, 12, blob_size=4))


def test_sctx_oversized():
    """声明的数据长度超过 256MB 上限 → 在切片前拒绝（防放大）。"""
    raw = _make_sctx(12, 12, data_len_field=300 * 1024 * 1024)
    with pytest.raises(CatalogError, match="上限"):
        parse_sctx(raw)


# ---------------------------------------------------------------------------
# decode_region 冒烟（合成 const 块）
# ---------------------------------------------------------------------------


def test_ktx_decode_region_const():
    """16x16 全红 const 块：全图与子区域解码颜色/尺寸正确。"""
    img = parse_ktx(_make_ktx(16, 16))
    red = bytes([0xFF, 0x00, 0x00, 0xFF])
    out = img.decode_region(0, 0, 16, 16)
    assert len(out) == 16 * 16 * 4
    assert out == red * (16 * 16)
    sub = img.decode_region(8, 8, 16, 16)
    assert len(sub) == 8 * 8 * 4
    assert sub == red * (8 * 8)


def test_sctx_decode_region_const():
    """12x12 全蓝 const 块：区域解码颜色/尺寸正确。"""
    img = parse_sctx(_make_sctx(12, 12))
    blue = bytes([0x00, 0x00, 0xFF, 0xFF])
    out = img.decode_region(0, 0, 12, 12)
    assert len(out) == 12 * 12 * 4
    assert out == blue * (12 * 12)


def test_decode_region_out_of_bounds_astc_error():
    """区域越界 → AstcError 透传（不包装成 CatalogError）。"""
    img = parse_ktx(_make_ktx(16, 16))
    with pytest.raises(AstcError):
        img.decode_region(0, 0, 100, 100)


def test_texture_to_rgba_helper():
    """统一 helper 对 KtxImage/SctxImage 均可用（Task 7 渲染生成器入口）。"""
    ktx = parse_ktx(_make_ktx(16, 16))
    sctx = parse_sctx(_make_sctx(12, 12))
    assert texture_to_rgba(ktx, 0, 0, 16, 16) == ktx.decode_region(0, 0, 16, 16)
    assert texture_to_rgba(sctx, 0, 0, 6, 6) == sctx.decode_region(0, 0, 6, 6)


# ---------------------------------------------------------------------------
# 真实 APK 冒烟
# ---------------------------------------------------------------------------


@_real_apk
def test_real_ui_sc_ktx_all_sets():
    """ui.sc 7 个内嵌 KTX：0x93B0 ASTC 4x4、level0 长度=ceil(w/4)*ceil(h/4)*16。

    对拍断言（实证）：set0-4 为 4096x4096（level0=16.7MB），set5 3050x3514，
    set6 912x1024；全部 kvb=0、单 mip、单 face、无尾随字节。
    """
    with zipfile.ZipFile(str(APK)) as z:
        sc = _load_sc(z.read("assets/sc/ui.sc"))
    for i in range(7):
        td = sc.texture_data(i)
        img = parse_ktx(td.data)
        assert img.internal_format == 0x93B0
        assert (img.block_w, img.block_h) == (4, 4)
        assert (img.width, img.height) == (td.width, td.height)
        expected = ((td.width + 3) // 4) * ((td.height + 3) // 4) * 16
        assert len(img.level0) == expected
    img0 = parse_ktx(sc.texture_data(0).data)
    assert (img0.width, img0.height) == (4096, 4096)
    assert len(img0.level0) == 1024 * 1024 * 16  # 16777216


@_real_apk
def test_real_buildings_sctx_all_71():
    """buildings.sc 全部 71 个 .sctx：头字段、数据长度与 6x6 块数全量一致。"""
    with zipfile.ZipFile(str(APK)) as z:
        sc = _load_sc(z.read("assets/sc/buildings.sc"))
        names = z.namelist()
        for i in range(71):
            td = sc.texture_data(i)
            full = next(n for n in names if n.endswith(td.external_texture))
            img = parse_sctx(z.read(full))
            assert img.pixel_type == 208
            assert (img.block_w, img.block_h) == (6, 6)
            assert (img.width, img.height) == (td.width, td.height)
            expected = ((td.width + 5) // 6) * ((td.height + 5) // 6) * 16
            assert len(img.level0) == expected
    # buildings_0 具体断言：608x1004、level0=274176
    with zipfile.ZipFile(str(APK)) as z:
        img = parse_sctx(z.read("assets/sc/buildings_0.sctx"))
    assert (img.width, img.height) == (608, 1004)
    assert len(img.level0) == 274176


@_real_apk
def test_real_decode_region_smoke():
    """真实小区域 decode_region：尺寸正确、非全零、值域合法。"""
    with zipfile.ZipFile(str(APK)) as z:
        sc = _load_sc(z.read("assets/sc/ui.sc"))
        img = parse_ktx(sc.texture_data(6).data)
        out = img.decode_region(456, 512, 520, 576)
        assert len(out) == 64 * 64 * 4
        assert any(b != 0 for b in out)
        assert all(0 <= b <= 255 for b in out)

        sc = _load_sc(z.read("assets/sc/buildings.sc"))
        img = parse_sctx(z.read("assets/sc/buildings_0.sctx"))
        out = img.decode_region(300, 300, 364, 364)
        assert len(out) == 64 * 64 * 4
        assert any(b != 0 for b in out)
        assert all(0 <= b <= 255 for b in out)


def _load_sc(data: bytes):
    from game_catalog.sc2 import load_sc

    return load_sc(data)
