"""pytest 共享配置：确保 Tools/ 在 sys.path，供 game_catalog 包导入。

提供 `full_minimal_apk` fixture：包含全部注册表（12 张）+ upgrade_data.csv +
本地化 + build.tag 的最小合成 APK。每张表只含表头 + doc 行（Name=String），
buildings.csv 额外带一条 Town Hall 数据行（供 counts 断言）。
"""

import lzma
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest

from game_catalog.tables import TABLES


def _packed(text: str) -> bytes:
    # Supercell ALONE 头：5 字节属性 + 4 字节 usz(LE) + lzma 数据
    data = text.encode("utf-8-sig")
    compressed = lzma.compress(data, format=lzma.FORMAT_ALONE)
    return compressed[:5] + len(data).to_bytes(4, "little") + compressed[13:]


def _doc_rows(spec) -> str:
    """按 TableSpec 必需列生成表头 + doc 行（Name=String）。"""
    cols = ["Name"]
    if spec.id_base is None:
        cols.append("GlobalID")
    cols.append(spec.level_column)
    for c in (
        spec.resource_column, spec.cost_column, spec.town_hall_column,
        spec.laboratory_column, spec.hero_tavern_column,
    ):
        if c:
            cols.append(c)
    cols += list(spec.icon_columns) + list(spec.visual_columns)
    cols += list(spec.time_columns)
    header = ",".join(cols)
    doc = ",".join("String" if c == "Name" else "int" if c in (
        spec.level_column, spec.cost_column, spec.town_hall_column,
        spec.laboratory_column, spec.hero_tavern_column, *spec.time_columns,
    ) else "String" for c in cols)
    return header + "\n" + doc + "\n"


TOWN_HALL_CSV = (
    "Name,GlobalID,BuildingLevel,TID,SWF,ExportName,Icon,"
    "BuildTimeD,BuildTimeH,BuildTimeM,BuildTimeS,"
    "BuildResource,BuildCost,TownHallLevel,VillageType\n"
    "String,int,int,String,String,String,String,int,int,int,int,String,int,int,String\n"
    "Town Hall,1000001,1,TID_A,sc/buildings.sc,town_hall_lvl1,,0,0,0,0,Gold,0,0,\n"
)

UPGRADE_DATA_CSV = (
    "Name,UpgradeLevel,UpgradeType,UpgradeTimeDays,UpgradeTimeHours,"
    "UpgradeTimeMinutes,UpgradeTimeSeconds,UpgradeResource,AltUpgradeResource,"
    "UpgradeCost,UpgradePriority\n"
    "String,int,String,int,int,int,int,String,String,int,int\n"
)

# 最小 townhall_levels：仅 Name 列 + 18 个 TH 行（无数量列 → instanceCounts = {}）
TOWNHALL_LEVELS_CSV = (
    "Name\nString\n" + "".join(f'"{i}"\n' for i in range(1, 19))
)


@pytest.fixture
def full_minimal_apk(tmp_path: Path) -> Path:
    apk = tmp_path / "fake.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/build.tag", "18_400_7")
        z.writestr("assets/localization/cn.csv", _packed("TID,CN\nTID_A,测试\n"))
        z.writestr("assets/localization/texts_patch.csv", _packed("TID,CN\n"))
        for spec in TABLES:
            if spec.table == "buildings.csv":
                continue  # 单独写带数据行的版本
            z.writestr("assets/logic/" + spec.table, _packed(_doc_rows(spec)))
        z.writestr("assets/logic/upgrade_data.csv", _packed(UPGRADE_DATA_CSV))
        z.writestr("assets/logic/townhall_levels.csv", _packed(TOWNHALL_LEVELS_CSV))
        z.writestr("assets/logic/buildings.csv", _packed(TOWN_HALL_CSV))
    return apk
