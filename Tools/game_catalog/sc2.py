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
from dataclasses import dataclass, field
from typing import Callable

from game_catalog.errors import CatalogError
from game_catalog.fbs import FlatBuffer

SC_MAGIC = b"SC"
SC_VERSION = 6
SC_DESCRIPTOR_OFFSET = 12  # 头部固定字节数

# 防资源放大：body 解压上限 512MB（_MAX_DECOMPRESSED），解压后的 vector 条目
# 数若不加限，O(n) 循环会在已解压的巨型 body 上再放大一轮 CPU/内存
# （交叉审核 FIX-5；真实数据：metadata ~几千、ExportNames 3024、Shapes 4053）
_MAX_VECTOR_ENTRIES = 1_000_000

# DataStorage movieclips_frame_elements [ushort] 原始缓冲上限（64MB）。
# 与 _MAX_VECTOR_ENTRIES 区分：这是字节切片（提取 O(1)，无逐元素放大），
# 真实数据 ui.sc 4.9MB / buildings.sc 15.5MB，64MB 留足余量防伪造长度。
_MAX_FRAME_ELEMENTS_BYTES = 64 * 1024 * 1024

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


@dataclass(frozen=True)
class DataStorageInfo:
    """DataStorage 全量信息（strings + MovieClip 帧元素池缓冲）。

    movieclips_frame_elements 是 `[ushort]` 原始字节（u16 LE 连续排列），
    即 MovieClipFrameElement 池：MovieClip.frame_elements_offset 是其中的
    **ushort 索引**（实证 + C++ 参考 `elements_vector->Get(offset++)`）。
    """

    strings: list[str]
    movieclips_frame_elements: bytes = b""


@dataclass(frozen=True)
class MovieClipFrame:
    """单帧元数据（MovieClips chunk `MovieClipFrame` struct，8 字节）。

    used_transform = 本帧显示的 MovieClipFrameElement 个数；元素按帧顺序从
    frame_elements_offset 起连续消费。label_ref_id 是 strings 索引（短帧无
    label，固定 0）。
    """

    used_transform: int
    label_ref_id: int


@dataclass(frozen=True)
class MovieClipFrameElement:
    """帧元素（6 字节 3×u16，实证对拍 ui.sc/buildings.sc + C++ 参考）。

    - instance_index: **movieclip children 数组索引**（children_ids[i] 才是
      shape/movieclip/textfield 的全局 id；无独立 type 字段，类型由
      children_ids[instance_index] 落点决定）
    - matrix_index: matrix bank 内矩阵索引（0xFFFF = 无）
    - color_transform_index: color transform 索引（0xFFFF = 无）
    """

    instance_index: int
    matrix_index: int
    color_transform_index: int


@dataclass(frozen=True)
class MovieClip:
    """MovieClip（时间线/动画对象）：帧 + 帧元素。

    frame_elements_offset 为 movieclips_frame_elements 缓冲中的 ushort 索引
    （0xFFFFFFFF = 无元素）；frame_elements 已按帧顺序全部物化。
    """

    id: int
    export_name_ref_id: int
    frames: list[MovieClipFrame]
    frame_elements_offset: int
    matrix_bank_index: int
    frame_elements: list[MovieClipFrameElement]


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
    first = fb.vector_elem(vec_off, 0, 1)
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
        if count > _MAX_VECTOR_ENTRIES:
            raise CatalogError(
                f"SC2 metadata 条目数 {count} 超过上限 {_MAX_VECTOR_ENTRIES}"
                "（防 512MB body 解压后的 O(n) 放大）")
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
        raise CatalogError(f"zstd 帧大小解析失败（返回码 0x{frame_size:x}）")
    if frame_size > len(region):
        raise CatalogError(
            f"zstd 帧声明 {frame_size} 字节超过区域长度 {len(region)}")
    frame = region[:frame_size]
    bound = int(lib.ZSTD_decompressBound(frame, len(frame)))
    if bound > _MAX_DECOMPRESSED:
        raise CatalogError(
            f"zstd 解压上限 0x{bound:x}（{bound}）字节超过允许的 "
            f"{_MAX_DECOMPRESSED}（防 zip bomb）")
    try:
        dst = ctypes.create_string_buffer(bound)
    except MemoryError as exc:
        # 分配失败 → CatalogError，不裸 MemoryError traceback 中止
        # （交叉审核 FIX-4；spike 由 render_spike 捕获转 blocked）
        raise CatalogError(
            f"zstd 解压缓冲分配失败（{bound} 字节，内存不足）") from exc
    n = int(lib.ZSTD_decompress(dst, bound, frame, len(frame)))
    if n == 0 or lib.ZSTD_isError(n):
        # n == 0：解压成功但输出 0 字节（真空帧）——SC2 body 恒非空，
        # 0 字节输出必为异常，按契约视为失败（合法空帧会被误拒，可接受）
        raise CatalogError(f"zstd 解压失败（返回码 0x{n:x}）")
    if n > bound:
        raise CatalogError(
            f"zstd 解压输出 {n} 字节超过上限 {bound}（数据损坏）")
    return dst.raw[:n]


