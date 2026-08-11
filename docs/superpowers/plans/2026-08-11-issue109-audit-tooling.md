# Issue #109 审计工具化：auditStatus 结构化复核状态 + 待复核清单

日期：2026-08-11
分支：codex/issue-109-audit-tooling
依据：issue #109 第 3 条（流程性盲区工具化）+ 评审修正（note 是自由文本不可做状态分类，#112 先例；不锁死清单为契约、只锁种子快照）

## 1. 范围

- **结构化复核状态**：`lifecycle_declarations.json` 条目新增可选 `auditStatus: "pending" | "verified"` 字段
  - `pending` = 生命周期判定待外部核实（官方公告/维基/APK 对拍）
  - `verified` = 已人工复核确认，**note 必须非空**（复核留痕证据）
  - 无字段 = 无需复核（不强制全量标注，最小侵入）
- **审计报告**：`audit_report()` + 纯函数 `compute_audit_report()`（与 #112 `coverage_report`/`compute_phase_coverage` 同构）
- **CLI 接入**：`validate_game_catalog.py` 非阻断输出 `audit:` 段（与 `coverage:` 段平行；失败打印 unavailable 不改退出码）
- **种子数据**：8 条已知待核实条目（units:4000090 + guardians:107000002~107000007/107000009）标 `pending`
- **测试**：单测 + hypothesis property 测试 + CLI 端到端

**不做**：不改任何 lifecycle 值（permanent/seasonalCandidate 不动——数据核实是 issue 1、2 条）；不改 catalog.json/manifest（auditStatus 是声明层私有字段）；不做 #113 冲突契约；不自动判定可疑条目（侦察证实误报爆炸，非本方案）。

## 2. 现状证据（已验证）

| 项 | 现状 |
|---|---|
| lifecycle.py | 已有 `load_declarations`/`load_phase_coverage`/`coverage_report`/`compute_phase_coverage`（#98/#112），fail loud 风格一致 |
| lifecycle_declarations.json | 697 条声明；8 条已知待核实条目（note 留痕"待外部核实"） |
| validate_game_catalog.py | 已有 `_emit_coverage_report` 非阻断输出先例（#112） |
| 数据侦察 | 单级 stub 规则命中 39 条正常常驻单位、跨 section 同名 108 个——自动特征规则误报爆炸，不可行；人工复核无法自动化，只能流程化 |
| 测试基线 | Python 812 passed / 2 skipped |

## 3. 类型契约（定稿）

### lifecycle.py 新增

```python
# 声明层审计状态闭枚举（Issue #109：note 自由文本不可做状态分类，#112 同款教训）
AUDIT_STATUS_VALUES: frozenset[str] = frozenset({"pending", "verified"})

def load_audit_status() -> dict[str, str]:
    """读声明文件 → {key: auditStatus}（仅带 auditStatus 字段的条目）。

    - auditStatus 值非闭枚举 → CatalogError（fail loud）；
    - verified 条目 note 为空/缺失 → CatalogError（复核留痕证据）；
    - 无 auditStatus 字段的条目 = 无需复核，不进入返回；
    - 文件缺失/解析失败/schemaVersion != 1 → CatalogError（与既有 loader 同口径）。
    """

def compute_audit_report(statuses: dict[str, str]) -> dict:
    """纯函数审计统计（property 测试目标），输入 {key: auditStatus}：
    返回 {"pending", "verified", "pending_keys", "verified_keys"}。
    - 意外值（非 pending/verified）忽略不崩溃（load 层已 fail loud，纯函数
      不重复校验，与 compute_phase_coverage 容忍语义一致）；
    - key 列表排序输出（确定性，便于测试与人工阅读）。
    """

def audit_report() -> dict:
    """真实数据审计报告：声明文件 auditStatus 统计（Issue #109）。
    待复核清单 = pending_keys；文件缺失/解析失败/字段非法 → CatalogError
    （与 coverage_report 同口径 fail loud）。
    """
```

### CLI（validate_game_catalog.py）新增

