#!/usr/bin/env python3
"""Generate the bundled Chinese account-ID catalog from a Clash of Clans APK.

The APK stores its CSV assets in Supercell's small LZMA wrapper. This script
decodes only the CSV tables needed by the village export and writes a compact
section-aware JSON catalog. It intentionally never copies the APK or account
export into the repository.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import lzma
import re
import zipfile
from pathlib import Path


def decode_asset(archive: zipfile.ZipFile, path: str) -> str:
    packed = archive.read(path)
    decoded = lzma.decompress(packed[:8] + b"\0" * 4 + packed[8:])
    return decoded.decode("utf-8-sig")


def rows(archive: zipfile.ZipFile, table: str) -> list[dict[str, str]]:
    text = decode_asset(archive, "assets/logic/" + table)
    return list(csv.DictReader(io.StringIO(text)))


def localization(archive: zipfile.ZipFile) -> dict[str, str]:
    values: dict[str, str] = {}
    for row in csv.DictReader(io.StringIO(decode_asset(archive, "assets/localization/cn.csv"))):
        if row.get("TID"):
            values[row["TID"]] = clean_name(row.get("CN", ""))

    # Patch rows use a wider, multi-locale schema. Apply Chinese values last.
    for row in csv.DictReader(io.StringIO(decode_asset(archive, "assets/localization/texts_patch.csv"))):
        if row.get("TID") and row.get("CN"):
            values[row["TID"]] = clean_name(row["CN"])
    return values


def clean_name(value: str) -> str:
    return value.replace("\\q", "").replace("\\n", " ").strip()


def key(section: str, data_id: int) -> str:
    return section + ":" + str(data_id)


def is_real_name(value: str | None) -> bool:
    return bool(value and value != "String")


def display_name(row: dict[str, str], localized: dict[str, str]) -> str:
    tid = row.get("TID", "")
    translated = localized.get(tid, "")
    if translated:
        return translated

    raw_name = clean_name(row.get("Name", ""))
    scenery_match = re.fullmatch(r"CN_VillageBackground(\d+)", raw_name)
    if scenery_match:
        return "场景 " + scenery_match.group(1)
    return raw_name


ARCHETYPE_NAMES = {
    "HookTower": "钩索塔",
    "FlameSpinner": "旋转喷火器",
    "CrusherMortar": "碎岩迫击炮",
    "LazyLaser": "懒惰激光",
    "SlowdownTower": "减速塔",
    "HeroBooster": "英雄助推器",
    "LogLobber": "掷木器",
    "SunBeam": "太阳光束",
    "SDRoaster": "熔岩火炮",
    "SDAirBombs": "防空炸弹",
    "SDLavaLauncher": "熔岩发射器",
    "Inferno Candle": "火热蜡烛",
    "InfernoCandle": "火热蜡烛",
    "Headhunter Tower": "英雄猎台",
    "HeadhunterTower": "英雄猎台",
    "Cake Thrower": "蛋糕投掷器",
    "CakeThrower": "蛋糕投掷器",
}


def seasonal_name(row: dict[str, str], table: str, localized: dict[str, str]) -> str:
    raw_name = clean_name(row.get("Name", ""))
    if table == "seasonal_defense_archetypes.csv":
        return ARCHETYPE_NAMES.get(raw_name, raw_name)

    translated = display_name(row, localized)
    if translated != raw_name:
        return translated

    suffixes = (
        ("HPModule", "生命值模组"),
        ("AttackModule", "攻击力模组"),
        ("EffectModule", "效果模组"),
    )
    for suffix, suffix_name in suffixes:
        if raw_name.endswith(suffix):
            return ARCHETYPE_NAMES.get(raw_name[: -len(suffix)], raw_name[: -len(suffix)]) + suffix_name
    return raw_name


def add_direct(
    entries: dict[str, str],
    archive: zipfile.ZipFile,
    localized: dict[str, str],
    table: str,
    sections: tuple[str, ...],
) -> None:
    for row in rows(archive, table):
        if not is_real_name(row.get("Name")) or not row.get("GlobalID"):
            continue
        name = display_name(row, localized)
        if not name:
            continue
        data_id = int(row["GlobalID"])
        for section in sections:
            entries.setdefault(key(section, data_id), name)


def add_grouped(
    entries: dict[str, str],
    archive: zipfile.ZipFile,
    localized: dict[str, str],
    table: str,
    base: int,
    sections: tuple[str, ...],
    special_table: str | None = None,
) -> None:
    ordinal = 0
    for row in rows(archive, table):
        if not is_real_name(row.get("Name")):
            continue
        name = seasonal_name(row, table, localized) if special_table else display_name(row, localized)
        if name:
            for section in sections:
                entries.setdefault(key(section, base + ordinal), name)
        ordinal += 1


def add_indexed(
    entries: dict[str, str],
    archive: zipfile.ZipFile,
    localized: dict[str, str],
    table: str,
    base: int,
    sections: tuple[str, ...],
) -> None:
    # Blank rows are retained in the index for stable IDs (skins and parts).
    index = 0
    for row in rows(archive, table):
        if row.get("Name") == "String":
            continue
        if is_real_name(row.get("Name")):
            name = display_name(row, localized)
            if name:
                for section in sections:
                    entries.setdefault(key(section, base + index), name)
        index += 1


def add_nonempty_indexed(
    entries: dict[str, str],
    archive: zipfile.ZipFile,
    localized: dict[str, str],
    table: str,
    base: int,
    sections: tuple[str, ...],
) -> None:
    # Background tables do not allocate IDs for blank placeholder rows.
    index = 0
    for row in rows(archive, table):
        if row.get("Name") == "String":
            continue
        if not is_real_name(row.get("Name")):
            continue
        name = display_name(row, localized)
        if name:
            for section in sections:
                entries.setdefault(key(section, base + index), name)
        index += 1


def build_catalog(apk: Path) -> dict[str, str]:
    entries: dict[str, str] = {}
    with zipfile.ZipFile(apk) as archive:
        localized = localization(archive)

        add_direct(entries, archive, localized, "buildings.csv", ("buildings", "buildings2"))
        add_direct(entries, archive, localized, "traps.csv", ("traps", "traps2"))
        add_direct(entries, archive, localized, "decos.csv", ("decos", "decos2"))
        add_direct(entries, archive, localized, "characters.csv", ("units", "units2", "siege_machines"))
        add_direct(entries, archive, localized, "spells.csv", ("spells",))

        add_grouped(entries, archive, localized, "heroes.csv", 28_000_000, ("heroes", "heroes2"))
        add_grouped(entries, archive, localized, "pets.csv", 73_000_000, ("pets",))
        add_grouped(entries, archive, localized, "character_items.csv", 90_000_000, ("equipment",))
        add_grouped(entries, archive, localized, "villager_apprentices.csv", 93_000_000, ("helpers",))
        add_grouped(entries, archive, localized, "guardians.csv", 107_000_000, ("guardians",))
        add_grouped(
            entries,
            archive,
            localized,
            "seasonal_defense_archetypes.csv",
            103_000_000,
            ("types",),
            special_table="seasonal_defense_archetypes.csv",
        )
        add_grouped(
            entries,
            archive,
            localized,
            "seasonal_defense_modules.csv",
            102_000_000,
            ("modules",),
            special_table="seasonal_defense_modules.csv",
        )

        add_indexed(entries, archive, localized, "obstacles.csv", 8_000_000, ("obstacles", "obstacles2"))
        add_indexed(entries, archive, localized, "building_parts.csv", 82_000_000, ("house_parts",))
        add_indexed(entries, archive, localized, "skins.csv", 52_000_000, ("skins", "skins2"))
        add_nonempty_indexed(entries, archive, localized, "village_backgrounds.csv", 60_000_000, ("sceneries", "sceneries2"))

    return dict(sorted(entries.items(), key=lambda item: (item[0].split(":", 1)[0], int(item[0].split(":", 1)[1]))))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    payload = {
        "schemaVersion": 1,
        "source": "Clash of Clans APK localized logic tables",
        "entries": build_catalog(args.apk),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("wrote", len(payload["entries"]), "entries to", args.output)


if __name__ == "__main__":
    main()
