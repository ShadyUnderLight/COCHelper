"""Issue #109：声明层 auditStatus（待人工复核清单）测试。测试是契约。

- 种子快照：当前 8 条已知待核实条目标 pending（tripwire——外部核实完成后
  逐条改 verified + note，并同步更新本清单）；
- load_audit_status 失败路径全部 fail loud（值非法 / verified 缺 note）；
- compute_audit_report 纯函数 hypothesis property：分类守恒 + 意外值容忍 +
  排序确定性；
- CLI 端到端：audit 段非阻断输出（与 coverage 段平行）。
"""

import json
from pathlib import Path

import pytest
from hypothesis import given, strategies as st

import game_catalog.lifecycle as lifecycle_module
from game_catalog.errors import CatalogError
from game_catalog.lifecycle import (
    AUDIT_STATUS_VALUES,
    audit_report,
    compute_audit_report,
    load_audit_status,
)

_REPO_ROOT = Path(__file__).resolve().parents[2]
DECLARATIONS = (
    Path(__file__).resolve().parents[1]
    / "game_catalog" / "lifecycle_declarations.json"
)

# 种子快照：Issue #109 已知待核实条目（8 条）。外部核实完成后逐条改
# verified + note 留痕，并同步更新本清单（tripwire，与 test_phase_coverage
# 的 PHASE_COVERAGE_REQUIRED_KEYS 同模式）。
PENDING_AUDIT_KEYS = {
    "units:4000090",
    "guardians:107000002", "guardians:107000003", "guardians:107000004",
    "guardians:107000005", "guardians:107000006", "guardians:107000007",
    "guardians:107000009",
}


def test_audit_status_seed_pending():
    """种子快照：8 条已知待核实条目标 pending；verified 目前为 0；字段值闭枚举。"""
    statuses = load_audit_status()
    pending = {k for k, v in statuses.items() if v == "pending"}
    verified = {k for k, v in statuses.items() if v == "verified"}
    assert pending == PENDING_AUDIT_KEYS
    assert verified == set()
    raw = json.loads(DECLARATIONS.read_text(encoding="utf-8"))["items"]
    for key in PENDING_AUDIT_KEYS:
        assert raw[key]["lifecycle"] == "permanent", f"{key} 种子必须是 permanent"
        assert raw[key]["note"], f"{key} 待核实必须留痕 note"
        assert raw[key]["auditStatus"] == "pending"
    for key, entry in raw.items():
        if "auditStatus" in entry:
            assert entry["auditStatus"] in AUDIT_STATUS_VALUES, key


# ---- load_audit_status：fail loud 失败路径 ----

@pytest.mark.parametrize(
    ("content", "message_fragment"),
    [
        # auditStatus 未知值（闭枚举外）
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "permanent",
                                                "auditStatus": "maybe"}}}, "auditStatus"),
        # auditStatus 非字符串（JSON 数字）
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "permanent",
                                                "auditStatus": 1}}}, "auditStatus"),
        # verified 缺 note（复核留痕证据缺失）
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "permanent",
                                                "auditStatus": "verified"}}}, "缺 note"),
        # verified note 为空串
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "permanent",
                                                "auditStatus": "verified",
                                                "note": ""}}}, "缺 note"),
        # 文件缺失
        (None, "声明文件缺失"),
        # schemaVersion != 1
        ({"schemaVersion": 2, "items": {}}, "schemaVersion"),
        # schemaVersion=true（bool 是 int 子类且 True == 1，R9 绕过类）
        ({"schemaVersion": True, "items": {}}, "schemaVersion"),
        # items 键缺失
        ({"schemaVersion": 1}, "缺少 items"),
        # 条目值非法（非 dict）
        ({"schemaVersion": 1, "items": {"a:1": "pending"}}, "条目非法"),
        # 顶层非 dict
        ([1, 2], "schemaVersion"),
        # JSON 语法错误
        ("{not json", "解析失败"),
    ],
)
def test_load_audit_status_failure_paths(monkeypatch, tmp_path, content, message_fragment):
    """load_audit_status 失败路径全部 fail loud → CatalogError；成功路径用
    真实声明文件（其余测试不受 monkeypatch 影响）。"""
    if content is None:
        path = tmp_path / "missing.json"
    else:
        path = tmp_path / "declarations.json"
        if isinstance(content, str):
            path.write_text(content, encoding="utf-8")
        else:
            path.write_text(json.dumps(content), encoding="utf-8")
    monkeypatch.setattr(lifecycle_module, "DECLARATIONS_PATH", path)
    with pytest.raises(CatalogError) as ei:
        load_audit_status()
    assert message_fragment in str(ei.value)


def test_load_audit_status_ignores_missing_field():
    """无 auditStatus 字段的条目不进入返回（最小侵入：689 条无需复核不带字段）。"""
    statuses = load_audit_status()
    assert len(statuses) == len(PENDING_AUDIT_KEYS)  # 只有种子 8 条
    assert set(statuses) == PENDING_AUDIT_KEYS
    assert set(statuses.values()) == {"pending"}


def test_audit_report_summary():
    """audit_report 真实数据：pending == 种子 8 条；verified == 0。"""
    report = audit_report()
    assert report["pending"] == 8
    assert report["verified"] == 0
    assert set(report["pending_keys"]) == PENDING_AUDIT_KEYS
    assert report["verified_keys"] == []


# ---- compute_audit_report：hypothesis property ----

_status_strategy = st.dictionaries(
    st.text(min_size=1),
    st.sampled_from(("pending", "verified")),
    max_size=50,
)
# 意外值容忍：非 pending/verified 值忽略不崩溃
_status_unexpected_strategy = st.dictionaries(
    st.text(min_size=1),
    st.one_of(st.sampled_from(("pending", "verified")), st.text()),
    max_size=50,
)


@given(_status_strategy)
def test_compute_audit_report_conservation(statuses):
    """分类守恒：pending + verified == 总条目数；key 列表 == 输入 key 集合；
    排序确定性（输出 == 自身排序，重复调用一致）。"""
    report = compute_audit_report(statuses)
    assert report["pending"] + report["verified"] == len(statuses)
    assert set(report["pending_keys"]) | set(report["verified_keys"]) == set(statuses)
    assert report["pending_keys"] == sorted(report["pending_keys"])
    assert report["verified_keys"] == sorted(report["verified_keys"])
    assert compute_audit_report(statuses) == report  # 确定性


@given(_status_unexpected_strategy)
def test_compute_audit_report_tolerates_unexpected(statuses):
    """意外值容忍：非 pending/verified 值被忽略（不崩溃、不计入）。"""
    report = compute_audit_report(statuses)
    recognized = {k for k, v in statuses.items() if v in ("pending", "verified")}
    assert report["pending"] + report["verified"] == len(recognized)


@given(st.dictionaries(st.text(min_size=1), st.text(), max_size=50))
def test_compute_audit_report_empty_degenerate(statuses):
    """退化端点：全部意外值 / 空输入 → 全零（与 compute_phase_coverage 同风格）。"""
    report = compute_audit_report(statuses)
    recognized = {k for k, v in statuses.items() if v in ("pending", "verified")}
    assert report["pending"] + report["verified"] == len(recognized)
    assert report["pending_keys"] == []
    assert report["verified_keys"] == []
