"""编排：读取 APK → 解析全部表 → 生成 Catalog + Manifest → 原子写出。"""

import json
import os
import shutil
import tempfile
import zipfile
from pathlib import Path

from . import SCHEMA_VERSION
from .apk import rows, read_build_tag, localization
from .builders import build_items, build_guardians
from .errors import CatalogError
from .fingerprint import sha256_bytes, sha256_file
from .model import Catalog, catalog_to_dict
from .tables import TABLES


def _infer_game_version(build_tag: str) -> str:
    """'18_400_7' → '18.400.7'：split("_") 取前 3 段 join "."；不足 3 段则 replace("_",".")。"""
    parts = build_tag.split("_")
    if len(parts) >= 3:
        return ".".join(parts[:3])
    return build_tag.replace("_", ".")


def _build_catalog_items(archive: zipfile.ZipFile, localized: dict[str, str]) -> list:
    items = []
    names = set(archive.namelist())
    for spec in TABLES:
        table_path = "assets/logic/" + spec.table
        if table_path not in names:
            continue  # 缺表容忍：测试用最小 APK 只含部分表；真实 APK 全表在场
        table_rows = rows(archive, spec.table)
        if spec.join_upgrade_data:
            if "assets/logic/upgrade_data.csv" not in names:
                continue
            upgrade_rows = rows(archive, "upgrade_data.csv")
            items.extend(build_guardians(table_rows, upgrade_rows, localized))
        else:
            items.extend(build_items(table_rows, spec, localized))
    items.sort(key=lambda i: (i.section, i.dataID))
    return items


def generate(apk: Path, game_version: str | None, output_dir: Path, locale: str = "zh-CN") -> Path:
    """从 APK 生成 catalog.json + manifest.json + icons/ 到 output_dir（原子写）。

    game_version 为 None 时从 build.tag 推断。输出目录已存在且非空 → CatalogError。
    """
    if not Path(apk).is_file():
        raise CatalogError(f"APK 不存在: {apk}")
    out = Path(output_dir)
    if out.exists() and any(out.iterdir()):
        raise CatalogError(f"输出目录已存在且非空（先清空或换目录）: {out}")

    try:
        with zipfile.ZipFile(apk) as archive:
            build_tag = read_build_tag(archive)
            effective_version = game_version or _infer_game_version(build_tag)
            localized = localization(archive)
            items = _build_catalog_items(archive, localized)
    except zipfile.BadZipFile as exc:
        raise CatalogError(f"APK 不是有效 zip: {apk}") from exc

    catalog = Catalog(schemaVersion=SCHEMA_VERSION, gameVersion=effective_version,
                      locale=locale, items=items)
    counts = {
        "items": len(items),
        "levels": sum(len(i.levels) for i in items),
        "missingTime": sum(1 for i in items for lv in i.levels if lv.durationSeconds is None),
        "missingIcons": sum(1 for i in items for lv in i.levels if lv.icon and lv.icon.renderedPath is None),
    }

    catalog_bytes = json.dumps(catalog_to_dict(catalog), ensure_ascii=False,
                               indent=2, sort_keys=True).encode("utf-8") + b"\n"
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "gameVersion": effective_version,
        "buildTag": build_tag,
        "locale": locale,
        "sourceFingerprint": sha256_file(apk),
        "generatedFiles": [
            {"path": "catalog.json", "sha256": sha256_bytes(catalog_bytes),
             "size": len(catalog_bytes)},
            {"path": "icons/", "kind": "directory", "entries": 0},
        ],
        "counts": counts,
    }
    manifest_bytes = json.dumps(manifest, ensure_ascii=False, indent=2,
                                sort_keys=True).encode("utf-8") + b"\n"

    # 原子写：tmp 目录（out.parent 下，同文件系统）+ 整目录单次 os.replace。
    # 整目录替换保证失败不留部分输出（逐文件 replace 的旧方案在两个 replace
    # 之间失败会留下不完整目录）。前置条件已保证 out 不存在或为空目录：
    # out 存在且为空时先 rmdir（空目录可删）再 replace（目标必须不存在或为空）。
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix=".coc-catalog-", dir=str(out.parent)))
    try:
        (tmp / "catalog.json").write_bytes(catalog_bytes)
        (tmp / "manifest.json").write_bytes(manifest_bytes)
        (tmp / "icons").mkdir()
        if out.exists() and out.is_dir() and not any(out.iterdir()):
            os.rmdir(out)
        os.replace(tmp, out)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return out
