import pytest

from game_catalog.builders import build_items, parse_upgrade_costs
from game_catalog.errors import CatalogError
from game_catalog.model import UpgradeCost
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
    assert item.levels[1].upgradeCosts == [
        UpgradeCost(resource="Gold", amount=1000000, rawResource="Gold",
                    rawAmount=None, parseFailed=False)]
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
    assert item.levels[0].upgradeCosts == [
        UpgradeCost(resource="CommonOre", amount=120, rawResource="CommonOre",
                    rawAmount=None, parseFailed=False)]
    assert item.levels[1].upgradeCosts == [
        UpgradeCost(resource="CommonOre", amount=500, rawResource="CommonOre",
                    rawAmount=None, parseFailed=False)]


# ---- parse_upgrade_costs（Issue #73 Task 1）----


def test_parse_upgrade_costs_single_value_table_ok():
    """单值表（separator=None）：资源非空 + 金额数字 → 单元素数组，parseFailed=False。"""
    assert parse_upgrade_costs("Elixir", "60000", None) == [
        UpgradeCost(resource="Elixir", amount=60000, rawResource="Elixir",
                    rawAmount=None, parseFailed=False)]


def test_parse_upgrade_costs_single_value_empty_resource_returns_none():
    """单值表资源串为空 → None（金额忽略）。"""
    assert parse_upgrade_costs("", "60000", None) is None


def test_parse_upgrade_costs_single_value_non_digit_cost():
    """单值表金额非纯数字 → parseFailed=True，rawAmount 保留原串。"""
    assert parse_upgrade_costs("Elixir", "12a", None) == [
        UpgradeCost(resource="Elixir", amount=None, rawResource="Elixir",
                    rawAmount="12a", parseFailed=True)]


def test_parse_upgrade_costs_single_value_empty_cost_means_free():
    """单值表资源非空 + 金额空串 → 免费（源 CSV 语义）：amount=0 是真实值，
    parseFailed=False（避免免费升级被误判为「金额缺失」UI 噪音）。

    18.400.13 实测：672 条「空金额串」记录被改为免费（此变更数）；目录中
    amount=0 总数为 692（另含 20 条源表金额显式 '0' 的初始行）。"""
    assert parse_upgrade_costs("Elixir", "", None) == [
        UpgradeCost(resource="Elixir", amount=0, rawResource="Elixir",
                    rawAmount=None, parseFailed=False)]


def test_parse_upgrade_costs_multi_resource_pair_ok():
    """多值表配对成功：CommonOre; RareOre + 120; 40 → 2 项 parseFailed=False。"""
    assert parse_upgrade_costs("CommonOre; RareOre", "120; 40", ";") == [
        UpgradeCost(resource="CommonOre", amount=120, rawResource="CommonOre",
                    rawAmount=None, parseFailed=False),
        UpgradeCost(resource="RareOre", amount=40, rawResource="RareOre",
                    rawAmount=None, parseFailed=False)]


def test_parse_upgrade_costs_multi_resource_extra_resource_failed():
    """资源多金额少：多余资源项 parseFailed=True（amount=None, rawAmount=''）。"""
    assert parse_upgrade_costs("CommonOre; RareOre", "120", ";") == [
        UpgradeCost(resource="CommonOre", amount=120, rawResource="CommonOre",
                    rawAmount=None, parseFailed=False),
        UpgradeCost(resource="RareOre", amount=None, rawResource="RareOre",
                    rawAmount="", parseFailed=True)]


def test_parse_upgrade_costs_multi_resource_extra_cost_failed():
    """金额多资源少：多余金额项 parseFailed=True（resource=最后资源段）。"""
    assert parse_upgrade_costs("CommonOre", "120; 40", ";") == [
        UpgradeCost(resource="CommonOre", amount=120, rawResource="CommonOre",
                    rawAmount=None, parseFailed=False),
        UpgradeCost(resource="CommonOre", amount=None, rawResource="CommonOre",
                    rawAmount="40", parseFailed=True)]


