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
import math
from dataclasses import replace
from pathlib import Path

from .errors import CatalogError
from .model import CatalogItem

#: Swift Double 可表示上限（JSONDecoder .deferredToDate 解码 Date 的域）。
#: 超出此范围的数值（含 Python 任意精度 int 与 1e400 → inf）在 Swift 侧
#: 解码失败 → 整表变空；Python 不得当合法命中（两侧漂移）。
_DOUBLE_MAX = 1.7976931348623157e308

DECLARATIONS_PATH = Path(__file__).resolve().parent / "lifecycle_declarations.json"

# 当前 bundled 目录版本（GameCatalog/<version>/）；coverage 报告默认用它，
# CLI 可通过 manifest.gameVersion 绑定其他版本（评审 follow-up：多版本时
# 不得固定 18.400.13）。
DEFAULT_GAME_VERSION = "18.400.13"


def _phases_path(version: str) -> Path:
    """bundled 阶段表路径：GameCatalog/<version>/seasonal_phases.json。

    与 test_lifecycle.py 的 CATALOG_DIR 推导方式一致（本文件位于
    Tools/game_catalog/，parents[2] = repo 根）。版本由调用方注入。
    """
    return (
        Path(__file__).resolve().parents[2]
        / "Sources" / "COCHelperCore" / "GameCatalog" / version
        / "seasonal_phases.json"
    )


# 默认版本路径（向后兼容：无版本参数时使用；测试 monkeypatch 此常量）
PHASES_PATH = _phases_path(DEFAULT_GAME_VERSION)


def phases_path_for(version: str | None) -> Path:
    """版本 → bundled 阶段表路径（None → DEFAULT_GAME_VERSION 的 PHASES_PATH）。

    Issue #113 评审提取：coverage_report（lifecycle.py 内部）与 validator
    冲突校验（validate_game_catalog.py）共用同一版本绑定，消除跨模块私有
    访问（此前 validator 直接调 _phases_path）。版本推导逻辑与 _phases_path
    docstring 一致（GameCatalog/<version>/seasonal_phases.json）。
    """
    return PHASES_PATH if version is None else _phases_path(version)

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
    except (json.JSONDecodeError, OSError, UnicodeDecodeError) as exc:
        # Issue #113 审计 F8：UnicodeDecodeError（ValueError 子类，非 OSError）
        # 此前逃逸为裸 traceback——非 UTF-8 文件统一转干净 CatalogError。
        raise CatalogError(f"{label}解析失败: {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise CatalogError(f"{label} schemaVersion != 1: {path}")
    sv = raw.get("schemaVersion")
    if isinstance(sv, bool) or not isinstance(sv, int) or sv != 1:
        # bool 是 int 子类且 True == 1——先排除 bool，否则 JSON true 绕过比较
        # （R9 防御，与 validate.py 同模式）
        raise CatalogError(f"{label} schemaVersion != 1: {path}")
    return raw


def _load_phase_coverage_from(path: Path) -> dict[str, str]:
    """读声明文件 → {key: phaseCoverage}（key = "section:dataID"）。

    Issue #113 提取：find_lifecycle_phase_conflicts 需要按参数路径读取声明
    文件（测试注入 tmp 数据），与 load_phase_coverage 共用同一校验逻辑，
    错误消息逐字节一致（失败路径测试锁定消息片段）。
    """
    raw = _load_raw(path, "lifecycle 声明文件")
    items = raw.get("items")
    if not isinstance(items, dict):
        raise CatalogError(f"lifecycle 声明文件缺少 items: {path}")
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
        if not isinstance(coverage, str) or coverage not in PHASE_COVERAGE_VALUES:
            # 先校验 str：JSON 数组/对象对 frozenset membership 会抛裸 TypeError
            # （unhashable），必须统一 fail loud 为 CatalogError
            raise CatalogError(
                f"seasonalCandidate 声明缺 phaseCoverage 或值非法: "
                f"{key}: {coverage!r}")
        out[key] = coverage
    return out


def _load_declarations_from(path: Path) -> dict[str, str]:
    """读声明文件 → {key: lifecycle}（key = "section:dataID"）。

    Issue #113 提取：find_lifecycle_phase_conflicts 需要按参数路径读取声明
    文件（测试注入 tmp 数据），与 load_declarations 共用同一校验逻辑，
    错误消息逐字节一致。path 必须传给 phaseCoverage 校验（同一文件）。
    """
    raw = _load_raw(path, "lifecycle 声明文件")
    items = raw.get("items")
    if not isinstance(items, dict):
        raise CatalogError(f"lifecycle 声明文件缺少 items: {path}")
    out: dict[str, str] = {}
    for key, entry in items.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("lifecycle"), str):
            raise CatalogError(
                f"lifecycle 声明条目非法: {key}: {entry!r}")
        if entry["lifecycle"] not in LIFECYCLE_VALUES:
            raise CatalogError(
                f"lifecycle 声明未知值: {key}: {entry['lifecycle']!r}")
        out[key] = entry["lifecycle"]
    # 红队 Fix 1：phaseCoverage 良构性必须进入生成管线——load_declarations 是
    # apply_lifecycle/lifecycle_for（→ 生成器）的唯一入口，只读文件不校验则
    # 「声明文件是生成前置条件」对 phaseCoverage 维度落空。此处调用仅用于
    # 校验（非法 → CatalogError），返回值丢弃：phaseCoverage 不参与
    # load_declarations 的返回结构。
    _load_phase_coverage_from(path)
    return out


