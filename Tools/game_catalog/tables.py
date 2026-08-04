"""表注册表（唯一事实源）+ 记录分组 + 逐列 forward-fill。"""

from dataclasses import dataclass
from typing import Iterable, Iterator, Mapping

from .errors import CatalogError

# ---- 记录分组 ----

def is_doc_row(row: Mapping[str, str]) -> bool:
    """Supercell 类型标注行：Name == 'String'。"""
    return row.get("Name") == "String"


def is_real_name(value: str | None) -> bool:
    return bool(value) and value != "String"


@dataclass
class Block:
    name: str
    rows: list[dict[str, str]]


def group_blocks(rows: list[dict[str, str]]) -> list[Block]:
    """按 Name 非空行切分记录；跳过 doc 行；空行并入当前块。"""
    blocks: list[Block] = []
    for row in rows:
        if is_doc_row(row):
            continue
        if is_real_name(row.get("Name")):
            blocks.append(Block(name=row["Name"].strip(), rows=[row]))
        elif blocks:
            blocks[-1].rows.append(row)
        else:
            raise CatalogError(f"doc/类型标注行之后的孤儿行: {row}")
    return blocks


def ffill_columns(rows: list[dict[str, str]], columns: Iterable[str]) -> list[dict[str, str]]:
    """块内逐列 forward-fill：空 cell 继承本列上方最近非空值；'0' 是真实值。

    纯函数，不修改输入；只填充白名单列；绝不跨块（调用方按块传入）。
    """
    result = [dict(r) for r in rows]
    for col in columns:
        carry = ""
        for row in result:
            value = row.get(col, "")
            if value == "":
                row[col] = carry
            else:
                carry = value
    return result


def section_for(village_type: str) -> str:
    """VillageType → 主村/建筑工人基地。''/'0'→home，'1'→builder。"""
    if village_type in ("", "0"):
        return "home"
    if village_type == "1":
        return "builder"
    raise CatalogError(f"未知 VillageType: {village_type!r}")


# ---- 表注册表 ----

@dataclass(frozen=True)
class TableSpec:
    table: str                          # 源 CSV 文件名
    section: str                        # catalog section（快照查找键）
    section2: str | None = None         # builder 后缀 section（如 buildings2）
    category: str = ""                  # Swift TrackerCategory rawValue
    category2: str | None = None
    level_column: str = "Level"
    time_columns: tuple[str, ...] = ()
    resource_column: str | None = None
    cost_column: str | None = None
    town_hall_column: str | None = None
    laboratory_column: str | None = None
    icon_columns: tuple[str, ...] = ()          # (IconSWF, IconExportName) 或 (Icon,)
    visual_columns: tuple[str, ...] = ()        # (SWF, ExportName)
    village_type_column: str | None = None
    fill_columns: tuple[str, ...] = ()          # forward-fill 白名单（不含等级列）
    id_base: int | None = None                  # None=用 GlobalID
    base_default: str | None = "home"           # capital 表传 None
    has_deprecated: bool = False
    join_upgrade_data: bool = False


def _with_time_fill(fill: tuple[str, ...], time: tuple[str, ...]) -> tuple[str, ...]:
    """fill_columns 的继承列 + 自动并入 time_columns（去重保序）。

    单一事实源：时间列只需在 time_columns 声明一次，
    避免 fill_columns 双份维护导致漂移（如加列忘改 fill）。
    """
    return tuple(dict.fromkeys(fill + time))


