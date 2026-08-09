#!/usr/bin/env python3
"""在既有 catalog 目录上标注 displayCategory（Issue #75 工作流 C 主路径）。

仓库无 APK → 无法走 generate() 全量重生成，标注脚本直接改写
catalog.json + manifest.json（幂等：重复运行不产生 diff）。

用法:
  python3 Tools/annotate_display_categories.py --dir Sources/COCHelperCore/GameCatalog/18.400.13

行为:
  - catalog.json：items 逐项应用 apply_display_categories（home buildings 命中
    defense/military/craftTable，其余 None），序列化格式与 generate() 一致
    （ensure_ascii=False, indent=2, sort_keys=True + "\n"）；instanceCounts 保留；
  - manifest.json：catalog.json 条目 sha256/size 重算，counts 刷新
    （counts_for 全量 + displayCategories；blockedIcons/renderedIcons 等快照
    字段保留），其他 generatedFiles 条目不动。
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from game_catalog.catalog import counts_for
from game_catalog.display_categories import (
    apply_display_categories, uncategorized_home_buildings,
)
from game_catalog.fingerprint import sha256_bytes
from game_catalog.model import catalog_from_dict, catalog_to_dict


def annotate_directory(dir_path: str | Path) -> dict:
    """标注一个 catalog 目录，返回统计信息。幂等。"""
    d = Path(dir_path)
    catalog_path = d / "catalog.json"
    manifest_path = d / "manifest.json"

    raw = json.loads(catalog_path.read_text(encoding="utf-8"))
    catalog = catalog_from_dict(raw)
    catalog.items = apply_display_categories(catalog.items)

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

    return {"counts": counts, "uncategorized": uncategorized_home_buildings(catalog.items)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="在既有 catalog 目录上标注 displayCategory")
    parser.add_argument("--dir", type=Path, required=True,
                        help="catalog 目录（含 catalog.json + manifest.json）")
    args = parser.parse_args(argv)

    result = annotate_directory(args.dir)
    dc = result["counts"]["displayCategories"]
    print(f"标注完成: defense={dc['defense']} military={dc['military']} "
          f"craftTable={dc['craftTable']} uncategorized={dc['uncategorizedBuildings']}")
    if result["uncategorized"]:
        print("未分类 home buildings: "
              + ", ".join(f"{data_id}:{name}" for data_id, name in result["uncategorized"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
