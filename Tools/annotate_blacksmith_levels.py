#!/usr/bin/env python3
"""在既有 catalog 目录上回填 equipment 的 requiredBlacksmithLevel（Issue #97 Task 2）。

仓库有 APK（与 bundled 目录同源）→ 从 assets/logic/character_items.csv 读
RequiredBlacksmithLevel 列，按生成器契约 (dataID, level) 构建映射，回填既有
catalog.json + 重算 manifest.json（幂等：重复运行不产生 diff）。

与 annotate_display_categories.py 同构：读 catalog.json → catalog_from_dict →
改字段 → catalog_to_dict 序列化（ensure_ascii=False, indent=2, sort_keys=True
+ "\\n"）→ 重算 catalog.json 的 sha256/size → 写回 manifest.json（counts 刷新，
其他 generatedFiles 条目不动）；instanceCounts 保留。

dataID 契约（与生成器完全一致，见 tables.py character_items spec 的
id_base 与 builders.py _make_item 的 data_id = spec.id_base + ordinal；
本脚本从该 spec 读 id_base/level_column/blacksmith_column，不双处硬编码）：
  - group_blocks 按 Name 非空行切块（继承行并入所属块），块序号即 ordinal；
  - deprecated 记录同样占 ordinal；
  - 行 Level 即等级（equipment 是 to_level 语义：行 N 的门槛属于 level N）。

fail-loud（外部评审 P1 硬化）：APK 不存在 / APK build.tag 与 manifest.buildTag
不一致 / APK SHA-256 与 manifest.sourceFingerprint 不一致 / manifest 畸形或缺
generatedFiles.catalog.json 条目 / 表缺失 / 列缺失 / 等级查不到 / BS 非数字或
越界 → CatalogError + exit 1，不写任何文件（全部校验与构建在写回前完成；
catalog.json + manifest.json 以 tmp + os.replace 双文件原子写回）。

用法:
  python3 Tools/annotate_blacksmith_levels.py \\
      --apk /path/to/base.apk --dir Sources/COCHelperCore/GameCatalog/18.400.13
"""

import argparse
import csv
import io
import json
import os
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from game_catalog.apk import decode_asset, read_build_tag
from game_catalog.catalog import counts_for
from game_catalog.errors import CatalogError
from game_catalog.fingerprint import sha256_bytes, sha256_file
from game_catalog.model import catalog_from_dict, catalog_to_dict
from game_catalog.tables import TABLES, group_blocks
from game_catalog import BLACKSMITH_LEVEL_MIN, BLACKSMITH_LEVEL_MAX

CHARACTER_ITEMS_TABLE = "character_items.csv"
# 单一事实源：dataID 基址、等级列、BS 列一律读 tables.py 的 character_items TableSpec，
# 不在此双处硬编码（builders.py 反先例："避免硬编码 id_base"）。
_ITEM_SPEC = next(s for s in TABLES if s.table == CHARACTER_ITEMS_TABLE)
if _ITEM_SPEC.id_base is None:
    raise CatalogError(f"{CHARACTER_ITEMS_TABLE} spec 未声明 id_base（dataID 契约破坏）")
if _ITEM_SPEC.blacksmith_column is None:
    raise CatalogError(f"{CHARACTER_ITEMS_TABLE} spec 未声明 blacksmith_column")
EQUIPMENT_ID_BASE = _ITEM_SPEC.id_base
LEVEL_COLUMN = _ITEM_SPEC.level_column
BS_COLUMN = _ITEM_SPEC.blacksmith_column
# 合法域单一事实源：game_catalog/__init__.py（validate.py 共用，防双处漂移）
BS_MIN, BS_MAX = BLACKSMITH_LEVEL_MIN, BLACKSMITH_LEVEL_MAX


