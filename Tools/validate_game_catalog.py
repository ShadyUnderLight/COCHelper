#!/usr/bin/env python3
"""校验 APK 静态升级目录（issue #13）。

用法:
  python3 Tools/validate_game_catalog.py --catalog /tmp/coc-game-catalog

退出码: 0=通过 1=存在 error 2=用法错误；--strict 把 warning 升级为失败（当前无 warning）
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from game_catalog.validate import validate_catalog
from game_catalog.errors import CatalogError
from game_catalog.lifecycle import coverage_report


def _catalog_game_version(catalog_dir: Path) -> str | None:
    """从 --catalog 的 manifest.json 读 gameVersion（coverage 版本绑定用）。

    评审 follow-up：多版本目录时不得固定 18.400.13；manifest 缺失/解析失败/
    非字符串 → None（回退默认版本，coverage 非阻断不受影响）。
    """
    try:
        manifest = json.loads(
            (catalog_dir / "manifest.json").read_text(encoding="utf-8"))
        version = manifest.get("gameVersion")
        return version if isinstance(version, str) and version else None
    except (OSError, ValueError, json.JSONDecodeError, AttributeError):
        return None


def _emit_coverage_report(catalog_dir: Path) -> None:
    """Issue #112：非阻断输出 seasonalCandidate ↔ phase 覆盖统计。

    接入维护者正常校验流程（验收标准「validator 输出 coverage 报告」）。
    独立于 validate_catalog 的 errors（评审红线：errors 非空即失败，诊断文本
    不得混入）；文件缺失/解析失败 → 打印 unavailable 提示，不影响退出码。
    版本绑定 --catalog 的 manifest.gameVersion（评审 follow-up）。
    """
    try:
        cov = coverage_report(version=_catalog_game_version(catalog_dir))
    except CatalogError as exc:
        print(f"coverage: unavailable: {exc}", file=sys.stderr)
        return
    print(
        "coverage: "
        f"seasonalCandidates={cov['seasonal_candidates']} "
        f"required={cov['required']} unknown={cov['unknown']} "
        f"requiredWithPhase={cov['required_with_phase']} "
        f"requiredMissingPhase={cov['required_missing_phase']} "
        f"phaseKeys={cov['phase_keys']} "
        f"phaseKeysDeclared={cov['phase_keys_declared']} "
        f"phaseKeysNotDeclared={cov['phase_keys_not_declared']} "
        f"invalidPhases={cov['invalid_phases']}"
    )


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
    _emit_coverage_report(args.catalog)
    if errors:
        print("verdict: FAIL")
        return 1
    print("verdict: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