def _parse_data_storage_info(fb: FlatBuffer) -> DataStorageInfo:
    """单布局解析 DataStorage（strings slot 0 + 帧元素池 slot 4）。

    畸形 → ValueError，由调用方包装。帧元素池是 [ushort] 原始字节切片
    （提取 O(1)），长度上限 _MAX_FRAME_ELEMENTS_BYTES 防伪造长度。
    """
    root = fb.root()
    strings_off = fb.table_field(root, 0)
    strings: list[str] = []
    if strings_off:
        count = fb.vector_len(strings_off)
        if count > _MAX_VECTOR_ENTRIES:
            raise ValueError(
                f"SC2 DataStorage strings 条目数 {count} 超过上限 {_MAX_VECTOR_ENTRIES}")
        strings = [fb.string(fb.vector_elem(strings_off, i, 4))
                   for i in range(count)]
    fe_bytes = b""
    fe_off = fb.table_field(root, 4)
    if fe_off:
        n = fb.vector_len(fe_off)
        if n * 2 > _MAX_FRAME_ELEMENTS_BYTES:
            raise ValueError(
                f"SC2 DataStorage movieclips_frame_elements 长度 {n * 2} "
                f"字节超过上限 {_MAX_FRAME_ELEMENTS_BYTES}")
        if n:
            # 校验最后一个元素在界内 → 整段连续切片必然合法
            first = fb.vector_elem(fe_off, n - 1, 2) - (n - 1) * 2
            fe_bytes = fb.data[first:first + n * 2]
    return DataStorageInfo(strings=strings,
                           movieclips_frame_elements=fe_bytes)


def parse_data_storage_info(fb: FlatBuffer, body: bytes) -> DataStorageInfo:
    """DataStorage 全量信息（strings + movieclips_frame_elements 缓冲）。

    布局回退与 parse_data_storage 一致：先按 body 偏移 0 解析，畸形则回退
    偏移 4（真实布局 `[u32 size][flatbuffer]`）。两种布局均失败 → CatalogError
    保留两个偏移的错误上下文。
    """
    try:
        return _parse_data_storage_info(fb)
    except ValueError as e0:
        if len(body) < 8:
            raise CatalogError(
                f"SC2 DataStorage 解析失败（偏移0: {e0}；body 仅 "
                f"{len(body)} 字节，无法回退偏移4）") from e0
        try:
            return _parse_data_storage_info(FlatBuffer(body[4:]))
        except ValueError as e:
            raise CatalogError(
                f"SC2 DataStorage 解析失败（偏移0: {e0}；偏移4: {e}）") from e


