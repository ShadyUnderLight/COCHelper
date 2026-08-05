"""sc2 容器头与 Header descriptor 解析测试。

fixture 构造：复用 test_fbs.FbBuilder 手工拼装 SC2 V6 文件字节——
[SC magic 2B][version u16][4B 跳过][descriptor_size u32][descriptor flatbuffer]。
其中 Header table 的 metadata vector 元素是 table（AssetMetaEntry：
name string + hash [ubyte]），hash 用 add_string(bytes) 构造——string 与
[ubyte] vector 的布局完全一致（u32 len + 原始字节），字节级等价。
"""

import ctypes
import struct

import pytest

from game_catalog.errors import CatalogError
from game_catalog.fbs import FlatBuffer
from game_catalog.sc2 import (
    AssetMetaEntry,
    ScFile,
    ScHeader,
    decode_body,
    load_libzstd,
    load_sc,
    metadata_entries,
    parse_data_storage,
    parse_export_names,
    parse_sc_header,
    parse_shapes,
    parse_textures,
    read_chunks,
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


def test_metadata_entries_count_limit_raises():
    """FIX-5 回归：metadata vector 条目数超上限（伪造长度字段 200 万）→
    CatalogError，不进入 O(n) 循环（防 512MB body 解压后的资源放大）。"""
    data = bytearray(build_header_with_metadata())
    root_pos = _descriptor_root(bytes(data))
    meta_field = root_pos + _table_slot_rel(bytes(data), root_pos, 10)
    vec_pos = meta_field + struct.unpack(
        "<I", bytes(data[meta_field:meta_field + 4]))[0]
    data[vec_pos:vec_pos + 4] = struct.pack("<I", 2_000_000)
    h = parse_sc_header(bytes(data))
    with pytest.raises(CatalogError, match="上限"):
        metadata_entries(bytes(data), h)


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


# ---------------------------------------------------------------------------
# Task 3: zstd body 解码 + DataStorage + ExportNames + chunks + load_sc
# ---------------------------------------------------------------------------

ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"


def _zstd_compress(data: bytes, level: int = 3) -> bytes:
    """用 libzstd 压缩（测试辅助；libzstd 不可用 → pytest.skip）。"""
    try:
        lib = load_libzstd()
    except CatalogError as e:
        pytest.skip(f"libzstd 不可用: {e}")
    lib.ZSTD_compressBound.restype = ctypes.c_size_t
    lib.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
    lib.ZSTD_compress.restype = ctypes.c_size_t
    lib.ZSTD_compress.argtypes = [
        ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p,
        ctypes.c_size_t, ctypes.c_int,
    ]
    cap = lib.ZSTD_compressBound(len(data))
    dst = ctypes.create_string_buffer(cap)
    n = lib.ZSTD_compress(dst, cap, data, len(data), level)
    if n == 0 or n > cap:
        raise RuntimeError(f"zstd 压缩失败: 返回码 {n}")
    return dst.raw[:n]


def build_data_storage(strings: list[str]) -> bytes:
    """DataStorage flatbuffer：slot 0 = strings vector<string>。"""
    b = FbBuilder()
    tokens = [b.add_string(s) for s in strings]
    vec = b.add_vector(tokens)
    root = b.add_table({0: ("uoffset", vec)})
    return b.finish(root)


def build_export_names(object_ids: list[int], name_refs: list[int]) -> bytes:
    """ExportNames flatbuffer：slot 0 = object_ids [ushort]，slot 1 = name_ref_ids [uint]。

    [ushort]/[uint] vector 长度字段写元素个数（flatbuffers 语义），
    用 add_raw_vector 构造（add_string(bytes) 只能表达 [ubyte] 等宽字节向量）。
    """
    b = FbBuilder()
    ids = b.add_raw_vector(
        len(object_ids), struct.pack("<" + "H" * len(object_ids), *object_ids))
    refs = b.add_raw_vector(
        len(name_refs), struct.pack("<" + "I" * len(name_refs), *name_refs))
    root = b.add_table({0: ("uoffset", ids), 1: ("uoffset", refs)})
    return b.finish(root)


def build_data_storage_with_prefix(strings: list[str]) -> bytes:
    """带 4 字节 size 前缀的 DataStorage（真实布局：resources_offset = 4 + size）。"""
    payload = build_data_storage(strings)
    return struct.pack("<I", len(payload)) + payload


def _build_minimal_textures(count: int) -> bytes:
    """Textures{textures: [TextureSet{highres}]} 最小构造（每条 highres 为最小 TextureData）。"""
    b = FbBuilder()
    tokens = []
    for _ in range(count):
        # TextureData{width u16, height u16} 最小表（slot 2/3）
        td = b.add_table({2: ("u16", 1), 3: ("u16", 1)})
        # TextureSet{highres: uoffset td}（slot 1）
        ts = b.add_table({1: ("uoffset", td)})
        tokens.append(ts)
    vec = b.add_vector(tokens)
    root = b.add_table({0: ("uoffset", vec)})
    return b.finish(root)


# -- decode_body -------------------------------------------------------------


def test_decode_body_uncompressed_passthrough():
    payload = bytes(range(256)) * 4
    assert decode_body(payload, None) == payload
    assert decode_body(payload, 0) == payload  # compressed_size=0 → 全量


def test_decode_body_compressed_size_slices_region():
    """compressed_size 指定时只取前 N 字节（body 后可能跟 matrix bank / 尾巴）。"""
    body = b"raw-body"
    trailing = ZSTD_MAGIC + b"\x00" * 8  # body 之后的 magic 不应干扰未压缩判断
    assert decode_body(body + trailing, len(body)) == body


def test_decode_body_zstd_roundtrip():
    payload = ("icon_unit_barbarian" * 50).encode() + bytes(range(64))
    compressed = _zstd_compress(payload)
    assert compressed.startswith(ZSTD_MAGIC)
    assert decode_body(compressed, None) == payload
    assert decode_body(compressed + b"TRAIL", len(compressed)) == payload


def test_decode_body_oversized_bound_rejected(monkeypatch):
    """bound 超 512MB → CatalogError（防 zip bomb）。

    真实 zstd 默认窗口上限 128MB，合法帧不可能声明 >512MB 内容——该守卫
    针对损坏/说谎帧（findFrameCompressedSize 失败路径另有 corrupt 测试）。
    这里用伪 lib 让 decompressBound 直接返回超限值，精确测守卫分支。
    """
    compressed = _zstd_compress(b"x" * 100)  # 真实帧，magic 检测通过

    class FakeLib:
        def ZSTD_findFrameCompressedSize(self, src, size):
            return size

        def ZSTD_decompressBound(self, src, size):
            return 600 * 1024 * 1024  # > 512MB

        def ZSTD_decompress(self, *args):
            raise AssertionError("不应到达解压步骤")

        def ZSTD_isError(self, n):
            return 0

    monkeypatch.setattr("game_catalog.sc2._libzstd", FakeLib())
    with pytest.raises(CatalogError, match="上限"):
        decode_body(compressed, None)


def test_decode_body_memory_error_wrapped(monkeypatch):
    """FIX-4 回归：create_string_buffer 分配失败（MemoryError）→ CatalogError，
    不裸 MemoryError traceback 中止（裸逃逸会让 spike 报告无法写盘）。"""
    compressed = _zstd_compress(b"y" * 100)

    class FakeLib:
        def ZSTD_findFrameCompressedSize(self, src, size):
            return size

        def ZSTD_decompressBound(self, src, size):
            return 4096

        def ZSTD_decompress(self, *args):
            raise AssertionError("不应到达解压步骤")

        def ZSTD_isError(self, n):
            return 0

    monkeypatch.setattr("game_catalog.sc2._libzstd", FakeLib())

    def _oom(*args, **kwargs):
        raise MemoryError("cannot allocate")

    monkeypatch.setattr("game_catalog.sc2.ctypes.create_string_buffer", _oom)
    with pytest.raises(CatalogError, match="内存"):
        decode_body(compressed, None)


def test_decode_body_corrupt_frame_raises():
    with pytest.raises(CatalogError):
        decode_body(ZSTD_MAGIC + b"\xff" * 32, None)


def test_decode_body_zero_output_is_error():
    """真空帧（ZSTD_compress(b"") 产生的真实空内容帧）：帧结构合法、解压
    成功但输出 0 字节 → ZSTD_decompress 返回码 0 → 按契约视为失败。

    契约背景：SC2 body 恒非空，0 字节输出必为异常；代价是合法空帧会被
    误拒（可接受）。断言消息含「解压失败」以锁定 n == 0 分支（若帧校验
    先失败会报「帧大小解析失败」）。
    """
    frame = _zstd_compress(b"")
    assert frame.startswith(ZSTD_MAGIC)
    with pytest.raises(CatalogError, match="解压失败"):
        decode_body(frame, None)


def test_decode_body_zstd_frame_with_trailing_padding():
    """对拍真实 ui.sc：zstd 帧后有 4 字节对齐填充（findFrameCompressedSize 裁剪）。"""
    payload = b"x" * 1000
    frame = _zstd_compress(payload)
    pad = b"\x00" * ((4 - len(frame) % 4) % 4)
    assert pad  # 确保确实有填充（压缩 1000B 不可能是 4 的倍数）
    assert decode_body(frame + pad, len(frame) + len(pad)) == payload


# -- parse_data_storage ------------------------------------------------------


def test_parse_data_storage_strings():
    body = build_data_storage(["hello", "icon_unit_barbarian", "building_town_hall"])
    assert parse_data_storage(FlatBuffer(body), body) == [
        "hello", "icon_unit_barbarian", "building_town_hall",
    ]


def test_parse_data_storage_missing_strings_returns_empty():
    b = FbBuilder()
    root = b.add_table({})
    body = b.finish(root)
    assert parse_data_storage(FlatBuffer(body), body) == []


def test_parse_data_storage_size_prefixed_layout():
    """对拍真实 ui.sc：body = [u32 size][DataStorage]，偏移 0 畸形 → 回退偏移 4。"""
    ds = build_data_storage(["a", "b"])
    body = struct.pack("<I", len(ds)) + ds
    assert parse_data_storage(FlatBuffer(body), body) == ["a", "b"]


def test_parse_data_storage_corrupt_raises_catalog_error():
    body = b"\xff\xff\xff\xff"  # root uoffset 越界 → fbs ValueError → CatalogError
    with pytest.raises(CatalogError):
        parse_data_storage(FlatBuffer(body), body)


def test_parse_data_storage_both_layouts_fail_preserves_offsets():
    """两种布局均畸形 → CatalogError 消息保留两个偏移的错误上下文（NB-1 回归）。"""
    body = b"\xff" * 8  # 偏移 0 与偏移 4 都是越界 root uoffset
    with pytest.raises(CatalogError, match=r"偏移0:.*偏移4:"):
        parse_data_storage(FlatBuffer(body), body)


# -- read_chunks -------------------------------------------------------------


def test_read_chunks_sequential_order():
    p1 = b"export-names-payload"
    p2 = b"text-fields-payload"
    body = (struct.pack("<I", len(p1)) + p1
            + struct.pack("<I", len(p2)) + p2
            + b"\x00" * 7)  # 尾部不足一个完整 chunk → 停止
    chunks = read_chunks(body, 0)
    assert chunks["ExportNames"] == p1
    assert chunks["TextFields"] == p2  # 第二块按固定顺序是 TextFields
    assert len(chunks) == 2  # 剩余 chunk 数据不够 → 停止（记录行为）


def test_read_chunks_resources_offset():
    prefix = b"DATA_STORAGE_PADDING"
    p = b"shapes-payload"
    body = prefix + struct.pack("<I", len(p)) + p
    chunks = read_chunks(body, len(prefix))
    assert chunks["ExportNames"] == p  # 第一块按固定顺序命名


def test_read_chunks_truncated_stops():
    body = struct.pack("<I", 5) + b"hello" + b"\x00"  # 读完后只剩 1 字节
    chunks = read_chunks(body, 0)
    assert chunks["ExportNames"] == b"hello"
    assert len(chunks) == 1


def test_read_chunks_size_out_of_bounds_raises():
    body = struct.pack("<I", 1000) + b"x"
    with pytest.raises(CatalogError, match="chunk"):
        read_chunks(body, 0)


def test_read_chunks_zero_size_stops():
    body = struct.pack("<I", 0) + b"junk"
    with pytest.raises(CatalogError, match="未读到任何 chunk"):
        read_chunks(body, 0)


def test_read_chunks_resources_offset_out_of_bounds_raises():
    """P1-1 回归：越界 resources_offset 必须 fail-closed（伪造 0xffffffff 不得
    静默返回空 chunks → 后续误报 export_not_found）。"""
    body = struct.pack("<I", 5) + b"hello"
    for bad in (0xFFFFFFFF, len(body) + 1, -1):
        with pytest.raises(CatalogError, match="resources_offset 越界"):
            read_chunks(body, bad)


def test_read_chunks_no_chunk_fail_closed():
    """P1-1 回归：resources_offset 之后无任何 chunk 数据 → CatalogError。"""
    body = b"\x00" * 100  # 100 字节全零：第一个 chunk size=0 → 无 chunk
    with pytest.raises(CatalogError, match="未读到任何 chunk"):
        read_chunks(body, 0)


# -- parse_export_names ------------------------------------------------------


def test_parse_export_names_mapping():
    strings = ["icon_unit_barbarian", "building_town_hall", "icon_missing"]
    payload = build_export_names([7, 42, 99], [0, 1, 2])
    assert parse_export_names(payload, strings) == [
        ("icon_unit_barbarian", 7),
        ("building_town_hall", 42),
        ("icon_missing", 99),
    ]


def test_parse_export_names_empty_payload_returns_empty():
    assert parse_export_names(b"", ["a"]) == []


def test_parse_export_names_missing_vectors_returns_empty():
    b = FbBuilder()
    root = b.add_table({})
    payload = b.finish(root)
    assert parse_export_names(payload, ["a"]) == []


def test_parse_export_names_length_mismatch_raises():
    payload = build_export_names([1, 2], [0, 1, 2])
    with pytest.raises(CatalogError, match="数量"):
        parse_export_names(payload, ["a", "b", "c"])


def test_parse_export_names_ref_out_of_range_raises():
    payload = build_export_names([1], [5])  # strings 只有 2 个
    with pytest.raises(CatalogError, match="越界"):
        parse_export_names(payload, ["a", "b"])


def test_parse_export_names_count_limit_raises():
    """FIX-5 回归：ExportNames 条目数超上限（伪造 ids/refs vector 长度）→
    CatalogError（防 512MB body 解压后的 O(n) 放大）。"""
    payload = bytearray(build_export_names([7, 42], [0, 1]))
    root_pos = struct.unpack("<I", payload[:4])[0]
    ids_field = root_pos + _table_slot_rel(bytes(payload), root_pos, 0)
    ids_vec = ids_field + struct.unpack(
        "<I", bytes(payload[ids_field:ids_field + 4]))[0]
    refs_field = root_pos + _table_slot_rel(bytes(payload), root_pos, 1)
    refs_vec = refs_field + struct.unpack(
        "<I", bytes(payload[refs_field:refs_field + 4]))[0]
    payload[ids_vec:ids_vec + 4] = struct.pack("<I", 2_000_000)
    payload[refs_vec:refs_vec + 4] = struct.pack("<I", 2_000_000)
    with pytest.raises(CatalogError, match="上限"):
        parse_export_names(bytes(payload), ["a", "b"])


def test_parse_shapes_count_limit_raises():
    """FIX-5 回归：Shapes 条目数超上限（伪造 shapes vector 长度）→ CatalogError。"""
    payload = bytearray(_build_minimal_shapes([(1, None)]))
    root_pos = struct.unpack("<I", payload[:4])[0]
    vec_field = root_pos + _table_slot_rel(bytes(payload), root_pos, 0)
    vec_pos = vec_field + struct.unpack(
        "<I", bytes(payload[vec_field:vec_field + 4]))[0]
    payload[vec_pos:vec_pos + 4] = struct.pack("<I", 2_000_000)
    with pytest.raises(CatalogError, match="上限"):
        parse_shapes(bytes(payload))


def test_parse_shapes_command_count_limit_raises():
    """FIX-5 回归：单个 Shape 的命令数超上限 → CatalogError（命令是 O(n) 放大源）。"""
    payload = bytearray(_build_minimal_shapes([(1, [0])]))
    root_pos = struct.unpack("<I", payload[:4])[0]
    vec_field = root_pos + _table_slot_rel(bytes(payload), root_pos, 0)
    vec_pos = vec_field + struct.unpack(
        "<I", bytes(payload[vec_field:vec_field + 4]))[0]
    elem = vec_pos + 4 + struct.unpack(
        "<I", bytes(payload[vec_pos + 4:vec_pos + 8]))[0]
    cmd_field = elem + _table_slot_rel(bytes(payload), elem, 1)
    cmd_vec = cmd_field + struct.unpack(
        "<I", bytes(payload[cmd_field:cmd_field + 4]))[0]
    payload[cmd_vec:cmd_vec + 4] = struct.pack("<I", 2_000_000)
    with pytest.raises(CatalogError, match="上限"):
        parse_shapes(bytes(payload))


def test_parse_textures_count_limit_raises():
    """交叉审核 FIX-B：Textures 条目数超上限 → CatalogError。"""
    payload = bytearray(_build_minimal_textures(1))
    root_pos = struct.unpack("<I", payload[:4])[0]
    vec_field = root_pos + _table_slot_rel(bytes(payload), root_pos, 0)
    vec_pos = vec_field + struct.unpack(
        "<I", bytes(payload[vec_field:vec_field + 4]))[0]
    payload[vec_pos:vec_pos + 4] = struct.pack("<I", 2_000_000)
    with pytest.raises(CatalogError, match="上限"):
        parse_textures(bytes(payload))


def test_parse_data_storage_strings_limit_raises():
    """交叉审核 FIX-B：DataStorage strings 条目数超上限 → CatalogError（经双布局包装）。"""
    body = bytearray(build_data_storage_with_prefix(["a"]))
    # 注意：FlatBuffer 持有 bytes 副本，须在伪造长度字段后构造
    root_pos = struct.unpack("<I", bytes(body[4:8]))[0]
    vec_field = root_pos + _table_slot_rel(bytes(body[4:]), root_pos, 0)
    vec_pos = vec_field + struct.unpack(
        "<I", bytes(body[4:][vec_field:vec_field + 4]))[0]
    body[4 + vec_pos:4 + vec_pos + 4] = struct.pack("<I", 2_000_000)
    fb = FlatBuffer(bytes(body[4:]))  # 带 4 字节 size 前缀的真实布局
    with pytest.raises(CatalogError, match="上限"):
        parse_data_storage(fb, bytes(body))


def _build_minimal_shapes(shapes: list[tuple[int, list[int] | None]]) -> bytes:
    """Shapes{shapes: [Shape{id u16, commands struct vector}]} 最小构造（FIX-5 用）。"""
    b = FbBuilder()
    tokens = []
    for shape_id, tex_indices in shapes:
        fields: dict[int, tuple] = {0: ("u16", shape_id)}
        if tex_indices is not None:
            cmd = b"".join(struct.pack("<4I", 0, ti, 3, 0)
                           for ti in (tex_indices or []))
            fields[1] = ("uoffset", b.add_raw_vector(len(tex_indices), cmd))
        tokens.append(b.add_table(fields))
    vec = b.add_vector(tokens)
    root = b.add_table({0: ("uoffset", vec)})
    return b.finish(root)


# -- load_sc 端到端 ----------------------------------------------------------


def _header_descriptor(resources_offset: int, compressed_size: int = 0,
                       external_matrix_bank_size: int = 0) -> bytes:
    """Header table：slot 8 resources_offset、slot 11 compressed_size、
    slot 12 external_matrix_bank_size。"""
    b = FbBuilder()
    root = b.add_table({
        8: ("u32", resources_offset),
        11: ("u32", compressed_size),
        12: ("u32", external_matrix_bank_size),
    })
    return b.finish(root)


def _build_sc2_file(descriptor: bytes, body: bytes, compressed: bool = False,
                    matrix_bank: bytes = b"") -> bytes:
    """[SC][version u16][4B 跳过][descriptor_size][descriptor][matrix_bank][body]。

    布局按 Task 契约：external_matrix_bank 段位于 body 之前（load_sc 先跳过）。
    """
    payload = _zstd_compress(body) if compressed else body
    return (b"SC" + struct.pack("<H", 6) + b"\x00" * 4
            + struct.pack("<I", len(descriptor)) + descriptor
            + matrix_bank + payload)


def _build_body(strings: list[str], exports: list[tuple[int, int]]
                ) -> tuple[bytes, bytes, int]:
    """DataStorage + ExportNames chunk，返回 (body, export_names_payload, ds_len)。"""
    ds = build_data_storage(strings)
    en = build_export_names([oid for _, oid in exports],
                            [ref for ref, _ in exports])
    return ds + struct.pack("<I", len(en)) + en, en, len(ds)


def test_load_sc_end_to_end_compressed():
    strings = ["icon_unit_barbarian", "building_town_hall"]
    body, en_payload, ds_len = _build_body(strings, [(0, 7), (1, 42)])
    compressed = _zstd_compress(body)
    descriptor = _header_descriptor(resources_offset=ds_len,
                                    compressed_size=len(compressed))
    sc = load_sc(_build_sc2_file(descriptor, body, compressed=True))
    assert sc.header.resources_offset == ds_len
    assert sc.header.compressed_size == len(compressed)
    assert sc.header.external_matrix_bank_size == 0
    assert sc.strings == strings
    assert sc.export_names == {"icon_unit_barbarian": 7, "building_town_hall": 42}
    assert sc.chunks["ExportNames"] == en_payload
    assert sc.metadata == []
    assert isinstance(sc, ScFile)


def test_load_sc_end_to_end_uncompressed():
    strings = ["icon_unit_barbarian"]
    body, en_payload, ds_len = _build_body(strings, [(0, 7)])
    descriptor = _header_descriptor(resources_offset=ds_len)
    sc = load_sc(_build_sc2_file(descriptor, body, compressed=False))
    assert sc.strings == strings
    assert sc.export_names == {"icon_unit_barbarian": 7}
    assert sc.chunks["ExportNames"] == en_payload


def test_load_sc_skips_external_matrix_bank():
    strings = ["icon_unit_barbarian"]
    body, _, ds_len = _build_body(strings, [(0, 7)])
    bank = b"\xde\xad\xbe\xef" * 4
    descriptor = _header_descriptor(resources_offset=ds_len,
                                    external_matrix_bank_size=len(bank))
    sc = load_sc(_build_sc2_file(descriptor, body, compressed=False,
                                 matrix_bank=bank))
    assert sc.strings == strings
    assert sc.export_names == {"icon_unit_barbarian": 7}
    assert sc.header.external_matrix_bank_size == len(bank)


def test_load_sc_bad_magic_raises():
    with pytest.raises(CatalogError, match="magic"):
        load_sc(b"XX" + b"\x00" * 10)  # 长度 >= 12 才走到 magic 校验


def test_load_sc_corrupt_body_raises():
    """body 内 ExportNames name_ref_id 越界 → CatalogError（不裸 ValueError 逃逸）。"""
    strings = ["only"]
    en = build_export_names([1], [3])  # name_ref_id=3 越界（strings 只有 1 个）
    body = build_data_storage(strings) + struct.pack("<I", len(en)) + en
    descriptor = _header_descriptor(resources_offset=len(build_data_storage(strings)))
    with pytest.raises(CatalogError, match="越界"):
        load_sc(_build_sc2_file(descriptor, body, compressed=False))


def test_load_sc_real_layout_prefixed_and_padded():
    """镜像真实 ui.sc 完整布局：DataStorage 带 u32 size 前缀（resources_offset
    = 4 + data_storage_size）+ zstd 帧尾 4 字节对齐填充。"""
    strings = ["icon_unit_barbarian", "building_town_hall"]
    ds = build_data_storage(strings)
    en = build_export_names([7, 42], [0, 1])
    body = struct.pack("<I", len(ds)) + ds + struct.pack("<I", len(en)) + en
    resources_offset = 4 + len(ds)
    compressed = _zstd_compress(body)
    pad = b"\x00" * ((4 - len(compressed) % 4) % 4)
    descriptor = _header_descriptor(resources_offset=resources_offset,
                                    compressed_size=len(compressed) + len(pad))
    data = _build_sc2_file(descriptor, body, compressed=True) + pad
    sc = load_sc(data)
    assert sc.strings == strings
    assert sc.export_names == {"icon_unit_barbarian": 7, "building_town_hall": 42}
    assert sc.chunks["ExportNames"] == en
    assert sc.header.compressed_size == len(compressed) + len(pad)
