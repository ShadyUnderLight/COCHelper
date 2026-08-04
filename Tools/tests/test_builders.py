import pytest

from game_catalog.builders import build_items
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
