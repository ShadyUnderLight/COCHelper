"""Task 6: generate() 编排——确定性（验收 #10）+ 最小 manifest + 原子写。"""

import json

import pytest

from game_catalog.catalog import generate
from game_catalog.errors import CatalogError


def test_generate_is_deterministic_byte_identical(full_minimal_apk, tmp_path):
    apk = full_minimal_apk
    out1 = tmp_path / "o1"
    out2 = tmp_path / "o2"
    generate(apk, "18.400.13", out1)
    generate(apk, "18.400.13", out2)
    assert (out1 / "catalog.json").read_bytes() == (out2 / "catalog.json").read_bytes()
    assert (out1 / "manifest.json").read_bytes() == (out2 / "manifest.json").read_bytes()


def test_generate_manifest_minimal_shape(full_minimal_apk, tmp_path):
    apk = full_minimal_apk
    out = tmp_path / "o"
    generate(apk, "18.400.13", out)
    manifest = json.loads((out / "manifest.json").read_text())
    assert manifest["schemaVersion"] == 3
    assert manifest["gameVersion"] == "18.400.13"
    assert manifest["buildTag"] == "18_400_7"
    assert manifest["locale"] == "zh-CN"
    assert "sourceFingerprint" not in manifest
    assert "generatedFiles" not in manifest
    assert "counts" not in manifest
    assert (out / "icons").is_dir()


def test_generate_default_game_version_from_build_tag(full_minimal_apk, tmp_path):
    apk = full_minimal_apk
    out = tmp_path / "o"
    generate(apk, None, out)
    manifest = json.loads((out / "manifest.json").read_text())
    assert manifest["gameVersion"] == "18.400.7"


def test_generate_catalog_content(full_minimal_apk, tmp_path):
    apk = full_minimal_apk
    out = tmp_path / "o"
    generate(apk, "18.400.13", out)
    data = json.loads((out / "catalog.json").read_text())
    assert data["schemaVersion"] == 3
    item = data["items"][0]
    assert item["section"] == "buildings"
    assert item["dataID"] == 1000001
    assert item["base"] == "home"
    assert item["name"] == "测试"  # TID_A 本地化命中
    assert item["maxLevel"] == 1
    assert item["levels"][0]["durationSeconds"] == 0  # 0 是真实值


def test_generate_rejects_existing_nonempty_output(full_minimal_apk, tmp_path):
    apk = full_minimal_apk
    out = tmp_path / "o"
    out.mkdir()
    (out / "stale.txt").write_text("x")
    with pytest.raises(CatalogError):
        generate(apk, "18.400.13", out)


def test_generate_raises_on_missing_apk(full_minimal_apk, tmp_path):
    with pytest.raises(CatalogError):
        generate(tmp_path / "nope.apk", "18.400.13", tmp_path / "o")
