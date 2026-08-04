import pytest

from game_catalog.builders import build_guardians
from game_catalog.errors import CatalogError
from game_catalog.tables import spec_for_table


def _guardian_rows():
    return [
        {"Name": "String", "Level": "int", "TID": "String", "UpgradeData": "String",
         "IconSWF": "String", "IconExportName": "String"},
        {"Name": "InfernoArtillery", "Level": "1", "TID": "TID_G", "UpgradeData": "GuardianGeneral",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_unit_guardian_ranged"},
        {"Name": "", "Level": "2", "TID": "", "UpgradeData": "", "IconSWF": "", "IconExportName": ""},
        {"Name": "", "Level": "5", "TID": "", "UpgradeData": "", "IconSWF": "", "IconExportName": ""},
    ]


def _upgrade_rows():
    return [
        {"Name": "String", "UpgradeLevel": "int", "UpgradeTimeDays": "int",
         "UpgradeTimeHours": "int", "UpgradeTimeMinutes": "int", "UpgradeTimeSeconds": "int",
         "UpgradeResource": "String", "UpgradeCost": "int"},
        {"Name": "GuardianGeneral", "UpgradeLevel": "1", "UpgradeTimeDays": "7",
         "UpgradeTimeHours": "0", "UpgradeTimeMinutes": "0", "UpgradeTimeSeconds": "0",
         "UpgradeResource": "Elixir", "UpgradeCost": "18000000"},
        {"Name": "", "UpgradeLevel": "2", "UpgradeTimeDays": "9",
         "UpgradeTimeHours": "0", "UpgradeTimeMinutes": "0", "UpgradeTimeSeconds": "0",
         "UpgradeResource": "", "UpgradeCost": "22000000"},
    ]


def test_guardian_join_hit_and_miss():
    items = build_guardians(_guardian_rows(), _upgrade_rows(), {})
    assert len(items) == 1
    item = items[0]
    assert item.dataID == 107_000_000
    assert [lv.level for lv in item.levels] == [1, 2, 5]
    assert item.levels[0].durationSeconds == 7 * 86400
    assert item.levels[0].upgradeCost == 18000000
    assert item.levels[1].durationSeconds == 9 * 86400
    assert item.levels[2].durationSeconds is None
    assert item.levels[2].missingReason == "upgrade_data_missing"


def _upgrade_rows_order_132():
    return [
        {"Name": "String", "UpgradeLevel": "int", "UpgradeTimeDays": "int",
         "UpgradeTimeHours": "int", "UpgradeTimeMinutes": "int", "UpgradeTimeSeconds": "int",
         "UpgradeResource": "String", "UpgradeCost": "int"},
        {"Name": "GuardianGeneral", "UpgradeLevel": "1", "UpgradeTimeDays": "7",
         "UpgradeTimeHours": "0", "UpgradeTimeMinutes": "0", "UpgradeTimeSeconds": "0",
         "UpgradeResource": "Elixir", "UpgradeCost": "18000000"},
        {"Name": "", "UpgradeLevel": "3", "UpgradeTimeDays": "11",
         "UpgradeTimeHours": "0", "UpgradeTimeMinutes": "0", "UpgradeTimeSeconds": "0",
         "UpgradeResource": "", "UpgradeCost": "26000000"},
        {"Name": "", "UpgradeLevel": "2", "UpgradeTimeDays": "9",
         "UpgradeTimeHours": "0", "UpgradeTimeMinutes": "0", "UpgradeTimeSeconds": "0",
         "UpgradeResource": "", "UpgradeCost": "22000000"},
    ]


def test_guardian_join_out_of_order_upgrade_levels():
    rows = [
        {"Name": "String", "Level": "int", "TID": "String", "UpgradeData": "String",
         "IconSWF": "String", "IconExportName": "String"},
        {"Name": "InfernoArtillery", "Level": "1", "TID": "TID_G", "UpgradeData": "GuardianGeneral",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_unit_guardian_ranged"},
        {"Name": "", "Level": "2", "TID": "", "UpgradeData": "", "IconSWF": "", "IconExportName": ""},
        {"Name": "", "Level": "3", "TID": "", "UpgradeData": "", "IconSWF": "", "IconExportName": ""},
    ]
    # upgrade_data 行序 1/3/2 → levels 输出仍 [1,2,3] 且时长正确对应
    items = build_guardians(rows, _upgrade_rows_order_132(), {})
    item = items[0]
    assert [lv.level for lv in item.levels] == [1, 2, 3]
    assert item.levels[0].durationSeconds == 7 * 86400
    assert item.levels[0].upgradeCost == 18000000
    assert item.levels[1].durationSeconds == 9 * 86400
    assert item.levels[1].upgradeCost == 22000000
    assert item.levels[2].durationSeconds == 11 * 86400
    assert item.levels[2].upgradeCost == 26000000


def test_guardian_duplicate_upgrade_key():
    up = _upgrade_rows()
    up.append({"Name": "GuardianGeneral", "UpgradeLevel": "1", "UpgradeTimeDays": "99",
               "UpgradeTimeHours": "0", "UpgradeTimeMinutes": "0", "UpgradeTimeSeconds": "0",
               "UpgradeResource": "", "UpgradeCost": "1"})
    with pytest.raises(CatalogError, match="重复键"):
        build_guardians(_guardian_rows(), up, {})


def test_guardian_missing_upgrade_data():
    rows = [
        {"Name": "String", "Level": "int", "TID": "String", "UpgradeData": "String",
         "IconSWF": "String", "IconExportName": "String"},
        {"Name": "InfernoArtillery", "Level": "1", "TID": "TID_G", "UpgradeData": "",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_unit_guardian_ranged"},
    ]
    with pytest.raises(CatalogError, match="缺少 UpgradeData"):
        build_guardians(rows, _upgrade_rows(), {})