```python
def _emit_audit_report() -> None:
    """Issue #109：非阻断输出审计统计（待人工复核清单）。

    与 _emit_coverage_report 同模式：独立于 validate_catalog errors（评审
    红线：errors 非空即失败，诊断文本不得混入）；失败打印 unavailable
    不影响退出码。
    """
    # 输出示例：
    # audit: pending=8 verified=0
    # audit: pendingItems=guardians:107000002,guardians:107000003,...
```

### 声明条目结构（种子）

```json
"units:4000090": {
  "lifecycle": "permanent",
  "auditStatus": "pending",
  "note": "雷霆皮卡（home 单级 stub 无成本无时长）——..."
}
```

## 4. 数据变更（种子）

8 条加 `"auditStatus": "pending"`：`units:4000090` + `guardians:107000002/3/4/5/6/7/9`。其余 689 条不加字段。

## 5. 任务分解（TDD）

### Task 1: 种子数据 + 真实数据断言测试

**Files:**
- Modify: `Tools/game_catalog/lifecycle_declarations.json`（8 条加 auditStatus）
- Create: `Tools/tests/test_audit.py`

- [ ] **Step 1: 写失败测试**（test_audit.py 头部，`PENDING_AUDIT_KEYS` 种子快照断言）

```python
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
```

- [ ] **Step 2: 运行验证红**（当前无字段，pending=∅）

```bash
python3 -m pytest Tools/tests/test_audit.py::test_audit_status_seed_pending -q
# 预期 FAIL：pending == PENDING_AUDIT_KEYS 断言失败（当前 statuses 为空）
```

- [ ] **Step 3: 数据种子**（lifecycle_declarations.json，8 条加字段；保持原 note）

以 `"units:4000090"` 为例，在现有条目上加一行 `"auditStatus": "pending",`（其余 7 条 guardians 同）。用脚本批量完成并格式化（先备份）：

```bash
python3 - <<'EOF'
import json
from pathlib import Path
p = Path('Tools/game_catalog/lifecycle_declarations.json')
raw = json.loads(p.read_text(encoding='utf-8'))
seeds = {'units:4000090', 'guardians:107000002', 'guardians:107000003',
         'guardians:107000004', 'guardians:107000005', 'guardians:107000006',
         'guardians:107000007', 'guardians:107000009'}
for key in seeds:
    entry = raw['items'][key]
    assert entry.get('auditStatus') is None, key
    entry['auditStatus'] = 'pending'
p.write_text(json.dumps(raw, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('seeded', len(seeds))
EOF
```

- [ ] **Step 4: 运行验证绿**

```bash
python3 -m pytest Tools/tests/test_audit.py::test_audit_status_seed_pending -q
# 预期 PASS
```

- [ ] **Step 5: 提交**

```bash
git add Tools/game_catalog/lifecycle_declarations.json Tools/tests/test_audit.py
git commit -m "feat(catalog): auditStatus 声明层复核状态 + 8 条待核实种子 (Issue #109)"
```

### Task 2: lifecycle.py 审计函数（TDD）

**Files:**
- Modify: `Tools/game_catalog/lifecycle.py`（AUDIT_STATUS_VALUES + 3 函数）
- Modify: `Tools/tests/test_audit.py`（追加失败路径 + property 测试）

- [ ] **Step 1: 写失败测试**（test_audit.py 追加）

```python
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
```

- [ ] **Step 2: 运行验证红**

```bash
python3 -m pytest Tools/tests/test_audit.py -q
# 预期：新增测试 FAIL（load_audit_status / compute_audit_report / audit_report 未定义）
```

- [ ] **Step 3: 实现**（lifecycle.py，`LIFECYCLE_VALUES` 定义之后追加）