TABLES: tuple[TableSpec, ...] = (
    TableSpec(
        table="buildings.csv", section="buildings", section2="buildings2",
        category="buildings", level_column="BuildingLevel",
        time_columns=("BuildTimeD", "BuildTimeH", "BuildTimeM", "BuildTimeS"),
        resource_column="BuildResource", cost_column="BuildCost",
        town_hall_column="TownHallLevel",
        icon_columns=("Icon",), visual_columns=("SWF", "ExportName"),
        village_type_column="VillageType",
        fill_columns=_with_time_fill(
            ("TID", "GlobalID", "VillageType", "SWF", "ExportName",
             "Icon", "BuildResource", "BuildCost", "TownHallLevel"),
            ("BuildTimeD", "BuildTimeH", "BuildTimeM", "BuildTimeS")),
    ),
    TableSpec(
        table="traps.csv", section="traps", section2="traps2",
        category="traps", level_column="Level",
        time_columns=("BuildTimeD", "BuildTimeH", "BuildTimeM"),
        resource_column="BuildResource", cost_column="BuildCost",
        icon_columns=("IconSWF", "IconExportName"), visual_columns=("SWF", "ExportName"),
        village_type_column="VillageType",
        fill_columns=_with_time_fill(
            ("TID", "GlobalID", "VillageType", "SWF", "ExportName",
             "IconSWF", "IconExportName", "BuildResource", "BuildCost"),
            ("BuildTimeD", "BuildTimeH", "BuildTimeM")),
    ),
    TableSpec(
        table="characters.csv", section="units", section2="units2",
        category="troops", category2="troops", level_column="VisualLevel",
        time_columns=("UpgradeTimeH", "UpgradeTimeM"),
        resource_column="UpgradeResource", cost_column="UpgradeCost",
        laboratory_column="LaboratoryLevel",
        icon_columns=("IconSWF", "IconExportName"),
        village_type_column="VillageType",
        fill_columns=_with_time_fill(
            ("TID", "GlobalID", "VillageType", "IconSWF", "IconExportName",
             "UpgradeResource", "UpgradeCost", "LaboratoryLevel", "ProductionBuilding",
             "Deprecated"),
            ("UpgradeTimeH", "UpgradeTimeM")),
        has_deprecated=True,
    ),
    TableSpec(
        table="spells.csv", section="spells", category="spells",
        level_column="Level", time_columns=("UpgradeTimeH",),
        resource_column="UpgradeResource", cost_column="UpgradeCost",
        laboratory_column="LaboratoryLevel",
        icon_columns=("IconSWF", "IconExportName"),
        village_type_column="VillageType",
        fill_columns=_with_time_fill(
            ("TID", "GlobalID", "VillageType", "IconSWF", "IconExportName",
             "UpgradeResource", "UpgradeCost", "LaboratoryLevel"),
            ("UpgradeTimeH",)),
    ),
    TableSpec(
        table="heroes.csv", section="heroes", section2="heroes2",
        category="heroes", level_column="VisualLevel",
        time_columns=("UpgradeTimeH",),
        resource_column="UpgradeResource", cost_column="UpgradeCost",
        town_hall_column="RequiredTownHallLevel",
        icon_columns=("IconSWF", "IconExportName"),
        village_type_column="VillageType",
        fill_columns=_with_time_fill(
            ("TID", "VillageType", "IconSWF", "IconExportName",
             "UpgradeResource", "UpgradeCost", "RequiredTownHallLevel"),
            ("UpgradeTimeH",)),
        id_base=28_000_000,
    ),
    TableSpec(
        table="pets.csv", section="pets", category="pets",
        level_column="TroopLevel", time_columns=("UpgradeTimeH", "UpgradeTimeM"),
        resource_column="UpgradeResource", cost_column="UpgradeCost",
        laboratory_column="LaboratoryLevel",
        icon_columns=("IconSWF", "IconExportName"),
        village_type_column="VillageType",
        fill_columns=_with_time_fill(
            ("TID", "VillageType", "IconSWF", "IconExportName",
             "UpgradeResource", "UpgradeCost", "LaboratoryLevel", "Deprecated"),
            ("UpgradeTimeH", "UpgradeTimeM")),
        id_base=73_000_000,
        has_deprecated=True,
    ),
    TableSpec(
        table="character_items.csv", section="equipment", category="equipment",
        level_column="Level", time_columns=(),  # 无时间列 → no_time_source
        resource_column="UpgradeResources", cost_column="UpgradeCosts",
        icon_columns=("IconSWF", "IconExportName"),
        fill_columns=_with_time_fill(
            ("TID", "IconSWF", "IconExportName", "UpgradeResources", "UpgradeCosts",
             "Deprecated"), ()),
        id_base=90_000_000,
        has_deprecated=True,
    ),
    TableSpec(
        table="guardians.csv", section="guardians", category="guardians",
        # 权威等级列是 CharacterLevels：真实数据 Level 列未逐行填写（Logger 块仅首行有值）
        level_column="CharacterLevels", time_columns=(),  # 时长来自 upgrade_data join
        icon_columns=("IconSWF", "IconExportName"),
        fill_columns=_with_time_fill(("TID", "IconSWF", "IconExportName", "UpgradeData",
                                      "Deprecated"), ()),
        id_base=107_000_000,
        has_deprecated=True,
        join_upgrade_data=True,
    ),
    TableSpec(
        table="capital_buildings.csv", section="capital_buildings",
        category="capitalBuildings", level_column="BuildingLevel",
        time_columns=("BuildTimeD", "BuildTimeH", "BuildTimeM", "BuildTimeS"),
        resource_column="BuildResource", cost_column="BuildCost",
        visual_columns=("SWF", "ExportName"),
        fill_columns=_with_time_fill(
            ("TID", "SWF", "ExportName", "BuildResource", "BuildCost"),
            ("BuildTimeD", "BuildTimeH", "BuildTimeM", "BuildTimeS")),
        base_default=None,
        # capital 表无 GlobalID 列，用独立段位（110M-113M，位于 guardians 107M 之后）
        id_base=110_000_000,
    ),
    TableSpec(
        table="capital_traps.csv", section="capital_traps",
        category="capitalTraps", level_column="Level",
        time_columns=("BuildTimeD", "BuildTimeH", "BuildTimeM"),
        resource_column="BuildResource", cost_column="BuildCost",
        fill_columns=_with_time_fill(
            ("TID", "BuildResource", "BuildCost"),
            ("BuildTimeD", "BuildTimeH", "BuildTimeM")),
        base_default=None,
        id_base=111_000_000,
    ),
    TableSpec(
        table="capital_characters.csv", section="capital_characters",
        category="capitalTroops", level_column="TroopLevel",
        time_columns=("UpgradeTimeH", "UpgradeTimeM"),
        icon_columns=("IconSWF", "IconExportName"),
        fill_columns=_with_time_fill(
            ("TID", "IconSWF", "IconExportName"),
            ("UpgradeTimeH", "UpgradeTimeM")),
        base_default=None,
        id_base=112_000_000,
    ),
    TableSpec(
        table="capital_spells.csv", section="capital_spells",
        category="capitalSpells", level_column="Level",
        time_columns=("UpgradeTimeH",),
        icon_columns=("IconSWF", "IconExportName"),
        fill_columns=_with_time_fill(("TID", "IconSWF", "IconExportName"), ("UpgradeTimeH",)),
        base_default=None,
        id_base=113_000_000,
    ),
)


def spec_for_table(table: str) -> TableSpec:
    for spec in TABLES:
        if spec.table == table:
            return spec
    raise CatalogError(f"未注册的表: {table}")