def load_declarations() -> dict[str, str]:
    """读声明文件 → {key: lifecycle}（key = "section:dataID"）。

    文件缺失 / JSON 解析失败 / schemaVersion != 1 / 值非闭枚举 → CatalogError
    （fail loud，声明文件是生成前置条件）。
    """
    return _load_declarations_from(DECLARATIONS_PATH)


def load_phase_coverage() -> dict[str, str]:
    """读声明文件 → {key: phaseCoverage}（key = "section:dataID"）。

    Issue #112 评审修正：note 是自由文本，不可做日期状态分类；新增结构化
    phaseCoverage 字段只存在于声明层（不写入 catalog 产物）：
    - 仅 seasonalCandidate 携带；缺字段或值非闭枚举 → CatalogError（fail loud）；
    - permanent 条目带 phaseCoverage → CatalogError（防误标）；
    - 文件缺失 / 解析失败 / schemaVersion != 1 → CatalogError（与
      load_declarations 同口径，声明文件是生成前置条件）。
    """
    return _load_phase_coverage_from(DECLARATIONS_PATH)


def _valid_interval(frm: object, until: object) -> bool:
    """from/until 是否构成合法阶段区间（from < until）。

    Issue #113 评审提取：compute_phase_coverage 的 phase_keys 与
    find_lifecycle_phase_conflicts 的命中判定共用（与 Swift
    phase(forItemKey:at:) 过滤语义对齐——非法区间 phase 的 key 不得计入）。
    R9 防御：bool 是 int 子类且 True == 1，先排除 bool，否则 JSON true 会被
    当作合法 from/until 绕过区间判定（与 validate.py 同模式）。
    Issue #113 审计 F1：Swift Date 经 JSONDecoder .deferredToDate 解码接受
    浮点时间戳（Double），Python 必须接受 int|float——严格 int 会让 float
    区间在 Python 侧漏报冲突/漏计 phase_keys（validator fail-open，门禁绕过）。
    Issue #113 审计 R2-F1：非有限 float（Infinity/NaN）与超出 Swift Double 域
    的数值在 Swift 侧解码失败整表空——本函数是纯函数容忍层，返回 False
    （不算命中）而非崩溃；真实数据入口由 _load_validated_phases 前置
    fail-loud（消息指引 Swift 解码失败根因）。
    """
    if isinstance(frm, bool) or not isinstance(frm, (int, float)):
        return False
    if isinstance(until, bool) or not isinstance(until, (int, float)):
        return False
    if isinstance(frm, float) and not math.isfinite(frm):
        return False
    if isinstance(until, float) and not math.isfinite(until):
        return False
    if abs(frm) > _DOUBLE_MAX or abs(until) > _DOUBLE_MAX:
        return False
    return frm < until


