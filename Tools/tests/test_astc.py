"""ASTC 块级解码器测试（Issue #30 Task 4）。

策略：
- 合成向量：测试内参考编码器构造 128-bit 块（BISE 编码用生产 decode 表穷举反查，
  块布局按 ARM symbolic_to_physical），断言精确 RGBA8 输出（含手工可推演 lerp）
- BISE 单测：trit / quint / bits 三种编码往返 + 已知序列位级验证
- 负例：保留模式 / 截断 / HDR 端点 / 非法组合 → AstcError
- 真实冒烟：COC APK（COC_APK_PATH）ui.sc KTX 4x4 与 buildings.sc .sctx 6x6
  与官方 astcenc 5.7.0 输出逐像素对拍（参考 PNG 在 /tmp/astc-ref 时启用）
"""

import os
import zipfile
from pathlib import Path

import pytest

from game_catalog.astc import (
    AstcError,
    _BITREV8,
    _TRITS_OF_INTEGER,
    _QUINTS_OF_INTEGER,
    _decode_ise,
    decode_block,
    decode_region,
)

APK = Path(os.environ.get("COC_APK_PATH", "/Users/lmz/Downloads/base.apk.1"))
REF = Path("/tmp/astc-ref")

_real_apk = pytest.mark.skipif(
    not APK.is_file(), reason="真实 APK 不存在（设置 COC_APK_PATH 可启用）"
)


# ---------------------------------------------------------------------------
# 测试内参考编码器（仅构造合成块；生产模块只解码）
# ---------------------------------------------------------------------------


def _write_bits(buf: bytearray, value: int, bitcount: int, bitoffset: int) -> None:
    """value 的低 bitcount 位写入位偏移 bitoffset（跨字节安全）。"""
    mask = (1 << bitcount) - 1
    value &= mask
    b = bitoffset >> 3
    off = bitoffset & 7
    v = int.from_bytes(buf[b : b + 2], "little") if b + 2 <= len(buf) else 0
    v &= ~(mask << off)
    v |= value << off
    buf[b : b + 2] = v.to_bytes(2, "little")


def _ise_bits(count: int, quant: int) -> int:
    """ARM get_ise_sequence_bitcount：ISE 序列总位数。"""
    scale, divisor = (
        (1, 1),
        (8, 5),
        (2, 1),
        (7, 3),
        (13, 5),
        (3, 1),
        (10, 3),
        (18, 5),
        (4, 1),
        (13, 3),
        (23, 5),
        (5, 1),
        (16, 3),
        (28, 5),
        (6, 1),
        (19, 3),
        (33, 5),
        (7, 1),
        (22, 3),
        (38, 5),
        (8, 1),
    )[quant]
    return (scale * count + divisor - 1) // divisor


