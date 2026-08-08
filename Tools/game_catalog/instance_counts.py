"""townhall_levels.csv → 每 TH 实例数量宇宙（纯 stdlib）。

Issue #70 阶段 2：catalog.json 的 instanceCounts 字段（"section:dataID" →
[TH1..TH18] 可建造实例数）来源。数据源实证：townhall_levels.csv 行 =
大本营等级（Name "1".."18"），列 = 建筑名 + 配置列；主村数量列全部可
join buildings.csv/traps.csv 的 Name。设计评审 B3 后 CONFIG_COLUMNS 含
Treasury 6 列。

稀疏列语义（与 wiki 交叉验证）：'' = 沿用上一 TH 的值（首值前 = 0）；
'0' 是真实值。TH1-18 数组 index = TH-1。
"""

from __future__ import annotations

from game_catalog.errors import CatalogError

# townhall_levels 非数量列（配置列 + gearup 强化列 + Treasury；join 失败即
# 说明不是建筑数量列——fail loud 前必须先白名单跳过，防新列静默丢失）。
# gearup 3 列（Cannon_gearup/Archer Tower_gearup/Mortar_gearup）为实施阶段
# 数据源实证补充：非空（TH1='1'）但无对应 buildings.csv 名（计划文档
# "「_gearup 强化列」非数量列需跳过"），不加白名单会误触发 join fail-loud。
CONFIG_COLUMNS = frozenset({
    "AttackCost", "ResourceStorageLootPercentage", "DarkElixirStorageLootPercentage",
    "ResourceStorageLootCap", "DarkElixirStorageLootCap", "WarPrizeResourceCap",
    "WarPrizeDarkElixirCap", "WarPrizeCommonOreCap", "WarPrizeRareOreCap",
    "WarPrizeEpicOreCap", "WarPrizeAllianceExpCap", "CartLootCapResource",
    "CartLootReengagementResource", "CartLootCapDarkElixir", "CartLootReengagementDarkElixir",
    "ReengagementBuildingBudget", "ReengagementHeroBudget", "ReengagementWallBudget",
    "ReengagementLabBudget", "HeroBoostHours", "PowerBoostHours",
    "ResourceProductionBoostHours", "StarBonusBoostHours", "FriendlyCost",
    "PackElixir", "PackGold", "PackDarkElixir", "PackGold2", "PackElixir2",
    "DuelPrizeResourceCap", "AttackCostVillage2", "ElixirCartStorageCap",
    "ResourceScalingPercentage", "ResourceScalingPercentage2", "LeagueTier",
    "UnrankedGoldRewardStarBonus", "UnrankedElixirRewardStarBonus",
    "UnrankedDarkElixirRewardStarBonus", "UnrankedCommonOreRewardStarBonus",
    "UnrankedRareOreRewardStarBonus", "UnrankedEpicOreRewardStarBonus",
    "SeasonPassResourceScalingPercentage", "SeasonPassResourceScalingPercentage2",
    "ScaleByTHPercent", "UnlockStage", "StrengthMaxTroopTypes",
    "StrengthMaxSpellTypes", "StrengthMaxSiegeTypes", "Mega Cannon", "Hidden",
    "TreasuryGold", "TreasuryElixir", "TreasuryDarkElixir",
    "TreasuryWarGold", "TreasuryWarElixir", "TreasuryWarDarkElixir",
    "Cannon_gearup", "Archer Tower_gearup", "Mortar_gearup",
})

# 大本营等级范围（townhall_levels 行）
_TH_LEVELS = range(1, 19)  # TH1..TH18
_TH_NAMES = frozenset(str(i) for i in _TH_LEVELS)


def _name_to_global_id(rows: list[dict[str, str]]) -> dict[str, int]:
    """Name → GlobalID 映射（取该 Name 首个出现行的 GlobalID；跳过类型行）。

    buildings.csv/traps.csv 每 Name 多等级行共享同一 GlobalID，首个出现行即可。
    """
    mapping: dict[str, int] = {}
    for row in rows:
        name = row.get("Name", "")
        if not name or name == "String":  # 类型行（Name='String'）
            continue
        gid = row.get("GlobalID", "")
        if gid and name not in mapping:
            mapping[name] = int(gid)
    return mapping


def build_instance_counts(
    townhall_rows: list[dict[str, str]],
    buildings_rows: list[dict[str, str]],
    traps_rows: list[dict[str, str]],
) -> dict[str, list[int]]:
    """townhall_levels 主村列 → {"section:dataID": [TH1..TH18 数量]}。

    契约：
    - TH 行 = Name ∈ {"1".."18"}，恒 18 行（缺行/多行 → CatalogError）；
    - 列跳过：CONFIG_COLUMNS、"BB " 前缀、TH 行全空（'' 或 '0'）、非整数值
      （类型行不计入判定；非空非整数 → CatalogError 而非跳过，fail loud）；
    - 列名 join buildings.csv.Name（→ "buildings"）与 traps.csv.Name（→ "traps"）
      的 GlobalID；任一非空数量列 join 失败 → CatalogError（消息含列名，fail loud）；
    - 输出键 "section:dataID" 排序，值长度恒 18（index = TH-1）。
    """
    th_rows = [r for r in townhall_rows if r.get("Name") in _TH_NAMES]
    if len(th_rows) != 18:
        raise CatalogError(
            f"townhall_levels 大本营行数 != 18: {len(th_rows)}（行 Name 应为 1..18）")

    buildings_ids = _name_to_global_id(buildings_rows)
    traps_ids = _name_to_global_id(traps_rows)

    counts: dict[str, list[int]] = {}
    for col in townhall_rows[0].keys():
        if col == "Name" or col in CONFIG_COLUMNS or col.startswith("BB "):
            continue
        raw = [r.get(col, "") for r in th_rows]
        if all(v in ("", "0") for v in raw):  # TH 行全空列跳过（类型行不计入）
            continue
        values: list[int] = []
        previous = 0  # '' = 沿用上一 TH（首值前 = 0）
        for v in raw:
            if v == "":
                values.append(previous)
            else:
                try:
                    previous = int(v)
                except ValueError:
                    raise CatalogError(
                        f"townhall_levels 列 {col!r} 含非整数值: {v!r}") from None
                values.append(previous)
        if col in buildings_ids:
            section, data_id = "buildings", buildings_ids[col]
        elif col in traps_ids:
            section, data_id = "traps", traps_ids[col]
        else:
            raise CatalogError(
                f"townhall_levels 列 {col!r} 无法 join buildings.csv/traps.csv 的 Name")
        counts[f"{section}:{data_id}"] = values

    return {k: counts[k] for k in sorted(counts)}
