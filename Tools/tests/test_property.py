"""hypothesis property-based：forward-fill 与时间解析不变量。

注意 group_blocks 语义：非空 Name 行切块，空 Name 行并入当前块，且首个非空
Name 之前的行会抛 CatalogError（孤儿行）。因此策略中**每块首行 Name 必须非空**
（计划 BLOCK_STRATEGY 原稿允许首行为 ""，会与前块合并/触发孤儿行，本文件已修正）。
"""

from hypothesis import given, strategies as st

from game_catalog.builders import parse_upgrade_costs
from game_catalog.tables import group_blocks, ffill_columns
from game_catalog.durations import parse_duration

_NAME_FIRST = st.sampled_from(["A", "B"])   # 块首行 Name：必须非空
_NAME_REST = st.sampled_from(["", "A", "B"])
_TIME = st.one_of(st.just(""), st.just("10"), st.just("0"), st.just("5"))


@st.composite
def _block(draw):
    """单个策略块：首行 Name 非空 + 0..7 行后续行（Name 可空）。"""
    first = draw(st.tuples(_NAME_FIRST, _TIME))
    rest = draw(st.lists(st.tuples(_NAME_REST, _TIME), min_size=0, max_size=7))
    return [first] + rest


BLOCK_STRATEGY = st.lists(_block(), min_size=1, max_size=5)


def _rows(blocks: list[list[tuple[str, str]]]) -> list[dict[str, str]]:
    return [{"Name": name, "Time": time} for block in blocks for name, time in block]


@given(BLOCK_STRATEGY)
def test_ffill_output_rows_equals_input_rows(blocks):
    rows = _rows(blocks)
    grouped = group_blocks(rows)
    total_filled = 0
    for g in grouped:
        filled = ffill_columns(g.rows, ("Time",))
        assert len(filled) == len(g.rows)
        total_filled += len(filled)
    assert total_filled == len(rows)


@given(BLOCK_STRATEGY)
def test_ffill_non_empty_values_never_change(blocks):
    for block in blocks:
        rows = [{"Name": n, "Time": t} for n, t in block]
        filled = ffill_columns(rows, ("Time",))
        for orig, new in zip(rows, filled):
            if orig["Time"] != "":
                assert new["Time"] == orig["Time"]


@given(BLOCK_STRATEGY)
def test_ffill_inherited_value_is_last_non_empty_in_block(blocks):
    for block in blocks:
        rows = [{"Name": n, "Time": t} for n, t in block]
        filled = ffill_columns(rows, ("Time",))
        carry = ""
        for row in filled:
            if row["Time"] != "":
                carry = row["Time"]
            else:
                assert row["Time"] == carry  # 空即继承（或 carry 为空时仍空）


# parse_duration 只接受 D/H/M/S 或 *Days/Hours/Minutes/Seconds 后缀列名（其他列名视为
# 配置错误抛 CatalogError，见 test_durations.py），故此处生成真实列名而非 C0/C1。
_UNIT_COLS = st.sampled_from(["D", "H", "M", "S", "Days", "Hours", "Minutes", "Seconds"])


@given(st.lists(
    st.tuples(_UNIT_COLS, st.sampled_from(["", "0", "12", "3600"])),
    min_size=1, max_size=4,
))
def test_parse_duration_non_negative_and_consistent(parts):
    cells = dict(parts)
    columns = tuple(cells)
    seconds, reason = parse_duration(cells, columns)
    if reason is not None:
        assert seconds is None
        assert reason in ("time_missing", "time_invalid")
    else:
        assert seconds is not None and seconds >= 0


@given(st.integers(min_value=0, max_value=10**9))
def test_parse_duration_single_field_roundtrip(total):
    cells = {"H": str(total), "M": ""}
    seconds, reason = parse_duration(cells, ("H", "M"))
    assert seconds == total * 3600


# ---- parse_upgrade_costs 不变量（Issue #73 Task 1）----
# 生成策略覆盖：空串、非数字金额、数量不匹配、前后空格、空段。

_SEG_EMPTY = st.just("")
_SEG_RES = st.text(alphabet="ab AB", min_size=1, max_size=4)     # 资源段（含空格）
_SEG_NUM = st.text(alphabet="0123456789", min_size=1, max_size=5)
_SEG_BAD = st.sampled_from(["x", "12a", " 3"])                    # 非数字金额


@st.composite
def _semicolon_pair(draw):
    res_segs = draw(st.lists(
        st.one_of(_SEG_EMPTY, _SEG_RES), min_size=0, max_size=5))
    cost_segs = draw(st.lists(
        st.one_of(_SEG_EMPTY, _SEG_NUM, _SEG_BAD), min_size=0, max_size=5))
    return ";".join(res_segs), ";".join(cost_segs)


@given(_semicolon_pair())
def test_parse_upgrade_costs_holds_invariants(pair):
    resources_raw, costs_raw = pair
    result = parse_upgrade_costs(resources_raw, costs_raw, ";")
    if result is None:
        return  # 不变量 1：无费用数据
    assert result  # 不变量 2：非 None 必须非空
    for uc in result:
        assert uc.rawResource and uc.resource  # 不变量 5/6：恒非空
        if uc.parseFailed:                    # 不变量 4
            assert uc.amount is None
            assert uc.rawAmount is not None
        else:                                 # 不变量 3
            assert uc.amount is not None and uc.amount >= 0
            assert uc.rawAmount is None
