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


def test_every_table_fill_includes_its_time_columns():
    # I4 不变式：时间列自动并入 fill_columns，防止未来维护漂移
    for spec in TABLES:
        if spec.time_columns:
            assert set(spec.time_columns) <= set(spec.fill_columns), spec.table
