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
    """coverage_report 真实数据统计（红队 Fix 4 动态化）：seasonal_candidates /
    unknown 从声明文件动态推导——#109 外部核实新增 unknown 候选时测试不锁死
    （plan「不锁死 71=4+67 为契约」）；required == 4 与阶段表事实（13 key =
    4 已声明 + 9 模组）为当前数据快照（tripwire）；当前 2 个 phase 区间均
    合法 → invalid_phases == 0。"""
    report = coverage_report()
    decl = load_phase_coverage()
    # 动态推导：总数与 unknown 不锁死（声明文件是唯一事实源）
    assert report["seasonal_candidates"] == len(decl)
    assert report["unknown"] == sum(1 for v in decl.values() if v == "unknown")
    # 契约 + 当前数据快照
    assert report["required"] == 4
    assert report["required_with_phase"] == 4
    assert report["required_missing_phase"] == 0
    assert report["phase_keys"] == 13
    assert report["phase_keys_declared"] == 4
    assert report["phase_keys_not_declared"] == 9
    assert report["invalid_phases"] == 0


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
        # Fix 3 结构校验：phase 元素非 dict → CatalogError（fail loud）
        ({"schemaVersion": 1, "phases": ["not-a-dict"]}, "非 dict"),
        # Fix 3 结构校验：itemKeys 非 list（字符串）→ CatalogError（bundle 为
        # 人工维护，错写应 fail loud，不做静默 [] 容忍——否则 13 个字符当 key）
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "from": 1, "until": 2,
                                          "itemKeys": "units:4000072"}]}, "itemKeys"),
        # Fix 3 结构校验：itemKeys 缺失 → CatalogError
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "from": 1, "until": 2}]},
         "itemKeys"),
        # Fix A 元素级校验：itemKeys 含 int 元素 → CatalogError（原：静默
        # 把 int 计入 phase_keys 产生幽灵 key 垃圾统计）
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "from": 1, "until": 2,
                                          "itemKeys": [12345]}]}, "itemKeys"),
        # Fix A 元素级校验：itemKeys 含 dict 元素 → CatalogError（原：
        # TypeError 裸 traceback 而非 CatalogError，违反 fail loud 契约）
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "from": 1, "until": 2,
                                          "itemKeys": [{"a": 1}]}]}, "itemKeys"),
        # Fix A 元素级校验：itemKeys 含 None 元素 → CatalogError
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "from": 1, "until": 2,
                                          "itemKeys": [None]}]}, "itemKeys"),
        # Round 4 结构校验：缺 phaseID → CatalogError（Swift SeasonalPhase.phaseID
        # 是 Codable 必填——缺失时 Swift loadBundled 解码失败返回空表，运行时
        # .unconfigured；Python 报告若照常统计会显示已覆盖，报告与运行时矛盾）
        ({"schemaVersion": 1, "phases": [{"from": 1, "until": 2,
                                          "itemKeys": ["a:1"]}]}, "phaseID"),
        # Round 4 结构校验：phaseID 非 str（如数字）→ CatalogError
        ({"schemaVersion": 1, "phases": [{"phaseID": 123, "from": 1, "until": 2,
                                          "itemKeys": ["a:1"]}]}, "phaseID"),
        # Round 4 结构校验：name 非 str（存在时必须 str，Swift Optional<String>；
        # 缺失/null 合法）→ CatalogError
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "name": 123,
                                          "from": 1, "until": 2,
                                          "itemKeys": ["a:1"]}]}, "name"),
        # Round 4 结构校验：sourceURL 非 str（存在时必须 str）→ CatalogError
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "sourceURL": ["u"],
                                          "from": 1, "until": 2,
                                          "itemKeys": ["a:1"]}]}, "sourceURL"),
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


def test_coverage_report_version_parameter(monkeypatch, tmp_path):
    """评审 follow-up：coverage_report(version=...) 必须使用该版本的 bundled
    阶段表路径（GameCatalog/<version>/seasonal_phases.json），而不是固定
    18.400.13。验证：monkeypatch _phases_path 后 version 参数被传递。"""
    sentinel = tmp_path / "seasonal_phases.json"
    sentinel.write_text(json.dumps(
        {"schemaVersion": 1, "phases": [{"phaseID": "v99", "from": 1, "until": 2,
                                         "itemKeys": []}]}), encoding="utf-8")
    calls: list[str] = []

    def fake_phases_path(version: str):
        calls.append(version)
        return sentinel

    monkeypatch.setattr(lifecycle_module, "_phases_path", fake_phases_path)
    coverage_report(version="99.99.99")
    assert calls == ["99.99.99"], "version 参数必须传递到 _phases_path"