def parse_data_storage(fb: FlatBuffer, body: bytes) -> list[str]:
    """DataStorage strings 列表（签名与行为兼容既有调用）。

    **布局（对拍真实 ui.sc，18.400.13）**：解压后 body 是
    `[u32 data_storage_size][DataStorage flatbuffer]`——带 4 字节 size 前缀，
    与 C++ 参考一致（`read_unsigned_int()` 后 `GetDataStorage(position)`），
    resources_offset = 4 + data_storage_size 即 chunk 起点。任务初版契约
    假设无前缀，被真实数据否定。

    带前缀布局是真实格式（已对拍）；**无前缀（body 偏移 0）回退是防御
    其他文件变体**：先按偏移 0 解析，畸形（root/vtable/字符串越界 →
    ValueError）则回退偏移 4。两种布局均失败时，CatalogError 消息保留
    两个偏移的错误上下文。

    strings 索引语义（C++ 注释提及 `strings[ref_id - 1]`）不做偏移，原样
    返回；-1 语义是否成立在 ExportNames 对拍时验证。
    """
    return parse_data_storage_info(fb, body).strings


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

    **fail-closed（交叉审核 P1）**：resources_offset 越界或未读到任何 chunk
    → CatalogError（损坏 APK 不得静默降级为空 exports，否则后续会把损坏
    误报为 export_not_found）。
    """
    if resources_offset < 0 or resources_offset > len(body):
        raise CatalogError(
            f"SC2 resources_offset 越界: {resources_offset}，body 长度 {len(body)}")
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
    if not chunks:
        raise CatalogError(
            f"SC2 未读到任何 chunk（resources_offset={resources_offset} 后无数据）")
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
        if ids_count > _MAX_VECTOR_ENTRIES:
            raise CatalogError(
                f"SC2 ExportNames 条目数 {ids_count} 超过上限 "
                f"{_MAX_VECTOR_ENTRIES}（防 512MB body 解压后的 O(n) 放大）")
        out: list[tuple[str, int]] = []
        for i in range(ids_count):
            ids_pos = fb.vector_elem(ids_off, i, 2)
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
    frame_elements: bytes = b""  # DataStorage 帧元素池 [ushort] 原始字节
    _cache: dict = field(default_factory=dict, repr=False, compare=False)

    def shape_textures(self, object_id: int) -> list[int] | None:
        """object_id → Shape 命令的 texture_index 列表；非 Shape id → None。

        Shapes chunk 首次调用时惰性解析并缓存（241KB 量级，成本低）。
        """
        if "shapes" not in self._cache:
            self._cache["shapes"] = parse_shapes(self.chunks.get("Shapes", b""))
        return self._cache["shapes"].get(object_id)

    def texture_data(self, index: int) -> TextureData:
        """纹理索引 → TextureData（惰性：仅读取对应 TextureSet，不整块解引用）。

        索引越界 → CatalogError（fail loud）。
        """
        if "textures" not in self._cache:
            self._cache["textures"] = parse_textures(
                self.chunks.get("Textures", b""))
        textures = self._cache["textures"]
        if not 0 <= index < len(textures):
            raise CatalogError(
                f"SC2 纹理索引 {index} 越界（Textures 共 {len(textures)} 个）")
        return textures[index]

    def movieclips(self) -> dict[int, MovieClip]:
        """MovieClips 惰性解析（按 movieclip 索引）并缓存。

        需要 DataStorage 帧元素池缓冲（load_sc 时已提取进 frame_elements）。
        """
        if "movieclips" not in self._cache:
            self._cache["movieclips"] = parse_movieclips(
                self.chunks.get("MovieClips", b""), self.frame_elements)
        return self._cache["movieclips"]

    def movieclip_for_export(self, name: str) -> MovieClip | None:
        """导出名 → object_id → MovieClip；未知导出或 id 非 movieclip → None。

        惰性：首次调用解析 MovieClips 并建 id → MovieClip 映射缓存。
        """
        object_id = self.export_names.get(name)
        if object_id is None:
            return None
        if "movieclip_by_id" not in self._cache:
            self._cache["movieclip_by_id"] = {
                mc.id: mc for mc in self.movieclips().values()}
        return self._cache["movieclip_by_id"].get(object_id)


def shape_textures(sc: ScFile, object_id: int) -> list[int] | None:
    """ScFile.shape_textures 的模块级别名（spike 渲染模块调用入口）。"""
    return sc.shape_textures(object_id)


def texture_data(sc: ScFile, index: int) -> TextureData:
    """ScFile.texture_data 的模块级别名（spike 渲染模块调用入口）。"""
    return sc.texture_data(index)


@dataclass(frozen=True)
class TextureData:
    """Textures chunk 中单个纹理的元数据 + 惰性像素数据。

    data 属性惰性物化：Textures chunk 可达 95MB（真实 ui.sc），构造时只
    记录读取闭包，首次访问 data 才切片对应 [ubyte] vector——避免整块
    解引用（--limit 预算之外不触碰数据）。
    """

    texture_format: int
    pixel_type: int
    width: int
    height: int
    external_texture: str | None = None
    _data_loader: Callable[[], bytes] | None = field(
        default=None, repr=False, compare=False)

    @property
    def data(self) -> bytes | None:
        """原始像素/压缩数据字节；data 字段缺失 → None。"""
        if self._data_loader is None:
            return None
        return self._data_loader()


def _u16_scalar(fb: FlatBuffer, buf: bytes, table_off: int, slot: int,
                what: str) -> int:
    """table 中 inline uint16 标量；字段缺省返回 0。"""
    off = fb.table_field(table_off, slot)
    if off == 0:
        return 0
    if off < 0 or off + 2 > len(buf):
        raise CatalogError(f"SC2 {what} u16 字段越界: 偏移 {off}")
    return struct.unpack("<H", buf[off:off + 2])[0]


def _u8_scalar(fb: FlatBuffer, buf: bytes, table_off: int, slot: int,
               what: str) -> int:
    """table 中 inline uint8 标量；字段缺省返回 0。"""
    off = fb.table_field(table_off, slot)
    if off == 0:
        return 0
    if off < 0 or off + 1 > len(buf):
        raise CatalogError(f"SC2 {what} u8 字段越界: 偏移 {off}")
    return buf[off]


def parse_shapes(payload: bytes) -> dict[int, list[int]]:
    """Shapes chunk：{shape_id: [texture_index, ...]}。

    `Shapes{shapes: [Shape]}`（slot 0）；`Shape{id: ushort (slot 0),
    commands: [ShapeDrawBitmapCommand] (slot 1)}`；命令是 **struct**（16 字节：
    unk1/texture_index/points_count/points_offset 各 u32），vector 元素直接
    连续排布（无 uoffset），元素 i 绝对偏移 = vector 数据区 + i*16。

    对拍真实 ui.sc：shapes 4053 个，id 稀疏（0..23358，非索引对齐），
    按 id 建 dict 正确；shape[0] 的 id 字段缺省（→ 0）。
    畸形数据 → CatalogError。
    """
    if not payload:
        return {}
    try:
        fb = FlatBuffer(payload)
        root = fb.root()
        shapes_vec = fb.table_field(root, 0)
        if shapes_vec == 0:
            return {}
        count = fb.vector_len(shapes_vec)
        if count > _MAX_VECTOR_ENTRIES:
            raise CatalogError(
                f"SC2 Shapes 条目数 {count} 超过上限 {_MAX_VECTOR_ENTRIES}"
                "（防 512MB body 解压后的 O(n) 放大）")
        out: dict[int, list[int]] = {}
        for i in range(count):
            shape_tbl = fb.table(fb.vector_elem(shapes_vec, i, 4))
            shape_id = _u16_scalar(fb, payload, shape_tbl, 0, "Shape.id")
            commands_vec = fb.table_field(shape_tbl, 1)
            if commands_vec == 0:
                out[shape_id] = []
                continue
            ncmd = fb.vector_len(commands_vec)
            if ncmd > _MAX_VECTOR_ENTRIES:
                raise CatalogError(
                    f"SC2 Shape[{i}] 命令数 {ncmd} 超过上限 {_MAX_VECTOR_ENTRIES}"
                    "（防 512MB body 解压后的 O(n) 放大）")
            tex = []
            for c in range(ncmd):
                elem = fb.vector_elem(commands_vec, c, 16)  # struct 16B 连续
                tex.append(struct.unpack("<I", payload[elem + 4:elem + 8])[0])
            out[shape_id] = tex
        return out
    except CatalogError:
        raise
    except ValueError as e:
        raise CatalogError(f"SC2 Shapes 解析失败: {e}") from e


def _u32_field_or(fb: FlatBuffer, buf: bytes, table_off: int, slot: int,
                  default: int) -> int:
    """table 中 inline uint32 标量；字段缺省返回 default（非 0）。"""
    off = fb.table_field(table_off, slot)
    if off == 0:
        return default
    if off < 0 or off + 4 > len(buf):
        raise CatalogError(
            f"SC2 u32 字段越界: 偏移 {off} 大小 4，数据长度 {len(buf)}")
    return struct.unpack("<I", buf[off:off + 4])[0]


def parse_movieclips(payload: bytes, frame_elements: bytes = b"") -> dict[int, MovieClip]:
    """MovieClips chunk → {movieclip 索引: MovieClip}。

    `MovieClips{movieclips: [MovieClip]}`（slot 0，元素 table 4B uoffset）。
    MovieClip 槽位（MovieClips.fbs）：0=id u16、1=export_name_ref_id u32、
    8=frames [MovieClipFrame]（**8 字节 struct 连续**：used_transform u32 +
    label_ref_id u32）、9=frame_elements_offset u32（缺省 0xFFFFFFFF）、
    10=matrix_bank_index u32、12=short_frames [MovieClipShortFrame]
    （2 字节 struct 连续，仅 used_transform u16）。frames 缺省时用 short_frames。

    frame elements 实证（对拍 ui.sc/buildings.sc + SupercellFlash
    MovieClip.cpp）：`frame_elements_offset` 是 DataStorage
    movieclips_frame_elements **ushort 索引**（非字节偏移）；元素 = 6 字节
    3×u16（instance_index=children 数组索引 / matrix_index /
    color_transform_index，0xFFFF=无）；所有帧 used_transform 之和个元素从
    该处顺序连续消费（frame 0 先用）。畸形/越界 → CatalogError。
    """
    if not payload:
        return {}
    try:
        fb = FlatBuffer(payload)
        root = fb.root()
        vec = fb.table_field(root, 0)
        if vec == 0:
            return {}
        count = fb.vector_len(vec)
        if count > _MAX_VECTOR_ENTRIES:
            raise CatalogError(
                f"SC2 MovieClips 条目数 {count} 超过上限 {_MAX_VECTOR_ENTRIES}"
                "（防 512MB body 解压后的 O(n) 放大）")
        out: dict[int, MovieClip] = {}
        for i in range(count):
            t = fb.table(fb.vector_elem(vec, i, 4))
            mc_id = _u16_scalar(fb, payload, t, 0, "MovieClip.id")
            export_ref = _u32_field(fb, payload, t, 1)
            matrix_bank = _u32_field(fb, payload, t, 10)
            feo = _u32_field_or(fb, payload, t, 9, 0xFFFFFFFF)
            frames: list[MovieClipFrame] = []
            fvec = fb.table_field(t, 8)
            if fvec:
                nf = fb.vector_len(fvec)
                if nf > _MAX_VECTOR_ENTRIES:
                    raise CatalogError(
                        f"SC2 MovieClip[{i}] 帧数 {nf} 超过上限 "
                        f"{_MAX_VECTOR_ENTRIES}（防 O(n) 放大）")
                for f in range(nf):
                    pos = fb.vector_elem(fvec, f, 8)
                    used, label = struct.unpack("<II", payload[pos:pos + 8])
                    frames.append(MovieClipFrame(used_transform=used,
                                                 label_ref_id=label))
            else:
                svec = fb.table_field(t, 12)
                if svec:
                    ns = fb.vector_len(svec)
                    if ns > _MAX_VECTOR_ENTRIES:
                        raise CatalogError(
                            f"SC2 MovieClip[{i}] 短帧数 {ns} 超过上限 "
                            f"{_MAX_VECTOR_ENTRIES}（防 O(n) 放大）")
                    for f in range(ns):
                        pos = fb.vector_elem(svec, f, 2)
                        frames.append(MovieClipFrame(
                            used_transform=struct.unpack(
                                "<H", payload[pos:pos + 2])[0],
                            label_ref_id=0))  # 短帧无 label
            total = sum(f.used_transform for f in frames)
            if total > _MAX_VECTOR_ENTRIES:
                raise CatalogError(
                    f"SC2 MovieClip[{i}] 帧元素总数 {total} 超过上限 "
                    f"{_MAX_VECTOR_ENTRIES}（防 O(n) 放大）")
            elements: list[MovieClipFrameElement] = []
            if total > 0:
                if feo == 0xFFFFFFFF:
                    raise CatalogError(
                        f"SC2 MovieClip[{i}] 有 {total} 个帧元素但 "
                        "frame_elements_offset=0xFFFFFFFF（数据损坏）")
                start = feo * 2  # ushort 索引 → 字节偏移
                need = total * 6
                if start + need > len(frame_elements):
                    raise CatalogError(
                        f"SC2 MovieClip[{i}] 帧元素越界: 起点 {start} 需要 "
                        f"{need} 字节，缓冲共 {len(frame_elements)} 字节")
                for e in range(total):
                    pos = start + e * 6
                    inst, midx, cidx = struct.unpack(
                        "<HHH", frame_elements[pos:pos + 6])
                    elements.append(MovieClipFrameElement(
                        instance_index=inst, matrix_index=midx,
                        color_transform_index=cidx))
            out[i] = MovieClip(id=mc_id, export_name_ref_id=export_ref,
                               frames=frames, frame_elements_offset=feo,
                               matrix_bank_index=matrix_bank,
                               frame_elements=elements)
        return out
    except CatalogError:
        raise
    except ValueError as e:
        raise CatalogError(f"SC2 MovieClips 解析失败: {e}") from e


def _parse_texture_data(fb: FlatBuffer, payload: bytes, td_off: int,
                        what: str) -> TextureData:
    """TextureData table（slot 0-5）解析；data 字段惰性（不复制字节）。"""
    fmt = _u8_scalar(fb, payload, td_off, 0, f"{what}.texture_format")
    pixel_type = _u8_scalar(fb, payload, td_off, 1, f"{what}.pixel_type")
    width = _u16_scalar(fb, payload, td_off, 2, f"{what}.width")
    height = _u16_scalar(fb, payload, td_off, 3, f"{what}.height")
    data_field = fb.table_field(td_off, 4)
    ext_field = fb.table_field(td_off, 5)
    external = fb.string(ext_field) if ext_field else None

    loader: Callable[[], bytes] | None = None
    if data_field:
        length = fb.vector_len(data_field)
        first = fb.vector_elem(data_field, 0, 1) if length else 0

        def _load() -> bytes:
            if length == 0:
                return b""
            if first + length > len(payload):
                raise CatalogError(
                    f"SC2 {what} data vector 越界: 起点 {first} 长度 "
                    f"{length}，chunk 长度 {len(payload)}")
            return payload[first:first + length]

        loader = _load
    return TextureData(texture_format=fmt, pixel_type=pixel_type,
                       width=width, height=height,
                       external_texture=external, _data_loader=loader)


def parse_textures(payload: bytes) -> list[TextureData]:
    """Textures chunk：TextureSet 列表（取 highres，lowres 元数据一并返回）。

    `Textures{textures: [TextureSet]}`（slot 0）；`TextureSet{lowres (slot 0),
    highres (slot 1, required)}`。highres 缺失（schema 违约）→ CatalogError。

    对拍真实 ui.sc：7 个 set 全部仅 highres，texture_format=8（内嵌 KTX
    ASTC），pixel_type 字段缺省；buildings.sc 71 个 set 全部 external_texture
    `.sctx`。data 惰性读取（避免 95MB chunk 整块解引用）。
    """
    if not payload:
        return []
    try:
        fb = FlatBuffer(payload)
        root = fb.root()
        vec = fb.table_field(root, 0)
        if vec == 0:
            return []
        count = fb.vector_len(vec)
        if count > _MAX_VECTOR_ENTRIES:
            raise CatalogError(
                f"SC2 Textures 条目数 {count} 超过上限 {_MAX_VECTOR_ENTRIES}"
                "（防 512MB body 解压后的 O(n) 放大）")
        out: list[TextureData] = []
        for i in range(count):
            set_tbl = fb.table(fb.vector_elem(vec, i, 4))
            high_field = fb.table_field(set_tbl, 1)
            if high_field == 0:
                raise CatalogError(
                    f"SC2 TextureSet[{i}] 缺少 required highres 字段")
            high = _parse_texture_data(
                fb, payload, fb.table(high_field), f"Textures[{i}].highres")
            # 返回 highres：C++ 默认路径（低内存模式才用 lowres，spike 不需要）
            out.append(high)
        return out
    except CatalogError:
        raise
    except ValueError as e:
        raise CatalogError(f"SC2 Textures 解析失败: {e}") from e


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
        info = parse_data_storage_info(fb, body)
        strings = info.strings
        chunks = read_chunks(body, header.resources_offset)
        # 重复 name last-wins（真实 ui.sc 导出名唯一；防御语义）
        export_names = dict(
            parse_export_names(chunks.get("ExportNames", b""), strings))
    except ValueError as e:
        raise CatalogError(f"SC2 body 解析失败: {e}") from e
    return ScFile(header=header, metadata=metadata, strings=strings,
                  export_names=export_names, chunks=chunks,
                  frame_elements=info.movieclips_frame_elements)
