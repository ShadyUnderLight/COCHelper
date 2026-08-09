import json

import pytest

from game_catalog.model import (
    AssetRef, CatalogLevel, CatalogItem, Catalog, UpgradeCost,
    item_to_dict, catalog_to_dict, catalog_from_dict,
)


def _sample_item() -> CatalogItem:
    return CatalogItem(
        section="units", dataID=4_000_000, category="troops", base="home",
        baseMissingReason=None, name="野蛮人", maxLevel=13,
        icon=AssetRef(container="sc/ui.sc", exportName="icon_unit_barbarian",
                      renderedPath=None, missingReason="icons_not_rendered"),
        levelVisual=None, missingReason=None,
        levels=[CatalogLevel(
            level=13, durationSeconds=1_081_800, missingReason=None,
            upgradeCosts=[UpgradeCost(
                resource="Elixir", amount=24_000_000, rawResource="Elixir",
                rawAmount=None, parseFailed=False)],
            requiredTownHallLevel=None, requiredLaboratoryLevel=16,
            icon=None, levelVisual=None,
        )],
    )


def test_assetref_dict_roundtrip():
    ref = AssetRef("sc/ui.sc", "icon_unit_barbarian", None, "icons_not_rendered")
    assert AssetRef.from_dict(ref.to_dict()) == ref


def test_item_dict_has_all_keys_even_null():
    d = item_to_dict(_sample_item())
    assert d["baseMissingReason"] is None
    assert d["levelVisual"] is None
    assert d["levels"][0]["requiredTownHallLevel"] is None
    assert d["levels"][0]["upgradeCosts"][0]["rawAmount"] is None


def test_catalog_roundtrip_through_json():
    cat = Catalog(schemaVersion=1, gameVersion="18.400.13", locale="zh-CN", items=[_sample_item()])
    d = catalog_to_dict(cat)
    text = json.dumps(d, ensure_ascii=False)
    back = catalog_from_dict(json.loads(text))
    assert back == cat


def test_catalog_dict_deterministic_key_order():
    cat = Catalog(schemaVersion=1, gameVersion="18.400.13", locale="zh-CN", items=[_sample_item()])
    d1 = json.dumps(catalog_to_dict(cat), ensure_ascii=False, sort_keys=True)
    d2 = json.dumps(catalog_to_dict(cat), ensure_ascii=False, sort_keys=True)
    assert d1 == d2


# ---- UpgradeCost / upgradeCosts（Issue #73 Task 1）----


def test_upgrade_cost_dict_roundtrip():
    for uc in (
        UpgradeCost("Elixir", 100, "Elixir", None, False),
        UpgradeCost("RareOre", None, "RareOre", "abc", True),
        UpgradeCost("RareOre", None, "RareOre", "", True),
    ):
        assert UpgradeCost.from_dict(uc.to_dict()) == uc


def test_upgrade_cost_dict_has_all_keys_even_null():
    d = UpgradeCost("Elixir", 100, "Elixir", None, False).to_dict()
    assert set(d) == {"resource", "amount", "rawResource", "rawAmount", "parseFailed"}
    assert d["rawAmount"] is None
    assert d["amount"] == 100


def test_upgrade_cost_from_dict_bad_type_raises():
    with pytest.raises(ValueError):
        UpgradeCost.from_dict("x")


def test_catalog_level_roundtrip_with_upgrade_costs():
    lv = CatalogLevel(
        level=1, durationSeconds=None, missingReason="time_missing",
        upgradeCosts=[UpgradeCost("RareOre", None, "RareOre", "oops", True)],
        requiredTownHallLevel=None, requiredLaboratoryLevel=None,
        icon=None, levelVisual=None,
    )
    assert CatalogLevel.from_dict(lv.to_dict()) == lv


def test_catalog_level_to_dict_empty_upgrade_costs_normalized_to_none():
    """契约「非 None 必须非空（[] 非法）」：upgradeCosts=[] → 序列化为 None。

    与 from_dict 的 None 语义对称：空列表不会进入 JSON。
    """
    lv = CatalogLevel(
        level=1, durationSeconds=None, missingReason="time_missing",
        upgradeCosts=[], requiredTownHallLevel=None, requiredLaboratoryLevel=None,
        icon=None, levelVisual=None,
    )
    assert lv.to_dict()["upgradeCosts"] is None


def test_catalog_level_from_dict_legacy_without_upgrade_costs():
    """旧格式 JSON（无 upgradeCosts 键，upgradeResource/upgradeCost）→ None。"""
    d = {"level": 1, "durationSeconds": 0, "missingReason": None,
         "upgradeResource": "Elixir", "upgradeCost": 100,
         "requiredTownHallLevel": None, "requiredLaboratoryLevel": None,
         "icon": None, "levelVisual": None}
    lv = CatalogLevel.from_dict(d)
    assert lv.upgradeCosts is None
    out = lv.to_dict()
    assert "upgradeCosts" in out and out["upgradeCosts"] is None
    assert "upgradeResource" not in out and "upgradeCost" not in out


# ---- Issue #75 工作流 C：displayCategory ----

def test_catalog_item_display_category_roundtrip():
    item = _sample_item()
    item.displayCategory = "defense"
    d = item_to_dict(item)
    assert d["displayCategory"] == "defense"
    assert CatalogItem.from_dict(d) == item


def test_catalog_item_to_dict_writes_display_category_null():
    d = item_to_dict(_sample_item())
    assert d["displayCategory"] is None


def test_catalog_item_from_dict_missing_display_category_defaults_none():
    """旧格式 JSON（无 displayCategory 键）→ None，不抛错。"""
    d = item_to_dict(_sample_item())
    del d["displayCategory"]
    assert CatalogItem.from_dict(d).displayCategory is None
