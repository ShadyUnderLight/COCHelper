"""Task 6/7: CLI 入口退出码契约（subprocess 端到端）。"""

import lzma
import subprocess
import sys
import zipfile
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[2] / "Tools"


def _run(args: list[str]):
    return subprocess.run([sys.executable, *args], capture_output=True, text=True)


def test_generate_cli_success(full_minimal_apk, tmp_path):
    apk = full_minimal_apk
    out = tmp_path / "out"
    r = _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
              "--output", str(out), "--game-version", "18.400.13"])
    assert r.returncode == 0, r.stderr
    assert (out / "catalog.json").exists()
    assert (out / "manifest.json").exists()


def test_generate_cli_missing_apk_fails(full_minimal_apk, tmp_path):
    r = _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(tmp_path / "nope.apk"),
              "--output", str(tmp_path / "out")])
    assert r.returncode == 1


def test_generate_cli_bad_zip_fails_cleanly(full_minimal_apk, tmp_path):
    """I5 回归：非 zip 输入 → exit 1 且 stderr 含 'error:'，无裸 traceback。"""
    apk = tmp_path / "not_an_apk.txt"
    apk.write_text("this is not a zip file")
    r = _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
              "--output", str(tmp_path / "out")])
    assert r.returncode == 1
    assert "error:" in r.stderr
    assert "Traceback" not in r.stderr


def test_generate_cli_nonempty_output_fails(full_minimal_apk, tmp_path):
    apk = full_minimal_apk
    out = tmp_path / "out"
    out.mkdir()
    (out / "x.txt").write_text("x")
    r = _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
              "--output", str(out)])
    assert r.returncode == 1


def test_generate_cli_usage_error(full_minimal_apk, tmp_path):
    r = _run([str(TOOLS / "generate_game_catalog.py")])
    assert r.returncode == 2