def test_parse_upgrade_costs_multi_resource_non_digit_cost():
    """多值表金额非数字 → 该项 parseFailed=True，rawAmount 保留原串。"""
    assert parse_upgrade_costs("CommonOre; RareOre", "120; abc", ";") == [
        UpgradeCost(resource="CommonOre", amount=120, rawResource="CommonOre",
                    rawAmount=None, parseFailed=False),
        UpgradeCost(resource="RareOre", amount=None, rawResource="RareOre",
                    rawAmount="abc", parseFailed=True)]


def test_parse_upgrade_costs_multi_resource_empty_cost_not_free():
    """多值表金额空串**不视为免费**（与单值表不对称，交叉审核 I-1 锁定防御语义）：
    空金额被过滤后资源项 parseFailed=True（rawAmount=''），而不是 amount=0。

    真实 18.400.13 数据 0 实例（源 CSV 339 条多资源行 → 生成后 385 个多资源等级，
    全部完整配对），此为纯防御
    行为——若未来 Supercell 在装备表引入免费升级（空金额段），需先明确语义
    再决定是否对称处理。"""
    assert parse_upgrade_costs("CommonOre; RareOre", "", ";") == [
        UpgradeCost(resource="CommonOre", amount=None, rawResource="CommonOre",
                    rawAmount="", parseFailed=True),
        UpgradeCost(resource="RareOre", amount=None, rawResource="RareOre",
                    rawAmount="", parseFailed=True)]


def test_parse_upgrade_costs_multi_resource_empty_all_segments_returns_none():
    """多值表资源串全空（空串/纯分隔符/空白段）→ None。"""
    assert parse_upgrade_costs("", "120; 40", ";") is None
    assert parse_upgrade_costs(";;", "120; 40", ";") is None
    assert parse_upgrade_costs("  ;  ", "120; 40", ";") is None


def test_parse_upgrade_costs_multi_resource_empty_segments_skipped():
    """多值表空段/空白段被过滤后配对，不产生非法空 resource 项。"""
    assert parse_upgrade_costs("CommonOre; ; RareOre", "120; ; 40", ";") == [
        UpgradeCost(resource="CommonOre", amount=120, rawResource="CommonOre",
                    rawAmount=None, parseFailed=False),
        UpgradeCost(resource="RareOre", amount=40, rawResource="RareOre",
                    rawAmount=None, parseFailed=False)]


def test_equipment_multi_resource_costs():
    """character_items.csv 多资源升级费用端到端（to_level 语义：行 N → level N）。"""
    rows = [
        {"Name": "String", "Level": "int", "TID": "String",
         "IconSWF": "String", "IconExportName": "String",
         "UpgradeResources": "String", "UpgradeCosts": "String"},
        {"Name": "Magic Mirror", "Level": "1", "TID": "TID_MM",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_equip_mm",
         "UpgradeResources": "CommonOre; RareOre", "UpgradeCosts": "120; 40"},
        {"Name": "", "Level": "2", "TID": "", "IconSWF": "", "IconExportName": "",
         "UpgradeResources": "", "UpgradeCosts": "500"},
    ]
    items = build_items(rows, spec_for_table("character_items.csv"), {})
    item = items[0]
    assert [lv.level for lv in item.levels] == [1, 2]
    assert item.levels[0].upgradeCosts == [
        UpgradeCost(resource="CommonOre", amount=120, rawResource="CommonOre",
                    rawAmount=None, parseFailed=False),
        UpgradeCost(resource="RareOre", amount=40, rawResource="RareOre",
                    rawAmount=None, parseFailed=False),
    ]
    # 行2 资源列 fill 继承行1 的多资源值，金额只有单段 → 资源多余 → 第二项 parseFailed
    # （真实数据行 2+ 通常不重复填 UpgradeResources）
    assert item.levels[1].upgradeCosts == [
        UpgradeCost(resource="CommonOre", amount=500, rawResource="CommonOre",
                    rawAmount=None, parseFailed=False),
        UpgradeCost(resource="RareOre", amount=None, rawResource="RareOre",
                    rawAmount="", parseFailed=True),
    ]


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

    to_next 语义下：去重后 maxLevel = 行数，levels 覆盖 1..maxLevel（level 1 无数据），
    重复行（属于不存在的下一级）的升级属性被丢弃。这里用 1,2,3,3 模拟"最高级重复"。
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
        {"Name": "", "GlobalID": "", "VisualLevel": "3", "TID": "", "IconSWF": "",
         "IconExportName": "", "ProductionBuilding": "", "UpgradeTimeH": "", "UpgradeTimeM": "",
         "LaboratoryLevel": "", "UpgradeResource": "", "UpgradeCost": "", "VillageType": ""},
        {"Name": "", "GlobalID": "", "VisualLevel": "3", "TID": "", "IconSWF": "",
         "IconExportName": "", "ProductionBuilding": "", "UpgradeTimeH": "", "UpgradeTimeM": "",
         "LaboratoryLevel": "", "UpgradeResource": "", "UpgradeCost": "", "VillageType": ""},
    ]
    items = build_items(rows, spec_for_table("characters.csv"), {})
    item = items[0]
    assert [lv.level for lv in item.levels] == [1, 2, 3]  # 重复 3 级行只保留一个
    assert item.maxLevel == 3
    # to_next：level 1 = 初始；level 2 ← 行1（0h0m）；level 3 ← 行2（时间空 → missing）
    assert item.levels[0].durationSeconds is None
    assert item.levels[0].missingReason == "min_level_initial_no_upgrade"
    assert item.levels[1].durationSeconds == 0
    assert item.levels[1].upgradeCosts == [
        UpgradeCost(resource="Elixir", amount=10, rawResource="Elixir",
                    rawAmount=None, parseFailed=False)]
    assert item.levels[2].durationSeconds is None
    assert item.levels[2].missingReason == "time_missing"


