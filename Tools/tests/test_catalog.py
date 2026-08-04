"""catalog.generate 原子写行为（I4 回归）：失败不留部分输出、tmp 必被清理。"""

import lzma
import zipfile

import pytest

from game_catalog import catalog as catalog_mod
from game_catalog.catalog import generate
from game_catalog.errors import CatalogError


def _leftover_tmp_dirs(tmp_path) -> list[str]:
    return [p.name for p in tmp_path.iterdir() if p.name.startswith(".coc-catalog-")]


def test_generate_replace_failure_leaves_no_partial_output(full_minimal_apk, tmp_path, monkeypatch):
    """整目录单次 replace 失败 → out 不存在、tmp 被 finally 清理。"""
    apk = full_minimal_apk
    out = tmp_path / "out"

    def boom(src, dst):
        raise OSError("simulated replace failure")

    monkeypatch.setattr(catalog_mod.os, "replace", boom)
    with pytest.raises(OSError, match="simulated replace failure"):
        generate(apk, None, out)

    assert not out.exists()
    assert _leftover_tmp_dirs(tmp_path) == []


def test_generate_into_existing_empty_dir(full_minimal_apk, tmp_path):
    """前置 out 为空目录（上次失败残留）→ 先 rmdir 再整目录替换，成功且无 tmp 残留。"""
    apk = full_minimal_apk
    out = tmp_path / "out"
    out.mkdir()

    generate(apk, None, out)

    assert (out / "catalog.json").is_file()
    assert (out / "manifest.json").is_file()
    assert (out / "icons").is_dir()
    assert _leftover_tmp_dirs(tmp_path) == []


def test_generate_nonempty_output_rejected(full_minimal_apk, tmp_path):
    apk = full_minimal_apk
    out = tmp_path / "out"
    out.mkdir()
    (out / "x.txt").write_text("x")
    with pytest.raises(CatalogError):
        generate(apk, None, out)
    assert _leftover_tmp_dirs(tmp_path) == []


def test_generate_missing_time_column_fails_loud(full_minimal_apk, tmp_path):
    """I8 回归：表头缺必需时间列（如 BuildTimeH 拼错/缺失）→ CatalogError，不静默 time_missing。"""
    from tests.conftest import _packed as _pack_csv
    apk = tmp_path / "fake.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/build.tag", "18_400_7")
        z.writestr("assets/localization/cn.csv", _pack_csv("TID,CN\nTID_A,测试\n"))
        z.writestr("assets/localization/texts_patch.csv", _pack_csv("TID,CN\n"))
        # 头里只有 BuildTimeD/M/S，缺 BuildTimeH
        z.writestr("assets/logic/buildings.csv", _pack_csv(
            "Name,GlobalID,BuildingLevel,TID,SWF,ExportName,Icon,BuildTimeD,BuildTimeM,BuildTimeS,BuildResource,BuildCost,TownHallLevel,VillageType\n"
            "String,int,int,String,String,String,String,int,int,int,String,int,int,String\n"
            "Town Hall,1000001,1,TID_A,sc/buildings.sc,town_hall_lvl1,,1,0,0,Gold,0,0,\n"))
    out = tmp_path / "out"
    with pytest.raises(CatalogError, match="缺少必需列"):
        generate(str(apk), None, out)
    assert not out.exists()
    assert _leftover_tmp_dirs(tmp_path) == []


def test_generate_missing_table_fails_loud(full_minimal_apk, tmp_path):
    """P1-2 回归：APK 缺一张注册表 → CatalogError（不产出部分/空目录）。"""
    import zipfile as _zf
    from tests.conftest import _packed as _pack_csv

    # 构造缺 traps.csv 的 APK
    apk = tmp_path / "missing-traps.apk"
    with _zf.ZipFile(apk, "w") as z:
        z.writestr("assets/build.tag", "18_400_7")
        z.writestr("assets/localization/cn.csv", _pack_csv("TID,CN\nTID_A,测试\n"))
        z.writestr("assets/localization/texts_patch.csv", _pack_csv("TID,CN\n"))
        for spec in __import__("game_catalog.tables", fromlist=["TABLES"]).TABLES:
            if spec.table in ("buildings.csv", "traps.csv"):
                continue  # buildings 也要，缺 traps 即可
            z.writestr("assets/logic/" + spec.table, _pack_csv(
                __import__("tests.conftest", fromlist=["_doc_rows"])._doc_rows(spec)))
        z.writestr("assets/logic/upgrade_data.csv", _pack_csv(
            "Name,UpgradeLevel,UpgradeType,UpgradeTimeDays,UpgradeTimeHours,"
            "UpgradeTimeMinutes,UpgradeTimeSeconds,UpgradeResource,AltUpgradeResource,"
            "UpgradeCost,UpgradePriority\n"
            "String,int,String,int,int,int,int,String,String,int,int\n"))
        z.writestr("assets/logic/buildings.csv", _pack_csv(
            "Name,GlobalID,BuildingLevel,TID,SWF,ExportName,Icon,"
            "BuildTimeD,BuildTimeH,BuildTimeM,BuildTimeS,"
            "BuildResource,BuildCost,TownHallLevel,VillageType\n"
            "String,int,int,String,String,String,String,int,int,int,int,String,int,int,String\n"
            "Town Hall,1000001,1,TID_A,sc/buildings.sc,town_hall_lvl1,,0,0,0,0,Gold,0,0,\n"))
    out = tmp_path / "out"
    with pytest.raises(CatalogError, match="缺少逻辑表"):
        generate(str(apk), None, out)
    assert not out.exists()


def test_generate_missing_upgrade_data_fails_loud(full_minimal_apk, tmp_path):
    """P1-2 回归：APK 缺 upgrade_data.csv（guardians join 依赖）→ CatalogError。"""
    import zipfile as _zf

    src = full_minimal_apk
    apk = tmp_path / "no-upgrade-data.apk"
    import shutil
    shutil.copy(src, apk)
    # 重写 zip 移除 upgrade_data.csv
    import tempfile, os
    tmp2 = apk.with_suffix(".tmp")
    with _zf.ZipFile(src) as zin, _zf.ZipFile(tmp2, "w") as zout:
        for item in zin.infolist():
            if item.filename == "assets/logic/upgrade_data.csv":
                continue
            zout.writestr(item, zin.read(item.filename))
    os.replace(tmp2, apk)
    out = tmp_path / "out"
    with pytest.raises(CatalogError, match="upgrade_data.csv"):
        generate(str(apk), None, out)
    assert not out.exists()
