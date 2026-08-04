"""Task 6: generate() 编排——确定性（验收 #10）+ 指纹 + counts + 原子写。"""

import json
import lzma
import zipfile

import pytest
from pathlib import Path

from game_catalog.catalog import generate
from game_catalog.errors import CatalogError


def _packed(text: str) -> bytes:
    # 与 test_apk.py 一致：Supercell ALONE 头 13B 截断为 9B（低 4B usz）
    data = text.encode("utf-8-sig")
    compressed = lzma.compress(data, format=lzma.FORMAT_ALONE)
    return compressed[:5] + len(data).to_bytes(4, "little") + compressed[13:]


def _minimal_apk(tmp_path: Path) -> Path:
    apk = tmp_path / "fake.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/build.tag", "18_400_7")
        z.writestr("assets/localization/cn.csv", _packed("TID,CN\nTID_A,测试\n"))
        z.writestr("assets/localization/texts_patch.csv", _packed("TID,CN\n"))
        z.writestr("assets/logic/buildings.csv", _packed(
            "Name,GlobalID,BuildingLevel,TID,SWF,ExportName,BuildTimeD,BuildTimeH,BuildTimeM,BuildTimeS,BuildResource,BuildCost,TownHallLevel,VillageType\n"
            "String,int,int,String,String,String,int,int,int,int,String,int,int,String\n"
            "Town Hall,1000001,1,TID_A,sc/buildings.sc,town_hall_lvl1,0,0,0,0,Gold,0,0,\n"))
    return apk


def test_generate_is_deterministic_byte_identical(tmp_path):
    apk = _minimal_apk(tmp_path)
    out1 = tmp_path / "o1"
    out2 = tmp_path / "o2"
    generate(apk, "18.400.13", out1)
    generate(apk, "18.400.13", out2)
    assert (out1 / "catalog.json").read_bytes() == (out2 / "catalog.json").read_bytes()
    assert (out1 / "manifest.json").read_bytes() == (out2 / "manifest.json").read_bytes()


def test_generate_manifest_fingerprint_and_counts(tmp_path):
    apk = _minimal_apk(tmp_path)
    out = tmp_path / "o"
    generate(apk, "18.400.13", out)
    manifest = json.loads((out / "manifest.json").read_text())
    assert manifest["gameVersion"] == "18.400.13"
    assert manifest["buildTag"] == "18_400_7"
    assert manifest["sourceFingerprint"].startswith("sha256:")
    assert manifest["counts"]["items"] == 1
    assert manifest["counts"]["levels"] == 1
    assert (out / "icons").is_dir()


def test_generate_default_game_version_from_build_tag(tmp_path):
    apk = _minimal_apk(tmp_path)
    out = tmp_path / "o"
    generate(apk, None, out)
    manifest = json.loads((out / "manifest.json").read_text())
    assert manifest["gameVersion"] == "18.400.7"


def test_generate_catalog_content(tmp_path):
    apk = _minimal_apk(tmp_path)
    out = tmp_path / "o"
    generate(apk, "18.400.13", out)
    data = json.loads((out / "catalog.json").read_text())
    assert data["schemaVersion"] == 1
    item = data["items"][0]
    assert item["section"] == "buildings"
    assert item["dataID"] == 1000001
    assert item["base"] == "home"
    assert item["name"] == "测试"  # TID_A 本地化命中
    assert item["maxLevel"] == 1
    assert item["levels"][0]["durationSeconds"] == 0  # 0 是真实值


def test_generate_rejects_existing_nonempty_output(tmp_path):
    apk = _minimal_apk(tmp_path)
    out = tmp_path / "o"
    out.mkdir()
    (out / "stale.txt").write_text("x")
    with pytest.raises(CatalogError):
        generate(apk, "18.400.13", out)


def test_generate_raises_on_missing_apk(tmp_path):
    with pytest.raises(CatalogError):
        generate(tmp_path / "nope.apk", "18.400.13", tmp_path / "o")