def test_characters_to_next_level_mapping():
    """to_next 语义核心：行 N 的升级属性属于 level N+1，level 1 = 初始无升级。"""
    rows = [
        {"Name": "String", "GlobalID": "int", "VisualLevel": "int", "TID": "String",
         "IconSWF": "String", "IconExportName": "String", "ProductionBuilding": "String",
         "UpgradeTimeH": "int", "UpgradeTimeM": "int", "LaboratoryLevel": "int",
         "UpgradeResource": "String", "UpgradeCost": "int", "VillageType": "String"},
        {"Name": "Archer", "GlobalID": "4000001", "VisualLevel": "1", "TID": "TID_A",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_a1", "ProductionBuilding": "",
         "UpgradeTimeH": "5", "UpgradeTimeM": "30", "LaboratoryLevel": "2",
         "UpgradeResource": "Elixir", "UpgradeCost": "60000", "VillageType": ""},
        {"Name": "", "GlobalID": "", "VisualLevel": "2", "TID": "", "IconSWF": "",
         "IconExportName": "icon_a2", "ProductionBuilding": "", "UpgradeTimeH": "8",
         "UpgradeTimeM": "", "LaboratoryLevel": "3", "UpgradeResource": "",
         "UpgradeCost": "120000", "VillageType": ""},
        {"Name": "", "GlobalID": "", "VisualLevel": "3", "TID": "", "IconSWF": "",
         "IconExportName": "icon_a3", "ProductionBuilding": "", "UpgradeTimeH": "",
         "UpgradeTimeM": "", "LaboratoryLevel": "", "UpgradeResource": "",
         "UpgradeCost": "", "VillageType": ""},
    ]
    items = build_items(rows, spec_for_table("characters.csv"), {})
    item = items[0]
    assert item.maxLevel == 3
    assert [lv.level for lv in item.levels] == [1, 2, 3]

    lv1, lv2, lv3 = item.levels
    # level 1 = 初始等级：无升级属性，保留自身图标
    assert lv1.durationSeconds is None
    assert lv1.missingReason == "min_level_initial_no_upgrade"
    assert lv1.upgradeCosts is None
    assert lv1.requiredLaboratoryLevel is None
    assert lv1.icon is not None and lv1.icon.exportName == "icon_a1"
    # level 2 ← 行1：5h30m = 19800s
    assert lv2.durationSeconds == 5 * 3600 + 30 * 60
    assert lv2.upgradeCosts == [
        UpgradeCost(resource="Elixir", amount=60000, rawResource="Elixir",
                    rawAmount=None, parseFailed=False)]
    assert lv2.requiredLaboratoryLevel == 2
    # level 3 ← 行2：8h = 28800s（UpTimeM='' 不继承行1的 30m）；资源列 fill 继承
    # 行1 的 Elixir、金额 120000 → 单元素数组
    assert lv3.durationSeconds == 8 * 3600
    assert lv3.upgradeCosts == [
        UpgradeCost(resource="Elixir", amount=120000, rawResource="Elixir",
                    rawAmount=None, parseFailed=False)]
    assert lv3.requiredLaboratoryLevel == 3
    # 外观跟随自己的行：lv2 用行2的 icon_a2，lv3 用行3的 icon_a3
    assert lv2.icon.exportName == "icon_a2"
    assert lv3.icon.exportName == "icon_a3"
    # 行3（maxLevel 行）的升级属性属于不存在的 level 4 → 丢弃（此处行3无时间，无直接可断言值）