def test_validate_cli_success(full_minimal_apk, tmp_path):
    apk = full_minimal_apk
    out = tmp_path / "out"
    _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
          "--output", str(out), "--game-version", "18.400.13"])
    # Issue #98 复审 P1：合成 APK 无 seasonal_defense 表（craft 生成器不可跑），
    # 手工模拟 craft 生成器登记（写 craft 文件 + manifest 条目）——CLI validator
    # 默认强制 craft 条目存在，完整链产物必须配套。
    import hashlib, json
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","buildTag":"18_400_7","locale":"zh-CN","source":"t","defenses":[],"modules":[]}\n'
    (out / "craft_table_catalog.json").write_bytes(craft_bytes)
    mp = out / "manifest.json"
    m = json.loads(mp.read_text(encoding="utf-8"))
    m["generatedFiles"].append({"path": "craft_table_catalog.json",
                                "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
                                "size": len(craft_bytes)})
    mp.write_text(json.dumps(m, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    r = _run([str(TOOLS / "validate_game_catalog.py"), "--catalog", str(out)])
    assert r.returncode == 0, r.stderr
    assert "verdict: OK" in r.stdout


def test_validate_cli_emits_coverage_report(full_minimal_apk, tmp_path):
    """Issue #112：coverage 报告接入 validator CLI（非阻断诊断输出）。

    validate_game_catalog.py 是维护者的正常校验入口，必须能在校验流程中看到
    seasonalCandidate ↔ phase 覆盖统计（评审 P1：coverage_report 此前只有函数
    定义和单测调用，无 CLI 消费者）。断言输出段存在且数字为真实数据值；退出码
    仍由目录校验决定（非阻断）。"""
    apk = full_minimal_apk
    out = tmp_path / "out"
    _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
          "--output", str(out), "--game-version", "18.400.13"])
    import hashlib
    import json
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","buildTag":"18_400_7","locale":"zh-CN","source":"t","defenses":[],"modules":[]}\n'
    (out / "craft_table_catalog.json").write_bytes(craft_bytes)
    mp = out / "manifest.json"
    m = json.loads(mp.read_text(encoding="utf-8"))
    m["generatedFiles"].append({"path": "craft_table_catalog.json",
                                "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
                                "size": len(craft_bytes)})
    mp.write_text(json.dumps(m, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    r = _run([str(TOOLS / "validate_game_catalog.py"), "--catalog", str(out)])
    assert r.returncode == 0, r.stderr
    assert "verdict: OK" in r.stdout
    assert "coverage:" in r.stdout, "validator 必须输出 coverage 报告段"
    assert "seasonalCandidates=71" in r.stdout
    assert "required=4" in r.stdout and "unknown=67" in r.stdout
    assert "requiredMissingPhase=0" in r.stdout


def test_validate_cli_coverage_unavailable_does_not_fail(full_minimal_apk, tmp_path, monkeypatch):
    """Issue #112 评审 P1：coverage 报告是非阻断诊断——声明/阶段表文件缺失
    （coverage_report 抛 CatalogError）时 validator 必须仍然成功（verdict OK、
    退出码 0），只输出 unavailable 提示，不把诊断文本混入 errors。"""
    import validate_game_catalog as vgc
    from game_catalog.errors import CatalogError

    apk = full_minimal_apk
    out = tmp_path / "out"
    _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
          "--output", str(out), "--game-version", "18.400.13"])
    import hashlib
    import json
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","buildTag":"18_400_7","locale":"zh-CN","source":"t","defenses":[],"modules":[]}\n'
    (out / "craft_table_catalog.json").write_bytes(craft_bytes)
    mp = out / "manifest.json"
    m = json.loads(mp.read_text(encoding="utf-8"))
    m["generatedFiles"].append({"path": "craft_table_catalog.json",
                                "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
                                "size": len(craft_bytes)})
    mp.write_text(json.dumps(m, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    monkeypatch.setattr(vgc, "coverage_report",
                        lambda version=None: (_ for _ in ()).throw(CatalogError("声明文件缺失: /nope")))
    rc = vgc.main(["--catalog", str(out)])
    assert rc == 0, "coverage 报告失败不得改变 validator 退出码"


def test_validate_cli_coverage_binds_catalog_game_version(full_minimal_apk, tmp_path, monkeypatch):
    """评审 follow-up：coverage 报告必须绑定 --catalog 的 manifest.gameVersion
    （而非固定 18.400.13）——_emit_coverage_report 从 manifest 读 gameVersion
    传给 coverage_report(version=...)。"""
    import validate_game_catalog as vgc

    apk = full_minimal_apk
    out = tmp_path / "out"
    _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
          "--output", str(out), "--game-version", "18.400.13"])
    import hashlib
    import json
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","buildTag":"18_400_7","locale":"zh-CN","source":"t","defenses":[],"modules":[]}\n'
    (out / "craft_table_catalog.json").write_bytes(craft_bytes)
    mp = out / "manifest.json"
    m = json.loads(mp.read_text(encoding="utf-8"))
    m["generatedFiles"].append({"path": "craft_table_catalog.json",
                                "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
                                "size": len(craft_bytes)})
    mp.write_text(json.dumps(m, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    seen: list[str | None] = []

    def fake_coverage_report(version=None):
        seen.append(version)
        return {"seasonal_candidates": 0, "required": 0, "unknown": 0,
                "required_with_phase": 0, "required_missing_phase": 0,
                "phase_keys": 0, "phase_keys_declared": 0,
                "phase_keys_not_declared": 0, "invalid_phases": 0}

    monkeypatch.setattr(vgc, "coverage_report", fake_coverage_report)
    rc = vgc.main(["--catalog", str(out)])
    assert rc == 0, "validator 应通过"
    assert seen == ["18.400.13"], \
        f"必须从 manifest.gameVersion 绑定版本，实际传入: {seen}"


def test_validate_cli_lifecycle_phase_conflict_fails(full_minimal_apk, tmp_path, monkeypatch, capsys):
    """Issue #113：permanent 声明与官方阶段表冲突 → blocking error（退出码 1）。

    冲突必须走 errors 阻断路径（红线：不得塞进 coverage 非阻断分支——对比
    test_validate_cli_coverage_unavailable_does_not_fail：coverage 失败仍返回 0，
    冲突失败必须返回 1）。stderr 含 key/phaseID/provenance（声明文件路径/阶段
    文件路径/sourceURL），verdict: FAIL。版本绑定与 coverage 同模式（manifest
    gameVersion → _phases_path，此处 monkeypatch 到 tmp 冲突数据）。"""
    import validate_game_catalog as vgc
    from game_catalog import lifecycle as lifecycle_module

    apk = full_minimal_apk
    out = tmp_path / "out"
    _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
          "--output", str(out), "--game-version", "18.400.13"])
    import hashlib
    import json
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","buildTag":"18_400_7","locale":"zh-CN","source":"t","defenses":[],"modules":[]}\n'
    (out / "craft_table_catalog.json").write_bytes(craft_bytes)
    mp = out / "manifest.json"
    m = json.loads(mp.read_text(encoding="utf-8"))
    m["generatedFiles"].append({"path": "craft_table_catalog.json",
                                "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
                                "size": len(craft_bytes)})
    mp.write_text(json.dumps(m, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    # 注入冲突数据：声明 Town Hall（buildings:1000001）permanent，官方阶段表命中该 key
    decl = tmp_path / "lifecycle_declarations.json"
    decl.write_text(json.dumps({"schemaVersion": 1, "items": {
        "buildings:1000001": {"lifecycle": "permanent"}}}, ensure_ascii=False),
        encoding="utf-8")
    phases = tmp_path / "seasonal_phases.json"
    phases.write_text(json.dumps({"schemaVersion": 1, "phases": [
        {"phaseID": "p1", "name": "阶段一", "from": 1, "until": 2,
         "itemKeys": ["buildings:1000001"],
         "sourceURL": "https://supercell.example/phase"}]},
        ensure_ascii=False), encoding="utf-8")
    monkeypatch.setattr(lifecycle_module, "DECLARATIONS_PATH", decl)
    monkeypatch.setattr(lifecycle_module, "_phases_path", lambda version: phases)

    rc = vgc.main(["--catalog", str(out)])
    assert rc == 1, "permanent ∩ 阶段表冲突必须 blocking（退出码 1）"
    captured = capsys.readouterr()
    assert "verdict: FAIL" in captured.out
    assert "buildings:1000001" in captured.err, captured.err
    assert "phases=[p1(阶段一)]" in captured.err, captured.err
    assert str(decl) in captured.err, "error 必须携带声明文件路径 provenance"
    assert str(phases) in captured.err, "error 必须携带阶段文件路径 provenance"
    assert "https://supercell.example/phase" in captured.err, \
        "error 必须携带官方来源 sourceURL provenance"


def test_validate_cli_multiple_phase_conflicts_reported(
    full_minimal_apk, tmp_path, monkeypatch, capsys
):
    """Issue #113 审计 F6：permanent key 命中多个 phase → error 消息列出全部
    phaseID（phases=[...]），维护者无需逐个猜测（Python 数据审计视角报告全部，
    Swift 运行时取单一确定性选择——两侧都可见完整候选集）。"""
    import validate_game_catalog as vgc
    from game_catalog import lifecycle as lifecycle_module

    apk = full_minimal_apk
    out = tmp_path / "out"
    _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
          "--output", str(out), "--game-version", "18.400.13"])
    import hashlib
    import json
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","buildTag":"18_400_7","locale":"zh-CN","source":"t","defenses":[],"modules":[]}\n'
    (out / "craft_table_catalog.json").write_bytes(craft_bytes)
    mp = out / "manifest.json"
    m = json.loads(mp.read_text(encoding="utf-8"))
    m["generatedFiles"].append({"path": "craft_table_catalog.json",
                                "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
                                "size": len(craft_bytes)})
    mp.write_text(json.dumps(m, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    decl = tmp_path / "lifecycle_declarations.json"
    decl.write_text(json.dumps({"schemaVersion": 1, "items": {
        "buildings:1000001": {"lifecycle": "permanent"}}}, ensure_ascii=False),
        encoding="utf-8")
    phases = tmp_path / "seasonal_phases.json"
    phases.write_text(json.dumps({"schemaVersion": 1, "phases": [
        {"phaseID": "p1", "name": "阶段一", "from": 1, "until": 2,
         "itemKeys": ["buildings:1000001"]},
        {"phaseID": "p2", "name": None, "from": 3, "until": 4,
         "itemKeys": ["buildings:1000001"]},
    ]}, ensure_ascii=False), encoding="utf-8")
    monkeypatch.setattr(lifecycle_module, "DECLARATIONS_PATH", decl)
    monkeypatch.setattr(lifecycle_module, "_phases_path", lambda version: phases)

    rc = vgc.main(["--catalog", str(out)])
    assert rc == 1
    captured = capsys.readouterr()
    assert "phases=[p1(阶段一), p2(无)]" in captured.err, captured.err
    assert str(decl) in captured.err
    assert str(phases) in captured.err


def test_validate_cli_conflict_check_unavailable_does_not_fail(
    full_minimal_apk, tmp_path, monkeypatch, capsys
):
    """Issue #113 审计 F3：冲突检查的基础设施故障（阶段表文件缺失/解析失败，
    CatalogError）→ 非阻断——打印 `conflict check: unavailable` 后退出码不变，
    与 #112 coverage 非阻断先例一致（红线：只有**数据冲突**才 blocking，
    文件缺失不是冲突；多版本未 bundled 阶段表时不得硬断管线）。"""
    import validate_game_catalog as vgc
    from game_catalog import lifecycle as lifecycle_module

    apk = full_minimal_apk
    out = tmp_path / "out"
    _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
          "--output", str(out), "--game-version", "18.400.13"])
    import hashlib
    import json
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","buildTag":"18_400_7","locale":"zh-CN","source":"t","defenses":[],"modules":[]}\n'
    (out / "craft_table_catalog.json").write_bytes(craft_bytes)
    mp = out / "manifest.json"
    m = json.loads(mp.read_text(encoding="utf-8"))
    m["generatedFiles"].append({"path": "craft_table_catalog.json",
                                "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
                                "size": len(craft_bytes)})
    m["gameVersion"] = "99.99.99"  # 仓库未 bundled 的版本 → 阶段表缺失
    # craft 文件与 manifest 版本必须同步（否则 validate_catalog 报版本不一致
    # 的 error，干扰本测试目标——只测冲突检查 unavailable 路径）
    craft_bytes = craft_bytes.replace(b"18.400.13", b"99.99.99")
    (out / "craft_table_catalog.json").write_bytes(craft_bytes)
    m["generatedFiles"][-1]["sha256"] = "sha256:" + hashlib.sha256(craft_bytes).hexdigest()
    m["generatedFiles"][-1]["size"] = len(craft_bytes)
    # catalog.json 的 gameVersion 同样需要同步（manifest == catalog 校验）
    catalog_path = out / "catalog.json"
    catalog_raw = json.loads(catalog_path.read_text(encoding="utf-8"))
    catalog_raw["gameVersion"] = "99.99.99"
    catalog_path.write_text(json.dumps(catalog_raw, ensure_ascii=False), encoding="utf-8")
    # 同步 manifest 中 catalog.json 的哈希/大小（改了内容必须重算，否则
    # validate_catalog 报 generatedFiles 哈希不一致的 error）
    for entry in m["generatedFiles"]:
        if entry["path"] == "catalog.json":
            entry["sha256"] = "sha256:" + hashlib.sha256(catalog_path.read_bytes()).hexdigest()
            entry["size"] = catalog_path.stat().st_size
    mp.write_text(json.dumps(m, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    rc = vgc.main(["--catalog", str(out)])
    assert rc == 0, "冲突检查 unavailable 不得改变 validator 退出码"
    captured = capsys.readouterr()
    assert "conflict check: unavailable" in captured.err, captured.err


def test_validate_cli_corrupt_phase_with_real_conflict_fails(
    full_minimal_apk, tmp_path, monkeypatch, capsys
):
    """Issue #113 审计 R2-F3：阶段表**损坏**（含结构非法 phase）与真实冲突
    共存 → fail-loud（rc=1）——只有文件**缺失**非阻断（版本未 bundled），
    损坏文件不得静默瘫痪冲突门禁（否则坏 phase 把冲突检查降级 unavailable，
    真实冲突漏报 fail-open，CI 假绿）。"""
    import validate_game_catalog as vgc
    from game_catalog import lifecycle as lifecycle_module

    apk = full_minimal_apk
    out = tmp_path / "out"
    _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
          "--output", str(out), "--game-version", "18.400.13"])
    import hashlib
    import json
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","buildTag":"18_400_7","locale":"zh-CN","source":"t","defenses":[],"modules":[]}\n'
    (out / "craft_table_catalog.json").write_bytes(craft_bytes)
    mp = out / "manifest.json"
    m = json.loads(mp.read_text(encoding="utf-8"))
    m["generatedFiles"].append({"path": "craft_table_catalog.json",
                                "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
                                "size": len(craft_bytes)})
    mp.write_text(json.dumps(m, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    decl = tmp_path / "lifecycle_declarations.json"
    decl.write_text(json.dumps({"schemaVersion": 1, "items": {
        "buildings:1000001": {"lifecycle": "permanent"}}}, ensure_ascii=False),
        encoding="utf-8")
    phases = tmp_path / "seasonal_phases.json"
    phases.write_text(json.dumps({"schemaVersion": 1, "phases": [
        # 坏 phase：from 是字符串 → F2 结构校验 fail-loud
        {"phaseID": "bad", "from": "2026-04-01", "until": 2,
         "itemKeys": ["buildings:1000001"]},
        # 真实冲突 phase：合法区间命中 permanent key
        {"phaseID": "p1", "from": 1, "until": 2,
         "itemKeys": ["buildings:1000001"]},
    ]}, ensure_ascii=False), encoding="utf-8")
    monkeypatch.setattr(lifecycle_module, "DECLARATIONS_PATH", decl)
    monkeypatch.setattr(lifecycle_module, "_phases_path", lambda version: phases)

    rc = vgc.main(["--catalog", str(out)])
    assert rc == 1, "阶段表损坏不得把冲突检查降级为 unavailable（fail-open 回归）"
    captured = capsys.readouterr()
    assert "from 缺失或非数字" in captured.err, captured.err
    assert "conflict check: unavailable" not in captured.err


def test_validate_cli_validate_and_conflict_errors_coexist(
    full_minimal_apk, tmp_path, monkeypatch, capsys
):
    """Issue #113 审计：validate errors 与 conflict errors **无异常**共存——
    目录校验有 error 且冲突检查正常返回冲突 → 两条都打印、rc=1（诊断完整性，
    与异常共存路径 test_validate_cli_conflict_collection_failure_preserves_validate_errors
    互补）。"""
    import validate_game_catalog as vgc
    from game_catalog import lifecycle as lifecycle_module

    apk = full_minimal_apk
    out = tmp_path / "out"
    _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
          "--output", str(out), "--game-version", "18.400.13"])
    import hashlib
    import json
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","buildTag":"18_400_7","locale":"zh-CN","source":"t","defenses":[],"modules":[]}\n'
    (out / "craft_table_catalog.json").write_bytes(craft_bytes)
    mp = out / "manifest.json"
    m = json.loads(mp.read_text(encoding="utf-8"))
    m["generatedFiles"].append({"path": "craft_table_catalog.json",
                                "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
                                "size": len(craft_bytes)})
    m["generatedFiles"][-1]["sha256"] = "sha256:" + "0" * 64  # 篡改 → validate error
    mp.write_text(json.dumps(m, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    decl = tmp_path / "lifecycle_declarations.json"
    decl.write_text(json.dumps({"schemaVersion": 1, "items": {
        "buildings:1000001": {"lifecycle": "permanent"}}}, ensure_ascii=False),
        encoding="utf-8")
    phases = tmp_path / "seasonal_phases.json"
    phases.write_text(json.dumps({"schemaVersion": 1, "phases": [
        {"phaseID": "p1", "from": 1, "until": 2,
         "itemKeys": ["buildings:1000001"]}]},
        ensure_ascii=False), encoding="utf-8")
    monkeypatch.setattr(lifecycle_module, "DECLARATIONS_PATH", decl)
    monkeypatch.setattr(lifecycle_module, "_phases_path", lambda version: phases)

    rc = vgc.main(["--catalog", str(out)])
    assert rc == 1
    captured = capsys.readouterr()
    assert "哈希不一致" in captured.err, "validate error 必须打印"
    assert "lifecycle 声明永久内容与官方阶段表冲突" in captured.err, \
        "conflict error 必须打印"


def test_validate_cli_conflict_collection_failure_preserves_validate_errors(
    full_minimal_apk, tmp_path, monkeypatch, capsys
):
    """Issue #113 评审修复：_collect_conflict_errors 抛 CatalogError 时不得吞掉
    已收集的 validate errors——stderr 必须同时含 validate error（哈希不一致）与
    lifecycle 错误（声明文件缺失），rc=1（诊断回归防护：except 分支先打印
    errors 再打印异常）。"""
    import validate_game_catalog as vgc
    from game_catalog import lifecycle as lifecycle_module

    apk = full_minimal_apk
    out = tmp_path / "out"
    _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
          "--output", str(out), "--game-version", "18.400.13"])
    import hashlib
    import json
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","buildTag":"18_400_7","locale":"zh-CN","source":"t","defenses":[],"modules":[]}\n'
    (out / "craft_table_catalog.json").write_bytes(craft_bytes)
    mp = out / "manifest.json"
    m = json.loads(mp.read_text(encoding="utf-8"))
    m["generatedFiles"].append({"path": "craft_table_catalog.json",
                                "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
                                "size": len(craft_bytes)})
    # 篡改 craft hash → validate_catalog 返回 errors（不抛）
    m["generatedFiles"][-1]["sha256"] = "sha256:" + "0" * 64
    mp.write_text(json.dumps(m, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    # 声明文件缺失 → _collect_conflict_errors 抛 CatalogError
    missing = tmp_path / "no_such_lifecycle_declarations.json"
    monkeypatch.setattr(lifecycle_module, "DECLARATIONS_PATH", missing)

    rc = vgc.main(["--catalog", str(out)])
    assert rc == 1
    captured = capsys.readouterr()
    assert "哈希不一致" in captured.err, \
        "validate errors 不得被冲突收集异常吞掉"
    assert "lifecycle 声明文件缺失" in captured.err, \
        "冲突收集异常必须打印"


def test_validate_cli_bad_dir_fails(full_minimal_apk, tmp_path):
    r = _run([str(TOOLS / "validate_game_catalog.py"), "--catalog", str(tmp_path / "empty")])
    assert r.returncode == 1
    assert "verdict: FAIL" in r.stdout


def test_validate_cli_corrupted_catalog_fails(full_minimal_apk, tmp_path):
    apk = full_minimal_apk
    out = tmp_path / "out"
    _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
          "--output", str(out), "--game-version", "18.400.13"])
    (out / "catalog.json").write_text("{not json")
    r = _run([str(TOOLS / "validate_game_catalog.py"), "--catalog", str(out)])
    assert r.returncode == 1