def compute_phase_coverage(
    decl: dict[str, str], phases: list[dict]
) -> dict[str, int]:
    """统计 seasonalCandidate phaseCoverage 与阶段表的对账（纯函数，可 property 测试）。

    Issue #112。输入契约（第二轮评审 Fix B）：
    - decl：**必须是 dict**（{key: phaseCoverage}，key = "section:dataID"；
      值 required/unknown；来自 load_phase_coverage 输出——实际调用路径不会
      传 None/非 dict，非 dict 输入不在本函数契约内）。不做 load 校验——
      load 由 load_phase_coverage 负责，纯函数不重复校验；意外值按「非
      required」处理，不崩溃；
    - phases：阶段表 phases 数组（每项含 itemKeys 列表与 from/until 区间），
      **容忍畸形**（见下方容忍语义）。

    返回结构化统计（全部非负整数，见 test_phase_coverage.py 的不变量契约）：
    - seasonal_candidates：decl 条目总数；
    - required / unknown：phaseCoverage 分类计数（守恒：
      seasonal_candidates == required + unknown，well-formed 输入下成立）；
    - required_with_phase / required_missing_phase：required 命中/未命中阶段表
      （守恒：required == 二者之和；missing > 0 = 有官方日期待录入）；
    - phase_keys：阶段表全部 itemKeys 去重数（红队 Fix 2：只统计 from < until
      的合法 phase——与 Swift phase(forItemKey:at:) 过滤语义对齐，非法区间
      phase 的 key 不得计入命中，否则报告与运行时矛盾）；
    - phase_keys_declared / phase_keys_not_declared：阶段 key 在/不在 decl 中
      （守恒：phase_keys == 二者之和；not_declared = 模组等非目录条目 key）；
    - invalid_phases：dict 形态但 from/until 缺失、非 int|float、非有限、
      超出 Swift Double 域、或 from >= until 的 phase 数（非 dict 元素跳过
      不计入；语义问题供报告区分，结构问题由 coverage_report fail loud）。
    容忍语义（红队 Fix 3 + 第二轮 Fix A）：纯函数对任意畸形 phases 输入不崩溃、
    不产生垃圾统计——phase 非 dict → 跳过；itemKeys 非 list → 按 [] 处理
    （不迭代字符串/int，否则字符串会被逐字符拆成幽灵 key）；itemKeys 元素
    非 str → 跳过（不计入 phase_keys / 命中判定）；from/until 非数字或
    非有限或超 Double 域 → 该 phase 归 invalid_phases。
    """
    required_keys = {key for key, value in decl.items() if value == "required"}
    unknown = sum(1 for value in decl.values() if value == "unknown")
    phase_keys: set[str] = set()
    invalid_phases = 0
    for phase in phases:
        if not isinstance(phase, dict):
            continue
        item_keys = phase.get("itemKeys")
        if not isinstance(item_keys, list):
            item_keys = []
        if _valid_interval(phase.get("from"), phase.get("until")):
            # Fix A：itemKeys 元素非 str → 跳过（不产生幽灵 key 垃圾统计）
            phase_keys.update(key for key in item_keys if isinstance(key, str))
        else:
            invalid_phases += 1
    return {
        "seasonal_candidates": len(decl),
        "required": len(required_keys),
        "unknown": unknown,
        "required_with_phase": len(required_keys & phase_keys),
        "required_missing_phase": len(required_keys - phase_keys),
        "phase_keys": len(phase_keys),
        "phase_keys_declared": len(phase_keys & set(decl)),
        "phase_keys_not_declared": len(phase_keys - set(decl)),
        "invalid_phases": invalid_phases,
    }


