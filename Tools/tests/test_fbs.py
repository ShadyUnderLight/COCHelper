"""fbs 只读解析器测试：手工构造 flatbuffers fixture 字节，验证逐字节读取语义。

本文件同时提供可复用的 fixture 构造辅助（FbBuilder / build_sample_table），
后续 SC2 解析 task 可直接 import 复用（纯 stdlib，无第三方依赖）。
"""

import struct

import pytest

from game_catalog.fbs import FlatBuffer

# ---------------------------------------------------------------------------
# fixture 构造辅助：手工拼装 flatbuffers 字节（无任何第三方库）
# ---------------------------------------------------------------------------


def fb_u16(x: int) -> bytes:
    """小端 u16。"""
    return struct.pack("<H", x)


def fb_u32(x: int) -> bytes:
    """小端 u32。"""
    return struct.pack("<I", x)


def fb_i32(x: int) -> bytes:
    """小端 i32。"""
    return struct.pack("<i", x)


def fb_align(buf: bytearray, n: int) -> None:
    """向 buf 追加零字节，使长度对齐到 n 的倍数。"""
    pad = (-len(buf)) % n
    buf += b"\x00" * pad


class FbBuilder:
    """两阶段构造 flatbuffers 文件字节（小端、4 字节对齐布局，纯 stdlib）。

    flatbuffers 的 uoffset 是无符号偏移（目标地址 > uoffset 所在位置），
    因此被引用对象必须排在引用者之后。本构造器按 **add 顺序的反序**布局：
    先 add 的被引用对象放在文件末尾（地址最大），最后 add 的 root 放在最前。
    调用方约定：先 add 叶子对象（string / 被嵌套 table / vector 元素），
    最后 add 引用它们的 table。

    布局约定（与解析器 fbs.FlatBuffer 对应，同官方 flatbuffers 格式）：
    - 文件头 4 字节：root uoffset（相对文件起点，指向 root table 起点）
    - string: u32 len + UTF-8 字节（无结尾 null）
    - vector: u32 len + 元素；uoffset 元素 4 字节对齐
    - table: 起点处为 i32 soffset（vtable 位置 = table 起点 - soffset）；
      字段从 table 起点 + 4 开始
    - vtable: u16 vtable_size + u16 table_size + 每 slot 一个 u16
      （相对 table 起点的偏移，0 = 字段缺省）

    usage:
        b = FbBuilder()
        s = b.add_string("hello")
        root = b.add_table({0: ("uoffset", s), 2: ("u32", 42)})
        data = b.finish(root)
    """

    def __init__(self) -> None:
        self._objs: list[tuple] = []

    def add_string(self, s: str | bytes) -> int:
        """注册 string，返回其 token（后续引用用）。"""
        raw = s.encode("utf-8") if isinstance(s, str) else s
        self._objs.append(("string", raw))
        return len(self._objs) - 1

    def add_vector(self, elem_positions: list[int]) -> int:
        """注册 vector（元素为 uoffset，指向 token），返回其 token。"""
        self._objs.append(("vector", tuple(elem_positions)))
        return len(self._objs) - 1

    def add_raw_vector(self, elem_count: int, raw: bytes) -> int:
        """注册原始元素 vector（如 [ushort]/[uint]）：u32 元素个数 + 元素字节。

        与 add_string(bytes) 的区别：长度字段写**元素个数**而非字节数
        （flatbuffers 的 [ushort] vector 长度字段语义是元素个数）。
        """
        self._objs.append(("rawvec", (elem_count, raw)))
        return len(self._objs) - 1

    def add_table(self, fields: dict[int, tuple[str, int]]) -> int:
        """注册 table，返回其 token。

        fields: {slot: (kind, value)}
        - ("uoffset", token): 字段处写 uoffset（相对字段自身位置，指向该 token 对象）
        - ("u32", 值): inline uint32 标量
        - ("u16", 值): inline uint16 标量（0..0xFFFF，Shapes/Textures schema 用）
        - ("u8", 值): inline uint8 标量（0..0xFF，TextureData 枚举/字节字段用）
        未出现的 slot 在 vtable 中偏移为 0（缺省 → 用默认值）。
        """
        self._objs.append(("table", dict(fields)))
        return len(self._objs) - 1

    def finish(self, root_token: int) -> bytes:
        """按 add 反序布局全部对象，写入 root uoffset 并返回文件字节。

        两遍完成：先放置全部对象（uoffset 字段留空）并记录各自位置，
        再统一填充 uoffset（目标位置此时全部已知）。
        """
        if not 0 <= root_token < len(self._objs):
            raise ValueError(f"root token {root_token} 越界（共 {len(self._objs)} 个对象）")
        positions: dict[int, int] = {}
        uoffsets: list[tuple[int, int]] = []  # (uoffset 起点, 目标 token)
        # 文件头 4 字节：root uoffset。root table（首个布局对象）的 soffset
        # 位于其起点处（起点 >= 4），不与文件头重叠。
        buf = bytearray(b"\x00" * 4)
        for token in reversed(range(len(self._objs))):
            obj = self._objs[token]
            fb_align(buf, 4)
            start = len(buf)
            if obj[0] == "string":
                raw = obj[1]
                buf += fb_u32(len(raw)) + raw
            elif obj[0] == "rawvec":
                elem_count, raw = obj[1]
                buf += fb_u32(elem_count) + raw
            elif obj[0] == "vector":
                elems = obj[1]
                buf += fb_u32(len(elems))
                for t in elems:
                    fp = len(buf)
                    buf += b"\x00" * 4
                    uoffsets.append((fp, t))
            else:  # table
                fields = obj[1]
                # 布局：[soffset i32][字段 body ...][vtable ...]
                # soffset 位于 table 起点（偏移 0）；vtable 位置 = table 起点 - soffset；
                # 字段从 table 起点 + 4 开始（vtable 偏移 0 表示缺省，字段偏移必须 > 0）
                field_positions: dict[int, int] = {}
                body = bytearray()
                for slot in sorted(fields):
                    kind, value = fields[slot]
                    field_positions[slot] = 4 + len(body)
                    if kind == "uoffset":
                        body += b"\x00" * 4
                    elif kind == "u32":
                        body += fb_u32(value)
                    elif kind == "u16":
                        if not 0 <= value <= 0xFFFF:
                            raise ValueError(f"u16 越界: {value}（slot {slot}）")
                        body += struct.pack("<H", value)
                    elif kind == "u8":
                        if not 0 <= value <= 0xFF:
                            raise ValueError(f"u8 越界: {value}（slot {slot}）")
                        body += bytes([value])
                    else:
                        raise ValueError(f"未知字段类型 {kind!r}（slot {slot}）")
                table_start = start  # 对象起点 = table 起点（soffset 处）
                buf += fb_i32(0)  # soffset 占位
                buf += body
                fb_align(buf, 2)
                vtable_start = len(buf)
                n_slots = max(fields) + 1 if fields else 0
                vtable = fb_u16(4 + 2 * n_slots) + fb_u16(4 + len(body))
                for slot in range(n_slots):
                    rel = field_positions.get(slot)
                    vtable += fb_u16(rel if rel is not None else 0)
                buf += vtable
                buf[table_start:table_start + 4] = fb_i32(table_start - vtable_start)
                for slot, (kind, value) in fields.items():
                    if kind == "uoffset":
                        uoffsets.append((table_start + field_positions[slot], value))
                positions[token] = table_start
                continue
            positions[token] = start
        # pass 2：填充全部 uoffset（目标位置此时已知）
        for here, token in uoffsets:
            target = positions.get(token)
            if target is None:
                raise ValueError(f"引用未注册的 token {token}（请先 add 被引用对象）")
            if target < here:
                raise ValueError(
                    f"uoffset 为负（目标 {target} < 当前位置 {here}）："
                    "请先 add 被引用对象、后 add 引用者")
            buf[here:here + 4] = fb_u32(target - here)
        buf[0:4] = fb_u32(positions[root_token])
        return bytes(buf)