```python
# 声明层审计状态闭枚举（Issue #109：note 是自由文本不可做状态分类，
# 与 #112 phaseCoverage 同款教训——待人工复核/已复核用结构化字段表达）。
AUDIT_STATUS_VALUES: frozenset[str] = frozenset({"pending", "verified"})


def load_audit_status() -> dict[str, str]:
    """读声明文件 → {key: auditStatus}（仅带 auditStatus 字段的条目）。

    Issue #109 流程工具化：auditStatus 把「note 自由文本里的待核实留痕」
    升级为结构化复核状态——
    - "pending"：生命周期判定待外部核实（官方公告/维基/APK 对拍）；
    - "verified"：已人工复核确认，note 必须非空（复核留痕证据）；
    - 无 auditStatus 字段 = 无需复核，不进入返回（最小侵入，不强制全量）。
    值非闭枚举 / verified 缺 note → CatalogError（fail loud，声明文件是
    唯一事实源）。文件缺失/解析失败/schemaVersion != 1 → CatalogError
    （与 load_declarations/load_phase_coverage 同口径）。
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
        status = entry.get("auditStatus")
        if status is None:
            continue
        if not isinstance(status, str) or status not in AUDIT_STATUS_VALUES:
            raise CatalogError(
                f"lifecycle 声明 auditStatus 未知值: {key}: {status!r}")
        if status == "verified" and not entry.get("note"):
            raise CatalogError(
                f"lifecycle 声明 verified 条目缺 note（复核留痕证据）: {key}")
        out[key] = status
    return out


def compute_audit_report(statuses: dict[str, str]) -> dict:
    """纯函数审计统计（property 测试目标）。

    Issue #109。输入契约：{key: auditStatus}，值 pending/verified（来自
    load_audit_status 输出——实际调用路径不会传 None/非 dict，非 dict 输入
    不在本函数契约内）。不做 load 校验——load 由 load_audit_status 负责，
    纯函数不重复校验；意外值按「非 pending 非 verified」忽略不崩溃（与
    compute_phase_coverage 容忍语义一致）。

    返回（全部非负整数/字符串列表）：
    - pending / verified：分类计数（守恒：pending + verified == 输入条目数）；
    - pending_keys / verified_keys：排序后的 key 列表（确定性，人工阅读
      即待复核清单）。
    """
    pending = [key for key, value in statuses.items() if value == "pending"]
    verified = [key for key, value in statuses.items() if value == "verified"]
    return {
        "pending": len(pending),
        "verified": len(verified),
        "pending_keys": sorted(pending),
        "verified_keys": sorted(verified),
    }


def audit_report() -> dict[str, int | list[str]]:
    """真实数据审计报告：声明文件 auditStatus 统计（Issue #109 流程工具化）。

    待人工复核清单 = pending_keys——维护者每次新增游戏版本目录后运行
    validator，对照 Supercell 官方公告 / 官方维基 Temporary Troops/Spells/
    Traps 清单逐条复核；复核后改 verified + note 留痕（清单即减）。
    文件缺失/解析失败/字段非法 → CatalogError（与 coverage_report 同口径
    fail loud）。只读声明文件，不触碰 catalog 产物。
    """
    return compute_audit_report(load_audit_status())
```

- [ ] **Step 4: 运行验证绿**

```bash
python3 -m pytest Tools/tests/test_audit.py -q
# 预期：全部 PASS（含 Task 1 种子测试）
python3 -m pytest Tools/tests -q
# 预期：812 + 新增全部 PASS（无回归）
```

- [ ] **Step 5: 提交**

```bash
git add Tools/game_catalog/lifecycle.py Tools/tests/test_audit.py
git commit -m "feat(catalog): auditStatus 加载/报告函数 + fail loud + property 测试 (Issue #109)"
```

### Task 3: CLI 接入（TDD）

**Files:**
- Modify: `Tools/validate_game_catalog.py`（_emit_audit_report + main 调用）
- Modify: `Tools/tests/test_cli.py`（端到端测试）

- [ ] **Step 1: 写失败测试**（test_cli.py 追加；先看现有 coverage 测试的 fixture 用法：`test_validate_cli_emits_coverage_report` 使用 `full_minimal_apk` + `tmp_path` 生成目录后跑 validate CLI）

