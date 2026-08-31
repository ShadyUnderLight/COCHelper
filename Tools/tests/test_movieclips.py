"""MovieClip 帧解析测试（Issue #30 Task 1，SC2 渲染链）。

实证结论（对拍 ui.sc / buildings.sc + sc-workshop/SupercellFlash
MovieClip.cpp / MovieClip.h，2026-08 对拍）：
- `MovieClipFrameElement` = **6 字节 3×u16**：
  instance_index（**children 数组索引**，非全局 id）/ matrix_index（matrix
  bank 内矩阵索引，0xFFFF=无）/ color_transform_index（0xFFFF=无）。
  **没有 type 字段**（任务初版假设的 8/12/16 字节 + type 枚举被真实字节否定）。
- `frame_elements_offset` = **ushort 索引**（相对 movieclips_frame_elements
  缓冲起点，非字节偏移）；所有帧的 used_transform 之和个元素从该处**顺序
  连续**消费（frame 0 先用）。
- 元素引用的对象类型由 `children_ids[instance_index]` 落在 shape / movieclip
  / textfield 的 id 空间决定（实证 ui.sc：child 7753=textfield、8025=shape；
  buildings.sc：1549=shape、1607=movieclip）。
- MovieClipFrame = 8 字节 struct（used_transform u32 + label_ref_id u32）；
  short_frames 帧 = 2 字节 struct（仅 used_transform u16）。
- 真实锚点：ui.sc icon_unit_barbarian（mc 索引 1992）**单帧** used_transform=2，
  frame_elements=[(0, 27581, 0xFFFF), (1, 0xFFFF, 0xFFFF)]；
  buildings.sc fireplace_lvl1（mc 索引 448）单帧 used_transform=2，
  frame_elements=[(0, 14432, 0xFFFF), (1, 14433, 0xFFFF)]。
"""

import os
import struct
import zipfile
from pathlib import Path

import pytest
from hypothesis import given, strategies as st

from game_catalog.errors import CatalogError
from game_catalog.fbs import FlatBuffer
from game_catalog.sc2 import (
    DataStorageInfo,
    MovieClip,
    MovieClipFrame,
    MovieClipFrameElement,
    ScFile,
    ScHeader,
    load_libzstd,
    load_sc,
    parse_data_storage_info,
    parse_movieclips,
)
from test_fbs import FbBuilder

APK = Path(os.environ.get("COC_APK_PATH", "/path/to/base.apk"))


# ---------------------------------------------------------------------------
# fixture 构造：手工拼装 MovieClips flatbuffer + frame elements 缓冲
# ---------------------------------------------------------------------------


def build_movieclips(mcs: list[dict]) -> bytes:
    """MovieClips{ movieclips: [MovieClip] } flatbuffer。

    mc dict 支持键：id(u16) / export_name_ref_id(u32) / frames(8B struct
    vector) / frame_elements_offset(u32) / matrix_bank_index(u32) /
    short_frames(2B struct vector)。
    """
    b = FbBuilder()
    tokens = []
    for mc in mcs:
        fields: dict[int, tuple] = {}
        if "id" in mc:
            fields[0] = ("u16", mc["id"])
        if "export_name_ref_id" in mc:
            fields[1] = ("u32", mc["export_name_ref_id"])
        if "frames" in mc:
            raw = b"".join(struct.pack("<II", used, label)
                           for used, label in mc["frames"])
            fields[8] = ("uoffset", b.add_raw_vector(len(mc["frames"]), raw))
        if "frame_elements_offset" in mc:
            fields[9] = ("u32", mc["frame_elements_offset"])
        if "matrix_bank_index" in mc:
            fields[10] = ("u32", mc["matrix_bank_index"])
        if "short_frames" in mc:
            raw = b"".join(struct.pack("<H", u) for u in mc["short_frames"])
            fields[12] = ("uoffset", b.add_raw_vector(len(mc["short_frames"]), raw))
        tokens.append(b.add_table(fields))
    vec = b.add_vector(tokens)
    root = b.add_table({0: ("uoffset", vec)})
    return b.finish(root)


def build_frame_elements(ushorts: list[int]) -> bytes:
    """DataStorage slot 4 movieclips_frame_elements 的原始 u16 字节。"""
    return struct.pack("<%dH" % len(ushorts), *ushorts)


# ---------------------------------------------------------------------------
# parse_movieclips：基础解析
# ---------------------------------------------------------------------------


