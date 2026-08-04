"""表 → CatalogItem 构建器（纯函数，输入已解码行 + 本地化表）。"""

from .durations import parse_duration, parse_optional_int
from .errors import CatalogError
from .model import AssetRef, CatalogLevel, CatalogItem
from .names import display_name
from .tables import TABLES, TableSpec, group_blocks, ffill_columns, section_for

SIEGE_PRODUCTION = "Siege Workshop"


def _asset_ref(container: str | None, export_name: str | None,
               missing_reason: str | None = None) -> AssetRef | None:
    if not container and not export_name:
        return None
    return AssetRef(
        container=container or None,
        exportName=export_name or None,
        renderedPath=None,
        missingReason=missing_reason or "icons_not_rendered",
    )


def _icon_ref(row: dict[str, str], spec: TableSpec) -> AssetRef | None:
    if not spec.icon_columns:
        return None
    if len(spec.icon_columns) == 1:
        container, export_name = spec.icon_columns[0], None
    else:
        container, export_name = spec.icon_columns[0], spec.icon_columns[1]
    c, e = row.get(container, ""), row.get(export_name, "") if export_name else ""
    if not c and not e:
        return None
    return _asset_ref(c, e)


def _visual_ref(row: dict[str, str], spec: TableSpec) -> AssetRef | None:
    if not spec.visual_columns:
        return None
    c, e = row.get(spec.visual_columns[0], ""), row.get(spec.visual_columns[1], "")
    if not c and not e:
        return None
    return _asset_ref(c, e, "icons_not_rendered")


def _make_item(
    block_name: str,
    rows: list[dict[str, str]],
    spec: TableSpec,
    localized: dict[str, str],
    ordinal: int,
    section_override: str | None = None,
    category_override: str | None = None,
) -> CatalogItem:
    filled = ffill_columns(rows, spec.fill_columns)
    tid = filled[0].get("TID", "")
    name = display_name(tid, block_name, localized)

    if spec.id_base is not None:
        data_id = spec.id_base + ordinal
    else:
        gid = filled[0].get("GlobalID", "")
        if not gid:
            raise CatalogError(f"{spec.table}: {block_name} 缺少 GlobalID")
        if not gid.isdigit():
            raise CatalogError(f"{spec.table}: {block_name} GlobalID 非数字: {gid!r}")
        data_id = int(gid)

    # base
    if spec.base_default is None:
        base, base_missing = None, "capital_has_no_base"
    elif spec.village_type_column:
        vt = filled[0].get(spec.village_type_column, "")
        base = section_for(vt)
        base_missing = None
    else:
        base, base_missing = spec.base_default, None

    section = section_override or spec.section
    category = category_override or spec.category
    if base == "builder" and spec.section2:
        section = spec.section2
    if base == "builder" and spec.category2:
        category = spec.category2

    deprecated = spec.has_deprecated and filled[0].get("Deprecated", "").upper() == "TRUE"
    item_missing = "deprecated_in_source" if deprecated else None

    levels = []
    for row in filled:
        level_value = row.get(spec.level_column, "")
        if not level_value:
            raise CatalogError(f"{spec.table}: {block_name} 缺少等级列 {spec.level_column}")
        if not level_value.isdigit():
            raise CatalogError(f"{spec.table}: {block_name} 等级非数字: {level_value!r}")
        level = int(level_value)

        if spec.join_upgrade_data:
            duration, missing = None, None  # 由 guardians join 填充
        elif not spec.time_columns:
            duration, missing = None, "no_time_source"  # 表无时间列（如 equipment）
        else:
            duration, missing = parse_duration(row, spec.time_columns)

        resource = row.get(spec.resource_column, "") if spec.resource_column else ""
        cost = parse_optional_int(row.get(spec.cost_column, "")) if spec.cost_column else None
        th = parse_optional_int(row.get(spec.town_hall_column, "")) if spec.town_hall_column else None
        lab = parse_optional_int(row.get(spec.laboratory_column, "")) if spec.laboratory_column else None

        levels.append(CatalogLevel(
            level=level,
            durationSeconds=duration,
            missingReason=missing,
            upgradeResource=resource or None,
            upgradeCost=cost,
            requiredTownHallLevel=th,
            requiredLaboratoryLevel=lab,
            icon=_icon_ref(row, spec),
            levelVisual=_visual_ref(row, spec),
        ))

    levels.sort(key=lambda lv: lv.level)
    # 真实数据偶发重复等级行（如 characters Defensive Tribal Tag Team lvl13），
    # sort 后相邻去重、保留首个，保证 levels 严格升序契约。
    unique: list[CatalogLevel] = []
    for lv in levels:
        if not unique or unique[-1].level != lv.level:
            unique.append(lv)
    levels = unique
    return CatalogItem(
        section=section,
        dataID=data_id,
        category=category,
        base=base,
        baseMissingReason=base_missing,
        name=name,
        maxLevel=levels[-1].level if levels else 0,
        icon=_icon_ref(filled[0], spec),
        levelVisual=_visual_ref(filled[0], spec),
        missingReason=item_missing,
        levels=levels,
    )


