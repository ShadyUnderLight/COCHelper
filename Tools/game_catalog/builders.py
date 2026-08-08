"""表 → CatalogItem 构建器（纯函数，输入已解码行 + 本地化表）。"""

from dataclasses import dataclass

from .durations import parse_duration, parse_optional_int
from .errors import CatalogError
from .model import AssetRef, CatalogLevel, CatalogItem, UpgradeCost
from .names import display_name
from .tables import TABLES, TableSpec, group_blocks, ffill_columns, section_for

SIEGE_PRODUCTION = "Siege Workshop"

INITIAL_LEVEL_REASON = "min_level_initial_no_upgrade"


def parse_upgrade_costs(resources_raw: str, costs_raw: str,
                        separator: str | None) -> list[UpgradeCost] | None:
    """解析升级费用列 → UpgradeCost 数组；None = 无费用数据（表无费用列/资源串空）。

    单值表（separator=None）：
      - 资源串空 → None（金额忽略）
      - 金额空串 → 免费（源 CSV 语义）：amount=0 是真实值，parseFailed=False
      - 金额纯数字 → 正常解析
      - 金额非纯数字 → parseFailed=True（amount=None，rawAmount=原串，
        不 strip——与 parse_optional_int 同一 isdigit 判据；注意：旧格式在此
        输出 None（金额丢弃），现改为 parseFailed 项保留原串，是所有表共性
        的输出变化）
    多值表（separator 非 None）：
      - 按 separator split 后逐段 strip；空段/空白段过滤
      - 资源全空 → None（金额忽略）
      - 按序配对：金额 isdigit → parseFailed=False；否则 parseFailed=True
      - 资源多余：多余项 parseFailed=True（amount=None, rawAmount=""，
        满足不变量 4：rawAmount != None）
      - 金额多余：多余项 parseFailed=True（amount=None, rawAmount=金额原串，
        resource=最后一个资源段）

    不变量（validate.py 强制）：parseFailed=False ⟹ amount 非 None 且 >= 0 且
    rawAmount=None；parseFailed=True ⟹ amount=None 且 rawAmount != None；
    resource/rawResource 恒非空。
    """
    if separator is None:
        if not resources_raw:
            return None
        if not costs_raw:
            # 金额空串 = 免费（源 CSV 语义，如圣诞奇袭等免费升级变体）：
            # amount=0 是真实值，不是解析失败（parseFailed=False）。
            return [UpgradeCost(resource=resources_raw, amount=0,
                                rawResource=resources_raw, rawAmount=None,
                                parseFailed=False)]
        if costs_raw.isdigit():
            return [UpgradeCost(resource=resources_raw, amount=int(costs_raw),
                                rawResource=resources_raw, rawAmount=None,
                                parseFailed=False)]
        return [UpgradeCost(resource=resources_raw, amount=None,
                            rawResource=resources_raw, rawAmount=costs_raw,
                            parseFailed=True)]
    resources = [s.strip() for s in resources_raw.split(separator) if s.strip()]
    if not resources:
        return None
    costs = [s.strip() for s in costs_raw.split(separator) if s.strip()]
    result = [
        UpgradeCost(resource=res, amount=int(cost) if cost.isdigit() else None,
                    rawResource=res,
                    rawAmount=None if cost.isdigit() else cost,
                    parseFailed=not cost.isdigit())
        for res, cost in zip(resources, costs)
    ]
    # 资源多余（无对应金额）：rawAmount="" 满足不变量 4（!= None）
    for res in resources[len(costs):]:
        result.append(UpgradeCost(resource=res, amount=None, rawResource=res,
                                  rawAmount="", parseFailed=True))
    # 金额多余：resource 复用最后一个资源段（保证不变量 6 非空）
    for cost in costs[len(resources):]:
        result.append(UpgradeCost(resource=resources[-1], amount=None,
                                  rawResource=resources[-1], rawAmount=cost,
                                  parseFailed=True))
    return result


@dataclass
class _ParsedRow:
    """单行解析结果：level/自身属性 + 该行的升级属性（语义由 TableSpec 决定）。"""
    level: int
    icon: AssetRef | None
    level_visual: AssetRef | None
    duration: int | None
    missing: str | None
    upgrade_costs: list[UpgradeCost] | None
    town_hall: int | None
    laboratory: int | None


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


def _parse_row(row: dict[str, str], spec: TableSpec) -> _ParsedRow:
    level_value = row.get(spec.level_column, "")
    if not level_value:
        raise CatalogError(f"{spec.table}: 缺少等级列 {spec.level_column}")
    if not level_value.isdigit():
        raise CatalogError(f"{spec.table}: 等级非数字: {level_value!r}")
    level = int(level_value)

    if spec.join_upgrade_data:
        duration, missing = None, None  # 由 guardians join 填充
    elif not spec.time_columns:
        duration, missing = None, "no_time_source"  # 表无时间列（如 equipment）
    else:
        duration, missing = parse_duration(row, spec.time_columns)

    if spec.resource_column:
        resources_raw = row.get(spec.resource_column, "")
        costs_raw = row.get(spec.cost_column, "") if spec.cost_column else ""
        upgrade_costs = parse_upgrade_costs(resources_raw, costs_raw, spec.list_separator)
    else:
        upgrade_costs = None  # 表无费用列 → 无费用数据
    th = parse_optional_int(row.get(spec.town_hall_column, "")) if spec.town_hall_column else None
    lab = parse_optional_int(row.get(spec.laboratory_column, "")) if spec.laboratory_column else None

    return _ParsedRow(
        level=level,
        icon=_icon_ref(row, spec),
        level_visual=_visual_ref(row, spec),
        duration=duration,
        missing=missing,
        upgrade_costs=upgrade_costs,
        town_hall=th,
        laboratory=lab,
    )