def test_parse_movieclips_basic_fields_and_elements():
    """单 mc：id/export_ref/frames/offset/bank + 元素按 3×u16 解析。"""
    payload = build_movieclips([{
        "id": 7, "export_name_ref_id": 3,
        "frames": [(2, 5), (1, 0)],
        "frame_elements_offset": 10, "matrix_bank_index": 1,
    }])
    # offset=10（ushort 索引）→ 字节偏移 20；3 个元素 = 9 ushort
    buf = build_frame_elements(list(range(0, 40)))
    mcs = parse_movieclips(payload, buf)
    assert list(mcs) == [0]  # 按 movieclip 索引
    mc = mcs[0]
    assert mc == MovieClip(
        id=7, export_name_ref_id=3,
        frames=[MovieClipFrame(used_transform=2, label_ref_id=5),
                MovieClipFrame(used_transform=1, label_ref_id=0)],
        frame_elements_offset=10, matrix_bank_index=1,
        frame_elements=[
            MovieClipFrameElement(instance_index=10, matrix_index=11,
                                  color_transform_index=12),
            MovieClipFrameElement(instance_index=13, matrix_index=14,
                                  color_transform_index=15),
            MovieClipFrameElement(instance_index=16, matrix_index=17,
                                  color_transform_index=18),
        ])


def test_parse_movieclips_multiple_movieclips_by_index():
    payload = build_movieclips([
        {"id": 100, "frames": [(0, 0)], "frame_elements_offset": 0},
        {"id": 200, "frames": [(0, 0)], "frame_elements_offset": 0},
    ])
    mcs = parse_movieclips(payload, b"")
    assert list(mcs) == [0, 1]
    assert mcs[0].id == 100
    assert mcs[1].id == 200


def test_parse_movieclips_empty_payload_returns_empty():
    assert parse_movieclips(b"", b"\x00" * 64) == {}


def test_parse_movieclips_no_frame_elements_offset_ok():
    """0xFFFFFFFF + 无元素 → frame_elements=[]（icon 类静态 mc 的常见形态）。"""
    payload = build_movieclips([{"id": 1, "frames": [(0, 0)]}])
    mc = parse_movieclips(payload, b"\x00" * 16)[0]
    assert mc.frame_elements == []
    assert mc.frame_elements_offset == 0xFFFFFFFF


def test_parse_movieclips_short_frames():
    """frames 缺省时用 short_frames（2B struct，仅 used_transform）。"""
    payload = build_movieclips([{
        "id": 9, "short_frames": [2, 1], "frame_elements_offset": 4,
    }])
    buf = build_frame_elements(list(range(0, 30)))
    mc = parse_movieclips(payload, buf)[0]
    assert [f.used_transform for f in mc.frames] == [2, 1]
    assert [f.label_ref_id for f in mc.frames] == [0, 0]  # short 帧无 label
    assert len(mc.frame_elements) == 3


def test_parse_movieclips_frames_preferred_over_short_frames():
    """frames 与 short_frames 并存 → 用 frames（保留 label），忽略 short_frames。

    若错误优先 short_frames：total=9 → 元素越界 CatalogError；解析成功 +
    label=77 保真即证明 frames 分支生效。
    """
    payload = build_movieclips([{
        "id": 1, "frames": [(1, 77)], "short_frames": [9],
        "frame_elements_offset": 0,
    }])
    mc = parse_movieclips(payload, build_frame_elements([5, 6, 7]))[0]
    assert [f.used_transform for f in mc.frames] == [1]
    assert mc.frames[0].label_ref_id == 77


# ---------------------------------------------------------------------------
# 畸形数据：fail loud
# ---------------------------------------------------------------------------


def test_parse_movieclips_missing_offset_with_elements_raises():
    """有元素但 offset=0xFFFFFFFF → CatalogError（不得静默读错位置）。"""
    payload = build_movieclips([{"id": 1, "frames": [(2, 0)]}])
    with pytest.raises(CatalogError, match="0xFFFFFFFF"):
        parse_movieclips(payload, b"\x00" * 64)


def test_parse_movieclips_buffer_out_of_bounds_raises():
    """offset 越界或元素超出缓冲 → CatalogError。"""
    payload = build_movieclips([{
        "id": 1, "frames": [(2, 0)], "frame_elements_offset": 100,
    }])
    with pytest.raises(CatalogError, match="越界"):
        parse_movieclips(payload, build_frame_elements([1, 2, 3, 4]))


