"""Scaleform SC2 V6 容器头与 Header descriptor 解析（纯 stdlib）。

COC APK 内 `assets/sc/*.sc` 的容器格式（已对拍 `base.apk.1` 的 `ui.sc`）：

- off0-1: 2 字节 magic `SC`
- off2-3: version u16 LE（当前为 6）
- off4-7: 4 字节跳过（全 0）
- off8-11: descriptor_size u32 LE
- off12 起: descriptor FlatBuffer（Header table），root uoffset 相对 descriptor
  起点（真实值 0x38），descriptor 结束 = 12 + descriptor_size
- descriptor 之后是 body（真实 APK 中为 zstd 压缩，本模块不涉及）

Header table 字段语义参考 sc-workshop/SupercellFlash 的 Header.fbs
（MIT），flatbuffers table 语义：uint 字段缺省时用默认值 0。
metadata 为 AssetMetaEntry table 的 vector：
`AssetMetaEntry { name: string (slot 0), hash: [ubyte] (slot 1) }`。

一切畸形数据统一抛 CatalogError（fail loud，不静默降级）。
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

from game_catalog.errors import CatalogError
from game_catalog.fbs import FlatBuffer

SC_MAGIC = b"SC"
SC_VERSION = 6
SC_DESCRIPTOR_OFFSET = 12  # 头部固定字节数

# Header table 槽位（Header.fbs 字段顺序）
_SLOT_METADATA = 10


@dataclass(frozen=True)
class ScHeader:
    """SC2 容器头 + Header table 标量字段（uint 字段缺省为 0）。"""

    version: int
    descriptor_size: int
    shape_count: int
    movie_clips_count: int
    texture_count: int
    text_fields_count: int
    resources_offset: int
    textures_length: int
    compressed_size: int
    external_matrix_bank_size: int


@dataclass(frozen=True)
class AssetMetaEntry:
    """metadata 条目：export 名 + 内容 hash 字节（字段缺失为 None）。"""

    name: str
    hash: bytes | None


def _descriptor(data: bytes, descriptor_size: int) -> bytes:
    """校验并切出 descriptor 区（越界 → CatalogError）。"""
    if SC_DESCRIPTOR_OFFSET + descriptor_size > len(data):
        raise CatalogError(
            f"SC2 descriptor 越界: 起点 {SC_DESCRIPTOR_OFFSET} 大小 "
            f"{descriptor_size} 超出数据长度 {len(data)}")
    return data[SC_DESCRIPTOR_OFFSET:SC_DESCRIPTOR_OFFSET + descriptor_size]


def _u32_field(fb: FlatBuffer, buf: bytes, table_off: int, slot: int) -> int:
    """table 中 inline uint32 标量；字段缺省返回 0。"""
    off = fb.table_field(table_off, slot)
    if off == 0:
        return 0
    return struct.unpack("<I", buf[off:off + 4])[0]


def _ubyte_vector_bytes(fb: FlatBuffer, buf: bytes, vec_off: int) -> bytes:
    """[ubyte] vector 的原始字节（元素 1 字节、紧邻 u32 len 连续排列）。"""
    length = fb.vector_len(vec_off)
    if length == 0:
        return b""
    first = fb.vector_elem(vec_off, 0, 1, alignment=1)
    if first + length > len(buf):
        raise CatalogError(
            f"SC2 [ubyte] vector 越界: 起点 {first} 长度 {length}，"
            f"数据长度 {len(buf)}")
    return buf[first:first + length]


def parse_sc_header(data: bytes) -> ScHeader:
    """解析 SC2 容器头 + Header table 标量字段。

    magic / version / descriptor 越界 / 截断数据一律抛 CatalogError。
    """
    if len(data) < SC_DESCRIPTOR_OFFSET:
        raise CatalogError(
            f"SC2 数据过短: {len(data)} 字节（头部需要 >= {SC_DESCRIPTOR_OFFSET}）")
    if data[:2] != SC_MAGIC:
        raise CatalogError(
            f"SC2 magic 不符: {data[:2]!r}（期望 {SC_MAGIC!r}）")
    version = struct.unpack("<H", data[2:4])[0]
    if version != SC_VERSION:
        raise CatalogError(
            f"不支持的 SC2 版本: {version}（仅支持 {SC_VERSION}）")
    descriptor_size = struct.unpack("<I", data[8:12])[0]
    descriptor = _descriptor(data, descriptor_size)
    try:
        fb = FlatBuffer(descriptor)
        root = fb.root()
        return ScHeader(
            version=version,
            descriptor_size=descriptor_size,
            shape_count=_u32_field(fb, descriptor, root, 2),
            movie_clips_count=_u32_field(fb, descriptor, root, 3),
            texture_count=_u32_field(fb, descriptor, root, 4),
            text_fields_count=_u32_field(fb, descriptor, root, 5),
            resources_offset=_u32_field(fb, descriptor, root, 8),
            textures_length=_u32_field(fb, descriptor, root, 9),
            compressed_size=_u32_field(fb, descriptor, root, 11),
            external_matrix_bank_size=_u32_field(fb, descriptor, root, 12),
        )
    except ValueError as e:
        raise CatalogError(f"SC2 Header descriptor 解析失败: {e}") from e


def metadata_entries(data: bytes, header: ScHeader) -> list[AssetMetaEntry]:
    """从 descriptor 内解析 metadata vector（AssetMetaEntry 列表）。

    name 字段缺失 → CatalogError；hash 字段缺失 → None；
    hash 存在但为空 → b""。
    """
    descriptor = _descriptor(data, header.descriptor_size)
    try:
        fb = FlatBuffer(descriptor)
        root = fb.root()
        meta_field = fb.table_field(root, _SLOT_METADATA)
        if meta_field == 0:
            return []
        count = fb.vector_len(meta_field)
        entries: list[AssetMetaEntry] = []
        for i in range(count):
            entry_table = fb.table(fb.vector_elem(meta_field, i, 4))
            name_off = fb.table_field(entry_table, 0)
            if name_off == 0:
                raise CatalogError("SC2 AssetMetaEntry 缺少 name 字段")
            name = fb.string(name_off)
            hash_off = fb.table_field(entry_table, 1)
            entry_hash: bytes | None = None
            if hash_off != 0:
                entry_hash = _ubyte_vector_bytes(fb, descriptor, hash_off)
            entries.append(AssetMetaEntry(name=name, hash=entry_hash))
        return entries
    except CatalogError:
        raise
    except ValueError as e:
        raise CatalogError(f"SC2 metadata 解析失败: {e}") from e