def _dedup_by_level(rows: list[_ParsedRow]) -> list[_ParsedRow]:
    """按等级升序去重，保留首个（真实数据偶发重复等级行，如 characters 的
    Defensive Tribal Tag Team lvl13），保证 levels 严格升序契约。"""
    out = sorted(rows, key=lambda r: r.level)
    uniq: list[_ParsedRow] = []
    for rec in out:
        if not uniq or uniq[-1].level != rec.level:
            uniq.append(rec)
    return uniq


def _level_from_row(rec: _ParsedRow) -> CatalogLevel:
    return CatalogLevel(
        level=rec.level,
        durationSeconds=rec.duration,
        missingReason=rec.missing,
        upgradeCosts=rec.upgrade_costs,
        requiredTownHallLevel=rec.town_hall,
        requiredLaboratoryLevel=rec.laboratory,
        icon=rec.icon,
        levelVisual=rec.level_visual,
    )


def _level_initial(level: int, own: _ParsedRow | None) -> CatalogLevel:
    """to_next 表 level 1 = 初始等级：无升级属性，只有自身外观。"""
    return CatalogLevel(
        level=level,
        durationSeconds=None,
        missingReason=INITIAL_LEVEL_REASON,
        upgradeCosts=None,
        requiredTownHallLevel=None,
        requiredLaboratoryLevel=None,
        icon=own.icon if own else None,
        levelVisual=own.level_visual if own else None,
    )


def _build_levels(records: list[_ParsedRow], spec: TableSpec) -> list[CatalogLevel]:
    """按 upgrade_semantics 把行的升级属性映射到等级。

    - to_level（建筑/陷阱）：行 N 的升级属性 → level N（原样）。
    - to_next_level（单位/法术/英雄/宠物/首都单位法术）：行 k-1 的升级属性 → level k
      （k≥2）；最低等级行 = 初始等级（无升级）；行 maxLevel 的升级属性属于不存在的
      level maxLevel+1 → 丢弃。level 值 = 行自身等级（保留原始编号，如战斗直升机
      15..35），icon/visual 跟随自己的行。
    """
    uniq = _dedup_by_level(records)
    if spec.join_upgrade_data:
        # guardians：等级行值即角色真实等级（1..5），join（level-1）在 build_guardians 完成
        return [_level_from_row(rec) for rec in uniq]
    if spec.upgrade_semantics == "to_next_level":
        # level 值 = 行自身等级（保留原始编号，如战斗直升机 15..35）；升级属性来自
        # 上一行：第 idx=0 行（最低等级）= 初始等级无升级；第 i 行的升级属性属于
        # level i+1；最后一行自身的升级属性属于不存在的 maxLevel+1 → 丢弃。
        levels: list[CatalogLevel] = []
        for idx, own in enumerate(uniq):
            if idx == 0:
                levels.append(_level_initial(own.level, own))
                continue
            src = uniq[idx - 1]
            levels.append(CatalogLevel(
                level=own.level,
                durationSeconds=src.duration,
                missingReason=src.missing,
                upgradeCosts=src.upgrade_costs,
                requiredTownHallLevel=src.town_hall,
                requiredLaboratoryLevel=src.laboratory,
                icon=own.icon,
                levelVisual=own.level_visual,
            ))
        return levels
    return [_level_from_row(rec) for rec in uniq]


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

    levels = _build_levels([_parse_row(row, spec) for row in filled], spec)
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

    # 与 build_items 同序分组，逐块取 UpgradeData 做 join（避免硬编码 id_base）。
    # to_next 语义：升级到 level N 使用 upgrade_data 的 N-1 条（L1→level 2，L4→level 5）；
    # level 1 = 初始等级无升级；join 未命中 → upgrade_data_missing。
    blocks = group_blocks(rows)
    for item, block in zip(items, blocks):
        join_key = ffill_columns(block.rows, ("UpgradeData",))[0].get("UpgradeData", "")
        if not join_key:
            raise CatalogError(f"guardians: {item.name} 缺少 UpgradeData")
        for level in item.levels:
            if level.level == 1:
                level.durationSeconds = None
                level.missingReason = INITIAL_LEVEL_REASON
                level.upgradeCosts = None
                continue
            hit = index.get((join_key, level.level - 1))
            if hit is None:
                level.durationSeconds = None
                level.missingReason = "upgrade_data_missing"
                level.upgradeCosts = None
                continue
            duration, missing = parse_duration(hit, ("UpgradeTimeDays", "UpgradeTimeHours",
                                                      "UpgradeTimeMinutes", "UpgradeTimeSeconds"))
            level.durationSeconds = duration
            level.missingReason = missing
            # 单值语义：UpgradeResource/AltUpgradeResource + UpgradeCost → 单元素数组；
            # 资源串空（join 行无资源值）→ None
            res_raw = hit.get("UpgradeResource") or hit.get("AltUpgradeResource") or ""
            level.upgradeCosts = parse_upgrade_costs(res_raw, hit.get("UpgradeCost", ""), None)
    return items
