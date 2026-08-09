"""建筑展示分类（displayCategory）：从 Swift 白名单迁移到 catalog 数据。

Issue #75 工作流 C。**本文件是分类知识的唯一事实源——改分类必须改本文件**，
不要在其他地方维护第二份 ID 集合（防双源漂移；Swift 侧白名单由 Task 2 删除）。

分类结论（与 Swift BuildingDisplayCategoryRules 现状逐字一致，基础设施迁移不改变分类）：
- 73 个 home buildings = 33 分类（21 defense + 11 military + 1 craftTable 1000097）+ 40 兜底；
- 兜底项维持现状契约（含 TH17 新建筑 1000093/1000098/1000099/1000100 等），
  是否应归入某分类待裁决（注释登记，勿在未裁决时静默改动）。

#65（craft_table_catalog 数据化）落地后可考虑把 CRAFT_TABLE_DATA_ID 也并入数据。
"""

from dataclasses import replace

from .model import CatalogItem

# 防御建筑（Swift defenseDataIDs，21 项）
DEFENSE_DATA_IDS: frozenset[int] = frozenset({
    1000008, 1000009, 1000010, 1000011, 1000012, 1000013, 1000019,
    1000021, 1000027, 1000028, 1000031, 1000032, 1000067, 1000072,
    1000077, 1000079, 1000084, 1000085, 1000086, 1000089, 1000102,
})

# 军事建筑（Swift militaryDataIDs，11 项）
MILITARY_DATA_IDS: frozenset[int] = frozenset({
    1000000, 1000006, 1000007, 1000014, 1000020, 1000026, 1000029,
    1000059, 1000068, 1000070, 1000071,
})

# 精制台（Swift craftTableDataID）
CRAFT_TABLE_DATA_ID: int = 1000097

# 兜底：其余全部 home buildings（73 − 33 = 40 项）。从 bundled catalog 实证核对：
# 所有 home buildings 中不在 defense/military/craftTable 集合的 dataID 精确等于此表。
# 现状契约：维持兜底（displayCategory = None），是否分类待裁决。
INTENTIONAL_FALLBACK_DATA_IDS: frozenset[int] = frozenset({
    # 资源建筑
    1000002, 1000003, 1000004, 1000005, 1000023, 1000024,
    # 大本营（含 TH17 升级中/TH18 预告变体）
    1000001, 1000103, 1000104,
    # 英雄神坛
    1000022, 1000025, 1000030, 1000066,
    # 建筑工人小屋 / 小博木屋
    1000015, 1000064,
    # 哥布林/单人战役
    1000016, 1000017, 1000018, 1000061, 1000069,
    # 不祥洞窟（单人）
    1000062, 1000074, 1000076,
    # 教学/未使用/事件加农炮变体
    1000060, 1000087, 1000088, 1000094, 1000095, 1000096,
    # 笼子/装饰/事件建筑
    1000073, 1000075, 1000083, 1000090, 1000091, 1000092,
    1000101,
    # TH17 新建筑（是否分类待裁决）
    1000093, 1000098, 1000099, 1000100,
})

# displayCategory 闭枚举（validate 校验用）
DISPLAY_CATEGORIES: frozenset[str] = frozenset({"defense", "military", "craftTable"})


def _category_for(item: CatalogItem) -> str | None:
    """单个 item 的分类：仅 home buildings 参与；其他 section/base 恒 None（兜底）。"""
    if item.section != "buildings" or item.base != "home":
        return None
    if item.dataID == CRAFT_TABLE_DATA_ID:
        return "craftTable"
    if item.dataID in DEFENSE_DATA_IDS:
        return "defense"
    if item.dataID in MILITARY_DATA_IDS:
        return "military"
    return None


def apply_display_categories(items: list[CatalogItem]) -> list[CatalogItem]:
    """对 items 应用展示分类，返回新列表（不改入参，纯函数）。

    - home buildings：命中 defense/military/craftTable → 对应分类；否则 None（兜底）；
    - 其他 section/base（buildings2、units、capital_* 等）→ 恒 None。
    """
    return [replace(item, displayCategory=_category_for(item)) for item in items]


def uncategorized_home_buildings(items: list[CatalogItem]) -> list[tuple[int, str]]:
    """未分类 home buildings 的 (dataID, name) 列表（供 validate / 标注统计用）。"""
    return [(i.dataID, i.name) for i in items
            if i.section == "buildings" and i.base == "home"
            and i.displayCategory is None]
