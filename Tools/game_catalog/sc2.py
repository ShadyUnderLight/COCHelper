"""Scaleform SC2 V6 容器头与 Header descriptor 解析（纯 stdlib）。

COC APK 内 `assets/sc/*.sc` 的容器格式（已对拍 `base.apk.1` 的 `ui.sc`）：

- off0-1: 2 字节 magic `SC`
- off2-3: version u16 LE（当前为 6）
- off4-7: 4 字节跳过（全 0）
- off8-11: descriptor_size u32 LE
- off12 起: descriptor FlatBuffer（Header table），root uoffset 相对 descriptor
  起点（真实值 0x38），descriptor 结束 = 12 + descriptor_size
- descriptor 之后是 body（真实 APK 中为 zstd 压缩，见 decode_body）
- body 前可能有 external_matrix_bank 段（external_matrix_bank_size > 0 时）

Header table 字段语义参考 sc-workshop/SupercellFlash 的 Header.fbs
（MIT），flatbuffers table 语义：uint 字段缺省时用默认值 0。
metadata 为 AssetMetaEntry table 的 vector：
`AssetMetaEntry { name: string (slot 0), hash: [ubyte] (slot 1) }`。

解压后 body（DataStorage + chunk 序列 + ExportNames）的解析见本文件
Task 3 部分。**依赖例外**：body 的 zstd 解码需要 ctypes/libzstd（spike
渲染模块专用，与纯 stdlib 生成管线分离，见 rendered-path 契约文档）；
其余解析保持纯 stdlib。

一切畸形数据统一抛 CatalogError（fail loud，不静默降级）。
"""

from __future__ import annotations

import ctypes
import ctypes.util
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
    if off < 0 or off + 4 > len(buf):
        raise CatalogError(
            f"SC2 u32 字段越界: 偏移 {off} 大小 4，数据长度 {len(buf)}")
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
    except ValueError as e:
        raise CatalogError(f"SC2 metadata 解析失败: {e}") from e


# ---------------------------------------------------------------------------
# Task 3: zstd body 解码 + DataStorage + ExportNames + chunk 序列 + load_sc
#
# 依赖例外：zstd 解码需要 ctypes/libzstd（spike 渲染模块专用，与纯 stdlib
# 生成管线分离，见 rendered-path 契约文档）。其余部分保持纯 stdlib。
# ---------------------------------------------------------------------------

_ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
_MAX_DECOMPRESSED = 512 * 1024 * 1024  # 512MB，防 zip bomb
_libzstd: ctypes.CDLL | None = None


def load_libzstd() -> ctypes.CDLL:
    """加载 libzstd（ctypes，模块级缓存）。

    依次尝试 `/opt/homebrew/lib/libzstd.dylib`、`/usr/local/lib/libzstd.dylib`、
    `ctypes.util.find_library("zstd")`；全部失败 → CatalogError。

    注意：zstd 解码是 spike 渲染模块的依赖例外——与纯 stdlib 生成管线分离，
    见 rendered-path 契约文档（spike 渲染模块需要 libzstd）。
    """
    global _libzstd
    if _libzstd is not None:
        return _libzstd
    candidates = [
        "/opt/homebrew/lib/libzstd.dylib",
        "/usr/local/lib/libzstd.dylib",
    ]
    found = ctypes.util.find_library("zstd")
    if found:
        candidates.append(found)
    last_err: OSError | None = None
    for path in candidates:
        try:
            lib = ctypes.CDLL(path)
        except OSError as e:
            last_err = e
            continue
        lib.ZSTD_decompressBound.restype = ctypes.c_ulonglong
        lib.ZSTD_decompressBound.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        lib.ZSTD_decompress.restype = ctypes.c_size_t
        lib.ZSTD_decompress.argtypes = [
            ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t,
        ]
        lib.ZSTD_isError.restype = ctypes.c_uint
        lib.ZSTD_isError.argtypes = [ctypes.c_size_t]
        lib.ZSTD_findFrameCompressedSize.restype = ctypes.c_ulonglong
        lib.ZSTD_findFrameCompressedSize.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        _libzstd = lib
        return lib
    raise CatalogError(
        f"无法加载 libzstd（{last_err}）：spike 渲染模块需要 libzstd，"
        "与纯 stdlib 生成管线分离，见契约文档")