def test_time_columns_not_inherited_to_next():
    """时间列空 cell = 0（不 forward-fill）：行2 UpH=1 UpM='' = 1h = 3600s（不是 1h30m），
    该值属于 level 3（行2 = "2→3" 升级）。"""
    rows = [
        {"Name": "String", "GlobalID": "int", "VisualLevel": "int", "TID": "String",
         "IconSWF": "String", "IconExportName": "String", "ProductionBuilding": "String",
         "UpgradeTimeH": "int", "UpgradeTimeM": "int", "LaboratoryLevel": "int",
         "UpgradeResource": "String", "UpgradeCost": "int", "VillageType": "String"},
        {"Name": "Barbarian", "GlobalID": "4000000", "VisualLevel": "1", "TID": "TID_B",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_b1", "ProductionBuilding": "",
         "UpgradeTimeH": "0", "UpgradeTimeM": "30", "LaboratoryLevel": "1",
         "UpgradeResource": "Elixir", "UpgradeCost": "10000", "VillageType": ""},
        {"Name": "", "GlobalID": "", "VisualLevel": "2", "TID": "", "IconSWF": "",
         "IconExportName": "", "ProductionBuilding": "", "UpgradeTimeH": "1",
         "UpgradeTimeM": "", "LaboratoryLevel": "", "UpgradeResource": "",
         "UpgradeCost": "", "VillageType": ""},
        {"Name": "", "GlobalID": "", "VisualLevel": "3", "TID": "", "IconSWF": "",
         "IconExportName": "", "ProductionBuilding": "", "UpgradeTimeH": "2",
         "UpgradeTimeM": "", "LaboratoryLevel": "", "UpgradeResource": "",
         "UpgradeCost": "", "VillageType": ""},
    ]
    items = build_items(rows, spec_for_table("characters.csv"), {})
    item = items[0]
    assert [lv.level for lv in item.levels] == [1, 2, 3]  # 行3 是 maxLevel 行，无 level 4
    # level 2 ← 行1：0h30m = 1800s（真实值，非继承）
    assert item.levels[1].durationSeconds == 1800
    # level 3 ← 行2：1h = 3600s，UpM='' 按 0 —— 若继承行1的 30m 会是 5400s
    assert item.levels[2].durationSeconds == 3600
    # 行3 的 2h 属于不存在的 level 4 → 丢弃（levels 只到 3）