def build_sample_table() -> bytes:
    """构造含 string / uint32 / 嵌套 table / vector<string> 的根 table。

    字段：slot 0 = string "hello"；slot 1 = 缺省；slot 2 = uint32 42；
    slot 3 = 嵌套 table（内含 string "world"）；slot 4 = vector<string> ["a", "bc"]。
    """
    b = FbBuilder()
    hello = b.add_string("hello")
    world = b.add_string("world")
    nested = b.add_table({0: ("uoffset", world)})
    a = b.add_string("a")
    bc = b.add_string("bc")
    vec = b.add_vector([a, bc])
    root = b.add_table({
        0: ("uoffset", hello),
        2: ("u32", 42),
        3: ("uoffset", nested),
        4: ("uoffset", vec),
    })
    return b.finish(root)


# ---------------------------------------------------------------------------
# 解析器测试
# ---------------------------------------------------------------------------


def test_root_position_matches_header():
    data = build_sample_table()
    fb = FlatBuffer(data)
    assert fb.root() == struct.unpack("<I", data[:4])[0]
    assert fb.root() % 4 == 0  # root table 4 字节对齐


def test_string_field():
    fb = FlatBuffer(build_sample_table())
    off = fb.table_field(fb.root(), 0)
    assert off > 0
    assert fb.string_bytes(off) == b"hello"
    assert fb.string(off) == "hello"
    # 字段存在时 default 不生效
    assert fb.table_field(fb.root(), 0, default=-1) == off


def test_missing_slot_returns_default():
    fb = FlatBuffer(build_sample_table())
    root = fb.root()
    assert fb.table_field(root, 1) == 0               # vtable 内但偏移为 0
    assert fb.table_field(root, 1, default=-1) == -1
    assert fb.table_field(root, 5, default=99) == 99  # 超出 vtable 声明范围


