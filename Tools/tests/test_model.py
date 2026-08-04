import json

from game_catalog.model import (
    AssetRef, CatalogLevel, CatalogItem, Catalog,
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
            upgradeResource="Elixir", upgradeCost=24_000_000,
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