def test_heroes_tavern_level_extracted():
    """heroes 表 RequiredHeroTavernLevel 列（Issue #67）：to_next 语义下行 N 的
    升级门槛属于 level N+1；level 1 = 初始等级无门槛。"""
    rows = [
        {"Name": "String", "VisualLevel": "int", "TID": "String",
         "UpgradeTimeH": "int", "VillageType": "String",
         "RequiredTownHallLevel": "int", "RequiredHeroTavernLevel": "int"},
        {"Name": "Barbarian King", "VisualLevel": "1", "TID": "TID_BK",
         "UpgradeTimeH": "0", "VillageType": "",
         "RequiredTownHallLevel": "4", "RequiredHeroTavernLevel": "1"},
        {"Name": "", "VisualLevel": "2", "TID": "", "UpgradeTimeH": "",
         "VillageType": "", "RequiredTownHallLevel": "", "RequiredHeroTavernLevel": ""},
    ]
    items = build_items(rows, spec_for_table("heroes.csv"), {})
    # level 2 ← 行1：升级到 2 级需要英雄殿堂 1 级 + 大本营 4 级
    assert items[0].levels[1].requiredHeroTavernLevel == 1
    assert items[0].levels[1].requiredTownHallLevel == 4
    # level 1 = 初始等级，无升级门槛
    assert items[0].levels[0].requiredHeroTavernLevel is None


def test_offset_levels_preserved_to_next():
    """to_next 表保留原始等级号（Super Barbarian 样式：VisualLevel 5..7，解锁即 5 级）。

    level 值 = 行自身等级；升级属性来自上一行（level 5=初始、6←行5、7←行6）；
    行7 的升级属性属于不存在的 level 8 → 丢弃。
    """
    rows = [
        {"Name": "String", "GlobalID": "int", "VisualLevel": "int", "TID": "String",
         "IconSWF": "String", "IconExportName": "String", "ProductionBuilding": "String",
         "UpgradeTimeH": "int", "UpgradeTimeM": "int", "LaboratoryLevel": "int",
         "UpgradeResource": "String", "UpgradeCost": "int", "VillageType": "String"},
        {"Name": "Super Barbarian", "GlobalID": "4000200", "VisualLevel": "5", "TID": "TID_SB",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_sb5", "ProductionBuilding": "",
         "UpgradeTimeH": "2", "UpgradeTimeM": "0", "LaboratoryLevel": "11",
         "UpgradeResource": "Elixir", "UpgradeCost": "100000", "VillageType": ""},
        {"Name": "", "GlobalID": "", "VisualLevel": "6", "TID": "", "IconSWF": "",
         "IconExportName": "icon_sb6", "ProductionBuilding": "", "UpgradeTimeH": "3",
         "UpgradeTimeM": "", "LaboratoryLevel": "", "UpgradeResource": "",
         "UpgradeCost": "200000", "VillageType": ""},
        {"Name": "", "GlobalID": "", "VisualLevel": "7", "TID": "", "IconSWF": "",
         "IconExportName": "icon_sb7", "ProductionBuilding": "", "UpgradeTimeH": "4",
         "UpgradeTimeM": "", "LaboratoryLevel": "", "UpgradeResource": "",
         "UpgradeCost": "300000", "VillageType": ""},
    ]
    items = build_items(rows, spec_for_table("characters.csv"), {})
    item = items[0]
    assert [lv.level for lv in item.levels] == [5, 6, 7]  # 保留原始编号，不压成 1..3
    assert item.maxLevel == 7
    lv5, lv6, lv7 = item.levels
    # level 5 = 初始等级：无升级属性，外观取自身行
    assert lv5.durationSeconds is None
    assert lv5.missingReason == "min_level_initial_no_upgrade"
    assert lv5.upgradeCosts is None
    assert lv5.icon is not None and lv5.icon.exportName == "icon_sb5"
    # level 6 ← 行5：2h = 7200s
    assert lv6.durationSeconds == 2 * 3600
    assert lv6.upgradeCosts == [
        UpgradeCost(resource="Elixir", amount=100000, rawResource="Elixir",
                    rawAmount=None, parseFailed=False)]
    assert lv6.requiredLaboratoryLevel == 11
    assert lv6.icon.exportName == "icon_sb6"          # 外观跟随自己的行
    # level 7 ← 行6：3h = 10800s；行6 资源列 fill 继承 Elixir、金额 200000
    assert lv7.durationSeconds == 3 * 3600
    assert lv7.upgradeCosts == [
        UpgradeCost(resource="Elixir", amount=200000, rawResource="Elixir",
                    rawAmount=None, parseFailed=False)]
    assert lv7.icon.exportName == "icon_sb7"
