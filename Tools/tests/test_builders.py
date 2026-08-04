import pytest

from game_catalog.builders import build_items
from game_catalog.errors import CatalogError
from game_catalog.tables import spec_for_table


def _buildings_rows():
    # doc 行 + Town Hall 两级
    return [
        {"Name": "String", "GlobalID": "int", "BuildingLevel": "int", "TID": "String",
         "SWF": "String", "ExportName": "String", "BuildTimeD": "int", "BuildTimeH": "int",
         "BuildTimeM": "int", "BuildTimeS": "int", "BuildResource": "String",
         "BuildCost": "int", "TownHallLevel": "int", "VillageType": "String"},
        {"Name": "Town Hall", "GlobalID": "1000001", "BuildingLevel": "1", "TID": "TID_TH",
         "SWF": "sc/buildings.sc", "ExportName": "town_hall_lvl1",
         "BuildTimeD": "0", "BuildTimeH": "0", "BuildTimeM": "0", "BuildTimeS": "0",
         "BuildResource": "Gold", "BuildCost": "0", "TownHallLevel": "0", "VillageType": ""},
        {"Name": "", "GlobalID": "", "BuildingLevel": "2", "TID": "",
         "SWF": "", "ExportName": "town_hall_lvl2",
         "BuildTimeD": "1", "BuildTimeH": "0", "BuildTimeM": "0", "BuildTimeS": "0",
         "BuildResource": "", "BuildCost": "1000000", "TownHallLevel": "1", "VillageType": ""},
    ]


def test_buildings_item_section_and_levels():
    items = build_items(_buildings_rows(), spec_for_table("buildings.csv"), {})
    assert len(items) == 1
    item = items[0]
    assert item.section == "buildings"
    assert item.base == "home"
    assert item.dataID == 1000001
    assert item.maxLevel == 2
    assert [lv.level for lv in item.levels] == [1, 2]
    assert item.levels[0].durationSeconds == 0          # 0 是真实值
    assert item.levels[1].durationSeconds == 86400      # 1 天
    assert item.levels[1].upgradeCost == 1000000
    assert item.levels[1].requiredTownHallLevel == 1
    assert item.levelVisual is not None
    assert item.levelVisual.exportName == "town_hall_lvl1"   # 首行继承
    assert item.levels[1].levelVisual is not None
    assert item.levels[1].levelVisual.exportName == "town_hall_lvl2"


def test_characters_siege_split():
    rows = [
        {"Name": "String", "GlobalID": "int", "VisualLevel": "int", "TID": "String",
         "IconSWF": "String", "IconExportName": "String", "ProductionBuilding": "String",
         "UpgradeTimeH": "int", "UpgradeTimeM": "int", "LaboratoryLevel": "int",
         "UpgradeResource": "String", "UpgradeCost": "int", "VillageType": "String"},
        {"Name": "Barbarian", "GlobalID": "4000000", "VisualLevel": "1", "TID": "TID_B",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_unit_barbarian", "ProductionBuilding": "",
         "UpgradeTimeH": "0", "UpgradeTimeM": "30", "LaboratoryLevel": "1",
         "UpgradeResource": "Elixir", "UpgradeCost": "10000", "VillageType": ""},
        {"Name": "Wall Wrecker", "GlobalID": "4000050", "VisualLevel": "1", "TID": "TID_WW",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_unit_wall_wrecker", "ProductionBuilding": "Siege Workshop",
         "UpgradeTimeH": "48", "UpgradeTimeM": "", "LaboratoryLevel": "1",
         "UpgradeResource": "Gold", "UpgradeCost": "3000000", "VillageType": ""},
    ]
    items = build_items(rows, spec_for_table("characters.csv"), {})
    by_name = {i.name: i for i in items}
    assert by_name["Barbarian"].section == "units"
    assert by_name["Barbarian"].category == "troops"
    assert by_name["Wall Wrecker"].section == "siege_machines"
    assert by_name["Wall Wrecker"].category == "siegeMachines"


def test_no_global_id_table_uses_id_base():
    rows = [
        {"Name": "String", "VisualLevel": "int", "TID": "String",
         "UpgradeTimeH": "int", "VillageType": "String"},
        {"Name": "Barbarian King", "VisualLevel": "1", "TID": "TID_BK",
         "UpgradeTimeH": "0", "VillageType": ""},
    ]
    items = build_items(rows, spec_for_table("heroes.csv"), {})
    assert items[0].dataID == 28_000_000


def _character_items_rows():
    return [
        {"Name": "String", "Level": "int", "TID": "String",
         "IconSWF": "String", "IconExportName": "String",
         "UpgradeResources": "String", "UpgradeCosts": "int"},
        {"Name": "Eternal Tome", "Level": "1", "TID": "TID_ET",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_equip_tome",
         "UpgradeResources": "CommonOre", "UpgradeCosts": "120"},
        {"Name": "", "Level": "2", "TID": "", "IconSWF": "", "IconExportName": "",
         "UpgradeResources": "", "UpgradeCosts": "500"},
    ]


