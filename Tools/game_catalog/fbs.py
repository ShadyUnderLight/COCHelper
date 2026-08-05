"""FlatBuffers 只读解析器（纯 stdlib，零第三方运行时依赖）。

解析 Scaleform SC2 V6 二进制中嵌套的 FlatBuffers 容器：只读访问
table / string / vector / uoffset / vtable，不做写回。

布局语义（与官方 flatbuffers 二进制格式一致）：
- 文件头 4 字节 uoffset 指向 root table 起点（soffset 所在处）
- table 起点处是 i32 soffset；vtable 位置 = table 起点 - soffset
- vtable: u16 vtable_size + u16 table_size + 每 slot 一个 u16，
  slot 偏移相对 table 起点；0 或未声明 = 字段缺省（用默认值）
- 字段从 table 起点 + 4 开始
- string: u32 len + UTF-8 字节（结尾 null 不计入 len）
- vector: u32 len + 元素（元素按自身大小对齐排列）
- 嵌套 table / vector / string 均以 uoffset 引用（相对自身所在位置）

偏移约定：对外 API 接收/返回的都是文件内绝对偏移；字段处存的 uoffset
相对其自身所在位置（uoffset 起点），解析时统一换算为绝对偏移。
"""

from __future__ import annotations

import struct


class FlatBuffer:
    """FlatBuffers 二进制缓冲的只读访问器。

    越界 / 畸形数据一律抛 ValueError（消息含偏移信息），绝不静默降级。
    """

    def __init__(self, data: bytes) -> None:
        if len(data) < 4:
            raise ValueError(f"FlatBuffer 数据过短: {len(data)} 字节（需要 >= 4）")
        self._data = data

    # -- 内部读取（统一越界检查） ----------------------------------------

    def _read(self, off: int, size: int, what: str) -> bytes:
        end = off + size
        if off < 0 or end > len(self._data):
            raise ValueError(
                f"越界读取 {what}: 偏移 {off} 大小 {size}，数据长度 {len(self._data)}")
        return self._data[off:end]

    def _u16(self, off: int, what: str) -> int:
        return struct.unpack("<H", self._read(off, 2, what))[0]

    def _u32(self, off: int, what: str) -> int:
        return struct.unpack("<I", self._read(off, 4, what))[0]

    def _i32(self, off: int, what: str) -> int:
        return struct.unpack("<i", self._read(off, 4, what))[0]

    def _uoffset_target(self, off: int, what: str) -> int:
        """uoffset 起点 -> 目标绝对偏移（uoffset 相对其所在位置）。"""
        return off + self._u32(off, what)

    # -- 公开 API ----------------------------------------------------------

    def root(self) -> int:
        """root table 绝对偏移（文件头 uoffset，相对文件起点）。"""
        return self._u32(0, "root uoffset")

    def table_field(self, table_off: int, slot: int, default: int = 0) -> int:
        """table 中 slot 字段的绝对偏移；字段缺省时返回 default。

        table 起点处是 i32 soffset（vtable 位置 = table 起点 - soffset）；
        slot 偏移为 0 或超出 vtable 声明范围 → 字段不存在 → 返回 default。
        """
        if slot < 0:
            raise ValueError(f"slot 必须 >= 0，实际 {slot}")
        if table_off < 0:
            raise ValueError(f"table 偏移 {table_off} 非法（必须 >= 0）")
        soffset = self._i32(table_off, f"table@{table_off} vtable soffset")
        vtable_pos = table_off - soffset
        vtable_size = self._u16(vtable_pos, f"vtable@{vtable_pos} size")
        if vtable_size < 4:
            raise ValueError(f"vtable@{vtable_pos} 畸形: size {vtable_size} < 4")
        slot_off_pos = vtable_pos + 4 + slot * 2
        if slot_off_pos + 2 > vtable_pos + vtable_size:
            return default  # 字段未声明
        field_rel = self._u16(slot_off_pos, f"vtable@{vtable_pos} slot{slot}")
        if field_rel == 0:
            return default
        return table_off + field_rel

    def table(self, off: int) -> int:
        """嵌套 table 字段绝对偏移（uoffset 起点）-> table 起点（soffset 处）。"""
        return self._uoffset_target(off, f"table 字段@{off}")

    def string_bytes(self, off: int) -> bytes:
        """字段绝对偏移（uoffset 起点）-> UTF-8 原始字节（不含结尾 null）。"""
        pos = self._uoffset_target(off, f"string 字段@{off}")
        length = self._u32(pos, f"string@{pos} 长度")
        return self._read(pos + 4, length, f"string@{pos} 内容")

    def string(self, off: int) -> str:
        """字段绝对偏移（uoffset 起点）-> 字符串（UTF-8 解码）。

        解码失败抛 UnicodeDecodeError（ValueError 子类，符合越界约定）。
        """
        return self.string_bytes(off).decode("utf-8")

    def vector_len(self, off: int) -> int:
        """vector 字段绝对偏移（uoffset 起点）-> 元素个数。"""
        pos = self._uoffset_target(off, f"vector 字段@{off}")
        return self._u32(pos, f"vector@{pos} 长度")

    def vector_elem(self, vec_off: int, index: int, elem_size: int,
                    alignment: int = 4) -> int:
        """vector 元素绝对偏移。vec_off 为 vector 字段绝对偏移（uoffset 起点）。

        elem_size 为元素字节大小（uoffset 元素为 4）；alignment 保留供未来
        非 4 字节元素使用（当前布局元素紧邻 u32 len 之后排列）。
        """
        if elem_size <= 0:
            raise ValueError(f"elem_size 必须 > 0，实际 {elem_size}")
        if index < 0:
            raise ValueError(f"vector 索引必须 >= 0，实际 {index}")
        pos = self._uoffset_target(vec_off, f"vector 字段@{vec_off}")
        length = self._u32(pos, f"vector@{pos} 长度")
        if index >= length:
            raise ValueError(f"vector@{pos} 索引越界: {index} >= 长度 {length}")
        elem_pos = pos + 4 + index * elem_size
        self._read(elem_pos, elem_size, f"vector@{pos} 元素{index}")
        return elem_pos
