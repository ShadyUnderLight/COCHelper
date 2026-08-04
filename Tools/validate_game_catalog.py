#!/usr/bin/env python3
"""校验 APK 静态升级目录（issue #13）。

用法:
  python3 Tools/validate_game_catalog.py --catalog /tmp/coc-game-catalog

退出码: 0=通过 1=存在 error 2=用法错误；--strict 把 warning 升级为失败（当前无 warning）
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from game_catalog.validate import validate_catalog
from game_catalog.errors import CatalogError


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="校验 APK 静态升级目录")
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--strict", action="store_true", help="将 warning 升级为失败")
    args = parser.parse_args(argv)

    try:
        errors = validate_catalog(args.catalog)
    except CatalogError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    if errors:
        print("verdict: FAIL")
        return 1
    print("verdict: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
