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
                        lambda: (_ for _ in ()).throw(CatalogError("声明文件缺失: /nope")))
    rc = vgc.main(["--catalog", str(out)])
    assert rc == 0, "coverage 报告失败不得改变 validator 退出码"


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
