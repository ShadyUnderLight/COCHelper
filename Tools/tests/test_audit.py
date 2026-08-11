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
    """种子快照（数据层）：8 条已知待核实条目带 auditStatus=pending；
    lifecycle=permanent；note 留痕；字段值闭枚举。

    函数层断言（load_audit_status 返回值）在 Task 2 实现后加入
    （test_load_audit_status_ignores_missing_field / test_audit_report_summary）。
    """
    raw = json.loads(DECLARATIONS.read_text(encoding="utf-8"))["items"]
    pending = {
        k for k, v in raw.items()
        if isinstance(v, dict) and v.get("auditStatus") == "pending"
    }
    verified = {
        k for k, v in raw.items()
        if isinstance(v, dict) and v.get("auditStatus") == "verified"
    }
    assert pending == PENDING_AUDIT_KEYS
    assert verified == set()
    for key in PENDING_AUDIT_KEYS:
        assert raw[key]["lifecycle"] == "permanent", f"{key} 种子必须是 permanent"
        assert raw[key]["note"], f"{key} 待核实必须留痕 note"
        assert raw[key]["auditStatus"] == "pending"
    for key, entry in raw.items():
        if isinstance(entry, dict) and "auditStatus" in entry:
            assert entry["auditStatus"] in {"pending", "verified"}, key
