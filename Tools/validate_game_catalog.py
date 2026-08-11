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

from game_catalog import lifecycle as lifecycle_module
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


def _collect_conflict_errors(catalog_dir: Path) -> list[str]:
    """Issue #113：permanent 声明与官方阶段表冲突 → blocking error（退出码 1）。

    blocking 路径红线：冲突必须进入 errors（errors 非空即 FAIL），不得塞进
    coverage_report/_emit_coverage_report 非阻断分支（#112 评审红线保持——
    对比：coverage 失败只打印 unavailable 且退出码不变）。版本绑定与
    _emit_coverage_report 同模式（_catalog_game_version 回退默认版本）。
    Issue #113 审计 F3：**基础设施故障**（声明/阶段表文件缺失、解析失败等
    CatalogError）→ 非阻断——打印 `conflict check: unavailable` 后返回空列表，
    与 #112 coverage 非阻断先例一致（文件缺失不是数据冲突；多版本目录在
    阶段表补录前不得硬断校验管线）。只有**数据冲突本身**才 blocking。
    路径从 lifecycle_module 运行期读取（测试可 monkeypatch 注入 tmp 数据）。
    """
    version = _catalog_game_version(catalog_dir)
    phases_path = lifecycle_module.phases_path_for(version)
    try:
        conflicts = lifecycle_module.find_lifecycle_phase_conflicts(
            declarations_path=lifecycle_module.DECLARATIONS_PATH,
            phases_path=phases_path)
    except CatalogError as exc:
        print(f"conflict check: unavailable: {exc}", file=sys.stderr)
        return []
    # Issue #113 审计 F6：按 key 分组，每条 error 列出该 key 命中的全部 phase
    #（phases=[p1(名称), p2(无)]）——Python 数据审计视角报告全部，维护者修复
    # 时能看到完整候选集（Swift 运行时取单一确定性选择）。
    by_key: dict[str, list[dict]] = {}
    for c in conflicts:
        by_key.setdefault(c["key"], []).append(c)
    errors: list[str] = []
    for key, items in by_key.items():
        phases_part = ", ".join(
            f"{c['phaseID']}({c.get('phaseName') or '无'})" for c in items)
        first = items[0]
        errors.append(
            f"lifecycle 声明永久内容与官方阶段表冲突: {key}: phases=[{phases_part}] "
            f"声明={first['declarationsPath']} "
            f"阶段={first['phasesPath']} 来源={first.get('sourceURL') or '无'}")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="校验 APK 静态升级目录")
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--strict", action="store_true", help="将 warning 升级为失败")
    args = parser.parse_args(argv)

    errors: list[str] = []
    try:
        errors = validate_catalog(args.catalog)
        # Issue #113：冲突收集与 validate_catalog 同一 try 块——CatalogError
        # （声明/阶段表文件异常）同样走 except → error: + 退出码 1。
        errors += _collect_conflict_errors(args.catalog)
    except CatalogError as exc:
        # 评审修复：异常分支不得吞掉已收集的 validate errors——先逐条打印
        #（诊断完整性），再打印异常本身（退出码保持 1）。
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
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