def build_bs_mapping(csv_text: str) -> dict[tuple[int, int], int]:
    """解析 character_items.csv → {(dataID, level): requiredBlacksmithLevel}。

    与生成器契约一致（见模块 docstring）：group_blocks 分块 → 块序号即 ordinal
    → dataID = EQUIPMENT_ID_BASE + ordinal；块内逐行取 (LEVEL_COLUMN, BS_COLUMN)。
    Name 空行（继承行）由 group_blocks 归入所属块，无需 forward-fill。
    """
    reader = csv.DictReader(io.StringIO(csv_text))
    raw_rows = [{k: (v or "").strip() for k, v in row.items() if k} for row in reader]
    if not raw_rows:
        raise CatalogError(f"{CHARACTER_ITEMS_TABLE} 为空（无数据行）")
    header = set(raw_rows[0].keys())
    missing = [c for c in (LEVEL_COLUMN, BS_COLUMN) if c not in header]
    if missing:
        raise CatalogError(f"{CHARACTER_ITEMS_TABLE} 缺少必需列: {missing}")

    mapping: dict[tuple[int, int], int] = {}
    for ordinal, block in enumerate(group_blocks(raw_rows)):
        data_id = EQUIPMENT_ID_BASE + ordinal
        for row in block.rows:
            level_raw = row.get(LEVEL_COLUMN, "")
            bs_raw = row.get(BS_COLUMN, "")
            if not level_raw.isdigit():
                raise CatalogError(
                    f"{CHARACTER_ITEMS_TABLE}: {block.name} 等级非数字: {level_raw!r}")
            if not bs_raw.isdigit():
                raise CatalogError(
                    f"{CHARACTER_ITEMS_TABLE}: {block.name} level {level_raw} "
                    f"{BS_COLUMN} 非数字: {bs_raw!r}")
            bs = int(bs_raw)
            if not BS_MIN <= bs <= BS_MAX:
                raise CatalogError(
                    f"{CHARACTER_ITEMS_TABLE}: {block.name} level {level_raw} "
                    f"RequiredBlacksmithLevel={bs} 超出合法域 {BS_MIN}...{BS_MAX}")
            key = (data_id, int(level_raw))
            if key in mapping:
                raise CatalogError(
                    f"{CHARACTER_ITEMS_TABLE}: 重复键 {key}（块内重复等级）")
            mapping[key] = bs
    if not mapping:
        raise CatalogError(f"{CHARACTER_ITEMS_TABLE}: 无有效等级行")
    return mapping


