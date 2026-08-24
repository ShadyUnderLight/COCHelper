#!/usr/bin/env python3
"""生成 Issue #226 性能验收用的 1000+ 城墙匿名 fixture（fixture-equivalent，非真实账号）。"""

from __future__ import annotations

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE = REPO_ROOT / "Tests/COCHelperCoreTests/Fixtures/perf_account_snapshot_home.json"
# 保留旧单文件（hyphen tag）以兼容现有测试；新增 paired before/after 用合法 tag 供 history Diff 行展开
# Paired 需确保同 lineage 下产生“大量 Wall 变化”的非 duplicate history row。
# 旧的 offset-cycle（0 vs 6）仅产生 3 段残余迁移（histogram 抵消后），不符合 perf 目标。
# 现改为 before 全 Lv1、after 全 Lv12，raw histogram 偏移 = 1005，可稳定产生大变化 row。
TARGETS_SINGLE = [
    REPO_ROOT / "Tests/COCHelperCoreTests/Fixtures/perf_account_snapshot_large_walls.json",
]
TARGETS_PAIRED = [
    (REPO_ROOT / "Tests/COCHelperCoreTests/Fixtures/perf_account_snapshot_large_walls_before.json", 1),
    (REPO_ROOT / "Tests/COCHelperCoreTests/Fixtures/perf_account_snapshot_large_walls_after.json", 12),
]
WALL_DATA_ID = 1_000_008
WALL_SEGMENT_COUNT = 1_005
# 合法 synthetic tag（OfficialPlayerTagValidator.isValid）：# + 大写字母/数字，1-14 字符
PAIRED_TAG = "#LARGEWALL01"


def build_wall_buildings(offset: int) -> list[dict]:
    # 兼容旧 offset-cycle 调用（保留函数以备单文件生成复用）
    base = json.loads(SOURCE.read_text(encoding="utf-8"))
    filtered = [
        item
        for item in base.get("buildings", [])
        if item.get("data") not in (WALL_DATA_ID, 1_000_010)
    ]
    for index in range(WALL_SEGMENT_COUNT):
        filtered.append(
            {
                "data": WALL_DATA_ID,
                "lvl": ((index + offset) % 12) + 1,
                "cnt": 1,
            }
        )
    return filtered


def build_wall_buildings_fixed(lvl: int) -> list[dict]:
    base = json.loads(SOURCE.read_text(encoding="utf-8"))
    filtered = [
        item
        for item in base.get("buildings", [])
        if item.get("data") not in (WALL_DATA_ID, 1_000_010)
    ]
    for _ in range(WALL_SEGMENT_COUNT):
        filtered.append(
            {
                "data": WALL_DATA_ID,
                "lvl": lvl,
                "cnt": 1,
            }
        )
    return filtered


def main() -> None:
    # 单文件（兼容旧测试，保留 hyphen tag 行为）
    data_single = json.loads(SOURCE.read_text(encoding="utf-8"))
    buildings_single = [
        item
        for item in data_single.get("buildings", [])
        if item.get("data") not in (WALL_DATA_ID, 1_000_010)
    ]
    for index in range(WALL_SEGMENT_COUNT):
        buildings_single.append(
            {
                "data": WALL_DATA_ID,
                "lvl": (index % 12) + 1,
                "cnt": 1,
            }
        )
    data_single["buildings"] = buildings_single
    data_single["tag"] = "#PERF-LARGE-WALLS"
    data_single["timestamp"] = 1_785_736_933
    encoded_single = json.dumps(data_single, ensure_ascii=False, indent=1) + "\n"
    for target in TARGETS_SINGLE:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(encoded_single, encoding="utf-8")

    # Paired：同 tag、同 lineage、同 1005 段，等级分布大幅偏移，确保 histogram 产生大量残余迁移
    # 前后分别全量 Lv1 与全量 Lv12，raw 差值 1005，可稳定产生非 duplicate 的大变化 history row
    for target, lvl in TARGETS_PAIRED:
        data = json.loads(SOURCE.read_text(encoding="utf-8"))
        data["buildings"] = build_wall_buildings_fixed(lvl)
        data["tag"] = PAIRED_TAG
        # before/after 用不同 timestamp，突出 sourceTimestamp 变化但不影响 duplicate 判定（fingerprint 忽略时间）
        data["timestamp"] = 1_785_736_933 + (0 if lvl == 1 else 1)
        encoded = json.dumps(data, ensure_ascii=False, indent=1) + "\n"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(encoded, encoding="utf-8")

    wall_count = sum(
        item.get("cnt", 1)
        for item in buildings_single
        if item.get("data") == WALL_DATA_ID
    )
    print(f"Wrote {WALL_SEGMENT_COUNT} wall segments ({wall_count} total count) to:")
    for target in TARGETS_SINGLE:
        print(f"  {target}")
    for target, _ in TARGETS_PAIRED:
        print(f"  {target} (tag {PAIRED_TAG})")


if __name__ == "__main__":
    main()