def decode_body(compressed: bytes, compressed_size: int | None) -> bytes:
    """解压 body：zstd magic 开头 → 解压；否则原样返回。

    compressed_size > 0 时只取前 compressed_size 字节作为压缩/未压缩区域
    （真实文件中 body 之后可能跟 external matrix bank / 尾部数据）。

    对拍真实 ui.sc 修正：zstd 帧后可能有 4 字节对齐填充（3 字节 `00`），
    单发 `ZSTD_decompress` 遇到尾随字节直接报错——先 `ZSTD_findFrameCompressedSize`
    裁剪出精确帧大小，再解压。解压上限 512MB（`ZSTD_decompressBound` 超限
    拒绝，防 zip bomb；无 content size 的帧返回 unknown 上限同样被拒）。
    """
    region = compressed if not compressed_size else compressed[:compressed_size]
    if not region.startswith(_ZSTD_MAGIC):
        return region
    lib = load_libzstd()
    frame_size = int(lib.ZSTD_findFrameCompressedSize(region, len(region)))
    if lib.ZSTD_isError(frame_size):
        raise CatalogError(f"zstd 帧大小解析失败（返回码 {frame_size}）")
    if frame_size > len(region):
        raise CatalogError(
            f"zstd 帧声明 {frame_size} 字节超过区域长度 {len(region)}")
    frame = region[:frame_size]
    bound = int(lib.ZSTD_decompressBound(frame, len(frame)))
    if bound > _MAX_DECOMPRESSED:
        raise CatalogError(
            f"zstd 解压上限 {bound} 字节超过允许的 {_MAX_DECOMPRESSED}"
            "（防 zip bomb）")
    dst = ctypes.create_string_buffer(bound)
    n = int(lib.ZSTD_decompress(dst, bound, frame, len(frame)))
    if n == 0 or lib.ZSTD_isError(n):
        raise CatalogError(f"zstd 解压失败（返回码 {n}）")
    if n > bound:
        raise CatalogError(
            f"zstd 解压输出 {n} 字节超过上限 {bound}（数据损坏）")
    return dst.raw[:n]


def _parse_data_storage(fb: FlatBuffer) -> list[str]:
    """单布局解析 DataStorage strings（畸形 → ValueError，由调用方包装）。"""
    root = fb.root()
    strings_off = fb.table_field(root, 0)
    if strings_off == 0:
        return []
    count = fb.vector_len(strings_off)
    return [fb.string(fb.vector_elem(strings_off, i, 4))
            for i in range(count)]


def parse_data_storage(fb: FlatBuffer, body: bytes) -> list[str]:
    """DataStorage strings 列表。

    **对拍真实 ui.sc 修正（以真实数据为准）**：解压后 body 实际是
    `[u32 data_storage_size][DataStorage flatbuffer]`——带 4 字节 size 前缀，
    与 C++ 参考一致（`read_unsigned_int()` 后 `GetDataStorage(position)`），
    resources_offset = 4 + data_storage_size 即 chunk 起点。任务初版契约
    假设无前缀，被真实数据否定。

    本函数两种布局都支持：先按无前缀（body 偏移 0）解析，畸形
    （root/vtable/字符串越界 → ValueError）则回退到偏移 4（带前缀）。
    strings 索引语义（C++ 注释提及 `strings[ref_id - 1]`）不做偏移，原样
    返回；-1 语义是否成立在 ExportNames 对拍时验证。
    """
    try:
        return _parse_data_storage(fb)
    except ValueError:
        if len(body) >= 8:
            try:
                return _parse_data_storage(FlatBuffer(body[4:]))
            except ValueError as e:
                raise CatalogError(f"SC2 DataStorage 解析失败: {e}") from e
        raise CatalogError("SC2 DataStorage 解析失败（两种布局均畸形）")


# chunk 固定顺序（参考 C++ `Table::load_chunk` 序列）
_CHUNK_NAMES = (
    "ExportNames",
    "TextFields",
    "Shapes",
    "MovieClips",
    "MovieClipModifiers",
    "Textures",
)


