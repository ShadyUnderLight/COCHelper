"""Issue #75 工作流 C：displayCategory 数据化。

覆盖：apply_display_categories 分类映射、validate 四类校验、
兜底登记表穷尽性（bundled catalog 实证 73 = 33 分类 + 40 兜底）。
"""

import json
from pathlib import Path

from game_catalog.display_categories import (
    CRAFT_TABLE_DATA_ID,
    DEFENSE_DATA_IDS,
    INTENTIONAL_FALLBACK_DATA_IDS,
    MILITARY_DATA_IDS,
    WALL_DATA_IDS,
    apply_display_categories,
    uncategorized_home_buildings,
)
from game_catalog.model import (
    Catalog, CatalogItem, CatalogLevel, catalog_from_dict, catalog_to_dict,
)
from game_catalog.validate import validate_catalog

_REPO_ROOT = Path(__file__).resolve().parents[2]
BUNDLED_CATALOG = _REPO_ROOT / "Sources/COCHelperCore/GameCatalog/18.400.13/catalog.json"


def _item(data_id=1000008, name="x", section="buildings", base="home", dc=None):
    return CatalogItem(
        section=section, dataID=data_id, category="buildings", base=base,
        baseMissingReason=None, name=name, maxLevel=1,
        icon=None, levelVisual=None, missingReason=None,
        levels=[CatalogLevel(
            level=1, durationSeconds=0, missingReason=None,
            upgradeCosts=None, requiredTownHallLevel=None,
            requiredLaboratoryLevel=None, icon=None, levelVisual=None)],
        displayCategory=dc,
        # Issue #98：构造用 dataID 均在真实声明文件中（permanent）
        lifecycle="permanent",
    )


# ---- apply_display_categories：分类映射 ----

def test_apply_defense():
    assert apply_display_categories([_item(1000008)])[0].displayCategory == "defense"


def test_apply_military():
    assert apply_display_categories([_item(1000000)])[0].displayCategory == "military"


def test_apply_craft_table():
    assert apply_display_categories([_item(1000097)])[0].displayCategory == "craftTable"


def test_apply_walls():
    # Issue #123：主村城墙 1000010 归入 walls 分类
    assert apply_display_categories([_item(1000010)])[0].displayCategory == "walls"


def test_wall_not_in_defense_registry():
    # Issue #123：城墙从 defense 移入 walls（防御集合不含 1000010）
    assert 1000010 not in DEFENSE_DATA_IDS


def test_apply_walls_non_home_always_none():
    # buildings2 同 dataID（夜世界城墙）→ None（walls 不越界）
    assert apply_display_categories([_item(1000010, section="buildings2")])[0].displayCategory is None


def test_apply_uncategorized_home_none():
    assert apply_display_categories([_item(1000002)])[0].displayCategory is None


def test_apply_non_home_building_always_none():
    # buildings2 同 dataID（BB 加农炮）→ None
    assert apply_display_categories([_item(1000008, section="buildings2")])[0].displayCategory is None
    # buildings 但 base 非 home（防御性）→ None
    assert apply_display_categories([_item(1000008, base="builder")])[0].displayCategory is None


def test_apply_returns_new_list_does_not_mutate_input():
    items = [_item(1000008)]
    out = apply_display_categories(items)
    assert items[0].displayCategory is None
    assert out[0].displayCategory == "defense"


def test_uncategorized_home_buildings_reports_ids_and_names():
    items = [_item(1000008, name="加农炮"), _item(1000002, name="圣水收集器"),
             _item(1000009, name="迫击炮")]
    out = apply_display_categories(items)
    assert uncategorized_home_buildings(out) == [(1000002, "圣水收集器")]


# ---- 兜底登记表穷尽（bundled catalog 实证） ----

def test_fallback_registry_matches_bundled_catalog():
    """bundled catalog 73 home buildings：33 分类 + 40 兜底 == 登记表（精确一致）。"""
    data = json.loads(BUNDLED_CATALOG.read_text(encoding="utf-8"))
    items = catalog_from_dict(data).items
    home = [i for i in items if i.section == "buildings" and i.base == "home"]
    assert len(home) == 73
    out = apply_display_categories(home)
    uncat = {i.dataID for i in out if i.displayCategory is None}
    cat = {i.dataID for i in out if i.displayCategory is not None}
    assert uncat == INTENTIONAL_FALLBACK_DATA_IDS
    assert len(uncat) == 40
    assert len(cat) == 33
    assert cat == DEFENSE_DATA_IDS | WALL_DATA_IDS | MILITARY_DATA_IDS | {CRAFT_TABLE_DATA_ID}