def test_parse_movieclips_partial_overlap_raises():
    """起点界内但终点越出缓冲（部分重叠）→ CatalogError，不得截断消费。"""
    payload = build_movieclips([{
        "id": 1, "frames": [(3, 0)], "frame_elements_offset": 2,
    }])
    buf = build_frame_elements([0] * 10)  # 20 字节：起点 4B 界内，需 18B → 越界
    with pytest.raises(CatalogError, match="越界"):
        parse_movieclips(payload, buf)


def test_parse_movieclips_elements_count_limit_raises():
    """FIX-5 同源：单 mc 元素总数超上限 → CatalogError（防 O(n) 放大）。"""
    payload = bytearray(build_movieclips([{
        "id": 1, "frames": [(2_000_000, 0)], "frame_elements_offset": 0,
    }]))
    with pytest.raises(CatalogError, match="上限"):
        parse_movieclips(bytes(payload), b"\x00" * 64)


def test_parse_movieclips_frames_count_limit_raises():
    """frames vector 元素数超上限 → CatalogError（防 O(n) 放大）。"""
    payload = bytearray(build_movieclips([{"id": 1, "frames": [(1, 0)]}]))
    data = bytes(payload)
    root_pos = struct.unpack("<I", data[:4])[0]
    mc_vec_field = root_pos + _table_slot_rel(data, root_pos, 0)
    mc_vec = mc_vec_field + struct.unpack("<I", data[mc_vec_field:mc_vec_field + 4])[0]
    mc_table = mc_vec + 4 + struct.unpack("<I", data[mc_vec + 4:mc_vec + 8])[0]
    frames_field = mc_table + _table_slot_rel(data, mc_table, 8)
    frames_vec = frames_field + struct.unpack("<I", data[frames_field:frames_field + 4])[0]
    payload[frames_vec:frames_vec + 4] = struct.pack("<I", 2_000_000)
    with pytest.raises(CatalogError, match="上限"):
        parse_movieclips(bytes(payload), b"\x00" * 64)


def test_parse_movieclips_count_limit_raises():
    """MovieClips vector 条目数超上限 → CatalogError（防 O(n) 放大）。"""
    payload = bytearray(build_movieclips([{"id": 1, "frames": [(0, 0)]}]))
    data = bytes(payload)
    root_pos = struct.unpack("<I", data[:4])[0]
    mc_vec_field = root_pos + _table_slot_rel(data, root_pos, 0)
    mc_vec = mc_vec_field + struct.unpack(
        "<I", data[mc_vec_field:mc_vec_field + 4])[0]
    payload[mc_vec:mc_vec + 4] = struct.pack("<I", 2_000_000)
    with pytest.raises(CatalogError, match="上限"):
        parse_movieclips(bytes(payload), b"\x00" * 64)


def _table_slot_rel(data: bytes, table_off: int, slot: int) -> int:
    """table 的 vtable 中某 slot 的相对偏移（0 = 缺省）。"""
    soffset = struct.unpack("<i", data[table_off:table_off + 4])[0]
    vtable = table_off - soffset
    return struct.unpack(
        "<H", data[vtable + 4 + 2 * slot:vtable + 6 + 2 * slot])[0]


# ---------------------------------------------------------------------------
# parse_data_storage_info：strings + frame elements 缓冲
# ---------------------------------------------------------------------------


def test_data_storage_info_returns_strings_and_buffer():
    """DataStorage slot 0 strings + slot 4 [ushort] 原始字节。"""
    b = FbBuilder()
    s1 = b.add_string("hello")
    s2 = b.add_string("world")
    sv = b.add_vector([s1, s2])
    fe = b.add_raw_vector(5, struct.pack("<5H", 10, 20, 30, 40, 50))
    root = b.add_table({0: ("uoffset", sv), 4: ("uoffset", fe)})
    payload = b.finish(root)
    info = parse_data_storage_info(FlatBuffer(payload), payload)
    assert info == DataStorageInfo(
        strings=["hello", "world"],
        movieclips_frame_elements=struct.pack("<5H", 10, 20, 30, 40, 50),
        payload=payload,
    )


def test_data_storage_info_size_prefixed_layout():
    """真实布局：body = [u32 size][DataStorage]；fb 传 body[4:]。"""
    b = FbBuilder()
    sv = b.add_vector([])
    fe = b.add_raw_vector(2, struct.pack("<2H", 1, 2))
    root = b.add_table({0: ("uoffset", sv), 4: ("uoffset", fe)})
    payload = b.finish(root)
    body = struct.pack("<I", len(payload)) + payload
    info = parse_data_storage_info(FlatBuffer(body[4:]), body)
    assert info.strings == []
    assert info.movieclips_frame_elements == struct.pack("<2H", 1, 2)