def build_items(
    rows: list[dict[str, str]],
    spec: TableSpec,
    localized: dict[str, str],
) -> list[CatalogItem]:
    blocks = group_blocks(rows)
    items: list[CatalogItem] = []
    for ordinal, block in enumerate(blocks):
        section_override = None
        category_override = None
        if spec.table == "characters.csv":
            pb = block.rows[0].get("ProductionBuilding", "")
            if pb == SIEGE_PRODUCTION:
                section_override = "siege_machines"
                category_override = "siegeMachines"
        items.append(_make_item(
            block.name, block.rows, spec, localized, ordinal,
            section_override=section_override, category_override=category_override,
        ))
    return items


def build_guardians(
    rows: list[dict[str, str]],
    upgrade_rows: list[dict[str, str]],
    localized: dict[str, str],
) -> list[CatalogItem]:
    spec = next(s for s in TABLES if s.table == "guardians.csv")
    items = build_items(rows, spec, localized)

    # upgrade_data 索引：(Name, Level) → row
    up_blocks = group_blocks(upgrade_rows)
    index: dict[tuple[str, int], dict[str, str]] = {}
    for block in up_blocks:
        filled = ffill_columns(block.rows, ("Name", "UpgradeResource", "AltUpgradeResource", "UpgradeCost"))
        for row in filled:
            lvl = row.get("UpgradeLevel", "")
            if not lvl.isdigit():
                raise CatalogError(f"upgrade_data: 等级非数字 {lvl!r}")
            key = (block.name, int(lvl))
            if key in index:
                raise CatalogError(f"upgrade_data: 重复键 {key}")
            index[key] = row

    # 与 build_items 同序分组，逐块取 UpgradeData 做 join（避免硬编码 id_base）
    blocks = group_blocks(rows)
    for item, block in zip(items, blocks):
        join_key = ffill_columns(block.rows, ("UpgradeData",))[0].get("UpgradeData", "")
        if not join_key:
            raise CatalogError(f"guardians: {item.name} 缺少 UpgradeData")
        for level in item.levels:
            hit = index.get((join_key, level.level))
            if hit is None:
                level.durationSeconds = None
                level.missingReason = "upgrade_data_missing"
                continue
            duration, missing = parse_duration(hit, ("UpgradeTimeDays", "UpgradeTimeHours",
                                                      "UpgradeTimeMinutes", "UpgradeTimeSeconds"))
            level.durationSeconds = duration
            level.missingReason = missing
            level.upgradeResource = hit.get("UpgradeResource") or hit.get("AltUpgradeResource") or None
            level.upgradeCost = parse_optional_int(hit.get("UpgradeCost", ""))
    return items