def _load_validated_phases(phases_path: Path) -> list[dict]:
    """阶段表读取 + 结构校验 → phases 列表（fail loud）。

    Issue #113 提取：find_lifecycle_phase_conflicts 与 coverage_report 共用
    同口径校验（文件缺失/解析失败/schemaVersion != 1/缺 phases/phase 非
    dict/phaseID 非 str/name、sourceURL 存在时非 str/itemKeys 非 list 或元素
    非 str/from、until 非数字或非有限或超出 Swift Double 域 → CatalogError），
    错误消息与 coverage_report 既有实现逐字节一致（失败路径测试锁定消息片段）。
    from/until 的**区间语义**（from >= until）是合法数值内的语义问题，不在此
    拦截——留给各调用点（invalid_phases / 冲突判定跳过）。
    """
    raw = _load_raw(phases_path, "阶段表文件")
    phases = raw.get("phases")
    if not isinstance(phases, list):
        raise CatalogError(f"阶段表文件缺少 phases: {phases_path}")
    # 红队 Fix 3：结构校验（类型问题）fail loud——bundle 文件人工维护，错写
    # 不得静默容忍（compute_phase_coverage 的容忍是纯函数防御，真实数据入口
    # 必须拦截）。区间非法（from/until）是语义问题，留给 invalid_phases。
    for i, phase in enumerate(phases):
        if not isinstance(phase, dict):
            raise CatalogError(
                f"阶段表文件 phases[{i}] 非法: 非 dict: {phase!r}")
        # Round 4：与 Swift SeasonalPhase Codable 契约对齐——phaseID 必填 str
        # （缺失/类型错 → Swift loadBundled 解码失败返回空表，运行时
        # .unconfigured；Python 报告若照常统计会显示已覆盖，报告与运行时矛盾）；
        # name/sourceURL 是 Optional<String>：缺失/null 合法，存在时必须 str。
        if not isinstance(phase.get("phaseID"), str):
            raise CatalogError(
                f"阶段表文件 phases[{i}] 非法: phaseID 缺失或非 str: "
                f"{phase.get('phaseID')!r}")
        # Issue #113 审计 F2：from/until 必须 int|float（非 bool）——Swift Date
        # 解码失败会**整表变空**（所有 key 显示 permanent/unconfigured），
        # Python 不得静默跳过（否则同一文件两侧对冲突给出相反答案）。
        # float 合法（F1：Swift Double 解码兼容）；bool 是 int 子类先排除（R9）。
        # Issue #113 审计 R2-F1：非有限 float（Infinity/NaN）与超出 Swift
        # Double 域（1e400 → inf、任意精度大 int）在 Swift 侧解码失败——
        # 与类型错误同属结构问题，fail loud 指引根因（拦截前必须修复文件，
        # 否则报告「已覆盖/冲突」与运行时「整表空」矛盾）。
        for field in ("from", "until"):
            value = phase.get(field)
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise CatalogError(
                    f"阶段表文件 phases[{i}] 非法: {field} 缺失或非数字: "
                    f"{value!r}")
            if isinstance(value, float) and not math.isfinite(value):
                raise CatalogError(
                    f"阶段表文件 phases[{i}] 非法: {field} 非有限数值: "
                    f"{value!r}（Swift Date 解码失败 → 整表变空）")
            if abs(value) > _DOUBLE_MAX:
                raise CatalogError(
                    f"阶段表文件 phases[{i}] 非法: {field} 超出 Swift Double "
                    f"上限: {value!r}")
        for optional_field in ("name", "sourceURL"):
            value = phase.get(optional_field)
            if value is not None and not isinstance(value, str):
                raise CatalogError(
                    f"阶段表文件 phases[{i}] 非法: {optional_field} 非 str: "
                    f"{value!r}")
        item_keys = phase.get("itemKeys")
        if not isinstance(item_keys, list):
            raise CatalogError(
                f"阶段表文件 phases[{i}] 非法: itemKeys 非 list: {item_keys!r}")
        # 第二轮 Fix A：元素级校验——itemKeys 元素必须 str；dict/list/int/None
        # 元素此前要么 TypeError 裸 traceback（[{"a": 1}]）要么静默幽灵 key
        # 统计（[12345]），一律 fail loud 为干净 CatalogError。
        for key in item_keys:
            if not isinstance(key, str):
                raise CatalogError(
                    f"阶段表文件 phases[{i}] 非法: itemKeys 元素非 str: {key!r}")
    return phases


