"""Issue #112：phase coverage 报告与反向对账（required 候选必须命中阶段表）。

- 反向对账（真实数据）：required = 4 条官方可靠日期清单，且每条必须命中
  seasonal_phases.json——issue 验收标准「已知官方日期的候选不能静默漏录」
  （补齐现有单向校验 test_lifecycle.py::test_seasonal_candidates_match_phase_table
  的缺口：phase key → seasonalCandidate 之外，候选 → phase 也必须成立）；
- coverage_report 真实数据统计：区分「有官方日期待录入」（required_missing_phase）
  与「暂无可靠日期」（unknown），诊断独立于 validate_catalog errors（消费方
  非空即失败，评审红线）；
- compute_phase_coverage 纯函数 hypothesis property：分类守恒不变量 + 意外值
  容忍 + 空输入退化端点。
"""

import json
from pathlib import Path

import pytest
from hypothesis import given, strategies as st

import game_catalog.lifecycle as lifecycle_module
from game_catalog.errors import CatalogError
from game_catalog.lifecycle import (
    compute_phase_coverage,
    coverage_report,
    load_phase_coverage,
)

_REPO_ROOT = Path(__file__).resolve().parents[2]
CATALOG_DIR = _REPO_ROOT / "Sources/COCHelperCore/GameCatalog/18.400.13"
PHASES_PATH = CATALOG_DIR / "seasonal_phases.json"

# required = 有可靠官方日期、必须命中 phase 表（精工防御 3 条 + Party Wizard，
# 官方公告 2026-04-08 08:00 UTC ~ 2026-04-29 08:00 UTC；与 test_lifecycle.py
# 的 PHASE_COVERAGE_REQUIRED_KEYS 同一清单）。
PHASE_COVERAGE_REQUIRED_KEYS = frozenset({
    "buildings:103000008", "buildings:103000009", "buildings:103000010",
    "units:4000072",
})


# ---- 反向对账（真实数据，issue 验收标准）----

def test_required_candidates_hit_phase_table():
    """反向对账：required 集合 == 4 条官方可靠日期清单，且每条命中阶段表
    （4/4 命中 → required_missing_phase == 0）。已知官方日期的候选不得
    静默漏录——声明成 required 却不在阶段表 = 维护者宣称有日期但数据没录入。"""
    decl = load_phase_coverage()
    required = {key for key, value in decl.items() if value == "required"}
    assert required == PHASE_COVERAGE_REQUIRED_KEYS
    phases = json.loads(PHASES_PATH.read_text(encoding="utf-8"))["phases"]
    report = compute_phase_coverage(decl, phases)
    assert report["required"] == 4
    assert report["required_with_phase"] == 4
    assert report["required_missing_phase"] == 0


# ---- coverage_report：真实数据统计 + 失败路径 ----

def test_coverage_report_summary():
    """coverage_report 真实数据统计：71 候选 = 4 required + 67 unknown；
    required 全部命中阶段表；13 个阶段 key = 4 已声明（3 精工防御 +
    Party Wizard）+ 9 模组 key（102000024-032 不在声明表）。"""
    assert coverage_report() == {
        "seasonal_candidates": 71,
        "required": 4,
        "unknown": 67,
        "required_with_phase": 4,
        "required_missing_phase": 0,
        "phase_keys": 13,
        "phase_keys_declared": 4,
        "phase_keys_not_declared": 9,
    }


@pytest.mark.parametrize(
    ("content", "message_fragment"),
    [
        # 文件缺失（临时目录下不存在）→ CatalogError
        (None, "阶段表文件缺失"),
        # JSON 语法错误（原始串，非 json.dumps 产物）→ CatalogError
        ("{not json", "阶段表文件解析失败"),
        # schemaVersion != 1 → CatalogError（与 load_phase_coverage 同口径）
        ({"schemaVersion": 2, "phases": []}, "schemaVersion"),
        # schemaVersion=true（bool 是 int 子类且 True == 1，R9 绕过类）→ CatalogError
        ({"schemaVersion": True, "phases": []}, "schemaVersion"),
        # phases 键缺失
        ({"schemaVersion": 1}, "缺少 phases"),
        # 顶层非 dict（如列表）→ CatalogError（"schemaVersion" 分支，兄弟测试
        # test_lifecycle.py 已确立「顶层非 dict」先例）
        ([1, 2], "schemaVersion"),
        # phases 非 list（如 dict）→ CatalogError
        ({"schemaVersion": 1, "phases": {}}, "缺少 phases"),
    ],
)
def test_coverage_report_failure_paths(monkeypatch, tmp_path, content, message_fragment):
    """阶段表文件异常全部 fail loud → CatalogError（与 load 同口径）；报告
    独立于 validate_catalog errors——诊断文本绝不 append 到 errors（评审红线：
    validate.py 消费方非空即失败）。"""
    if content is None:
        path = tmp_path / "missing_seasonal_phases.json"  # 不存在
    else:
        path = tmp_path / "seasonal_phases.json"
        if isinstance(content, str):
            path.write_text(content, encoding="utf-8")  # JSON 语法错误用例
        else:
            path.write_text(json.dumps(content), encoding="utf-8")
    monkeypatch.setattr(lifecycle_module, "PHASES_PATH", path)
    with pytest.raises(CatalogError) as ei:
        coverage_report()
    assert message_fragment in str(ei.value)


