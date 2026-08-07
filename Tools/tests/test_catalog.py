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


# ---- Issue #74b：时长语义 counts 拆分 ----

def _level(seconds, reason):
    from game_catalog.model import CatalogLevel
    return CatalogLevel(
        level=1, durationSeconds=seconds, missingReason=reason,
        upgradeResource=None, upgradeCost=None,
        requiredTownHallLevel=None, requiredLaboratoryLevel=None,
        icon=None, levelVisual=None,
    )


def _item(data_id, levels):
    from game_catalog.model import CatalogItem
    return CatalogItem(
        section="units", dataID=data_id, category="troops", base="home",
        baseMissingReason=None, name="x", maxLevel=len(levels),
        icon=None, levelVisual=None, missingReason=None, levels=levels,
    )


def test_counts_for_duration_buckets():
    """counts_for 把时长拆到 6 个语义桶，且 sum 不变量成立。"""
    from game_catalog.catalog import counts_for
    items = [
        _item(1, [_level(3600, None), _level(0, None)]),                      # timed + instant
        _item(2, [_level(None, "min_level_initial_no_upgrade")]),             # initialLevel
        _item(3, [_level(None, "no_time_source")]),                           # notApplicable
        _item(4, [_level(None, "time_missing"), _level(None, "upgrade_data_missing")]),  # sourceMissing ×2
        _item(5, [_level(None, "time_invalid")]),                             # parseFailed
        _item(6, [_level(None, None)]),                                       # unknown（计入 missingTime）
    ]
    counts = counts_for(items)
    assert counts["timed"] == 1
    assert counts["instant"] == 1
    assert counts["initialLevel"] == 1
    assert counts["notApplicable"] == 1
    assert counts["sourceMissing"] == 2
    assert counts["parseFailed"] == 1
    # missingTime 语义保持：全部 durationSeconds is None（含 unknown）
    assert counts["missingTime"] == 6
    # sum 不变量：timed + instant + missingTime == levels
    assert counts["timed"] + counts["instant"] + counts["missingTime"] == counts["levels"] == 8


def test_generate_manifest_counts_include_duration_buckets(full_minimal_apk, tmp_path):
    """生成器产出的 manifest counts 带拆分字段（Town Hall 0 秒 → instant）。"""
    import json
    out = tmp_path / "out"
    generate(full_minimal_apk, None, out)
    c = json.loads((out / "manifest.json").read_text())["counts"]
    for field in ("timed", "instant", "notApplicable", "initialLevel",
                  "sourceMissing", "parseFailed"):
        assert isinstance(c.get(field), int), f"counts.{field} 缺失或非 int"
    assert c["timed"] == 0
    assert c["instant"] == 1
    assert c["missingTime"] == 0
    assert c["timed"] + c["instant"] + c["missingTime"] == c["levels"]


def test_counts_for_annotations_evaluable():
    """P1 回归：counts_for 的类型注解必须可立即求值（Python 3.11 模块导入即
    求值注解；3.14 PEP 649 延迟掩盖了 NameError——get_type_hints 强制求值）。"""
    import typing
    from game_catalog import catalog as catalog_mod
    hints = typing.get_type_hints(catalog_mod.counts_for)
    assert "items" in hints