def encode_ise(quant: int, values: list[int]) -> tuple[bytes, int]:
    """BISE 编码（参考实现）。返回 (打包字节, 总位数)。值与 ARM 布局一致。"""
    bits, trits, quints = (
        (1, 0, 0),
        (0, 1, 0),
        (2, 0, 0),
        (0, 0, 1),
        (1, 1, 0),
        (3, 0, 0),
        (1, 0, 1),
        (2, 1, 0),
        (4, 0, 0),
        (2, 0, 1),
        (3, 1, 0),
        (5, 0, 0),
        (3, 0, 1),
        (4, 1, 0),
        (6, 0, 0),
        (4, 0, 1),
        (5, 1, 0),
        (7, 0, 0),
        (5, 0, 1),
        (6, 1, 0),
        (8, 0, 0),
    )[quant]
    n = len(values)
    total = _ise_bits(n, quant)
    buf = bytearray((total + 7) // 8 + 2)
    pos = 0
    mask = (1 << bits) - 1 if bits else 0
    if trits:
        # 每 5 个值一组：值 = trit * 2^bits + m；trit 块 8 位
        for i in range(0, n, 5):
            ts = [values[i + j] >> bits if i + j < n else 0 for j in range(5)]
            ms = [values[i + j] & mask if i + j < n else 0 for j in range(5)]
            t = next(
                t
                for t in range(256)
                if [_TRITS_OF_INTEGER[t][j] for j in range(5)] == ts
            )
            tbits = (2, 2, 1, 2, 1)
            tsh = (0, 2, 4, 5, 7)
            for j in range(5):
                if i + j >= n:
                    continue
                _write_bits(
                    buf,
                    ms[j] | (((t >> tsh[j]) & ((1 << tbits[j]) - 1)) << bits),
                    bits + tbits[j],
                    pos,
                )
                pos += bits + tbits[j]
    elif quints:
        # 每 3 个值一组：值 = quint * 2^bits + m；quint 块 7 位
        for i in range(0, n, 3):
            qs = [values[i + j] >> bits if i + j < n else 0 for j in range(3)]
            ms = [values[i + j] & mask if i + j < n else 0 for j in range(3)]
            q = next(
                q
                for q in range(128)
                if [_QUINTS_OF_INTEGER[q][j] for j in range(3)] == qs
            )
            qbits = (3, 2, 2)
            qsh = (0, 3, 5)
            for j in range(3):
                if i + j >= n:
                    continue
                _write_bits(
                    buf,
                    ms[j] | (((q >> qsh[j]) & ((1 << qbits[j]) - 1)) << bits),
                    bits + qbits[j],
                    pos,
                )
                pos += bits + qbits[j]
    else:
        for v in values:
            _write_bits(buf, v, bits, pos)
            pos += bits
    return bytes(buf), total


# ---------------------------------------------------------------------------
# BISE 单测
# ---------------------------------------------------------------------------


def test_ise_known_bit_sequence():
    """QUANT_8（纯 3-bit）：值序列的位级已知打包。"""
    # 值 {7, 3, 0}，LSB-first：位流 111_011_000 → 字节 0b00111011 = 0x3B
    packed, total = encode_ise(5, [7, 3, 0])
    assert total == 9
    assert packed[0] == 0x1F
    assert _decode_ise(5, 3, packed, 0) == [7, 3, 0]


def test_ise_trit_roundtrip():
    """QUANT_3（纯 trit，5 值 8 位）往返。"""
    for values in ([0, 1, 2, 0, 1], [2, 2, 2, 2, 2], [1, 0, 2, 1, 0]):
        packed, total = encode_ise(1, values)
        assert total == 8
        assert _decode_ise(1, len(values), packed, 0) == values


def test_ise_quint_roundtrip():
    """QUANT_5（纯 quint，3 值 7 位）往返。"""
    for values in ([0, 1, 4], [4, 4, 4], [2, 3, 0]):
        packed, total = encode_ise(3, values)
        assert total == 7
        assert _decode_ise(3, len(values), packed, 0) == values


def test_ise_quint_tail_partial():
    """QUANT_10（1 bit + quint）：4 值（跨 2 个 quint 块，尾部不完整）。"""
    for values in ([0, 1, 2, 3], [5, 7, 9, 1], [9, 8, 7, 6]):
        packed, total = encode_ise(6, values)
        assert total == _ise_bits(4, 6)
        assert _decode_ise(6, 4, packed, 0) == values


def test_ise_trit_tail_partial():
    """QUANT_6（1 bit + trit）：7 值（跨 2 个 trit 块）。"""
    for values in ([0, 1, 5, 3, 2, 4, 1], [5, 5, 5, 5, 5, 5, 5]):
        packed, total = encode_ise(4, values)
        assert total == _ise_bits(7, 4)
        assert _decode_ise(4, 7, packed, 0) == values


def test_ise_quant32_bits_only():
    """QUANT_32（纯 5 bit）往返。"""
    values = [0, 31, 17, 3, 30, 1]
    packed, total = encode_ise(11, values)
    assert total == 30
    assert _decode_ise(11, 6, packed, 0) == values


# ---------------------------------------------------------------------------
# 合成块解码
# ---------------------------------------------------------------------------


def _constant_u16_block(r: int, g: int, b: int, a: int) -> bytes:
    """const U16 块：0xFC 家族 + 4×16bit 颜色（ARM 的 cbytes 布局）。"""
    head = bytes([0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    color = b"".join(v.to_bytes(2, "little") for v in (r, g, b, a))
    return head + color


def test_constant_block_u16():
    """const U16 块：整块填充 16bit 颜色的高 8 位。"""
    blk = _constant_u16_block(0x1234, 0xABCD, 0x00FF, 0x8000)
    out = decode_block(blk, 4, 4)
    assert len(out) == 4 * 4 * 4
    assert out == bytes([0x12, 0xAB, 0x00, 0x80]) * 16


def test_constant_block_6x6():
    """const 块与块尺寸无关：6x6 也全块同色。"""
    blk = _constant_u16_block(0x0102, 0x0304, 0x0506, 0x0708)
    out = decode_block(blk, 6, 6)
    assert out == bytes([0x01, 0x03, 0x05, 0x07]) * 36


def test_void_extent_invalid_low_ge_high():
    """void-extent：low >= high 且非全 1 → AstcError（spec 非法块）。"""
    # 0xFC 头 + extent 全 0（low=0 high=0）+ 颜色任意
    blk = bytes([0xFC, 0xFF]) + b"\x00" * 6 + b"\x12\x34\x56\x78\x9a\xbc\xde\xf0"
    with pytest.raises(AstcError):
        decode_block(blk, 4, 4)


def test_void_extent_all_ones_ok():
    """void-extent：extent 全 1（整图语义）→ 合法，按颜色填充。"""
    blk = _constant_u16_block(0xFF00, 0xFF00, 0xFF00, 0xFF00)
    out = decode_block(blk, 4, 4)
    assert out == bytes([0xFF, 0xFF, 0xFF, 0xFF]) * 16


def test_weights_zero_endpoint0():
    """weight 全 0 → 全部 texel = 端点 0。

    0x42（grid 4x4 QUANT_4）块：16 权重全 0；LUMINANCE 端点 (10, 200)，
    QUANT_256 颜色。预期全块 (10,10,10,255)。
    """
    # 手工按布局填：mode=0x42@0、pc=1、cem=0@13、颜色 2×8bit@17、权重 32bit 尾部
    buf = bytearray(16)
    _write_bits(buf, 0x42, 11, 0)
    _write_bits(buf, 0, 2, 11)  # pc=1
    _write_bits(buf, 0, 4, 13)  # cem=0 LUMINANCE
    _write_bits(buf, 10, 8, 17)
    _write_bits(buf, 200, 8, 25)
    # 权重全 0 → 尾部字节全 0（权重区 LSB-first 全 0）
    blk = bytes(buf)
    out = decode_block(blk, 4, 4)
    assert out == bytes([10, 10, 10, 255]) * 16


def test_weights_max_endpoint1():
    """weight 全 1（QUANT_4 unquant=21）→ 手工可推演 lerp 结果。

    ep0=10, ep1=200（16-bit 展开 2570/51400），w=21：
    ((2570*43 + 51400*21 + 32) >> 6) >> 8 = 72。
    """
    buf = bytearray(16)
    _write_bits(buf, 0x42, 11, 0)
    _write_bits(buf, 0, 2, 11)
    _write_bits(buf, 0, 4, 13)
    _write_bits(buf, 10, 8, 17)
    _write_bits(buf, 200, 8, 25)
    # 权重 16×2bit 全 1：QUANT_4 权重区 = 32 位，写尾部（LSB-first）
    # bswapped[0..3] = 0b010101... → 每字节 0x55
    wbytes = bytes([0x55]) * 4
    for i in range(4):
        buf[15 - i] = _BITREV8[wbytes[i]]
    blk = bytes(buf)
    out = decode_block(blk, 4, 4)
    assert out == bytes([72, 72, 72, 255]) * 16


def test_rgb_direct_block():
    """CEM 8（RGB direct 6 值）：端点 (10,20,30)→(200,210,220)，权重全 0。"""
    buf = bytearray(16)
    _write_bits(buf, 0x42, 11, 0)
    _write_bits(buf, 0, 2, 11)
    _write_bits(buf, 8, 4, 13)
    for i, v in enumerate((10, 200, 20, 210, 30, 220)):
        _write_bits(buf, v, 8, 17 + 8 * i)
    blk = bytes(buf)
    out = decode_block(blk, 4, 4)
    assert out == bytes([10, 20, 30, 255]) * 16


def test_truncated_data_raises():
    """数据不足 16 字节 → AstcError。"""
    with pytest.raises(AstcError):
        decode_block(b"\x42" * 10, 4, 4)


def test_reserved_block_mode_raises():
    """保留 block mode（0x00 家族：位 0-3 全 0）→ AstcError。"""
    blk = bytes([0x00]) + b"\x00" * 15
    with pytest.raises(AstcError):
        decode_block(blk, 4, 4)


def test_hdr_endpoint_decodes():
    """HDR 端点格式（CEM 2/3/7/11/14/15）可解码：HDR 通道 clamp 到 [0,255]。"""
    for cem in (2, 3, 7, 11, 14, 15):
        buf = bytearray(16)
        _write_bits(buf, 0x42, 11, 0)
        _write_bits(buf, 0, 2, 11)
        _write_bits(buf, cem, 4, 13)
        for i, v in enumerate((255, 0, 255, 0, 255, 0, 255, 0)):
            _write_bits(buf, v, 8, 17 + 8 * i)
        out = decode_block(bytes(buf), 4, 4)
        assert len(out) == 64
        assert all(0 <= v <= 255 for v in out)


def test_hdr_luminance_large_handcalc():
    """HDR luminance large range（CEM 2）手算：v0=240, v1=0 → 端点0 16-bit=128。

    v1 < v0 → y0 = (0<<4)+8 = 8, y1 = (240<<4)-8 = 3832；端点 16-bit =
    (8<<4, 3832<<4) = (128, 61312)。权重全 0 → 全块 = 端点 0 = 128 →
    piecewise: E=0, M=128 → Mt=384 → Cf=48 → fp16 次正规 → u8 = 0。
    alpha 0x7800 (1.0) → 255。
    """
    buf = bytearray(16)
    _write_bits(buf, 0x42, 11, 0)
    _write_bits(buf, 0, 2, 11)
    _write_bits(buf, 2, 4, 13)  # CEM 2 HDR luminance large range
    _write_bits(buf, 240, 8, 17)
    _write_bits(buf, 0, 8, 25)
    out = decode_block(bytes(buf), 4, 4)
    assert out == bytes([0, 0, 0, 255]) * 16


def test_f16_constant_raises():
    """F16 const 块（bit9 置位）→ AstcError（HDR）。"""
    blk = bytes([0xFC, 0xFD | 0x02]) + b"\xff" * 6 + b"\x00" * 8
    with pytest.raises(AstcError):
        decode_block(blk, 4, 4)


def test_dual_plane_4_partitions_raises():
    """dual-plane + 4 partitions → AstcError（spec 非法组合）。"""
    buf = bytearray(16)
    _write_bits(buf, 0x5DE, 11, 0)  # 0xde + bit8/10 → dual-plane grid 3x3
    _write_bits(buf, 3, 2, 11)  # pc=4
    blk = bytes(buf)
    with pytest.raises(AstcError):
        decode_block(blk, 4, 4)


def test_dual_plane_block_decodes():
    """dual-plane 合法块（3x3 grid ×2 平面）可解码且输出合法范围。"""
    buf = bytearray(16)
    _write_bits(buf, 0x5DE, 11, 0)  # dual-plane
    _write_bits(buf, 0, 2, 11)  # pc=1
    _write_bits(buf, 0, 4, 13)  # cem=0 LUMINANCE
    _write_bits(buf, 10, 8, 17)
    _write_bits(buf, 200, 8, 25)
    _write_bits(buf, 0, 2, 128 - 36 - 2)  # plane2_component = 0（R）
    # 权重 18×2bit 全 0（尾部 36 位）
    blk = bytes(buf)
    out = decode_block(blk, 4, 4)
    assert len(out) == 64
    assert all(0 <= v <= 255 for v in out)
    assert out[0:4] == bytes([10, 10, 10, 255])  # 权重全 0 → 端点 0


def test_all_weight_quants_smoke():
    """各权重 quant 构造块：合法模式可解，spec 非法模式抛 AstcError。

    0x441（grid 4x4 QUANT_10）、0x51（QUANT_3）、0x42（QUANT_4）、
    0x52（QUANT_6）、0x43（QUANT_8）、0x53（QUANT_10）、0x03（grid 4x2
    QUANT_6 21bits <24 非法）、0x41（16bits 非法）、0x04（grid 12x2 非法）。
    """
    legal = (0x441, 0x51, 0x42, 0x52, 0x43, 0x53)
    illegal = (0x41, 0x0E, 0x0F, 0x04, 0x05, 0x03, 0x14, 0x15)
    for bm in legal:
        buf = bytearray(16)
        _write_bits(buf, bm, 11, 0)
        _write_bits(buf, 0, 2, 11)
        _write_bits(buf, 0, 4, 13)
        _write_bits(buf, 10, 8, 17)
        _write_bits(buf, 200, 8, 25)
        out = decode_block(bytes(buf), 4, 4)
        assert len(out) == 64
        assert all(0 <= v <= 255 for v in out)
    for bm in illegal:
        buf = bytearray(16)
        _write_bits(buf, bm, 11, 0)
        _write_bits(buf, 0, 2, 11)
        _write_bits(buf, 0, 4, 13)
        with pytest.raises(AstcError):
            decode_block(bytes(buf), 4, 4)


def test_decode_region():
    """decode_region：只解覆盖区域的块，输出区域 RGBA8。"""
    # 2x2 块 = 8x8 像素：0 块 const 红，其余 const 蓝
    red = _constant_u16_block(0xFF00, 0x0000, 0x0000, 0xFF00)
    blue = _constant_u16_block(0x0000, 0x0000, 0xFF00, 0xFF00)
    data = red + blue + blue + blue
    # 区域 (4,4)-(8,8)（右下 4x4 属于块 1）
    reg = decode_region(data, 8, 8, 4, 4, 4, 4, 8, 8)
    assert reg == bytes([0, 0, 255, 255]) * 16
    # 区域 (0,0)-(8,8) = 整图：左上 4x4 红，其余蓝
    full = decode_region(data, 8, 8, 4, 4, 0, 0, 8, 8)
    red_px = bytes([255, 0, 0, 255])
    blue_px = bytes([0, 0, 255, 255])
    for y in range(8):
        row = full[y * 32 : (y + 1) * 32]
        assert row[:16] == red_px * 4 if y < 4 else row[:16] == blue_px * 4
        assert row[16:] == blue_px * 4


# ---------------------------------------------------------------------------
# 真实 APK 冒烟 + astcenc 对拍
# ---------------------------------------------------------------------------


def _load_sc(container: str):
    from game_catalog.sc2 import load_sc

    with zipfile.ZipFile(str(APK)) as z:
        return load_sc(z.read(container))


def _ktx_data(payload: bytes) -> bytes:
    """KTX1 容器 → ASTC 数据（64B 头 + imageSize 4B）。"""
    assert payload[:4] == b"\xabKTX"
    return payload[68:]


def _sctx_data(payload: bytes) -> bytes:
    """Supercell .sctx → ASTC 数据：u32@0 + 52 = 起点（对拍 3 纹理验证）。"""
    return payload[int.from_bytes(payload[0:4], "little") + 52 :]


@_real_apk
def test_real_ui_sc_4x4_smoke():
    """ui.sc 内嵌 KTX（ASTC 4x4）：前 64 块解码不崩、范围合法、统计模式分布。"""
    sc = _load_sc("assets/sc/ui.sc")
    td = sc.texture_data(6)
    data = _ktx_data(td.data)
    assert len(data) % 16 == 0
    modes: dict[int, int] = {}
    for i in range(64):
        blk = data[i * 16 : (i + 1) * 16]
        out = decode_block(blk, 4, 4)
        assert len(out) == 64
        assert all(0 <= v <= 255 for v in out)
        modes[blk[0]] = modes.get(blk[0], 0) + 1
    # 常见模式必须出现（0x42 grid 4x4 QUANT_4、0xFC const）
    assert 0x42 in modes or 0xFC in modes


@_real_apk
def test_real_buildings_sctx_6x6_smoke():
    """buildings.sc 外部 .sctx（ASTC 6x6）：前 64 块解码不崩、范围合法。"""
    sc = _load_sc("assets/sc/buildings.sc")
    td = sc.texture_data(0)
    with zipfile.ZipFile(str(APK)) as z:
        sctx_name = next(n for n in z.namelist() if n.endswith(td.external_texture))
        sctx = _sctx_data(z.read(sctx_name))
    assert len(sctx) % 16 == 0
    for i in range(64):
        blk = sctx[i * 16 : (i + 1) * 16]
        out = decode_block(blk, 6, 6)
        assert len(out) == 6 * 6 * 4
        assert all(0 <= v <= 255 for v in out)


@_real_apk
def test_astcenc_parity_tex6():
    """与官方 astcenc 5.7.0 输出逐像素对拍（ui.sc tex6，912x1024 全图）。"""
    ref_png = REF / "tex6.png"
    if not ref_png.is_file():
        pytest.skip("参考 PNG 不存在（/tmp/astc-ref/tex6.png）")
    sc = _load_sc("assets/sc/ui.sc")
    td = sc.texture_data(6)
    data = _ktx_data(td.data)
    w, h = td.width, td.height
    out = bytearray(w * h * 4)
    bw, bh = w // 4, h // 4
    for by in range(bh):
        for bx in range(bw):
            blk = data[(by * bw + bx) * 16 : (by * bw + bx + 1) * 16]
            px = decode_block(blk, 4, 4)
            for yy in range(4):
                src_off = yy * 16
                dst_off = (by * 4 + yy) * w * 4 + bx * 16
                out[dst_off : dst_off + 16] = px[src_off : src_off + 16]
    # 读参考 PNG（RGBA8）
    ref = _read_ref_png(ref_png, w, h)
    diff = sum(1 for a, b in zip(out, ref) if a != b)
    assert diff == 0, f"与 astcenc 不一致像素数: {diff}"


@_real_apk
def test_astcenc_parity_buildings0():
    """与官方 astcenc 5.7.0 输出逐像素对拍（buildings_0.sctx，608x1004 全图）。"""
    ref_png = REF / "b0.png"
    if not ref_png.is_file():
        pytest.skip("参考 PNG 不存在（/tmp/astc-ref/b0.png）")
    sc = _load_sc("assets/sc/buildings.sc")
    td = sc.texture_data(0)
    with zipfile.ZipFile(str(APK)) as z:
        sctx_name = next(n for n in z.namelist() if n.endswith(td.external_texture))
        data = _sctx_data(z.read(sctx_name))
    w, h = td.width, td.height
    bw, bh = (w + 5) // 6, (h + 5) // 6
    out = bytearray(w * h * 4)
    for by in range(bh):
        for bx in range(bw):
            blk = data[(by * bw + bx) * 16 : (by * bw + bx + 1) * 16]
            px = decode_block(blk, 6, 6)
            for yy in range(6):
                if by * 6 + yy >= h:
                    break
                base = (by * 6 + yy) * w * 4 + bx * 24
                out[base : base + min(24, (w - bx * 6) * 4)] = px[
                    yy * 24 : (yy + 1) * 24
                ][: min(24, (w - bx * 6) * 4)]
    ref = _read_ref_png(ref_png, w, h)
    diff = sum(1 for a, b in zip(out, ref) if a != b)
    assert diff == 0, f"与 astcenc 不一致像素数: {diff}"


def _read_ref_png(path: Path, w: int, h: int) -> bytes:
    """读 RGBA8 PNG 原始像素（含逆滤镜；astcenc 输出）。"""
    import struct
    import zlib

    d = path.read_bytes()
    pos, idat, ct = 8, b"", 0
    while pos < len(d):
        ln = struct.unpack(">I", d[pos : pos + 4])[0]
        typ = d[pos + 4 : pos + 8]
        if typ == b"IHDR":
            _, _, bd, ct = struct.unpack(">IIBB", d[pos + 8 : pos + 18])
        elif typ == b"IDAT":
            idat += d[pos + 8 : pos + 8 + ln]
        pos += 12 + ln
    nc = 4 if ct == 6 else 3
    raw = zlib.decompress(idat)
    stride = w * nc + 1
    out = bytearray(w * h * nc)
    prev = bytearray(w * nc)
    for y in range(h):
        row = raw[y * stride : (y + 1) * stride]
        f = row[0]
        line = bytearray(row[1:])
        if f == 1:  # Sub
            for i in range(nc, w * nc):
                line[i] = (line[i] + line[i - nc]) & 0xFF
        elif f == 2:  # Up
            for i in range(w * nc):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:  # Average
            for i in range(w * nc):
                left = line[i - nc] if i >= nc else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif f == 4:  # Paeth
            for i in range(w * nc):
                left = line[i - nc] if i >= nc else 0
                up = prev[i]
                ul = prev[i - nc] if i >= nc else 0
                p = left + up - ul
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - ul)
                pred = left if pa <= pb and pa <= pc else (up if pb <= pc else ul)
                line[i] = (line[i] + pred) & 0xFF
        out[y * w * nc : (y + 1) * w * nc] = line
        prev = line
    px = bytearray(w * h * 4)
    for y in range(h):
        row = out[y * w * nc : (y + 1) * w * nc]
        for x in range(w):
            px[(y * w + x) * 4 : (y * w + x + 1) * 4] = (
                row[x * nc],
                row[x * nc + 1],
                row[x * nc + 2],
                255 if nc == 3 else row[x * nc + 3],
            )
    return bytes(px)
