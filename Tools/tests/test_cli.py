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
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","defenses":[],"modules":[]}\n'
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
