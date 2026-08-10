#!/usr/bin/env python3
"""Generate the versioned static catalog for seasonal defense modules.

The normal game catalog intentionally does not join ``types``/``modules``
from an account export.  This generator keeps that boundary explicit while
still making the APK's Defense → Module relationship reproducible.
"""

from __future__ import annotations

import argparse
import json
import sys
import zipfile
from pathlib import Path

from game_catalog.apk import localization, read_build_tag, rows
from game_catalog.durations import parse_duration, parse_optional_int
from game_catalog.lifecycle import lifecycle_for
from game_catalog.tables import ffill_columns, group_blocks
from generate_account_name_catalog import seasonal_name


STAT_TITLES = {
    "HitPoints": "生命值",
    "DamagePerSecond": "每秒伤害",
    "DamagePerHit": "每次伤害",
    "TotalTimeAbilityActiveInBattle": "战斗中效果持续时间",
    "PoisonOnHitSpellLevel": "命中毒药法术等级",
    "AttackRange": "攻击范围",
    "AttackSpeed": "攻击速度",
    "StunTime": "眩晕时间",
    "ProjectileHitSpellExplosionDamage": "投射物命中爆炸伤害",
    "ProjectileHitSpellTotalDamage": "投射物命中总伤害",
    "DamageRadius": "伤害范围",
    "BurstCount": "爆发次数",
    "AuraDefendingHeroDamage": "防守英雄伤害",
    "AuraDefendingHeroHealth": "防守英雄生命值",
}


def split_stat_types(row: dict[str, str]) -> list[str]:
    values = [row.get("StatType", ""), row.get("NextLevelShownStatTypes", "")]
    result: list[str] = []
    for value in values:
        for stat_type in value.split(";"):
            if stat_type and stat_type not in result:
                result.append(stat_type)
    return result


def int_or_none(value: str) -> int | None:
    return parse_optional_int(value)


def build_module_catalog(
    archive: zipfile.ZipFile,
    localized: dict[str, str],
) -> tuple[list[dict[str, object]], dict[str, int]]:
    modules: list[dict[str, object]] = []
    ids_by_name: dict[str, int] = {}
    for ordinal, block in enumerate(group_blocks(rows(archive, "seasonal_defense_modules.csv"))):
        data_id = 102_000_000 + ordinal
        ids_by_name[block.name] = data_id
        filled = ffill_columns(
            block.rows,
            ("SpecialAbility", "StatType", "NextLevelShownStatTypes", "BuildResource", "TownHallLevel", "TID"),
        )
        first = filled[0]
        stat_types = split_stat_types(first)
        modules.append(
            {
                "dataID": data_id,
                "name": seasonal_name(first, "seasonal_defense_modules.csv", localized),
                "sourceName": block.name,
                "specialAbility": first.get("SpecialAbility", ""),
                "statTypes": stat_types,
                "displayTitles": [STAT_TITLES.get(value, value) for value in stat_types],
                "maxLevel": len(block.rows),
                "levels": [
                    {
                        "level": level,
                        "durationSeconds": parse_duration(
                            row,
                            ("BuildTimeD", "BuildTimeH", "BuildTimeM", "BuildTimeS"),
                        )[0],
                        "upgradeResource": row.get("BuildResource") or None,
                        "upgradeCost": int_or_none(row.get("BuildCost", "")),
                        "requiredTownHallLevel": int_or_none(row.get("TownHallLevel", "")),
                    }
                    for level, row in enumerate(filled, start=1)
                ],
            }
        )
    return modules, ids_by_name


def build_catalog(apk: Path, game_version: str) -> dict[str, object]:
    with zipfile.ZipFile(apk) as archive:
        localized = localization(archive)
        modules, module_ids = build_module_catalog(archive, localized)
        defenses: list[dict[str, object]] = []
        for ordinal, block in enumerate(group_blocks(rows(archive, "seasonal_defense_archetypes.csv"))):
            row = ffill_columns(block.rows, ("SpecialAbility", "Modules", "TotalModuleLevelThresholds"))[0]
            module_names = [value for value in row.get("Modules", "").split(";") if value]
            missing = [value for value in module_names if value not in module_ids]
            if missing:
                raise ValueError(f"archetype {block.name} references unknown modules: {missing}")
            defenses.append(
                {
                    "dataID": 103_000_000 + ordinal,
                    # Issue #98：生命周期事实（声明文件唯一事实源，fail loud）
                    "lifecycle": lifecycle_for("buildings", 103_000_000 + ordinal),
                    "name": seasonal_name(row, "seasonal_defense_archetypes.csv", localized),
                    "sourceName": block.name,
                    "specialAbility": row.get("SpecialAbility", ""),
                    "moduleIDs": [module_ids[value] for value in module_names],
                    "totalModuleLevelThresholds": [
                        int(value)
                        for value in row.get("TotalModuleLevelThresholds", "").split(";")
                        if value
                    ],
                }
            )
        return {
            "schemaVersion": 1,
            "gameVersion": game_version,
            "buildTag": read_build_tag(archive),
            "locale": "zh-CN",
            "source": "Clash of Clans APK seasonal defense logic tables",
            "defenses": defenses,
            "modules": modules,
        }


def _update_manifest_craft_entry(output_dir: Path, craft_bytes: bytes) -> None:
    """把 craft_table_catalog.json 条目写入同目录 manifest（幂等，fail loud）。

    Issue #98 审核 P1-2 + 复审 P1：CraftTableCatalog.loadBundled 运行时对账
    manifest 中 craft 条目的 sha256/size（缺条目 → fail-closed 目录不可用）。
    因此登记失败（manifest 缺失/损坏/结构非法）必须 raise 而非告警继续——
    "生成成功但运行时不可用"的三方不一致由生成器前置拦截：main 在登记成功前
    不写 craft 文件（先登记后写盘，失败不留成功状态产物）。
    """
    import hashlib

    from game_catalog.errors import CatalogError

    manifest_path = output_dir / "manifest.json"
    if not manifest_path.is_file():
        raise CatalogError(
            f"manifest.json 不存在（无法登记 craft 条目；"
            f"请先运行 generate_game_catalog.py 生成目录）: {manifest_path}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, ValueError) as exc:
        raise CatalogError(f"manifest.json 损坏（无法登记 craft 条目）: {manifest_path}: {exc}")
    if not isinstance(manifest, dict) or not isinstance(manifest.get("generatedFiles"), list):
        raise CatalogError(f"manifest.json 结构非法（无法登记 craft 条目）: {manifest_path}")
    entry = {
        "path": "craft_table_catalog.json",
        "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
        "size": len(craft_bytes),
    }
    replaced = False
    for i, existing in enumerate(manifest["generatedFiles"]):
        if isinstance(existing, dict) and existing.get("path") == "craft_table_catalog.json":
            manifest["generatedFiles"][i] = entry
            replaced = True
            break
    if not replaced:
        manifest["generatedFiles"].append(entry)
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="生成版本化精制台 Defense/Module 目录")
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--game-version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)

    from game_catalog.errors import CatalogError

    try:
        payload = build_catalog(args.apk, args.game_version)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        craft_bytes = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"
        # Issue #98 复审 P1：先登记 manifest 再写 craft 文件——登记失败（manifest
        # 缺失/损坏）时非零退出且不留下"成功状态产物"（craft 文件未写入）。
        _update_manifest_craft_entry(args.output.parent, craft_bytes)
        args.output.write_bytes(craft_bytes)
    except CatalogError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(
        "wrote",
        len(payload["defenses"]),
        "defenses and",
        len(payload["modules"]),
        "modules to",
        args.output,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