def test_data_storage_info_missing_buffer_returns_empty_bytes():
    b = FbBuilder()
    sv = b.add_vector([])
    root = b.add_table({0: ("uoffset", sv)})
    payload = b.finish(root)
    info = parse_data_storage_info(FlatBuffer(payload), payload)
    assert info.movieclips_frame_elements == b""


def test_data_storage_info_frame_elements_over_64mb_raises():
    """帧元素池声明长度超 64MB → CatalogError（只查声明长度，不分配缓冲）。"""
    b = FbBuilder()
    sv = b.add_vector([])
    fe = b.add_raw_vector(33_600_000, b"")  # 声明 67.2MB > 64MB 上限
    root = b.add_table({0: ("uoffset", sv), 4: ("uoffset", fe)})
    payload = b.finish(root)
    with pytest.raises(CatalogError, match="超过上限"):
        parse_data_storage_info(FlatBuffer(payload), payload)


def test_data_storage_both_layouts_fail_raises_with_both_offsets():
    """两种布局均失败 → CatalogError 消息含偏移0 与偏移4 两个上下文。"""
    payload = bytes(range(32))  # 任意垃圾：偏移0/偏移4 的 root uoffset 均越界
    with pytest.raises(CatalogError, match="偏移0.*偏移4"):
        parse_data_storage_info(FlatBuffer(payload), payload)


# ---------------------------------------------------------------------------
# ScFile.movieclip_for_export + 惰性缓存
# ---------------------------------------------------------------------------


def _build_scfile(payload: bytes, frame_elements: bytes,
                  export_names: dict[str, int]) -> ScFile:
    """最小 ScFile（跳过完整 SC 头：直接构造 dataclass）。"""
    header = ScHeader(version=6, descriptor_size=0, shape_count=0,
                      movie_clips_count=0, texture_count=0, text_fields_count=0,
                      resources_offset=0, textures_length=0, compressed_size=0,
                      external_matrix_bank_size=0)
    chunks = {"MovieClips": payload}
    return ScFile(header=header, metadata=[], strings=[],
                  export_names=export_names, chunks=chunks,
                  frame_elements=frame_elements)


def test_movieclip_for_export_found():
    sc = _build_scfile(
        build_movieclips([{"id": 7, "frames": [(0, 0)], "export_name_ref_id": 0},
                          {"id": 42, "frames": [(1, 0)], "export_name_ref_id": 1,
                           "frame_elements_offset": 0}]),
        build_frame_elements([5, 6, 7]),
        export_names={"icon_a": 7, "icon_b": 42})
    mc = sc.movieclip_for_export("icon_b")
    assert mc is not None
    assert mc.id == 42
    assert mc.frame_elements == [MovieClipFrameElement(5, 6, 7)]


def test_movieclip_for_export_unknown_name_returns_none():
    sc = _build_scfile(build_movieclips([]), b"", export_names={})
    assert sc.movieclip_for_export("no_such_export") is None


def test_movieclip_for_export_non_movieclip_object_returns_none():
    """export 指向的 object_id 不是任何 movieclip 的 id → None。"""
    sc = _build_scfile(
        build_movieclips([{"id": 7, "frames": [(0, 0)]}]),
        b"", export_names={"icon_a": 999})  # oid 999 不存在于 movieclips
    assert sc.movieclip_for_export("icon_a") is None


def test_movieclips_parsed_lazily_and_cached():
    sc = _build_scfile(
        build_movieclips([{"id": 7, "frames": [(0, 0)]}]),
        b"", export_names={"icon_a": 7})
    assert "movieclips" not in sc._cache
    mc1 = sc.movieclip_for_export("icon_a")
    assert "movieclips" in sc._cache
    mc2 = sc.movieclip_for_export("icon_a")
    assert mc1 is mc2  # 同一缓存对象（惰性只解析一次）


def test_movieclip_for_export_duplicate_id_raises():
    """两个 movieclip 同 id → CatalogError（fail loud，防静默 last-wins）。"""
    sc = _build_scfile(
        build_movieclips([{"id": 7, "frames": [(0, 0)]},
                          {"id": 7, "frames": [(0, 0)]}]),
        b"", export_names={"icon_a": 7})
    with pytest.raises(CatalogError, match="重复"):
        sc.movieclip_for_export("icon_a")


