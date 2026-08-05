"""KTX 1.x / Supercell SCTX 纹理容器解析（纯 stdlib）。

用途：把 SC2 `TextureData`（sc2.py）的两种载荷变成统一的「压缩纹理图像」
对象，供 ASTC 解码（astc.decode_region）得到 RGBA8 区域，是渲染管线
（Issue #30）的纹理入口。

**KTX 1.x**（ui.sc 内嵌数据，实测 2026-08-05 对拍 base.apk.1）：
- 文件头：12B magic `\xabKTX 11\xbb\r\n\x1a\n` + 13 个 u32 LE（字节序标识 /
  glType / glTypeSize / glFormat / glInternalFormat / glBaseInternalFormat /
  pixelWidth / pixelHeight / pixelDepth / numberOfArrayElements /
  numberOfFaces / numberOfMipmapLevels / bytesOfKeyValueData），共 64B
- 字节序标识恒为 0x04030201（小端）
- 压缩格式时 glType=0、glTypeSize=1、glFormat=0、glBaseInternalFormat=6408
  （GL_RGBA8）；pixelDepth=0、arrayElements=0、faces=1、mips=1、kvb=0
  —— APK 全量（~180 个 .sc 的 KTX）无例外
- glInternalFormat 分布：0x93B0（4x4，ui.sc/clouds 等）、0x93B4（6x6，
  绝大多数）、0x93B7（8x8，debug.sc）；**块尺寸映射按 GL 官方枚举**
  （任务书初稿 0x93B2→6x6 的猜测被真实数据否定：0x93B2=5x5、0x93B4=6x6、
  0x93B7=8x8）
- level0 数据：`64 + kvb` 处 u32 imageSize + 像素（单 mip 单 face、ASTC
  块行恒 4 字节对齐 → 无行填充）；imageSize 恒等于
  ceil(w/bw)*ceil(h/bh)*16，文件无尾随字节（全部实测一致）

**.sctx**（buildings.sc 外部纹理，实测 71 个全量一致）：
- 固定头 60B：u32@0 = 数据起点 - 52（元数据 blob 偏移，1420..26972 不等）；
  u32@4 = 36（buildings 风格变体标记，APK 内 28/32 变体是其他布局，
  不支持）；u32@8 = `SCTX` magic；u32@44 = pixel_type（208 =
  ASTC_RGBA8_6x6）；u16@48/u16@50 = 宽/高；u32@56 = 数据长度
- 数据区：起点 = u32@0 + 52，长度 = u32@56 = ceil(w/6)*ceil(h/6)*16
  （71/71 与 SC2 TextureData 宽高及 ASTC 6x6 块数精确一致，无尾随字节）
- 任务书 spike 猜测（u16@12=width、u16@14=height）被实测否定：off12/14
  恒为 0/26；宽高在 off48/50
- 头内另有若干常量字段（off12-44 之间）未解码——两文件变体一致且渲染
  不需要，不做语义猜测；需要时按 SupercellTexture Header.fbs 补充

一切畸形数据统一抛 CatalogError（fail loud，不静默降级）；decode_region
的 AstcError 原样透传（块数据损坏属于解码层错误）。
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

from game_catalog.astc import decode_region as _astc_decode_region
from game_catalog.errors import CatalogError

KTX_MAGIC = b"\xabKTX 11\xbb\r\n\x1a\n"
KTX_HEADER_SIZE = 64  # magic 12B + 13×u32
_KTX_ENDIAN_LITTLE = 0x04030201
# level0 数据前缀：imageSize u32 在 `64 + kvb` 处，像素在其后
_KTX_IMAGE_SIZE_FIELD = 4

SCTX_MAGIC = b"SCTX"
SCTX_HEADER_SIZE = 60  # 解析所需固定头（读至 u32@56 数据长度字段）
_SCTX_DATA_BASE = 52  # 数据起点 = u32@0 + 52（实证）
_SCTX_VARIANT_BUILDINGS = 36  # u32@4 变体标记（实测 28/32 = 其他布局）
_SCTX_PIXEL_TYPE_ASTC_6X6 = 208  # ASTC_RGBA8_6x6（社区枚举，实测 71/71）

# GL_COMPRESSED_RGBA_ASTC_*_KHR 官方枚举 → (block_w, block_h)。
# 实测 APK 只用 0x93B0/0x93B4/0x93B7，其余条目为规范完整性防御。
_ASTC_BLOCK = {
    0x93B0: (4, 4), 0x93B1: (5, 4), 0x93B2: (5, 5), 0x93B3: (6, 5),
    0x93B4: (6, 6), 0x93B5: (8, 5), 0x93B6: (8, 6), 0x93B7: (8, 8),
    0x93B8: (10, 5), 0x93B9: (10, 6), 0x93BA: (10, 8), 0x93BB: (10, 10),
    0x93BC: (12, 10), 0x93BD: (12, 12),
}

# 防资源放大：level0 上限 256MB（真实最大 ui.sc set0-4 的 16.7MB）。
# 检查发生在切片之前，伪造超大 imageSize 不会触发分配。
_MAX_IMAGE_BYTES = 256 * 1024 * 1024
# 宽高上限（KTX 的 u32 尺寸可伪造巨型值；真实最大 4096x4096）
_MAX_DIMENSION = 16384


@dataclass(frozen=True, slots=True)
class KtxImage:
    """KTX 1.x 解析结果：尺寸 + internal_format + level0 像素字节。"""

    width: int
    height: int
    internal_format: int
    block_w: int
    block_h: int
    level0: bytes

    def decode_region(self, x0: int, y0: int, x1: int, y1: int) -> bytes:
        """解码 (x0,y0)-(x1,y1) 区域 → RGBA8；AstcError 透传。"""
        return _astc_decode_region(self.level0, self.width, self.height,
                                   self.block_w, self.block_h,
                                   x0, y0, x1, y1)


@dataclass(frozen=True, slots=True)
class SctxImage:
    """Supercell SCTX 解析结果：尺寸 + pixel_type + level0 像素字节。"""

    width: int
    height: int
    pixel_type: int
    block_w: int
    block_h: int
    level0: bytes

    def decode_region(self, x0: int, y0: int, x1: int, y1: int) -> bytes:
        """解码 (x0,y0)-(x1,y1) 区域 → RGBA8；AstcError 透传。"""
        return _astc_decode_region(self.level0, self.width, self.height,
                                   self.block_w, self.block_h,
                                   x0, y0, x1, y1)


def parse_ktx(data: bytes) -> KtxImage:
    """解析 KTX 1.x 容器 → KtxImage（level0 = 第一个 mip 的第一个 face）。

    校验：magic / 字节序 / 尺寸 / 格式 / 深度 / 数组 / cube / mip 数 /
    kvb 与 level0 越界 / imageSize 与声明尺寸的块数一致性 / 256MB 上限。
    畸形一律 CatalogError（fail loud）。
    """
    if len(data) < KTX_HEADER_SIZE:
        raise CatalogError(
            f"KTX 数据过短: {len(data)} 字节（头部需要 {KTX_HEADER_SIZE}）")
    if not data.startswith(KTX_MAGIC):
        raise CatalogError(
            f"KTX magic 不符: {data[:12]!r}（期望 {KTX_MAGIC!r}）")
    (endian, _gt, _gts, _gf, gif, _gbif,
     pw, ph, pd, nae, faces, mips, kvb) = struct.unpack("<13I", data[12:64])
    if endian != _KTX_ENDIAN_LITTLE:
        raise CatalogError(
            f"KTX 字节序标识非法: 0x{endian:08x}（仅支持小端 "
            f"0x{_KTX_ENDIAN_LITTLE:08x}）")
    block = _ASTC_BLOCK.get(gif)
    if block is None:
        raise CatalogError(
            f"KTX 不支持的内部格式（glInternalFormat）: 0x{gif:04x}"
            f"（仅支持 ASTC {', '.join(f'0x{k:04x}' for k in _ASTC_BLOCK)}）")
    if pw == 0 or ph == 0 or pw > _MAX_DIMENSION or ph > _MAX_DIMENSION:
        raise CatalogError(
            f"KTX 尺寸非法: {pw}x{ph}（宽高需在 1..{_MAX_DIMENSION}）")
    if pd != 0:
        raise CatalogError(
            f"KTX 3D 纹理（pixelDepth={pd}）不支持（仅 2D）")
    if nae != 0:
        raise CatalogError(
            f"KTX 纹理数组（numberOfArrayElements={nae}）不支持")
    if faces != 1:
        raise CatalogError(
            f"KTX cube map（numberOfFaces={faces}）不支持（仅单 face）")
    if mips == 0:
        raise CatalogError("KTX numberOfMipmapLevels=0 非法（至少 1 级）")
    start = KTX_HEADER_SIZE + kvb
    if start + _KTX_IMAGE_SIZE_FIELD > len(data):
        raise CatalogError(
            f"KTX 数据越界: kv 区后 imageSize 前缀起点 {start} 超出数据长度 "
            f"{len(data)}")
    image_size = struct.unpack("<I", data[start:start + 4])[0]
    if image_size > _MAX_IMAGE_BYTES:
        raise CatalogError(
            f"KTX level0 大小 {image_size} 超过上限 {_MAX_IMAGE_BYTES}"
            "（防资源放大）")
    bw, bh = block
    expected = ((pw + bw - 1) // bw) * ((ph + bh - 1) // bh) * 16
    if image_size != expected:
        raise CatalogError(
            f"KTX imageSize {image_size} 与块尺寸不一致（预期 {expected}，"
            f"格式 0x{gif:04x} = ASTC {bw}x{bh}）")
    if start + 4 + image_size > len(data):
        raise CatalogError(
            f"KTX 数据截断: level0 起点 {start + 4} 长度 {image_size}，"
            f"数据长度 {len(data)}")
    return KtxImage(width=pw, height=ph, internal_format=gif,
                    block_w=bw, block_h=bh,
                    level0=data[start + 4:start + 4 + image_size])


def parse_sctx(data: bytes) -> SctxImage:
    """解析 Supercell SCTX 容器（buildings 风格）→ SctxImage。

    布局（实测 71 个全量一致）：u32@0+52 = 数据起点、u32@4=36 = 变体标记、
    u32@8=`SCTX`、u32@44=pixel_type（208=ASTC 6x6）、u16@48/50=宽/高、
    u32@56=数据长度。数据长度必须等于 ceil(w/6)*ceil(h/6)*16。
    其他头变体（u32@4=28/32，APK 内 508 个，布局不同）→ CatalogError。
    """
    if len(data) < SCTX_HEADER_SIZE:
        raise CatalogError(
            f"SCTX 数据过短: {len(data)} 字节（头部需要 {SCTX_HEADER_SIZE}）")
    if data[8:12] != SCTX_MAGIC:
        raise CatalogError(
            f"SCTX magic 不符: {data[8:12]!r}（期望 {SCTX_MAGIC!r}）")
    variant = struct.unpack("<I", data[4:8])[0]
    if variant != _SCTX_VARIANT_BUILDINGS:
        raise CatalogError(
            f"SCTX 头变体不支持: u32@4={variant}（仅支持 "
            f"{_SCTX_VARIANT_BUILDINGS} = buildings 风格；实测 28/32 是"
            "其他布局）")
    blob_size = struct.unpack("<I", data[0:4])[0]
    data_start = blob_size + _SCTX_DATA_BASE
    if data_start < SCTX_HEADER_SIZE:
        raise CatalogError(
            f"SCTX 数据起点 {data_start} 越界: 压入 {SCTX_HEADER_SIZE} "
            "字节固定头（u32@0 过小）")
    pixel_type = struct.unpack("<I", data[44:48])[0]
    if pixel_type != _SCTX_PIXEL_TYPE_ASTC_6X6:
        raise CatalogError(
            f"SCTX 不支持的 pixel_type: {pixel_type}（仅支持 "
            f"{_SCTX_PIXEL_TYPE_ASTC_6X6} = ASTC_RGBA8_6x6）")
    width, height = struct.unpack("<HH", data[48:52])
    if width == 0 or height == 0 or width > _MAX_DIMENSION or height > _MAX_DIMENSION:
        raise CatalogError(
            f"SCTX 尺寸非法: {width}x{height}（宽高需在 1..{_MAX_DIMENSION}）")
    data_len = struct.unpack("<I", data[56:60])[0]
    if data_len > _MAX_IMAGE_BYTES:
        raise CatalogError(
            f"SCTX 数据长度 {data_len} 超过上限 {_MAX_IMAGE_BYTES}"
            "（防资源放大）")
    bw, bh = 6, 6  # pixel_type 208 = ASTC_RGBA8_6x6
    expected = ((width + bw - 1) // bw) * ((height + bh - 1) // bh) * 16
    if data_len != expected:
        raise CatalogError(
            f"SCTX 数据长度 {data_len} 与块尺寸不一致（预期 {expected}，"
            f"pixel_type {pixel_type} = ASTC {bw}x{bh}）")
    if data_start + data_len > len(data):
        raise CatalogError(
            f"SCTX 数据截断: 起点 {data_start} 长度 {data_len}，"
            f"数据长度 {len(data)}")
    return SctxImage(width=width, height=height, pixel_type=pixel_type,
                     block_w=bw, block_h=bh,
                     level0=data[data_start:data_start + data_len])


def texture_to_rgba(img: KtxImage | SctxImage,
                    x0: int, y0: int, x1: int, y1: int) -> bytes:
    """统一区域解码入口：KtxImage/SctxImage 一视同仁 → RGBA8。

    Task 7 渲染生成器用它组合两种容器，无需感知容器类型；AstcError 透传。
    """
    return img.decode_region(x0, y0, x1, y1)
