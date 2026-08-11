"""Issue #109：声明层 auditStatus（待人工复核清单）测试。测试是契约。

- 种子快照：8 条已核实条目（Issue #109 1/2 条闭环）标 verified + 证据 note，
  pending 为空（tripwire——核实状态变化时同步更新 VERIFIED_AUDIT_KEYS）；
- load_audit_status 失败路径全部 fail loud（值非法 / verified 缺 note）；
- compute_audit_report 纯函数 hypothesis property：分类守恒 + 意外值容忍 +
  排序确定性；
- CLI 端到端：audit 段非阻断输出（与 coverage 段平行）。

**auditStatus 判据（#109 复审明确）**：只标「permanent 声明、生命周期判定
悬而未决」的条目——与 issue #109 第 1/2 条清单一一对应。其余待核实类型
不在 auditStatus 域内，由既有机制跟踪，不重复标注：
- seasonalCandidate 的待核实（如 pets:73000006「待外部核实」note）→ 已由
  #112 phaseCoverage=unknown + coverage 报告结构化跟踪（未知日期候选），
  加 pending 会造成双轨；
- 常驻白名单人工判定（PERMANENT_FESTIVE_LOOKING_KEYS 系「人工判定，待复核」
  note）→ 判定结论已在 note 留痕，复核记录即 note 本身。
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

DECLARATIONS = (
    Path(__file__).resolve().parents[1]
    / "game_catalog" / "lifecycle_declarations.json"
)

# 种子快照（tripwire，与 test_phase_coverage 的 PHASE_COVERAGE_REQUIRED_KEYS
# 同模式）：
# - VERIFIED_AUDIT_KEYS：Issue #109 1/2 条已外部核实的 8 条（APK provenance +
#   官方模式语义证据链，2026-08-11 核实完成）——保持 permanent + verified +
#   note 证据留痕；
# - PENDING_AUDIT_KEYS：当前无待核实条目（新发现待核实条目时加入并标 pending）。
# 后续任何核实状态变化必须同步更新本清单。
VERIFIED_AUDIT_KEYS = {
    "units:4000090",
    "guardians:107000002", "guardians:107000003", "guardians:107000004",
    "guardians:107000005", "guardians:107000006", "guardians:107000007",
    "guardians:107000009",
}
PENDING_AUDIT_KEYS: set[str] = set()


def test_audit_status_seed_verified():
    """种子快照：8 条已知待核实条目已核实为 verified（Issue #109 1/2 条闭环）；
    pending 当前为空；字段值闭枚举。"""
    statuses = load_audit_status()
    pending = {k for k, v in statuses.items() if v == "pending"}
    verified = {k for k, v in statuses.items() if v == "verified"}
    assert pending == PENDING_AUDIT_KEYS
    assert verified == VERIFIED_AUDIT_KEYS
    raw = json.loads(DECLARATIONS.read_text(encoding="utf-8"))["items"]
    for key in VERIFIED_AUDIT_KEYS:
        assert raw[key]["lifecycle"] == "permanent", f"{key} 核实后必须是 permanent"
        assert raw[key]["note"], f"{key} 核实必须留痕 note（证据链）"
        assert raw[key]["auditStatus"] == "verified"
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
        # 非 permanent 携带 auditStatus（P3：seasonalCandidate 待核实由
        # phaseCoverage=unknown 跟踪，auditStatus 双轨会被拒）
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "seasonalCandidate",
                                                "auditStatus": "pending",
                                                "phaseCoverage": "unknown",
                                                "note": "n"}}}, "仅允许 permanent"),
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": None,
                                                "auditStatus": "pending",
                                                "note": "n"}}}, "条目非法"),
        # verified 缺 note（复核留痕证据缺失）
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "permanent",
                                                "auditStatus": "verified"}}}, "缺 note"),
        # verified note 为空串
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "permanent",
                                                "auditStatus": "verified",
                                                "note": ""}}}, "缺 note"),
        # verified note 全空白（P4：非空字符串，拒绝空白）
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "permanent",
                                                "auditStatus": "verified",
                                                "note": "   "}}}, "缺 note"),
        # verified note 非字符串（P4：对象/数组/数字均拒绝）
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "permanent",
                                                "auditStatus": "verified",
                                                "note": {"url": "x"}}}}, "缺 note"),
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "permanent",
                                                "auditStatus": "verified",
                                                "note": ["x"]}}}, "缺 note"),
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "permanent",
                                                "auditStatus": "verified",
                                                "note": 123}}}, "缺 note"),
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
    """无 auditStatus 字段的条目不进入返回（最小侵入：689 条无需复核不带字段）；
    带字段的 8 条全部 verified。"""
    statuses = load_audit_status()
    assert len(statuses) == len(VERIFIED_AUDIT_KEYS)  # 只有核实过的 8 条
    assert set(statuses) == VERIFIED_AUDIT_KEYS
    assert set(statuses.values()) == {"verified"}


def test_audit_report_summary():
    """audit_report 真实数据：pending == 0（无待核实）；verified == 8 条。"""
    report = audit_report()
    assert report["pending"] == 0
    assert report["verified"] == 8
    assert report["pending_keys"] == []
    assert set(report["verified_keys"]) == VERIFIED_AUDIT_KEYS


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
    """分类守恒：pending + verified == 总条目数；pending/verified 列表互斥
    （无同 key 双计，union 断言不够——重叠 key 会掩盖 len 守恒）；key 列表
    == 输入 key 集合；排序确定性（输出 == 自身排序，重复调用一致）。"""
    report = compute_audit_report(statuses)
    assert report["pending"] + report["verified"] == len(statuses)
    assert len(report["pending_keys"]) == report["pending"]
    assert len(report["verified_keys"]) == report["verified"]
    # 互斥：同 key 不得同时出现在两个列表（union 断言无法捕获重叠）
    assert set(report["pending_keys"]) & set(report["verified_keys"]) == set()
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
    """退化端点：任意值输入（含意外值）不崩溃；计数与 key 列表精确匹配
    （意外值忽略，与容忍语义一致）。"""
    report = compute_audit_report(statuses)
    recognized = {k for k, v in statuses.items() if v in ("pending", "verified")}
    assert report["pending"] + report["verified"] == len(recognized)
    assert report["pending_keys"] == sorted(
        k for k, v in statuses.items() if v == "pending")
    assert report["verified_keys"] == sorted(
        k for k, v in statuses.items() if v == "verified")


# ---- validate 端到端门禁（P2：非法 auditStatus 必须进 validator errors）----

def _minimal_catalog_dir(tmp_path) -> Path:
    """最小合法目录（Town Hall + craft 条目），供 validate 门禁测试。"""
    import hashlib
    from game_catalog.model import (
        Catalog, CatalogItem, CatalogLevel, catalog_to_dict,
    )
    d = tmp_path / "cat"
    d.mkdir()
    item = CatalogItem(
        section="buildings", dataID=1000001, category="buildings", base="home",
        baseMissingReason=None, name="Town Hall", maxLevel=1,
        icon=None, levelVisual=None, missingReason=None,
        levels=[CatalogLevel(level=1, durationSeconds=0, missingReason=None,
                             upgradeCosts=None, requiredTownHallLevel=None,
                             requiredLaboratoryLevel=None, icon=None, levelVisual=None)],
        lifecycle="permanent")
    catalog = Catalog(schemaVersion=2, gameVersion="18.400.13", locale="zh-CN",
                      items=[item])
    cat_bytes = json.dumps(catalog_to_dict(catalog), ensure_ascii=False).encode("utf-8")
    (d / "catalog.json").write_bytes(cat_bytes)
    (d / "icons").mkdir()
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","buildTag":"18_400_7","locale":"zh-CN","source":"t","defenses":[],"modules":[]}\n'
    (d / "craft_table_catalog.json").write_bytes(craft_bytes)
    (d / "manifest.json").write_text(json.dumps({
        "schemaVersion": 2, "gameVersion": "18.400.13", "buildTag": "18_400_7",
        "locale": "zh-CN", "sourceFingerprint": "sha256:" + "a" * 64,
        "generatedFiles": [
            {"path": "catalog.json",
             "sha256": "sha256:" + hashlib.sha256(cat_bytes).hexdigest(),
             "size": len(cat_bytes)},
            {"path": "icons/", "kind": "directory"},
            {"path": "craft_table_catalog.json",
             "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
             "size": len(craft_bytes)},
        ],
        "counts": {"items": 1, "levels": 1, "missingTime": 0, "missingIcons": 0},
    }, ensure_ascii=False))
    return d


def test_validate_rejects_invalid_audit_status(monkeypatch, tmp_path):
    """P2：声明文件 auditStatus 字段非法（未知值）→ validate_catalog errors
    必须包含 auditStatus 错误（fail loud 端到端门禁，不得被 CLI 吞掉）。
    monkeypatch lifecycle 模块的 DECLARATIONS_PATH 即可——validate 内部
    调用的 load_audit_status 读该常量。"""
    import game_catalog.validate as validate_module
    path = tmp_path / "declarations.json"
    path.write_text(json.dumps({"schemaVersion": 1, "items": {
        "buildings:1000001": {"lifecycle": "permanent", "auditStatus": "typo"}}}),
        encoding="utf-8")
    monkeypatch.setattr(lifecycle_module, "DECLARATIONS_PATH", path)
    d = _minimal_catalog_dir(tmp_path)
    errors = validate_module.validate_catalog(d)
    assert any("auditStatus" in e and "未知值" in e for e in errors), errors


def test_validate_rejects_verified_without_note(monkeypatch, tmp_path):
    """P2：verified 缺 note → validate errors 必须包含（复核留痕证据缺失
    是内容错误，不得非阻断）。"""
    import game_catalog.validate as validate_module
    path = tmp_path / "declarations.json"
    path.write_text(json.dumps({"schemaVersion": 1, "items": {
        "buildings:1000001": {"lifecycle": "permanent", "auditStatus": "verified"}}}),
        encoding="utf-8")
    monkeypatch.setattr(lifecycle_module, "DECLARATIONS_PATH", path)
    d = _minimal_catalog_dir(tmp_path)
    errors = validate_module.validate_catalog(d)
    assert any("auditStatus" in e and "缺 note" in e for e in errors), errors


def test_validate_rejects_audit_status_on_seasonal(monkeypatch, tmp_path):
    """P3：seasonalCandidate 携带 auditStatus → validate errors 必须包含
    （双轨跟踪禁止，与 phaseCoverage 域分离）。"""
    import game_catalog.validate as validate_module
    path = tmp_path / "declarations.json"
    path.write_text(json.dumps({"schemaVersion": 1, "items": {
        "buildings:1000001": {"lifecycle": "seasonalCandidate",
                              "auditStatus": "pending",
                              "phaseCoverage": "unknown", "note": "n"}}}),
        encoding="utf-8")
    monkeypatch.setattr(lifecycle_module, "DECLARATIONS_PATH", path)
    d = _minimal_catalog_dir(tmp_path)
    errors = validate_module.validate_catalog(d)
    assert any("auditStatus" in e and "仅允许 permanent" in e for e in errors), errors


def test_validate_accepts_wellformed_audit_status():
    """P2 正向：真实声明文件（8 条合法 verified 条目）→ validate 不报
    auditStatus 错误（基线对照）。"""
    import game_catalog.validate as validate_module
    errors = validate_module.validate_catalog(
        Path(__file__).resolve().parents[2]
        / "Sources/COCHelperCore/GameCatalog/18.400.13")
    assert not any("auditStatus" in e for e in errors), errors