# ---------------------------------------------------------------------------
# property-based：元素连续消费与保序不变量
# ---------------------------------------------------------------------------


@given(st.lists(st.integers(0, 5), max_size=4), st.integers(0, 20))
def test_prop_frame_elements_consumed_sequentially(used_values, offset):
    """元素从 offset（ushort 索引）起按帧顺序连续消费；3×u16 保序读回。"""
    frames = [(u, 7 + i) for i, u in enumerate(used_values)]  # label 也保序
    payload = build_movieclips([{
        "id": 1, "frames": frames, "frame_elements_offset": offset,
    }])
    total = sum(used_values)
    buf = bytearray((offset + total * 3) * 2)
    for i in range(total):
        pos = (offset + i * 3) * 2
        struct.pack_into("<HHH", buf, pos, i, 1000 + i, 2000 + i)
    mc = parse_movieclips(payload, bytes(buf))[0]
    assert [f.used_transform for f in mc.frames] == used_values
    assert [f.label_ref_id for f in mc.frames] == [7 + i for i in range(len(frames))]
    assert len(mc.frame_elements) == total
    assert [e.instance_index for e in mc.frame_elements] == list(range(total))
    assert [e.matrix_index for e in mc.frame_elements] == [1000 + i for i in range(total)]
    assert [e.color_transform_index for e in mc.frame_elements] == [2000 + i for i in range(total)]


@given(st.lists(st.integers(0, 3), max_size=3), st.integers(0, 10))
def test_prop_zero_used_frames_skip_no_elements(used_values, offset):
    """used_transform=0 的帧不消费任何元素（元素数 = sum，无偏移依赖）。"""
    frames = [(u, 0) for u in used_values]
    payload = build_movieclips([{
        "id": 1, "frames": frames, "frame_elements_offset": offset,
    }])
    total = sum(used_values)
    buf = bytearray((offset + total * 3) * 2)
    for i in range(total):
        struct.pack_into("<HHH", buf, (offset + i * 3) * 2, i, 0, 0)
    mc = parse_movieclips(payload, bytes(buf))[0]
    assert len(mc.frame_elements) == total


# ---------------------------------------------------------------------------
# 真实 APK 冒烟（无 APK 或无 libzstd 时跳过）
# ---------------------------------------------------------------------------

_real_apk = pytest.mark.skipif(
    not APK.is_file(),
    reason="真实 APK 不存在（设置 COC_APK_PATH 指向 base.apk.1 可启用）")


def _load_sc(container: str) -> ScFile:
    try:
        load_libzstd()
    except CatalogError as e:
        pytest.skip(f"libzstd 不可用: {e}")
    with zipfile.ZipFile(str(APK)) as z:
        return load_sc(z.read(container))


@_real_apk
def test_real_apk_icon_unit_barbarian_anchor():
    """ui.sc icon_unit_barbarian：单帧 used_transform=2（#27 spike 锚点）。"""
    sc = _load_sc("assets/sc/ui.sc")
    mc = sc.movieclip_for_export("icon_unit_barbarian")
    assert mc is not None
    assert mc.id == 8397
    assert len(mc.frames) == 1
    assert mc.frames[0].used_transform == 2
    assert len(mc.frame_elements) == 2
    # 18.400.13 锚点（实证）：instance 为 children 索引，matrix 或为 0xFFFF
    assert mc.frame_elements[0].instance_index == 0
    assert mc.frame_elements[1].instance_index == 1
    assert mc.frame_elements[0].color_transform_index == 0xFFFF
    assert mc.frame_elements[1].color_transform_index == 0xFFFF


@_real_apk
def test_real_apk_fireplace_lvl1_anchor():
    """buildings.sc fireplace_lvl1：单帧 used_transform=2，元素 2 个。"""
    sc = _load_sc("assets/sc/buildings.sc")
    mc = sc.movieclip_for_export("fireplace_lvl1")
    assert mc is not None
    assert mc.id == 1635
    assert len(mc.frames) == 1
    assert mc.frames[0].used_transform == 2
    assert len(mc.frame_elements) == 2
    assert mc.frame_elements[0].instance_index == 0
    assert mc.frame_elements[1].instance_index == 1
    assert mc.frame_elements[1].color_transform_index == 0xFFFF