def test_coverage_report_version_defaults_to_current(monkeypatch):
    """coverage_report() 不传 version → 默认使用当前 bundled 版本路径
    （DEFAULT_GAME_VERSION 18.400.13，真实文件存在 → 正常返回统计）。"""
    report = coverage_report()
    assert report["phase_keys"] == 13
    assert report["required"] == 4


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
        "invalid_phases": 0,
    }


def test_compute_phase_coverage_phase_without_itemkeys():
    """phase 缺 itemKeys 键 → 按空列表处理（纯函数容忍意外值，不崩溃）；
    缺 from/until → 非法区间（invalid_phases 计数，Fix 2）。"""
    report = compute_phase_coverage(
        {"buildings:103000008": "required"}, [{"phaseID": "no-itemkeys"}])
    assert report["phase_keys"] == 0
    assert report["required_with_phase"] == 0
    assert report["required_missing_phase"] == 1
    assert report["invalid_phases"] == 1


def test_compute_phase_coverage_skips_invalid_interval_phases():
    """红队 Fix 2：与 Swift phase(forItemKey:at:) 对齐——只统计 from < until
    的合法 phase；from == until / from > until（非法区间）的 itemKeys 不得
    计入 phase_keys / required_with_phase（否则报告显示 4/4 命中而运行时
    .unconfigured，反向对账在非法日期场景静默失效）。"""
    decl = {"buildings:103000008": "required", "units:9999999": "unknown"}
    phases = [
        {"phaseID": "valid", "from": 1, "until": 10,
         "itemKeys": ["buildings:103000008"]},
        {"phaseID": "equal", "from": 5, "until": 5,
         "itemKeys": ["buildings:103000008"]},
        {"phaseID": "inverted", "from": 10, "until": 1,
         "itemKeys": ["buildings:103000008"]},
    ]
    report = compute_phase_coverage(decl, phases)
    assert report["invalid_phases"] == 2
    assert report["phase_keys"] == 1  # 仅合法 phase 的 key
    assert report["required_with_phase"] == 1  # 仅合法命中
    assert report["required_missing_phase"] == 0


def test_compute_phase_coverage_skips_non_str_itemkey_elements():
    """第二轮 Fix A：itemKeys 混合 [str, int, None] 元素 → 只统计 str 元素
    （非 str 元素跳过，不产生幽灵 key 垃圾统计；真实数据入口 coverage_report
    层 fail loud，纯函数层是防御性容忍）。"""
    decl = {"buildings:103000008": "required", "units:9999999": "unknown"}
    phases = [{"phaseID": "x", "from": 1, "until": 2,
               "itemKeys": ["buildings:103000008", 12345, None]}]
    report = compute_phase_coverage(decl, phases)
    assert report["phase_keys"] == 1
    assert report["required_with_phase"] == 1
    assert report["required_missing_phase"] == 0
    assert report["invalid_phases"] == 0


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
    """随机阶段表 phases 数组：每项含 from/until（任意 int，覆盖 from >= until
    非法区间场景）与 itemKeys（允许跨 phase 重复 key——去重语义由被测函数
    保证）。"""
    count = draw(st.integers(min_value=0, max_value=3))
    return [
        {"phaseID": f"phase-{i}",
         "from": draw(st.integers(min_value=0, max_value=10)),
         "until": draw(st.integers(min_value=0, max_value=10)),
         "itemKeys": draw(st.lists(_PHASE_KEY_POOL, min_size=0, max_size=5))}
        for i in range(count)
    ]


@given(_decl_strategy(), _phases_strategy())
def test_compute_phase_coverage_invariants(decl, phases):
    """纯函数不变量：required 分类守恒（with_phase + missing_phase ==
    required）；seasonal_candidates == required + unknown；phase_keys
    去重后守恒（declared + not_declared == phase_keys）——仅统计合法区间
    phase（from < until，Fix 2）；invalid_phases 非负且不超过 phase 总数；
    全部统计非负。"""
    report = compute_phase_coverage(decl, phases)
    assert report["required"] == (
        report["required_with_phase"] + report["required_missing_phase"])
    assert report["seasonal_candidates"] == report["required"] + report["unknown"]
    assert report["phase_keys"] == (
        report["phase_keys_declared"] + report["phase_keys_not_declared"])
    assert 0 <= report["invalid_phases"] <= len(phases)
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


