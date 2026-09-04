"""annotate_display_categories 标注脚本（Issue #75 工作流 C 主路径）。

仓库无 APK → 在既有 catalog.json 上标注（幂等，只写 catalog.json；
E0-03/Issue #303 起不再触碰 manifest.json）。
"""

import json

import pytest

from annotate_display_categories import annotate_directory
from game_catalog.errors import CatalogError
from game_catalog.model import Catalog, CatalogItem, CatalogLevel, catalog_to_dict


def _item(data_id, name="x", section="buildings", base="home"):
    return CatalogItem(
        section=section, dataID=data_id, category="buildings", base=base,
        baseMissingReason=None, name=name, maxLevel=1,
        icon=None, levelVisual=None, missingReason=None,
        levels=[CatalogLevel(
            level=1, durationSeconds=0, missingReason=None,
            upgradeCosts=None, requiredTownHallLevel=None,
            requiredLaboratoryLevel=None, icon=None, levelVisual=None)],
        # Issue #98：构造用 dataID 均在真实声明文件中（permanent）
        lifecycle="permanent",
    )


def _make_dir(tmp_path):
    d = tmp_path / "cat"
    d.mkdir()
    items = [_item(1000008, "加农炮"), _item(1000010, "城墙"), _item(1000097, "精制台"),
             _item(1000002, "圣水收集器")]
    catalog = Catalog(schemaVersion=3, gameVersion="18.400.13", locale="zh-CN",
                      items=items)
    catalog_bytes = json.dumps(catalog_to_dict(catalog), ensure_ascii=False,
                               indent=2, sort_keys=True).encode("utf-8") + b"\n"
    (d / "catalog.json").write_bytes(catalog_bytes)
    (d / "icons").mkdir()
    # Issue #98 复审 P1：validator 强制 craft 条目存在——fixture 目录必须配套
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","buildTag":"18_400_7","locale":"zh-CN","source":"t","defenses":[],"modules":[]}\n'
    (d / "craft_table_catalog.json").write_bytes(craft_bytes)
    (d / "manifest.json").write_text(json.dumps({
        "schemaVersion": 3, "gameVersion": "18.400.13", "buildTag": "18_400_7",
        "locale": "zh-CN",
    }))
    return d


def test_annotate_sets_display_category_fields(tmp_path):
    d = _make_dir(tmp_path)
    annotate_directory(d)
    data = json.loads((d / "catalog.json").read_text())
    by_id = {i["dataID"]: i for i in data["items"]}
    assert by_id[1000008]["displayCategory"] == "defense"
    assert by_id[1000010]["displayCategory"] == "walls"  # Issue #123：城墙归 walls
    assert by_id[1000097]["displayCategory"] == "craftTable"
    assert by_id[1000002]["displayCategory"] is None


def test_annotate_does_not_touch_manifest(tmp_path):
    """E0-03：标注只写 catalog.json，manifest.json 字节不变。"""
    d = _make_dir(tmp_path)
    man_before = (d / "manifest.json").read_bytes()
    annotate_directory(d)
    assert (d / "manifest.json").read_bytes() == man_before


def test_annotate_reports_distribution(tmp_path):
    d = _make_dir(tmp_path)
    result = annotate_directory(d)
    assert result["distribution"] == {"defense": 1, "military": 0, "craftTable": 1}


def test_annotate_preserves_instance_counts(tmp_path):
    d = _make_dir(tmp_path)
    data = json.loads((d / "catalog.json").read_text())
    data["instanceCounts"] = {"buildings:1000001": [0] * 18}
    (d / "catalog.json").write_text(
        json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    annotate_directory(d)
    out = json.loads((d / "catalog.json").read_text())
    assert out["instanceCounts"] == {"buildings:1000001": [0] * 18}


def test_annotate_idempotent(tmp_path):
    d = _make_dir(tmp_path)
    annotate_directory(d)
    cat1 = (d / "catalog.json").read_bytes()
    man1 = (d / "manifest.json").read_bytes()
    annotate_directory(d)
    assert (d / "catalog.json").read_bytes() == cat1
    assert (d / "manifest.json").read_bytes() == man1


def test_annotate_result_passes_validate(tmp_path):
    from game_catalog.validate import validate_catalog
    d = _make_dir(tmp_path)
    annotate_directory(d)
    assert validate_catalog(d) == []


# ---- P1-A（评审修复）：未登记新建筑 fail-closed，写回前中止且不落盘 ----

def test_annotate_fails_closed_on_unregistered_new_building(tmp_path):
    """目录含未登记新建筑（不在兜底登记表）→ 抛错，catalog.json/manifest.json 零改动。"""
    d = _make_dir(tmp_path)
    data = json.loads((d / "catalog.json").read_text())
    data["items"].append({
        "section": "buildings", "dataID": 999999, "category": "buildings",
        "base": "home", "baseMissingReason": None, "name": "新建筑", "maxLevel": 1,
        "icon": None, "levelVisual": None, "missingReason": None,
        "levels": [{"level": 1, "durationSeconds": 0, "missingReason": None,
                    "upgradeCosts": None, "requiredTownHallLevel": None,
                    "requiredLaboratoryLevel": None, "icon": None,
                    "levelVisual": None, "requiredHeroTavernLevel": None}],
    })
    (d / "catalog.json").write_text(
        json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    cat_before = (d / "catalog.json").read_bytes()
    man_before = (d / "manifest.json").read_bytes()
    with pytest.raises(CatalogError, match="999999"):
        annotate_directory(d)
    assert (d / "catalog.json").read_bytes() == cat_before
    assert (d / "manifest.json").read_bytes() == man_before


def test_annotate_fail_closed_error_limits_listing_and_counts(tmp_path):
    """错误消息列未登记项（最多 10 个）+ 总数。"""
    d = _make_dir(tmp_path)
    data = json.loads((d / "catalog.json").read_text())
    for i in range(12):
        data["items"].append({
            "section": "buildings", "dataID": 900000 + i, "category": "buildings",
            "base": "home", "baseMissingReason": None, "name": f"新建筑{i}",
            "maxLevel": 1, "icon": None, "levelVisual": None, "missingReason": None,
            "levels": [{"level": 1}],
        })
    (d / "catalog.json").write_text(
        json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    with pytest.raises(CatalogError) as excinfo:
        annotate_directory(d)
    msg = str(excinfo.value)
    assert "12 个未登记" in msg
    assert msg.count("新建筑") == 10  # 最多列 10 个
    # 文件未被写
    assert len((d / "catalog.json").read_text()) > 0


def test_annotate_ok_with_registered_fallback_buildings(tmp_path):
    """对照：兜底登记表内的未分类项（1000001 大本营）不触发 fail-closed。"""
    d = _make_dir(tmp_path)
    data = json.loads((d / "catalog.json").read_text())
    data["items"].append({
        "section": "buildings", "dataID": 1000001, "category": "buildings",
        "base": "home", "baseMissingReason": None, "name": "大本营", "maxLevel": 1,
        "icon": None, "levelVisual": None, "missingReason": None,
        "levels": [{"level": 1}],
    })
    (d / "catalog.json").write_text(
        json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    annotate_directory(d)  # 不抛错
    out = json.loads((d / "catalog.json").read_text())
    assert next(i for i in out["items"] if i["dataID"] == 1000001)["displayCategory"] is None