def coverage_report(version: str | None = None) -> dict[str, int]:
    """真实数据 coverage 报告：声明 phaseCoverage vs bundled 阶段表对账统计。

    Issue #112。独立于 validate_catalog（errors 非空即失败，诊断文本不得
    混入 errors——评审红线）；只读声明文件 + seasonal_phases.json；文件缺失 /
    解析失败 / schemaVersion != 1 / 缺 phases → CatalogError（与
    load_phase_coverage 同口径 fail loud）。

    version：bundled 目录版本（GameCatalog/<version>/seasonal_phases.json）；
    None → DEFAULT_GAME_VERSION（CLI 从 --catalog 的 manifest.gameVersion
    绑定，评审 follow-up：多版本时不得固定写死）。
    """
    decl = load_phase_coverage()
    phases = _load_validated_phases(phases_path_for(version))
    return compute_phase_coverage(decl, phases)


def find_lifecycle_phase_conflicts(
    declarations_path: Path = DECLARATIONS_PATH,
    phases_path: Path = PHASES_PATH,
) -> list[dict]:
    """permanent 声明 ∩ 阶段表 itemKeys → 冲突列表（每项含 key、phaseID、
    phaseName、declarationsPath、phasesPath、sourceURL）。无冲突返回 []。

    Issue #113：permanent 声明与官方阶段表命中是数据冲突（运行时 Swift
    availability 显式 .conflict fail-closed，validator 必须 blocking）——
    与 #112 coverage_report 非阻断路径严格分离。结构校验与 coverage_report
    同口径 fail loud（文件缺失/解析失败/schemaVersion != 1/缺 phases/phaseID
    非 str/name、sourceURL 存在时非 str/itemKeys 非 list 或元素非 str/from、
    until 非数字、非有限或超出 Swift Double 域 → CatalogError）。数字类型但
    区间非法（from >= until）的 phase 不算命中——与 Swift phase(forItemKey:at:)
    过滤语义及 compute_phase_coverage 的 phase_keys 口径一致。多 phase 命中 →
    报告全部命中（Python 是数据审计视角，与 Swift 单一确定性选择不同，spec
    明确如此）。
    """
    decl = _load_declarations_from(declarations_path)
    phases = _load_validated_phases(phases_path)
    permanent_keys = {key for key, value in decl.items() if value == "permanent"}
    conflicts: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for phase in phases:
        if not _valid_interval(phase.get("from"), phase.get("until")):
            continue
        for key in phase["itemKeys"]:
            if key not in permanent_keys:
                continue
            # Issue #113 审计 F5：同一 phase 内重复 key 只报一条（(key, phaseID)
            # 去重，保持表序——重复条目无诊断增量）
            if (key, phase["phaseID"]) in seen:
                continue
            seen.add((key, phase["phaseID"]))
            conflicts.append({
                "key": key,
                "phaseID": phase["phaseID"],
                "phaseName": phase.get("name"),
                "declarationsPath": str(declarations_path),
                "phasesPath": str(phases_path),
                "sourceURL": phase.get("sourceURL"),
            })
    return conflicts


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
