"""目录条目生命周期（lifecycle）：声明文件是唯一事实源，生成器机械写入。

Issue #98。三态 `CatalogAvailability` 的 `.permanent` 生产路径修复：
版本化目录条目携带显式生命周期事实（"permanent" / "seasonalCandidate"），
来源 = 人工维护声明文件 `lifecycle_declarations.json`，生成器照抄不推断。

- fail loud：目录条目无声明 → CatalogError（绝不静默降级为默认值）；
- 声明文件缺失 / 解析失败 / schemaVersion != 1 → CatalogError；
- 多余声明（声明有、目录无）不报错（人工清单允许前瞻登记）。
"""

from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path

from .errors import CatalogError
from .model import CatalogItem

DECLARATIONS_PATH = Path(__file__).resolve().parent / "lifecycle_declarations.json"

# bundled 阶段表（Issue #112 coverage 报告用）：从本文件推导 repo 根再下钻，
# 与 test_lifecycle.py 的 CATALOG_DIR 推导方式一致（本文件位于 Tools/game_catalog/，
# parents[2] = repo 根）。
PHASES_PATH = (
    Path(__file__).resolve().parents[2]
    / "Sources" / "COCHelperCore" / "GameCatalog" / "18.400.13"
    / "seasonal_phases.json"
)

# lifecycle 闭枚举（validate 校验用）
LIFECYCLE_VALUES: frozenset[str] = frozenset({"permanent", "seasonalCandidate"})

# phaseCoverage 闭枚举（Issue #112：seasonalCandidate 的官方日期覆盖状态）。
# note 是自由文本不可做日期状态分类，故用结构化字段：
# - "required"：有可靠官方日期，必须命中 phase 表；
# - "unknown"：暂无可靠日期，允许 .unconfigured fail-closed。
PHASE_COVERAGE_VALUES: frozenset[str] = frozenset({"required", "unknown"})


def _load_raw(path: Path, label: str) -> dict:
    """读 + JSON 解析 + 顶层 dict + schemaVersion==1 校验 → raw dict。

    label 用于错误消息（"lifecycle 声明文件" / "阶段表文件"），保持各调用点
    既有消息逐字节不变（失败路径测试断言消息片段）。items/phases 等结构
    内容检查留在各调用点（结构不同，不合并进本 helper）。
    """
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise CatalogError(f"{label}缺失: {path}") from None
    except (json.JSONDecodeError, OSError) as exc:
        raise CatalogError(f"{label}解析失败: {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise CatalogError(f"{label} schemaVersion != 1: {path}")
    sv = raw.get("schemaVersion")
    if isinstance(sv, bool) or not isinstance(sv, int) or sv != 1:
        # bool 是 int 子类且 True == 1——先排除 bool，否则 JSON true 绕过比较
        # （R9 防御，与 validate.py 同模式）
        raise CatalogError(f"{label} schemaVersion != 1: {path}")
    return raw


def load_declarations() -> dict[str, str]:
    """读声明文件 → {key: lifecycle}（key = "section:dataID"）。

    文件缺失 / JSON 解析失败 / schemaVersion != 1 / 值非闭枚举 → CatalogError
    （fail loud，声明文件是生成前置条件）。
    """
    raw = _load_raw(DECLARATIONS_PATH, "lifecycle 声明文件")
    items = raw.get("items")
    if not isinstance(items, dict):
        raise CatalogError(f"lifecycle 声明文件缺少 items: {DECLARATIONS_PATH}")
    out: dict[str, str] = {}
    for key, entry in items.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("lifecycle"), str):
            raise CatalogError(
                f"lifecycle 声明条目非法: {key}: {entry!r}")
        if entry["lifecycle"] not in LIFECYCLE_VALUES:
            raise CatalogError(
                f"lifecycle 声明未知值: {key}: {entry['lifecycle']!r}")
        out[key] = entry["lifecycle"]
    return out


