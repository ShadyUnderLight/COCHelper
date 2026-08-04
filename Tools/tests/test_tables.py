import pytest

from game_catalog.errors import CatalogError
from game_catalog.tables import (
    TableSpec,
    TABLES,
    is_doc_row,
    group_blocks,
    ffill_columns,
    section_for,
    spec_for_table,
)


def make_rows(*rows: tuple[str, ...], names: tuple[str, ...] | None = None) -> list[dict[str, str]]:
    cols = ("Name", "Level", "Time", "Cost")
    out = []
    for r in rows:
        out.append(dict(zip(cols, r)))
    return out


def test_is_doc_row():
    assert is_doc_row({"Name": "String", "Level": "int"})
    assert not is_doc_row({"Name": "Town Hall", "Level": "int"})


def test_group_blocks_splits_by_name_and_skips_doc():
    rows = make_rows(
        ("String", "int", "int", "int"),
        ("A", "1", "", ""),
        ("", "2", "10", ""),
        ("B", "1", "20", ""),
        ("", "2", "", ""),
    )
    blocks = group_blocks(rows)
    assert [b.name for b in blocks] == ["A", "B"]
    assert [len(b.rows) for b in blocks] == [2, 2]


def test_group_blocks_orphan_row_before_any_block_raises():
    # doc 行之后、第一个块之前的数据行 → 孤儿行，fail loud
    rows = make_rows(
        ("String", "int", "int", "int"),
        ("", "2", "10", ""),
    )
    with pytest.raises(CatalogError):
        group_blocks(rows)


def test_ffill_columns_does_not_mutate_input():
    block_rows = [
        {"Name": "A", "Time": "10", "Cost": ""},
        {"Name": "", "Time": "", "Cost": "5"},
    ]
    snapshot = [dict(r) for r in block_rows]
    ffill_columns(block_rows, ("Time", "Cost"))
    assert block_rows == snapshot
    # 传同一列表两次：第二次输入仍是原始状态（纯函数）
    ffill_columns(block_rows, ("Time", "Cost"))
    assert block_rows == snapshot


def test_ffill_columns_forward_fills_within_block_only():
    block_rows = [
        {"Name": "A", "Time": "10", "Cost": ""},
        {"Name": "", "Time": "", "Cost": "5"},
        {"Name": "", "Time": "30", "Cost": ""},
    ]
    filled = ffill_columns(block_rows, ("Time", "Cost"))
    assert filled[0] == {"Name": "A", "Time": "10", "Cost": ""}
    assert filled[1] == {"Name": "", "Time": "10", "Cost": "5"}
    assert filled[2] == {"Name": "", "Time": "30", "Cost": "5"}


def test_ffill_preserves_zero():
    block_rows = [
        {"Name": "A", "Time": "0"},
        {"Name": "", "Time": ""},
    ]
    filled = ffill_columns(block_rows, ("Time",))
    assert filled[1]["Time"] == "0"


def test_ffill_does_not_fill_non_whitelisted_columns():
    block_rows = [
        {"Name": "A", "Time": "10", "Level": "1"},
        {"Name": "", "Time": "", "Level": "2"},
    ]
    filled = ffill_columns(block_rows, ("Time",))
    assert filled[1]["Time"] == "10"
    assert filled[1]["Level"] == "2"  # 等级列不参与继承（自身带值）


def test_section_for():
    assert section_for("") == "home"
    assert section_for("0") == "home"
    assert section_for("1") == "builder"
    with pytest.raises(CatalogError):
        section_for("2")


def test_tables_registry_has_expected_sections():
    sections = {s.section for s in TABLES}
    assert sections == {
        "buildings", "traps", "units", "spells", "heroes", "pets",
        "equipment", "guardians", "capital_buildings", "capital_traps",
        "capital_characters", "capital_spells",
    }


def test_spec_for_table():
    assert spec_for_table("buildings.csv").table == "buildings.csv"
    with pytest.raises(CatalogError):
        spec_for_table("nope.csv")


def test_every_table_fill_excludes_time_columns():
    # I4 不变式（修正后）：时间列绝不进 fill_columns——空时间 cell 语义是 0，
    # 不做 forward-fill 继承（行 2 UpM='' = 0 分钟，不是继承行 1 的 30 分钟）。
    for spec in TABLES:
        for col in spec.time_columns:
            assert col not in spec.fill_columns, spec.table


def test_to_next_level_tables_declared():
    # I4 不变式：单位/法术/英雄/宠物/首都单位法术/守卫 = 行 N = "N→N+1" 升级
    to_next = {s.table for s in TABLES if s.upgrade_semantics == "to_next_level"}
    assert to_next == {
        "characters.csv", "spells.csv", "heroes.csv", "pets.csv",
        "guardians.csv", "capital_characters.csv", "capital_spells.csv",
    }
    to_level = {s.table for s in TABLES if s.upgrade_semantics == "to_level"}
    assert to_level == {
        "buildings.csv", "traps.csv", "character_items.csv",
        "capital_buildings.csv", "capital_traps.csv",
    }
