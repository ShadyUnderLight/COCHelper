"""sc2 容器头与 Header descriptor 解析测试。

fixture 构造：复用 test_fbs.FbBuilder 手工拼装 SC2 V6 文件字节——
[SC magic 2B][version u16][4B 跳过][descriptor_size u32][descriptor flatbuffer]。
其中 Header table 的 metadata vector 元素是 table（AssetMetaEntry：
name string + hash [ubyte]），hash 用 add_string(bytes) 构造——string 与
[ubyte] vector 的布局完全一致（u32 len + 原始字节），字节级等价。
"""

import struct

import pytest

from game_catalog.errors import CatalogError
from game_catalog.sc2 import (
    AssetMetaEntry,
    ScHeader,
    metadata_entries,
    parse_sc_header,
)
from test_fbs import FbBuilder


def build_sc_bytes(descriptor: bytes, version: int = 6,
                   size_override: int | None = None) -> bytes:
    """SC 头字节 + descriptor。size_override 用于构造越界场景。"""
    size = len(descriptor) if size_override is None else size_override
    return (b"SC" + struct.pack("<H", version) + b"\x00" * 4
            + struct.pack("<I", size) + descriptor)


def build_header_with_metadata() -> bytes:
    """Header table：shape_count=683、texture_count=1234、resources_offset、
    compressed_size + metadata vector（2 个 AssetMetaEntry：一个带 16B hash，
    一个 hash 字段缺失）。
    """
    b = FbBuilder()
    name1 = b.add_string("icon_unit_barbarian")
    name2 = b.add_string("building_town_hall")
    hash_vec = b.add_string(bytes(range(1, 17)))  # 16B，布局同 [ubyte] vector
    entry1 = b.add_table({0: ("uoffset", name1), 1: ("uoffset", hash_vec)})
    entry2 = b.add_table({0: ("uoffset", name2)})  # hash 字段缺失
    meta = b.add_vector([entry1, entry2])
    root = b.add_table({
        2: ("u32", 683),
        4: ("u32", 1234),
        8: ("u32", 0x100000),
        10: ("uoffset", meta),
        11: ("u32", 999888),
    })
    return build_sc_bytes(b.finish(root))


# ---------------------------------------------------------------------------
# 合法解析
# ---------------------------------------------------------------------------


def test_parse_sc_header_fields():
    data = build_header_with_metadata()
    h = parse_sc_header(data)
    assert h == ScHeader(
        version=6,
        descriptor_size=len(data) - 12,
        shape_count=683,
        movie_clips_count=0,      # 未声明 → 0
        texture_count=1234,
        text_fields_count=0,      # 未声明 → 0
        resources_offset=0x100000,
        textures_length=0,        # 未声明 → 0
        compressed_size=999888,
        external_matrix_bank_size=0,  # 未声明 → 0
    )


def test_metadata_entries_names_and_hashes():
    data = build_header_with_metadata()
    h = parse_sc_header(data)
    entries = metadata_entries(data, h)
    assert entries == [
        AssetMetaEntry(name="icon_unit_barbarian", hash=bytes(range(1, 17))),
        AssetMetaEntry(name="building_town_hall", hash=None),
    ]


def test_empty_hash_vector_returns_empty_bytes():
    """hash 字段存在但长度为 0 → b""（区别于字段缺失 → None）。"""
    b = FbBuilder()
    name = b.add_string("empty_hash")
    empty_vec = b.add_string(b"")  # u32 0 + 无字节
    entry = b.add_table({0: ("uoffset", name), 1: ("uoffset", empty_vec)})
    meta = b.add_vector([entry])
    root = b.add_table({10: ("uoffset", meta)})
    data = build_sc_bytes(b.finish(root))
    h = parse_sc_header(data)
    assert metadata_entries(data, h) == [AssetMetaEntry(name="empty_hash", hash=b"")]


def test_missing_metadata_vector_returns_empty():
    b = FbBuilder()
    root = b.add_table({2: ("u32", 7)})
    data = build_sc_bytes(b.finish(root))
    h = parse_sc_header(data)
    assert h.shape_count == 7
    assert metadata_entries(data, h) == []


# ---------------------------------------------------------------------------
# 错误场景
# ---------------------------------------------------------------------------