def load_phase_coverage() -> dict[str, str]:
    """读声明文件 → {key: phaseCoverage}（key = "section:dataID"）。

    Issue #112 评审修正：note 是自由文本，不可做日期状态分类；新增结构化
    phaseCoverage 字段只存在于声明层（不写入 catalog 产物）：
    - 仅 seasonalCandidate 携带；缺字段或值非闭枚举 → CatalogError（fail loud）；
    - permanent 条目带 phaseCoverage → CatalogError（防误标）；
    - 文件缺失 / 解析失败 / schemaVersion != 1 → CatalogError（与
      load_declarations 同口径，声明文件是生成前置条件）。
    """
    raw = _load_raw(DECLARATIONS_PATH, "lifecycle 声明文件")
    items = raw.get("items")
    if not isinstance(items, dict):
        raise CatalogError(f"lifecycle 声明文件缺少 items: {DECLARATIONS_PATH}")
    out: dict[str, str] = {}
    for key, entry in items.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("lifecycle"), str):
            raise CatalogError(
                f"lifecycle 声明条目非法: {key}: {entry!r}")
        if entry["lifecycle"] not in LIFECYCLE_VALUES:
            raise CatalogError(
                f"lifecycle 声明未知值: {key}: {entry['lifecycle']!r}")
        if entry["lifecycle"] == "permanent":
            if "phaseCoverage" in entry:
                raise CatalogError(
                    f"permanent 条目不得携带 phaseCoverage: {key}")
            continue
        coverage = entry.get("phaseCoverage")
        if coverage not in PHASE_COVERAGE_VALUES:
            raise CatalogError(
                f"seasonalCandidate 声明缺 phaseCoverage 或值非法: "
                f"{key}: {coverage!r}")
        out[key] = coverage
    return out


def compute_phase_coverage(
    decl: dict[str, str], phases: list[dict]
) -> dict[str, int]:
    """统计 seasonalCandidate phaseCoverage 与阶段表的对账（纯函数，可 property 测试）。

    Issue #112。输入：
    - decl：{key: phaseCoverage}（key = "section:dataID"；值 required/unknown。
      不做 load 校验——load 由 load_phase_coverage 负责，纯函数不重复校验；
      意外值按「非 required」处理，不崩溃）；
    - phases：阶段表 phases 数组（每项含 itemKeys 列表；缺 itemKeys 按空处理）。

    返回结构化统计（全部非负整数，见 test_phase_coverage.py 的不变量契约）：
    - seasonal_candidates：decl 条目总数；
    - required / unknown：phaseCoverage 分类计数（守恒：
      seasonal_candidates == required + unknown，well-formed 输入下成立）；
    - required_with_phase / required_missing_phase：required 命中/未命中阶段表
      （守恒：required == 二者之和；missing > 0 = 有官方日期待录入）；
    - phase_keys：阶段表全部 itemKeys 去重数；
    - phase_keys_declared / phase_keys_not_declared：阶段 key 在/不在 decl 中
      （守恒：phase_keys == 二者之和；not_declared = 模组等非目录条目 key）。
    """
    required_keys = {key for key, value in decl.items() if value == "required"}
    unknown = sum(1 for value in decl.values() if value == "unknown")
    phase_keys = {key for phase in phases
                  for key in (phase.get("itemKeys") or [])}
    return {
        "seasonal_candidates": len(decl),
        "required": len(required_keys),
        "unknown": unknown,
        "required_with_phase": len(required_keys & phase_keys),
        "required_missing_phase": len(required_keys - phase_keys),
        "phase_keys": len(phase_keys),
        "phase_keys_declared": len(phase_keys & set(decl)),
        "phase_keys_not_declared": len(phase_keys - set(decl)),
    }


def coverage_report() -> dict[str, int]:
    """真实数据 coverage 报告：声明 phaseCoverage vs bundled 阶段表对账统计。

    Issue #112。独立于 validate_catalog（errors 非空即失败，诊断文本不得
    混入 errors——评审红线）；只读声明文件 + seasonal_phases.json；文件缺失 /
    解析失败 / schemaVersion != 1 / 缺 phases → CatalogError（与
    load_phase_coverage 同口径 fail loud）。
    """
    decl = load_phase_coverage()
    raw = _load_raw(PHASES_PATH, "阶段表文件")
    phases = raw.get("phases")
    if not isinstance(phases, list):
        raise CatalogError(f"阶段表文件缺少 phases: {PHASES_PATH}")
    return compute_phase_coverage(decl, phases)


def apply_lifecycle(items: list[CatalogItem]) -> list[CatalogItem]:
    """对 items 应用声明 lifecycle，返回新列表（不改入参，保持顺序）。

    条目无声明 → CatalogError（fail loud，错误含 section:dataID 和 name）。
    """
    decl = load_declarations()
    out: list[CatalogItem] = []
    for item in items:
        key = f"{item.section}:{item.dataID}"
        lifecycle = decl.get(key)
        if lifecycle is None:
            raise CatalogError(f"lifecycle 声明缺失: {key} {item.name}")
        out.append(replace(item, lifecycle=lifecycle))
    return out


def lifecycle_for(section: str, dataID: int) -> str:
    """供独立生成器（craft_table 等）查声明；缺失 → CatalogError。"""
    decl = load_declarations()
    key = f"{section}:{dataID}"
    lifecycle = decl.get(key)
    if lifecycle is None:
        raise CatalogError(f"lifecycle 声明缺失: {key}")
    return lifecycle