# ---- compute_phase_coverage：纯函数退化端点（空输入 / 缺 itemKeys）----

def test_compute_phase_coverage_empty_inputs():
    """空 decl + 空 phases → 全 0 不崩溃（property 规模可控的退化端点）。"""
    assert compute_phase_coverage({}, []) == {
        "seasonal_candidates": 0,
        "required": 0,
        "unknown": 0,
        "required_with_phase": 0,
        "required_missing_phase": 0,
        "phase_keys": 0,
        "phase_keys_declared": 0,
        "phase_keys_not_declared": 0,
    }


def test_compute_phase_coverage_phase_without_itemkeys():
    """phase 缺 itemKeys 键 → 按空列表处理（纯函数容忍意外值，不崩溃）。"""
    report = compute_phase_coverage(
        {"buildings:103000008": "required"}, [{"phaseID": "no-itemkeys"}])
    assert report["phase_keys"] == 0
    assert report["required_with_phase"] == 0
    assert report["required_missing_phase"] == 1


# ---- hypothesis property：纯函数分类守恒不变量 ----

# key 池 12 个（required 4 条 + unknown 示例 + 模组 key + 未声明 key），
# 控制规模：decl ≤ 8 条、phases ≤ 3 个、每 phase itemKeys ≤ 5，测试快。
_PHASE_KEY_POOL = st.sampled_from([
    "buildings:103000008", "buildings:103000009", "buildings:103000010",
    "units:4000072", "units:4000030", "spells:26000004", "pets:73000006",
    "traps:12000003", "buildings:102000024", "buildings:102000025",
    "buildings:102000026", "units:9999999",
])


@st.composite
def _decl_strategy(draw):
    """随机 phaseCoverage 映射（required/unknown 混合，key 唯一）。"""
    keys = draw(st.lists(_PHASE_KEY_POOL, min_size=0, max_size=8, unique=True))
    values = draw(st.lists(
        st.sampled_from(["required", "unknown"]),
        min_size=len(keys), max_size=len(keys)))
    return dict(zip(keys, values))


@st.composite
def _decl_unexpected_strategy(draw):
    """随机 phaseCoverage 映射（值任意字符串，含意外值——load 层才校验）。"""
    keys = draw(st.lists(_PHASE_KEY_POOL, min_size=0, max_size=8, unique=True))
    values = draw(st.lists(
        st.text(min_size=0, max_size=8),
        min_size=len(keys), max_size=len(keys)))
    return dict(zip(keys, values))


@st.composite
def _phases_strategy(draw):
    """随机阶段表 phases 数组（每项含 itemKeys 列表，允许跨 phase 重复 key——
    去重语义由被测函数保证）。"""
    count = draw(st.integers(min_value=0, max_value=3))
    return [
        {"phaseID": f"phase-{i}",
         "itemKeys": draw(st.lists(_PHASE_KEY_POOL, min_size=0, max_size=5))}
        for i in range(count)
    ]


@given(_decl_strategy(), _phases_strategy())
def test_compute_phase_coverage_invariants(decl, phases):
    """纯函数不变量：required 分类守恒（with_phase + missing_phase ==
    required）；seasonal_candidates == required + unknown；phase_keys
    去重后守恒（declared + not_declared == phase_keys）；全部统计非负。"""
    report = compute_phase_coverage(decl, phases)
    assert report["required"] == (
        report["required_with_phase"] + report["required_missing_phase"])
    assert report["seasonal_candidates"] == report["required"] + report["unknown"]
    assert report["phase_keys"] == (
        report["phase_keys_declared"] + report["phase_keys_not_declared"])
    for value in report.values():
        assert isinstance(value, int) and value >= 0


@given(_decl_unexpected_strategy(), _phases_strategy())
def test_compute_phase_coverage_tolerates_unexpected_values(decl, phases):
    """意外 phaseCoverage 值（闭枚举外，如 "maybe"/""）→ 不崩溃；仅
    required/unknown 计入分类桶，意外值仍在候选总数中（统计非负）。"""
    report = compute_phase_coverage(decl, phases)
    for value in report.values():
        assert isinstance(value, int) and value >= 0
    assert report["required"] + report["unknown"] <= report["seasonal_candidates"]