def test_fallback_registry_contains_th17_buildings():
    """TH17 新建筑在兜底登记表（现状契约：维持兜底，是否分类待裁决）。"""
    for did in (1000093, 1000098, 1000099, 1000100):
        assert did in INTENTIONAL_FALLBACK_DATA_IDS


def test_fallback_registry_disjoint_from_classified():
    assert (DEFENSE_DATA_IDS | WALL_DATA_IDS | MILITARY_DATA_IDS | {CRAFT_TABLE_DATA_ID}) \
        .isdisjoint(INTENTIONAL_FALLBACK_DATA_IDS)


# ---- validate：闭枚举 / 域 / 未分类 fail-loud / 1000097 ----


def _write_dir(tmp_path, items):
    d = tmp_path / "cat"
    d.mkdir()
    catalog = Catalog(schemaVersion=3, gameVersion="18.400.13", locale="zh-CN",
                      items=items)
    catalog_bytes = json.dumps(catalog_to_dict(catalog),
                               ensure_ascii=False).encode("utf-8")
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


def test_validate_display_category_ok(tmp_path):
    items = [_item(1000008, dc="defense"), _item(1000002, dc=None),
             _item(1000097, dc="craftTable")]
    assert validate_catalog(_write_dir(tmp_path, items)) == []


def test_validate_display_category_unknown_value(tmp_path):
    d = _write_dir(tmp_path, [_item(1000008, dc="weird")])
    errors = validate_catalog(d)
    assert any("displayCategory" in e and "weird" in e for e in errors)


def test_validate_display_category_on_non_home_building(tmp_path):
    d = _write_dir(tmp_path, [_item(1000008, section="buildings2", dc="defense")])
    errors = validate_catalog(d)
    assert any("buildings2" in e and "displayCategory" in e for e in errors)


def test_validate_uncategorized_new_building_fails_loud(tmp_path):
    """home buildings 未分类且不在兜底登记表 → error（新版本新增建筑必须裁决）。"""
    d = _write_dir(tmp_path, [_item(data_id=999999, dc=None)])
    errors = validate_catalog(d)
    assert any("新增建筑未分类" in e and "999999" in e for e in errors)
    # P1-B（评审修复）：错误消息自解释——旧产物（无 displayCategory 字段）如何补救
    assert any("annotate_display_categories.py" in e for e in errors)


def test_validate_craft_table_data_id_must_be_crafttable(tmp_path):
    d = _write_dir(tmp_path, [_item(1000097, dc=None)])
    errors = validate_catalog(d)
    assert any("1000097" in e and "craftTable" in e for e in errors)


# ---- 错标分类（评审补强：全量重算比对）----

def test_validate_mislabeled_defense_rejected(tmp_path):
    """登记表内 ID 错标分类 → error（1000008 注册表 defense，实际 military）。"""
    d = _write_dir(tmp_path, [_item(1000008, dc="military")])
    errors = validate_catalog(d)
    assert any("displayCategory 与注册表不一致" in e and "1000008" in e for e in errors)


def test_validate_fallback_item_labeled_classified_rejected(tmp_path):
    """兜底登记表内 ID 被标分类 → error（1000002 注册表 None，实际 defense）。"""
    d = _write_dir(tmp_path, [_item(1000002, dc="defense")])
    errors = validate_catalog(d)
    assert any("displayCategory 与注册表不一致" in e and "1000002" in e for e in errors)


def test_validate_mislabeled_craft_table_rejected(tmp_path):
    """防御建筑错标 craftTable → error（1000008 注册表 defense，实际 craftTable）。"""
    d = _write_dir(tmp_path, [_item(1000008, dc="craftTable")])
    errors = validate_catalog(d)
    assert any("displayCategory 与注册表不一致" in e and "1000008" in e for e in errors)
