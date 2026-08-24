#!/usr/bin/env python3
"""生成 Issue #226 性能验收用的 1000+ 城墙匿名 fixture（fixture-equivalent，非真实账号）。"""

from __future__ import annotations

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE = REPO_ROOT / "Tests/COCHelperCoreTests/Fixtures/perf_account_snapshot_home.json"
TARGETS = [
    REPO_ROOT / "Tests/COCHelperCoreTests/Fixtures/perf_account_snapshot_large_walls.json",
]
WALL_DATA_ID = 1_000_008
WALL_SEGMENT_COUNT = 1_005


def main() -> None:
    data = json.loads(SOURCE.read_text(encoding="utf-8"))
    buildings = [
        item
        for item in data.get("buildings", [])
        if item.get("data") not in (WALL_DATA_ID, 1_000_010)
    ]
    for index in range(WALL_SEGMENT_COUNT):
        buildings.append(
            {
                "data": WALL_DATA_ID,
                "lvl": (index % 12) + 1,
                "cnt": 1,
            }
        )
    data["buildings"] = buildings
    data["tag"] = "#PERF-LARGE-WALLS"
    data["timestamp"] = 1_785_736_933
    encoded = json.dumps(data, ensure_ascii=False, indent=1) + "\n"
    for target in TARGETS:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(encoded, encoding="utf-8")
    wall_count = sum(
        item.get("cnt", 1)
        for item in buildings
        if item.get("data") == WALL_DATA_ID
    )
    print(f"Wrote {WALL_SEGMENT_COUNT} wall segments ({wall_count} total count) to:")
    for target in TARGETS:
        print(f"  {target}")


if __name__ == "__main__":
    main()
