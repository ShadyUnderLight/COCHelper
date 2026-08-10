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

fail-loud：APK 不存在 / 表缺失 / 列缺失 / 等级查不到 / BS 非数字或越界 →
CatalogError + exit 1，不写任何文件（写回前完成全部检查与构建）。

用法:
  python3 Tools/annotate_blacksmith_levels.py \\
      --apk /path/to/base.apk --dir Sources/COCHelperCore/GameCatalog/18.400.13
"""

import argparse
import csv
import io
import json
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from game_catalog.apk import decode_asset
from game_catalog.catalog import counts_for
from game_catalog.errors import CatalogError
from game_catalog.fingerprint import sha256_bytes
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

    try:
        with zipfile.ZipFile(apk_path) as archive:
            # 表缺失时 decode_asset 抛 CatalogError（"APK 缺少资源"）
            mapping = build_bs_mapping(
                decode_asset(archive, "assets/logic/" + CHARACTER_ITEMS_TABLE))
    except zipfile.BadZipFile as exc:
        raise CatalogError(f"APK 不是有效 zip: {apk_path}") from exc

    raw = json.loads(catalog_path.read_text(encoding="utf-8"))
    catalog = catalog_from_dict(raw)

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
    catalog_path.write_bytes(catalog_bytes)

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for entry in manifest.get("generatedFiles", []):
        if entry.get("path") == "catalog.json":
            entry["sha256"] = sha256_bytes(catalog_bytes)
            entry["size"] = len(catalog_bytes)
    counts = counts_for(catalog.items)
    manifest.setdefault("counts", {}).update(counts)
    manifest_bytes = json.dumps(manifest, ensure_ascii=False, indent=2,
                                sort_keys=True).encode("utf-8") + b"\n"
    manifest_path.write_bytes(manifest_bytes)

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