def annotate_directory(apk: str | Path, dir_path: str | Path) -> dict:
    """从 APK 回填 catalog 目录的 equipment requiredBlacksmithLevel。幂等。

    **写回前置校验（外部评审 P1）——任何失败都不落盘：**
    - manifest.json 必须可解析、含 buildTag/sourceFingerprint、且
      generatedFiles 含 catalog.json 条目（否则无法重算哈希 → fail loud）；
    - APK 的 build.tag 必须与 manifest.buildTag 一致（换用其他版本 APK 会
      写入错误版本的门槛数据 → fail loud）；
    - APK 文件的 SHA-256 必须与 manifest.sourceFingerprint 一致（目录生成
      时的原 APK 溯源契约，防同版本不同字节的 APK 数据漂移）。
    全部校验 + 映射构建 + catalog 回填完成后，catalog.json / manifest.json
    以「同目录 tmp + os.replace」双文件原子写回（单文件原子；两个 replace
    之间崩溃的窗口极小，且 validator 的 generatedFiles 哈希比对可检测，
    重跑幂等修复）。

    返回统计：items=回填件数、levels=回填等级数、mapping=映射总条数、
    unused=映射中未被目录消费的条数（>0 时 main 向 stderr 打 dataID 契约漂移
    提示，不阻断——目录生成时的 APK 版本不可知）。
    """
    apk_path = Path(apk)
    d = Path(dir_path)
    catalog_path = d / "catalog.json"
    manifest_path = d / "manifest.json"

    if not apk_path.is_file():
        raise CatalogError(f"APK 不存在: {apk_path}")
    if not catalog_path.is_file():
        raise CatalogError(f"catalog.json 不存在: {catalog_path}")
    if not manifest_path.is_file():
        raise CatalogError(f"manifest.json 不存在: {manifest_path}")

    # ---- P1-2a：写回前解析并校验 manifest（畸形 manifest 不得留下半写入目录）----
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, ValueError, TypeError) as exc:
        raise CatalogError(f"manifest.json 解析失败: {exc}") from exc
    if not isinstance(manifest, dict):
        raise CatalogError("manifest.json 顶层必须是对象")
    manifest_build_tag = manifest.get("buildTag")
    manifest_fingerprint = manifest.get("sourceFingerprint")
    if not manifest_build_tag:
        raise CatalogError("manifest.json 缺少 buildTag（目录 provenance 不完整）")
    if not manifest_fingerprint:
        raise CatalogError("manifest.json 缺少 sourceFingerprint（目录 provenance 不完整）")
    gen = manifest.get("generatedFiles")
    if not isinstance(gen, list) or not any(
            isinstance(e, dict) and e.get("path") == "catalog.json" for e in gen):
        raise CatalogError(
            "manifest.json 缺少 generatedFiles.catalog.json 条目（无法重算哈希）")

    try:
        with zipfile.ZipFile(apk_path) as archive:
            # ---- P1-1：APK 版本/来源契约（换用不同 APK 不得静默成功）----
            apk_build_tag = read_build_tag(archive)
            if apk_build_tag != manifest_build_tag:
                raise CatalogError(
                    f"APK build.tag={apk_build_tag!r} 与 manifest buildTag="
                    f"{manifest_build_tag!r} 不一致（请使用与目录同版本的 APK）")
            # 表缺失时 decode_asset 抛 CatalogError（"APK 缺少资源"）
            mapping = build_bs_mapping(
                decode_asset(archive, "assets/logic/" + CHARACTER_ITEMS_TABLE))
    except zipfile.BadZipFile as exc:
        raise CatalogError(f"APK 不是有效 zip: {apk_path}") from exc
    # APK 文件 SHA-256 溯源（zip 内容读取后、任何写盘前）
    apk_fingerprint = sha256_file(apk_path)
    if apk_fingerprint != manifest_fingerprint:
        raise CatalogError(
            f"APK SHA-256 与 manifest sourceFingerprint 不一致"
            f"（请使用生成目录时的原 APK 文件）")

    try:
        raw = json.loads(catalog_path.read_text(encoding="utf-8"))
        catalog = catalog_from_dict(raw)
    except (json.JSONDecodeError, OSError, ValueError, TypeError,
            KeyError, AttributeError) as exc:
        raise CatalogError(f"catalog.json 解析失败: {exc}") from exc

    # 回填：仅 equipment；查不到 → fail loud（防 dataID 错位静默）。
    annotated_items = 0
    for item in catalog.items:
        if item.section != "equipment":
            continue
        annotated_items += 1
        for level in item.levels:
            bs = mapping.get((item.dataID, level.level))
            if bs is None:
                raise CatalogError(
                    f"equipment {item.section}:{item.dataID} ({item.name}) "
                    f"level {level.level} 查不到 RequiredBlacksmithLevel"
                    f"（APK 与目录版本错位或 dataID 契约漂移？）")
            level.requiredBlacksmithLevel = bs

    payload = catalog_to_dict(catalog)
    if "instanceCounts" in raw:
        payload["instanceCounts"] = raw["instanceCounts"]
    catalog_bytes = json.dumps(payload, ensure_ascii=False, indent=2,
                               sort_keys=True).encode("utf-8") + b"\n"

    # ---- P1-2b：manifest 内容全部在内存中构建完成后，双文件原子写回 ----
    for entry in manifest["generatedFiles"]:
        if isinstance(entry, dict) and entry.get("path") == "catalog.json":
            entry["sha256"] = sha256_bytes(catalog_bytes)
            entry["size"] = len(catalog_bytes)
    counts = counts_for(catalog.items)
    try:
        manifest.setdefault("counts", {}).update(counts)
    except (AttributeError, TypeError) as exc:
        raise CatalogError(f"manifest.json counts 字段非法: {exc}") from exc
    manifest_bytes = json.dumps(manifest, ensure_ascii=False, indent=2,
                                sort_keys=True).encode("utf-8") + b"\n"

    for target, data in ((catalog_path, catalog_bytes),
                         (manifest_path, manifest_bytes)):
        tmp = target.with_name(target.name + ".tmp")
        tmp.write_bytes(data)
        os.replace(tmp, target)

    looked_up = sum(1 for item in catalog.items if item.section == "equipment"
                    for _ in item.levels)
    return {
        "items": annotated_items,
        "levels": looked_up,
        "mapping": len(mapping),
        "unused": len(mapping) - looked_up,
        "counts": counts,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="从 APK 回填 catalog 目录 equipment 的 requiredBlacksmithLevel")
    parser.add_argument("--apk", type=Path, required=True, help="真实 APK 路径")
    parser.add_argument("--dir", type=Path, required=True,
                        help="catalog 目录（含 catalog.json + manifest.json）")
    args = parser.parse_args(argv)

    try:
        result = annotate_directory(args.apk, args.dir)
    except CatalogError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"回填完成: equipment={result['items']} 件, 等级 {result['levels']} 个, "
          f"映射 {result['mapping']} 条")
    if result["unused"] > 0:
        print(f"warning: 映射有 {result['unused']} 条未被目录消费（APK 比目录新/多，"
              f"可能 dataID 契约漂移；目录生成时的 APK 版本不可知，不阻断）",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
