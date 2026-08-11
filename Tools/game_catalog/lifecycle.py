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

# lifecycle 闭枚举（validate 校验用）
LIFECYCLE_VALUES: frozenset[str] = frozenset({"permanent", "seasonalCandidate"})

# phaseCoverage 闭枚举（Issue #112：seasonalCandidate 的官方日期覆盖状态）。
# note 是自由文本不可做日期状态分类，故用结构化字段：
# - "required"：有可靠官方日期，必须命中 phase 表；
# - "unknown"：暂无可靠日期，允许 .unconfigured fail-closed。
PHASE_COVERAGE_VALUES: frozenset[str] = frozenset({"required", "unknown"})


def load_declarations() -> dict[str, str]:
    """读声明文件 → {key: lifecycle}（key = "section:dataID"）。

    文件缺失 / JSON 解析失败 / schemaVersion != 1 / 值非闭枚举 → CatalogError
    （fail loud，声明文件是生成前置条件）。
    """
    try:
        raw = json.loads(DECLARATIONS_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise CatalogError(f"lifecycle 声明文件缺失: {DECLARATIONS_PATH}") from None
    except (json.JSONDecodeError, OSError) as exc:
        raise CatalogError(f"lifecycle 声明文件解析失败: {DECLARATIONS_PATH}: {exc}") from exc
    if not isinstance(raw, dict):
        raise CatalogError(
            f"lifecycle 声明文件 schemaVersion != 1: {DECLARATIONS_PATH}")
    sv = raw.get("schemaVersion")
    if isinstance(sv, bool) or not isinstance(sv, int) or sv != 1:
        # bool 是 int 子类且 True == 1——先排除 bool，否则 JSON true 绕过比较
        # （R9 防御，与 validate.py 同模式）
        raise CatalogError(
            f"lifecycle 声明文件 schemaVersion != 1: {DECLARATIONS_PATH}")
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
    try:
        raw = json.loads(DECLARATIONS_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise CatalogError(f"lifecycle 声明文件缺失: {DECLARATIONS_PATH}") from None
    except (json.JSONDecodeError, OSError) as exc:
        raise CatalogError(f"lifecycle 声明文件解析失败: {DECLARATIONS_PATH}: {exc}") from exc
    if not isinstance(raw, dict):
        raise CatalogError(
            f"lifecycle 声明文件 schemaVersion != 1: {DECLARATIONS_PATH}")
    sv = raw.get("schemaVersion")
    if isinstance(sv, bool) or not isinstance(sv, int) or sv != 1:
        # bool 是 int 子类且 True == 1——先排除 bool，否则 JSON true 绕过比较
        # （R9 防御，与 validate.py 同模式）
        raise CatalogError(
            f"lifecycle 声明文件 schemaVersion != 1: {DECLARATIONS_PATH}")
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