def test_inline_u32_field():
    data = build_sample_table()
    fb = FlatBuffer(data)
    off = fb.table_field(fb.root(), 2)
    assert struct.unpack("<I", data[off:off + 4])[0] == 42


def test_nested_table_string():
    fb = FlatBuffer(build_sample_table())
    nested = fb.table(fb.table_field(fb.root(), 3))
    assert nested > 0
    assert fb.string(fb.table_field(nested, 0)) == "world"
    assert fb.table_field(nested, 1, default=7) == 7  # 嵌套表缺省字段


def test_vector_of_strings():
    fb = FlatBuffer(build_sample_table())
    vec = fb.table_field(fb.root(), 4)
    assert fb.vector_len(vec) == 2
    assert [fb.string(fb.vector_elem(vec, i, 4)) for i in range(2)] == ["a", "bc"]
    with pytest.raises(ValueError, match="越界"):
        fb.vector_elem(vec, 2, 4)


def test_table_with_only_default_fields():
    """缺省场景：只有 slot 0 的 table，其余字段全部走默认值。"""
    b = FbBuilder()
    s = b.add_string("only")
    root = b.add_table({0: ("uoffset", s)})
    fb = FlatBuffer(b.finish(root))
    assert fb.string(fb.table_field(fb.root(), 0)) == "only"
    assert fb.table_field(fb.root(), 1, default=123) == 123
    assert fb.table_field(fb.root(), 3, default=-5) == -5


def test_short_buffer_raises():
    with pytest.raises(ValueError, match="过短"):
        FlatBuffer(b"")
    with pytest.raises(ValueError, match="过短"):
        FlatBuffer(b"\x04\x00\x00")


def test_truncated_table_raises():
    data = build_sample_table()
    fb = FlatBuffer(data[:8])
    with pytest.raises(ValueError):
        fb.string(fb.table_field(fb.root(), 0))


def test_string_length_out_of_bounds_raises():
    # 构造合法 fixture 后，把 "hello" 的长度字段改为 1000（越界）
    data = bytearray(build_sample_table())
    root = struct.unpack("<I", data[:4])[0]
    soffset = struct.unpack("<i", data[root:root + 4])[0]
    vtable = root - soffset
    slot0_rel = struct.unpack("<H", data[vtable + 4:vtable + 6])[0]
    field_off = root + slot0_rel
    str_pos = field_off + struct.unpack("<I", data[field_off:field_off + 4])[0]
    data[str_pos:str_pos + 4] = fb_u32(1000)
    fb = FlatBuffer(bytes(data))
    with pytest.raises(ValueError):
        fb.string(fb.table_field(fb.root(), 0))


def test_malformed_vtable_size_raises():
    b = FbBuilder()
    root = b.add_table({})
    data = bytearray(b.finish(root))
    root_pos = struct.unpack("<I", data[:4])[0]
    soffset = struct.unpack("<i", data[root_pos:root_pos + 4])[0]
    vtable_pos = root_pos - soffset
    data[vtable_pos:vtable_pos + 2] = b"\x00\x00"  # vtable_size 改为 0（畸形）
    fb = FlatBuffer(bytes(data))
    with pytest.raises(ValueError):
        fb.table_field(root_pos, 0)


def test_vtable_size_declared_out_of_bounds_raises():
    # vtable_size 声明 0xFFFF（远超 buffer）→ 任何 slot 读取都应抛错，
    # 不能按声明的 size 继续读（可能读到 vtable 外的垃圾当作字段偏移）
    b = FbBuilder()
    s = b.add_string("x")
    root = b.add_table({0: ("uoffset", s)})
    data = bytearray(b.finish(root))
    root_pos = struct.unpack("<I", data[:4])[0]
    soffset = struct.unpack("<i", data[root_pos:root_pos + 4])[0]
    vtable_pos = root_pos - soffset
    data[vtable_pos:vtable_pos + 2] = b"\xff\xff"
    fb = FlatBuffer(bytes(data))
    with pytest.raises(ValueError):
        fb.table_field(root_pos, 0)


def test_field_rel_exceeding_table_size_raises():
    # slot 偏移声明 0x7FFF（远超 table_size）→ table_field 应抛错，
    # 不能静默返回垃圾偏移
    b = FbBuilder()
    s = b.add_string("x")
    root = b.add_table({0: ("uoffset", s)})
    data = bytearray(b.finish(root))
    root_pos = struct.unpack("<I", data[:4])[0]
    soffset = struct.unpack("<i", data[root_pos:root_pos + 4])[0]
    vtable_pos = root_pos - soffset
    data[vtable_pos + 4:vtable_pos + 6] = b"\xff\x7f"
    fb = FlatBuffer(bytes(data))
    with pytest.raises(ValueError):
        fb.table_field(root_pos, 0)


def test_table_offset_too_small_raises():
    fb = FlatBuffer(build_sample_table())
    with pytest.raises(ValueError):
        fb.table_field(2, 0)