def read_chunks(body: bytes, resources_offset: int) -> dict[str, bytes]:
    """从 resources_offset 起连续读 chunk：u32 size + size 字节 flatbuffer。

    chunk 顺序固定：ExportNames → TextFields → Shapes → MovieClips →
    MovieClipModifiers → Textures。读到 body 末尾（剩余 < 4 字节）或遇到
    size 0 时停止；size 超过 body 剩余 → CatalogError（数据损坏）。
    """
    chunks: dict[str, bytes] = {}
    pos = resources_offset
    for name in _CHUNK_NAMES:
        if pos + 4 > len(body):
            break  # 剩余不足一个 size 头 → 停止
        size = struct.unpack("<I", body[pos:pos + 4])[0]
        if size == 0:
            break  # 空 chunk → 视为终止（记录行为）
        if pos + 4 + size > len(body):
            raise CatalogError(
                f"SC2 chunk {name} 越界: 起点 {pos} 大小 {size}，"
                f"body 长度 {len(body)}")
        chunks[name] = body[pos + 4:pos + 4 + size]
        pos += 4 + size
    return chunks


def parse_export_names(payload: bytes, strings: list[str]) -> list[tuple[str, int]]:
    """ExportNames flatbuffer：object_ids [ushort]（slot 0）+ name_ref_ids
    [uint]（slot 1）；数量不等 → CatalogError；name = strings[name_ref_id]
    （越界 → CatalogError，不做 -1 索引除非真实数据证实需要）。
    """
    if not payload:
        return []
    try:
        fb = FlatBuffer(payload)
        root = fb.root()
        ids_off = fb.table_field(root, 0)
        refs_off = fb.table_field(root, 1)
        if ids_off == 0 or refs_off == 0:
            return []
        ids_count = fb.vector_len(ids_off)
        refs_count = fb.vector_len(refs_off)
        if ids_count != refs_count:
            raise CatalogError(
                f"SC2 ExportNames object_ids/name_ref_ids 数量不等: "
                f"{ids_count} vs {refs_count}")
        out: list[tuple[str, int]] = []
        for i in range(ids_count):
            ids_pos = fb.vector_elem(ids_off, i, 2, alignment=2)
            refs_pos = fb.vector_elem(refs_off, i, 4)
            obj_id = struct.unpack("<H", payload[ids_pos:ids_pos + 2])[0]
            ref_id = struct.unpack("<I", payload[refs_pos:refs_pos + 4])[0]
            if ref_id >= len(strings):
                raise CatalogError(
                    f"SC2 ExportNames name_ref_id {ref_id} 越界"
                    f"（strings 共 {len(strings)} 个）")
            out.append((strings[ref_id], obj_id))
        return out
    except CatalogError:
        raise
    except ValueError as e:
        raise CatalogError(f"SC2 ExportNames 解析失败: {e}") from e


@dataclass(frozen=True)
class ScFile:
    """SC2 文件完整解析结果。"""

    header: ScHeader
    metadata: list[AssetMetaEntry]
    strings: list[str]
    export_names: dict[str, int]  # name → object_id
    chunks: dict[str, bytes]


def load_sc(data: bytes) -> ScFile:
    """高级入口：SC2 头 + descriptor + body 解码 + DataStorage + chunks。

    body_start = 12 + descriptor_size；external_matrix_bank_size > 0 时先跳过
    该段（只记录尺寸，不解码）；随后按 zstd magic 检测与解码 body。
    """
    header = parse_sc_header(data)
    metadata = metadata_entries(data, header)
    body_start = SC_DESCRIPTOR_OFFSET + header.descriptor_size
    pos = body_start + header.external_matrix_bank_size
    body = decode_body(data[pos:], header.compressed_size)
    try:
        fb = FlatBuffer(body)
        strings = parse_data_storage(fb, body)
        chunks = read_chunks(body, header.resources_offset)
        export_names = dict(
            parse_export_names(chunks.get("ExportNames", b""), strings))
    except ValueError as e:
        raise CatalogError(f"SC2 body 解析失败: {e}") from e
    return ScFile(header=header, metadata=metadata, strings=strings,
                  export_names=export_names, chunks=chunks)
