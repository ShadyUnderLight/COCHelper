#!/usr/bin/env python3
"""生成 APK 版本化静态升级目录（issue #13）。

用法:
  python3 Tools/generate_game_catalog.py --apk base.apk.1 --output /tmp/coc-game-catalog
  python3 Tools/generate_game_catalog.py --apk base.apk.1 --game-version 18.400.13 --output /tmp/coc-game-catalog

退出码: 0=成功 1=Tier-1 错误 2=用法错误
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from game_catalog.catalog import generate
from game_catalog.errors import CatalogError
from game_catalog.validate import validate_catalog


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="生成 APK 静态升级目录")
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--game-version", default=None,
                        help="游戏版本（APK 内无该字符串；默认从 build.tag 推断）")
    parser.add_argument("--locale", default="zh-CN")
    args = parser.parse_args(argv)

    try:
        generate(args.apk, args.game_version, args.output, args.locale)
    except CatalogError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    # 写盘后自检：validate_catalog + catalog_invariants，失败不静默
    try:
        # Issue #98 复审 P1：主生成器自检豁免 craft 条目强制（两步生成链——
        # craft 表由 generate_craft_table_catalog.py 独立生成并幂等登记 manifest
        # 条目；主生成器运行时条目尚未登记，独立 validate/CI 默认强制）。
        errors = validate_catalog(args.output, require_craft_entry=False)
    except CatalogError as exc:
        print(f"error: 自检失败: {exc}", file=sys.stderr)
        return 1
    if errors:
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        return 1
    print(f"wrote catalog to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
