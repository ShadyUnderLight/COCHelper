from game_catalog.builders import build_guardians
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