def test_bad_magic_raises():
    data = build_sc_bytes(b"\x00" * 4)  # 任意 descriptor
    bad = b"XX" + data[2:]
    with pytest.raises(CatalogError, match="magic"):
        parse_sc_header(bad)


def test_unsupported_version_raises():
    data = build_sc_bytes(b"\x00" * 4, version=5)
    with pytest.raises(CatalogError, match="版本"):
        parse_sc_header(data)


def test_descriptor_out_of_bounds_raises():
    data = build_sc_bytes(b"\x00" * 4, size_override=1000)
    with pytest.raises(CatalogError, match="越界"):
        parse_sc_header(data)


def test_truncated_header_raises():
    with pytest.raises(CatalogError, match="过短"):
        parse_sc_header(b"SC\x06\x00")  # 4 字节 < 12
    with pytest.raises(CatalogError, match="过短"):
        parse_sc_header(b"")


def test_malformed_descriptor_content_raises():
    """descriptor 内 root uoffset 0xFFFFFFFF → fbs ValueError → CatalogError。"""
    data = build_sc_bytes(b"\xff\xff\xff\xff")
    with pytest.raises(CatalogError):
        parse_sc_header(data)


def test_metadata_entries_descriptor_out_of_bounds_raises():
    """header 与 data 不一致（data 被截短）时 metadata_entries 也要报错。"""
    data = build_header_with_metadata()
    h = parse_sc_header(data)
    with pytest.raises(CatalogError, match="越界"):
        metadata_entries(data[:20], h)


def _descriptor_root(data: bytes) -> int:
    """Header root table 绝对偏移（descriptor 起点 12 + root uoffset）。"""
    return 12 + struct.unpack("<I", data[12:16])[0]


def _table_slot_rel(data: bytes, table_off: int, slot: int) -> int:
    """table 的 vtable 中某 slot 的相对偏移（0 = 缺省）。"""
    soffset = struct.unpack("<i", data[table_off:table_off + 4])[0]
    vtable = table_off - soffset
    return struct.unpack(
        "<H", data[vtable + 4 + 2 * slot:vtable + 6 + 2 * slot])[0]


def test_u32_field_out_of_bounds_raises_catalog_error():
    """伪造 vtable：table_size=0xFFFF + slot 偏移 0x8000（指向 buffer 末尾之外）。

    _u32_field 必须抛 CatalogError 而非裸 struct.error（struct.error 不是
    ValueError 子类，会绕过模块的异常包装契约）。
    """
    b = FbBuilder()
    root = b.add_table({2: ("u32", 683)})
    data = bytearray(build_sc_bytes(b.finish(root)))
    root_pos = _descriptor_root(bytes(data))
    soffset = struct.unpack("<i", bytes(data[root_pos:root_pos + 4]))[0]
    vtable_pos = root_pos - soffset
    data[vtable_pos + 2:vtable_pos + 4] = b"\xff\xff"  # table_size → 0xFFFF
    data[vtable_pos + 8:vtable_pos + 10] = b"\x00\x80"  # slot2 偏移 → 0x8000
    with pytest.raises(CatalogError, match="越界"):
        parse_sc_header(bytes(data))


def test_ubyte_vector_length_out_of_bounds_raises():
    """伪造 hash vector 长度字段超界 → _ubyte_vector_bytes 抛 CatalogError。"""
    data = bytearray(build_header_with_metadata())
    root_pos = _descriptor_root(bytes(data))
    meta_field = root_pos + _table_slot_rel(bytes(data), root_pos, 10)
    vec_pos = meta_field + struct.unpack(
        "<I", bytes(data[meta_field:meta_field + 4]))[0]
    entry_pos = vec_pos + 4 + struct.unpack(
        "<I", bytes(data[vec_pos + 4:vec_pos + 8]))[0]
    hash_field = entry_pos + _table_slot_rel(bytes(data), entry_pos, 1)
    hash_vec = hash_field + struct.unpack(
        "<I", bytes(data[hash_field:hash_field + 4]))[0]
    data[hash_vec:hash_vec + 4] = struct.pack("<I", 0xFFFF)  # 长度 → 越界
    h = parse_sc_header(bytes(data))
    with pytest.raises(CatalogError, match="越界"):
        metadata_entries(bytes(data), h)