@st.composite
def _phases_malformed_strategy(draw):
    """随机畸形 phases 数组（Fix 3 + 第二轮 Fix A）：合法 dict 与 非 dict 元素、
    itemKeys 为 list/字符串/int/None、itemKeys 元素级畸形（str/int/dict/list/
    None 混合）、缺键——纯函数必须完全容忍。"""
    count = draw(st.integers(min_value=0, max_value=4))
    phases = []
    for i in range(count):
        kind = draw(st.integers(min_value=0, max_value=4))
        if kind == 0:  # 合法 dict
            phases.append({
                "phaseID": f"phase-{i}",
                "from": draw(st.integers(min_value=0, max_value=10)),
                "until": draw(st.integers(min_value=0, max_value=10)),
                "itemKeys": draw(st.lists(
                    _PHASE_KEY_POOL, min_size=0, max_size=5)),
            })
        elif kind == 1:  # 非 dict 元素
            phases.append(draw(st.one_of(
                st.integers(min_value=-5, max_value=5),
                st.text(min_size=0, max_size=5), st.none())))
        elif kind == 2:  # itemKeys 类型错（非 list）
            phases.append({
                "phaseID": f"phase-{i}",
                "from": draw(st.integers(min_value=0, max_value=10)),
                "until": draw(st.integers(min_value=0, max_value=10)),
                "itemKeys": draw(st.one_of(
                    _PHASE_KEY_POOL, st.integers(min_value=0, max_value=9),
                    st.none())),
            })
        elif kind == 3:  # 缺 from/until/itemKeys
            phases.append({"phaseID": f"phase-{i}"})
        else:  # Fix A：itemKeys 元素级畸形（str/int/dict/list/None 混合）
            phases.append({
                "phaseID": f"phase-{i}",
                "from": draw(st.integers(min_value=0, max_value=10)),
                "until": draw(st.integers(min_value=0, max_value=10)),
                "itemKeys": draw(st.lists(st.one_of(
                    _PHASE_KEY_POOL,
                    st.integers(min_value=0, max_value=9), st.none(),
                    st.lists(st.integers(min_value=0, max_value=9),
                             max_size=2),
                    st.fixed_dictionaries(
                        {"a": st.integers(min_value=0, max_value=9)}),
                ), min_size=0, max_size=4)),
            })
    return phases


def _valid_interval(phase: dict) -> bool:
    """oracle：与 compute_phase_coverage 的区间合法判定一致（from < until，
    int 且排除 bool）。"""
    frm = phase.get("from")
    until = phase.get("until")
    return (isinstance(frm, int) and not isinstance(frm, bool)
            and isinstance(until, int) and not isinstance(until, bool)
            and frm < until)


@given(_decl_strategy(), _phases_malformed_strategy())
def test_compute_phase_coverage_tolerates_malformed_phases(decl, phases):
    """红队 Fix 3 + 第二轮 Fix A：畸形 phases（非 dict 元素、itemKeys 字符串/
    int/None、itemKeys 元素级 str/int/dict/list/None 混合、缺键）→ 不崩溃、
    不产生垃圾统计；phase_keys 守恒与 required 守恒仍成立；oracle 重算
    phase_keys == 仅合法区间 dict phase 的 str 元素集合大小（元素非 str
    跳过）；invalid_phases 非负且不超过 phase 总数。"""
    report = compute_phase_coverage(decl, phases)
    assert report["required"] == (
        report["required_with_phase"] + report["required_missing_phase"])
    assert report["phase_keys"] == (
        report["phase_keys_declared"] + report["phase_keys_not_declared"])
    # oracle：phase_keys 只含「合法区间 dict phase 的 itemKeys str 元素」去重
    expected = {
        key
        for phase in phases
        if isinstance(phase, dict)
        and isinstance(phase.get("itemKeys"), list)
        and _valid_interval(phase)
        for key in phase["itemKeys"]
        if isinstance(key, str)
    }
    assert report["phase_keys"] == len(expected)
    assert 0 <= report["invalid_phases"] <= len(phases)
    for value in report.values():
        assert isinstance(value, int) and value >= 0