def test_equipment_no_time_source():
    items = build_items(_character_items_rows(), spec_for_table("character_items.csv"), {})
    assert len(items) == 1
    item = items[0]
    assert [lv.level for lv in item.levels] == [1, 2]
    assert item.dataID == 90_000_000
    for lv in item.levels:
        assert lv.durationSeconds is None
        assert lv.missingReason == "no_time_source"
    assert item.levels[0].upgradeResource == "CommonOre"
    assert item.levels[0].upgradeCost == 120
    assert item.levels[1].upgradeCost == 500


def _pets_rows():
    return [
        {"Name": "String", "TroopLevel": "int", "TID": "String",
         "IconSWF": "String", "IconExportName": "String", "Deprecated": "bool",
         "UpgradeTimeH": "int", "UpgradeTimeM": "int", "LaboratoryLevel": "int",
         "UpgradeResource": "String", "UpgradeCost": "int", "VillageType": "String"},
        {"Name": "Stork", "TroopLevel": "1", "TID": "TID_ST",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_pet_stork", "Deprecated": "TRUE",
         "UpgradeTimeH": "12", "UpgradeTimeM": "0", "LaboratoryLevel": "10",
         "UpgradeResource": "Gold", "UpgradeCost": "100000", "VillageType": ""},
        {"Name": "", "TroopLevel": "2", "TID": "", "IconSWF": "", "IconExportName": "",
         "Deprecated": "", "UpgradeTimeH": "", "UpgradeTimeM": "30", "LaboratoryLevel": "",
         "UpgradeResource": "", "UpgradeCost": "200000", "VillageType": ""},
    ]


def test_pets_deprecated():
    items = build_items(_pets_rows(), spec_for_table("pets.csv"), {})
    assert len(items) == 1
    item = items[0]
    assert item.missingReason == "deprecated_in_source"
    assert item.dataID == 73_000_000
    assert [lv.level for lv in item.levels] == [1, 2]


def test_build_items_error_paths():
    # GlobalID 非数字 → CatalogError（而非裸 ValueError）
    rows = _buildings_rows()
    rows[1]["GlobalID"] = "abc"
    with pytest.raises(CatalogError, match="GlobalID 非数字"):
        build_items(rows, spec_for_table("buildings.csv"), {})

    # 缺等级列值 → CatalogError
    rows = _buildings_rows()
    rows[2]["BuildingLevel"] = ""
    with pytest.raises(CatalogError, match="缺少等级列"):
        build_items(rows, spec_for_table("buildings.csv"), {})


def test_duplicate_level_rows_deduplicated():
    """真实数据 Defensive Tribal Tag Team：块内 VisualLevel 重复（1-15 后又一个 13）。

    保留首个等级行，输出严格升序，保证 validate 契约（levels 严格升序）可满足。
    """
    rows = [
        {"Name": "String", "GlobalID": "int", "VisualLevel": "int", "TID": "String",
         "IconSWF": "String", "IconExportName": "String", "ProductionBuilding": "String",
         "UpgradeTimeH": "int", "UpgradeTimeM": "int", "LaboratoryLevel": "int",
         "UpgradeResource": "String", "UpgradeCost": "int", "VillageType": "String"},
        {"Name": "Tribal Tag Team", "GlobalID": "4000166", "VisualLevel": "1", "TID": "TID_T",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_t", "ProductionBuilding": "",
         "UpgradeTimeH": "0", "UpgradeTimeM": "0", "LaboratoryLevel": "1",
         "UpgradeResource": "Elixir", "UpgradeCost": "10", "VillageType": ""},
        {"Name": "", "GlobalID": "", "VisualLevel": "2", "TID": "", "IconSWF": "",
         "IconExportName": "", "ProductionBuilding": "", "UpgradeTimeH": "", "UpgradeTimeM": "",
         "LaboratoryLevel": "", "UpgradeResource": "", "UpgradeCost": "", "VillageType": ""},
        {"Name": "", "GlobalID": "", "VisualLevel": "13", "TID": "", "IconSWF": "",
         "IconExportName": "", "ProductionBuilding": "", "UpgradeTimeH": "", "UpgradeTimeM": "",
         "LaboratoryLevel": "", "UpgradeResource": "", "UpgradeCost": "", "VillageType": ""},
        {"Name": "", "GlobalID": "", "VisualLevel": "13", "TID": "", "IconSWF": "",
         "IconExportName": "", "ProductionBuilding": "", "UpgradeTimeH": "", "UpgradeTimeM": "",
         "LaboratoryLevel": "", "UpgradeResource": "", "UpgradeCost": "", "VillageType": ""},
    ]
    items = build_items(rows, spec_for_table("characters.csv"), {})
    item = items[0]
    assert [lv.level for lv in item.levels] == [1, 2, 13]
    assert item.maxLevel == 13