```python
def test_validate_cli_emits_audit_report(full_minimal_apk, tmp_path):
    """Issue #109：audit 段接入 validator CLI（非阻断诊断输出）。

    与 coverage 段平行：validator 输出必须含 audit: 行（种子 8 条 pending →
    pending=8），且不改变 verdict/退出码。
    """
    apk = full_minimal_apk
    out = tmp_path / "out"
    r = _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
              "--output", str(out), "--game-version", "18.400.13"])
    assert r.returncode == 0, r.stderr
    r = _run([str(TOOLS / "validate_game_catalog.py"), "--catalog", str(out)])
    assert r.returncode == 0, r.stderr
    assert "audit:" in r.stdout, "validator 必须输出 audit 报告段"
    assert "pending=8" in r.stdout
    assert "pendingItems=" in r.stdout
    assert "verdict: OK" in r.stdout


def test_validate_cli_audit_unavailable_does_not_fail(full_minimal_apk, tmp_path, monkeypatch):
    """Issue #109：audit 报告是非阻断诊断——audit_report 抛 CatalogError
    （声明文件缺失）时 validator 必须仍然成功（verdict OK、退出码 0）。"""
    import validate_game_catalog as vgc
    apk = full_minimal_apk
    out = tmp_path / "out"
    r = _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
              "--output", str(out), "--game-version", "18.400.13"])
    assert r.returncode == 0, r.stderr

    def _boom():
        raise CatalogError("声明文件缺失")
    monkeypatch.setattr(vgc, "audit_report", _boom)
    r = _run([str(TOOLS / "validate_game_catalog.py"), "--catalog", str(out)])
    assert r.returncode == 0, "audit 报告失败不得改变 validator 退出码"
    assert "audit: unavailable" in r.stderr
    assert "verdict: OK" in r.stdout
```

- [ ] **Step 2: 运行验证红**

```bash
python3 -m pytest Tools/tests/test_cli.py -k audit -q
# 预期：FAIL（audit: 段不存在）
```

- [ ] **Step 3: 实现**（validate_game_catalog.py）

```python
from game_catalog.lifecycle import audit_report, coverage_report


def _emit_audit_report() -> None:
    """Issue #109：非阻断输出审计统计（待人工复核清单）。

    与 _emit_coverage_report 同模式：独立于 validate_catalog 的 errors
    （评审红线：errors 非空即失败，诊断文本不得混入）；文件缺失/解析失败
    → 打印 unavailable 提示，不影响退出码。
    """
    try:
        audit = audit_report()
    except CatalogError as exc:
        print(f"audit: unavailable: {exc}", file=sys.stderr)
        return
    print(f"audit: pending={audit['pending']} verified={audit['verified']}")
    if audit["pending_keys"]:
        print("audit: pendingItems=" + ",".join(audit["pending_keys"]))
```

main() 中 `_emit_coverage_report(args.catalog)` 之后加 `_emit_audit_report()`。

- [ ] **Step 4: 运行验证绿**

```bash
python3 -m pytest Tools/tests/test_cli.py -k audit -q
# 预期：PASS
python3 -m pytest Tools/tests -q
# 预期：全部 PASS
```

- [ ] **Step 5: 提交**

```bash
git add Tools/validate_game_catalog.py Tools/tests/test_cli.py
git commit -m "feat(tools): validator CLI 接入 audit 待复核清单输出 (Issue #109)"
```

### Task 4: 全量回归 + 收尾

**Files:** 无新增

- [ ] **Step 1: 全量测试**

```bash
python3 -m pytest Tools/tests -q
# 预期：全部 PASS（812 基线 + 新增）
git diff --check
```

- [ ] **Step 2: 手工验证 CLI 输出**（真实目录）

```bash
python3 Tools/validate_game_catalog.py --catalog Sources/COCHelperCore/GameCatalog/18.400.13
# 预期：stdout 含 "audit: pending=8 verified=0" + pendingItems 行；verdict: OK
```

- [ ] **Step 3: 提交**（如有 diff）

```bash
git add -A
git commit -m "test: Issue #109 审计工具化全量回归通过"  # 无 diff 则跳过
```

## 6. 边界与风险

- **不顺手做**：#113（permanent+phase 冲突契约，独立 issue）；issue 1、2 条的数据核实（外部证据未取得）；不给 689 条无需复核条目加字段（最小侵入）；不改 catalog.json/manifest（auditStatus 声明层私有）。
- **种子快照锁定的风险**：外部核实完成后 pending 集合会变化——测试 tripwire 会红，需同步更新 `PENDING_AUDIT_KEYS`（与 #112 `PHASE_COVERAGE_REQUIRED_KEYS` 同模式，注释已说明）。
- **回归风险低**：纯新增函数 + 可选字段（无字段条目不进入返回，load_declarations/load_phase_coverage 不读 auditStatus，行为不变）；CLI 输出是追加行，不影响既有断言。
