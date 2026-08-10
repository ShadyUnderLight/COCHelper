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
from .display_categories import apply_display_categories
from .durations import classify_duration
from .errors import CatalogError
from .fingerprint import sha256_bytes, sha256_file
from .instance_counts import build_instance_counts
from .lifecycle import apply_lifecycle
from .model import Catalog, CatalogItem, catalog_to_dict
from .tables import TABLES


def _infer_game_version(build_tag: str) -> str:
    """'18_400_7' → '18.400.7'：split("_") 取前 3 段 join "."；不足 3 段则 replace("_",".")。"""
    parts = build_tag.split("_")
    if len(parts) >= 3:
        return ".".join(parts[:3])
    return build_tag.replace("_", ".")


def _check_columns(table: str, rows: list[dict], required: list[str]) -> None:
    """表头对照必需列，缺失即 CatalogError（fail loud，不静默降级）。

    rows[0] 的 keys 即 CSV 表头（DictReader 以首行为键）；空表跳过（无数据可查）。
    """
    if not rows:
        return
    header = set(rows[0].keys())
    missing = [c for c in required if c not in header]
    if missing:
        raise CatalogError(f"{table} 缺少必需列: {missing}")


def _spec_required_columns(spec) -> list[str]:
    """spec 声明的必需列：等级列 + 时间列 + 资源/成本/门槛 + 图标/外观列。"""
    cols = [spec.level_column]
    cols += list(spec.time_columns)
    for c in (spec.resource_column, spec.cost_column,
              spec.town_hall_column, spec.laboratory_column):
        if c:
            cols.append(c)
    cols += list(spec.icon_columns) + list(spec.visual_columns)
    return cols


def _build_catalog_items(
    archive: zipfile.ZipFile,
    localized: dict[str, str],
    require_all_tables: bool = True,
) -> list:
    items = []
    names = set(archive.namelist())
    for spec in TABLES:
        table_path = "assets/logic/" + spec.table
        if table_path not in names:
            if require_all_tables:
                raise CatalogError(f"APK 缺少逻辑表: {spec.table}")
            continue
        table_rows = rows(archive, spec.table)
        _check_columns(spec.table, table_rows, _spec_required_columns(spec))
        if spec.join_upgrade_data:
            if "assets/logic/upgrade_data.csv" not in names:
                if require_all_tables:
                    raise CatalogError("APK 缺少逻辑表: upgrade_data.csv")
                continue
            upgrade_rows = rows(archive, "upgrade_data.csv")
            _check_columns("upgrade_data.csv", upgrade_rows, [
                "UpgradeLevel", "UpgradeTimeDays", "UpgradeTimeHours",
                "UpgradeTimeMinutes", "UpgradeTimeSeconds"])
            items.extend(build_guardians(table_rows, upgrade_rows, localized))
        else:
            items.extend(build_items(table_rows, spec, localized))
    items.sort(key=lambda i: (i.section, i.dataID))
    return items


def counts_for(items: list[CatalogItem]) -> dict:
    """目录计数（含时长语义拆分，Issue #74b）。catalog.py 生成与 validate.py
    重算共用同一实现，防双实现漂移。

    - missingTime 语义保持：全部 durationSeconds is None（含 unknown 桶）；
    - 拆分桶：timed / instant / notApplicable / initialLevel / sourceMissing /
      parseFailed（语义见 durations.classify_duration）；
    - 不变量：timed + instant + missingTime == levels。
    """
    levels = [lv for item in items for lv in item.levels]
    buckets: dict[str, int] = {}
    for lv in levels:
        bucket = classify_duration(lv.durationSeconds, lv.missingReason)
        buckets[bucket] = buckets.get(bucket, 0) + 1
    return {
        "items": len(items),
        "levels": len(levels),
        "missingTime": buckets.get("unknown", 0) + buckets.get("initialLevel", 0)
            + buckets.get("notApplicable", 0) + buckets.get("sourceMissing", 0)
            + buckets.get("parseFailed", 0),
        "missingIcons": sum(1 for lv in levels if lv.icon and lv.icon.renderedPath is None),
        "timed": buckets.get("timed", 0),
        "instant": buckets.get("instant", 0),
        "notApplicable": buckets.get("notApplicable", 0),
        "initialLevel": buckets.get("initialLevel", 0),
        "sourceMissing": buckets.get("sourceMissing", 0),
        "parseFailed": buckets.get("parseFailed", 0),
        # Issue #75 工作流 C：展示分类分布（只统计 home buildings）
        "displayCategories": {
            "defense": sum(1 for i in items if i.section == "buildings"
                           and i.base == "home" and i.displayCategory == "defense"),
            "military": sum(1 for i in items if i.section == "buildings"
                            and i.base == "home" and i.displayCategory == "military"),
            "craftTable": sum(1 for i in items if i.section == "buildings"
                              and i.base == "home" and i.displayCategory == "craftTable"),
            "uncategorizedBuildings": sum(1 for i in items
                                          if i.section == "buildings"
                                          and i.base == "home"
                                          and i.displayCategory is None),
        },
    }


def generate(
    apk: Path,
    game_version: str | None,
    output_dir: Path,
    locale: str = "zh-CN",
    require_all_tables: bool = True,
) -> Path:
    """从 APK 生成 catalog.json + manifest.json + icons/ 到 output_dir（原子写）。

    game_version 为 None 时从 build.tag 推断。输出目录已存在且非空 → CatalogError。
    require_all_tables=True 时缺任何注册表/upgrade_data.csv → CatalogError（fail loud，
    不产出部分/空目录）；测试用最小合成 APK 可传 False。
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
            items = _build_catalog_items(archive, localized, require_all_tables=require_all_tables)
            # Issue #75 工作流 C：展示分类数据化（分类知识唯一事实源 display_categories.py）
            items = apply_display_categories(items)
            # Issue #98：生命周期事实（声明文件唯一事实源 lifecycle.py，fail loud）
            items = apply_lifecycle(items)
            # Issue #70 阶段 2：townhall_levels → instanceCounts 宇宙
            # （先 build items：缺表/缺列错误优先报，再读宇宙表）
            instance_counts = build_instance_counts(
                rows(archive, "townhall_levels.csv"),
                rows(archive, "buildings.csv"),
                rows(archive, "traps.csv"),
            )
    except zipfile.BadZipFile as exc:
        raise CatalogError(f"APK 不是有效 zip: {apk}") from exc

    catalog = Catalog(schemaVersion=SCHEMA_VERSION, gameVersion=effective_version,
                      locale=locale, items=items)
    counts = counts_for(items)

    # instanceCounts 恒输出（空 dict 也写 {}，字段恒存在契约）
    payload = catalog_to_dict(catalog)
    payload["instanceCounts"] = instance_counts
    catalog_bytes = json.dumps(payload, ensure_ascii=False,
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
