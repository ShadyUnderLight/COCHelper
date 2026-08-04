"""catalog.generate 原子写行为（I4 回归）：失败不留部分输出、tmp 必被清理。"""

import lzma
import zipfile

import pytest

from game_catalog import catalog as catalog_mod
from game_catalog.catalog import generate
from game_catalog.errors import CatalogError


def _packed(text: str) -> bytes:
    data = text.encode("utf-8-sig")
    compressed = lzma.compress(data, format=lzma.FORMAT_ALONE)
    return compressed[:5] + len(data).to_bytes(4, "little") + compressed[13:]


def _minimal_apk(tmp_path) -> str:
    apk = tmp_path / "fake.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/build.tag", "18_400_7")
        z.writestr("assets/localization/cn.csv", _packed("TID,CN\nTID_A,测试\n"))
        z.writestr("assets/localization/texts_patch.csv", _packed("TID,CN\n"))
        z.writestr("assets/logic/buildings.csv", _packed(
            "Name,GlobalID,BuildingLevel,TID,SWF,ExportName,BuildTimeD,BuildTimeH,BuildTimeM,BuildTimeS,BuildResource,BuildCost,TownHallLevel,VillageType\n"
            "String,int,int,String,String,String,int,int,int,int,String,int,int,String\n"
            "Town Hall,1000001,1,TID_A,sc/buildings.sc,town_hall_lvl1,0,0,0,0,Gold,0,0,\n"))
    return str(apk)


def _leftover_tmp_dirs(tmp_path) -> list[str]:
    return [p.name for p in tmp_path.iterdir() if p.name.startswith(".coc-catalog-")]


def test_generate_replace_failure_leaves_no_partial_output(tmp_path, monkeypatch):
    """整目录单次 replace 失败 → out 不存在、tmp 被 finally 清理。"""
    apk = _minimal_apk(tmp_path)
    out = tmp_path / "out"

    def boom(src, dst):
        raise OSError("simulated replace failure")

    monkeypatch.setattr(catalog_mod.os, "replace", boom)
    with pytest.raises(OSError, match="simulated replace failure"):
        generate(apk, None, out)

    assert not out.exists()
    assert _leftover_tmp_dirs(tmp_path) == []


def test_generate_into_existing_empty_dir(tmp_path):
    """前置 out 为空目录（上次失败残留）→ 先 rmdir 再整目录替换，成功且无 tmp 残留。"""
    apk = _minimal_apk(tmp_path)
    out = tmp_path / "out"
    out.mkdir()

    generate(apk, None, out)

    assert (out / "catalog.json").is_file()
    assert (out / "manifest.json").is_file()
    assert (out / "icons").is_dir()
    assert _leftover_tmp_dirs(tmp_path) == []


def test_generate_nonempty_output_rejected(tmp_path):
    apk = _minimal_apk(tmp_path)
    out = tmp_path / "out"
    out.mkdir()
    (out / "x.txt").write_text("x")
    with pytest.raises(CatalogError):
        generate(apk, None, out)
    assert _leftover_tmp_dirs(tmp_path) == []
