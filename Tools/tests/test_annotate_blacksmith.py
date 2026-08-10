"""annotate_blacksmith_levels 回填脚本（Issue #97 Task 2）。

从真实 APK 的 character_items.csv 读 RequiredBlacksmithLevel 列，按生成器契约
(dataID, level) 构建映射（dataID = 90_000_000 + 块序号，deprecated 块也占序号），
回填既有 catalog 目录 equipment 各级 + manifest 重算（幂等，catalog + manifest 双写）。
"""

import hashlib
import json
import lzma
import os
import zipfile
from pathlib import Path

import pytest

from annotate_blacksmith_levels import annotate_directory, build_bs_mapping
from game_catalog.catalog import counts_for
from game_catalog.errors import CatalogError
from game_catalog.fingerprint import sha256_file
from game_catalog.model import Catalog, CatalogItem, CatalogLevel, catalog_to_dict

# 最小 character_items.csv：3 块（第 3 块 deprecated），header + doc 行 + 数据行。
# 块序号 → dataID：0→90000000（Barbarian Puppet，4 级）、1→90000001（Rage Vial，2 级）、
# 2→90000002（UNUSED2，1 级，Deprecated=TRUE）。
CSV_TEXT = (
    "Name,Level,IconSWF,IconExportName,TID,Deprecated,RequiredBlacksmithLevel\n"
    "String,int,String,String,String,boolean,int\n"
    "Barbarian Puppet,1,sc/ui.sc,icon_a,TID_A,,1\n"
    ",2,,,,,1\n"
    ",3,,,,,3\n"
    ",4,,,,,5\n"
    "Rage Vial,1,,,,,1\n"
    ",2,,,,,2\n"
    "UNUSED2,1,,,,TRUE,1\n"
)


def _packed(text: str) -> bytes:
    # Supercell ALONE 头：5 字节属性 + 4 字节 usz(LE) + lzma 数据（与 conftest 同法）
    data = text.encode("utf-8-sig")
    compressed = lzma.compress(data, format=lzma.FORMAT_ALONE)
    return compressed[:5] + len(data).to_bytes(4, "little") + compressed[13:]


def _make_apk(tmp_path: Path, csv_text: str = CSV_TEXT) -> Path:
    apk = tmp_path / "fake.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/build.tag", "18_400_7")
        z.writestr("assets/logic/character_items.csv", _packed(csv_text))
    return apk


def _equipment_item(data_id: int, name: str, levels: list[int],
                    deprecated: bool = False) -> CatalogItem:
    return CatalogItem(
        section="equipment", dataID=data_id, category="equipment", base="home",
        baseMissingReason=None, name=name, maxLevel=levels[-1],
        icon=None, levelVisual=None,
        missingReason="deprecated_in_source" if deprecated else None,
        levels=[CatalogLevel(
            level=lvl, durationSeconds=None, missingReason="no_time_source",
            upgradeCosts=None, requiredTownHallLevel=None,
            requiredLaboratoryLevel=None, icon=None, levelVisual=None)
            for lvl in levels],
        # Issue #98 F3：目录条目 lifecycle 必须与声明一致（90000000-90000005
        # 均为真实 equipment 条目，声明=permanent）
        lifecycle="permanent",
    )


def _units_item() -> CatalogItem:
    """非 equipment 对照项：回填不触碰。"""
    return CatalogItem(
        section="units", dataID=4_000_000, category="troops", base="home",
        baseMissingReason=None, name="野蛮人", maxLevel=1,
        icon=None, levelVisual=None, missingReason=None,
        levels=[CatalogLevel(level=1, durationSeconds=0, missingReason=None,
                             upgradeCosts=None, requiredTownHallLevel=None,
                             requiredLaboratoryLevel=None, icon=None, levelVisual=None)],
        # Issue #98 F3：units:4000000 在真实声明中（permanent）
        lifecycle="permanent",
    )


def _make_dir_and_apk(tmp_path: Path) -> tuple[Path, Path]:
    apk = _make_apk(tmp_path)
    d = tmp_path / "cat"
    d.mkdir()
    items = [
        _equipment_item(90_000_000, "野蛮人木偶", [1, 2, 3, 4]),
        _equipment_item(90_000_001, "狂暴药水瓶", [1, 2]),
        _equipment_item(90_000_002, "UNUSED2", [1], deprecated=True),
        _units_item(),
    ]
    catalog = Catalog(schemaVersion=2, gameVersion="18.400.13", locale="zh-CN",
                      items=items)
    catalog_bytes = json.dumps(catalog_to_dict(catalog), ensure_ascii=False,
                               indent=2, sort_keys=True).encode("utf-8") + b"\n"
    (d / "catalog.json").write_bytes(catalog_bytes)
    (d / "icons").mkdir()
    # Issue #98 复审 P1：validator 强制 craft 条目存在——fixture 目录必须配套
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","defenses":[],"modules":[]}\n'
    (d / "craft_table_catalog.json").write_bytes(craft_bytes)
    (d / "manifest.json").write_text(json.dumps({
        "schemaVersion": 2, "gameVersion": "18.400.13", "buildTag": "18_400_7",
        "locale": "zh-CN", "sourceFingerprint": sha256_file(apk),
        "generatedFiles": [
            {"path": "catalog.json",
             "sha256": "sha256:" + hashlib.sha256(catalog_bytes).hexdigest(),
             "size": len(catalog_bytes)},
            {"path": "icons/", "kind": "directory"},
            {"path": "craft_table_catalog.json",
             "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
             "size": len(craft_bytes)},
        ],
        "counts": counts_for(items),
    }))
    return d, apk


# ---- 映射构建（dataID 契约）----

def test_build_mapping_contract_dataid_ordinal():
    """dataID 契约：块序号即 ordinal（deprecated 块也占位）；行 Level 即等级
    （equipment 是 to_level 语义：行 N 的门槛属于 level N）。"""
    mapping = build_bs_mapping(CSV_TEXT)
    assert mapping == {
        (90_000_000, 1): 1, (90_000_000, 2): 1, (90_000_000, 3): 3, (90_000_000, 4): 5,
        (90_000_001, 1): 1, (90_000_001, 2): 2,
        (90_000_002, 1): 1,  # deprecated 块占 ordinal 2
    }


def test_build_mapping_missing_column():
    with pytest.raises(CatalogError, match="RequiredBlacksmithLevel"):
        build_bs_mapping(CSV_TEXT.replace("RequiredBlacksmithLevel",
                                          "RequiredTownHallLevel"))


def test_build_mapping_non_numeric_bs():
    with pytest.raises(CatalogError, match="非数字"):
        build_bs_mapping(CSV_TEXT.replace(",3,,,,,3", ",3,,,,,abc"))


def test_build_mapping_bs_out_of_domain():
    with pytest.raises(CatalogError, match="1\\.\\.\\.10"):
        build_bs_mapping(CSV_TEXT.replace("UNUSED2,1,,,,TRUE,1",
                                          "UNUSED2,1,,,,TRUE,11"))


# ---- 回填行为 ----

def test_annotate_sets_blacksmith_levels(tmp_path):
    d, apk = _make_dir_and_apk(tmp_path)
    annotate_directory(apk, d)
    data = json.loads((d / "catalog.json").read_text())
    by_id = {i["dataID"]: i for i in data["items"]}
    assert [lv["requiredBlacksmithLevel"] for lv in by_id[90_000_000]["levels"]] == [1, 1, 3, 5]
    assert [lv["requiredBlacksmithLevel"] for lv in by_id[90_000_001]["levels"]] == [1, 2]
    # deprecated 项同样回填（源数据有值）
    assert by_id[90_000_002]["levels"][0]["requiredBlacksmithLevel"] == 1
    # 非 equipment 不动（canonical 序列化只写 null）
    units = next(i for i in data["items"] if i["section"] == "units")
    assert units["levels"][0]["requiredBlacksmithLevel"] is None


def test_annotate_updates_manifest_sha_and_size(tmp_path):
    d, apk = _make_dir_and_apk(tmp_path)
    annotate_directory(apk, d)
    m = json.loads((d / "manifest.json").read_text())
    entry = next(e for e in m["generatedFiles"] if e["path"] == "catalog.json")
    actual = "sha256:" + hashlib.sha256((d / "catalog.json").read_bytes()).hexdigest()
    assert entry["sha256"] == actual
    assert entry["size"] == (d / "catalog.json").stat().st_size


def test_annotate_idempotent(tmp_path):
    d, apk = _make_dir_and_apk(tmp_path)
    annotate_directory(apk, d)
    cat1 = (d / "catalog.json").read_bytes()
    man1 = (d / "manifest.json").read_bytes()
    annotate_directory(apk, d)
    assert (d / "catalog.json").read_bytes() == cat1
    assert (d / "manifest.json").read_bytes() == man1


def test_annotate_preserves_other_generated_files_entries(tmp_path):
    d, apk = _make_dir_and_apk(tmp_path)
    m = json.loads((d / "manifest.json").read_text())
    png = {"path": "icons/equipment/x.png", "sha256": "sha256:" + "b" * 64, "size": 10}
    m["generatedFiles"].insert(1, png)
    (d / "manifest.json").write_text(json.dumps(m))
    (d / "icons" / "equipment").mkdir(parents=True)
    (d / "icons" / "equipment" / "x.png").write_bytes(b"x" * 10)
    annotate_directory(apk, d)
    m2 = json.loads((d / "manifest.json").read_text())
    assert m2["generatedFiles"][1] == png


def test_annotate_preserves_instance_counts(tmp_path):
    d, apk = _make_dir_and_apk(tmp_path)
    data = json.loads((d / "catalog.json").read_text())
    data["instanceCounts"] = {"buildings:1000001": [0] * 18}
    (d / "catalog.json").write_text(
        json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    annotate_directory(apk, d)
    out = json.loads((d / "catalog.json").read_text())
    assert out["instanceCounts"] == {"buildings:1000001": [0] * 18}


def test_annotate_result_passes_validate(tmp_path):
    from game_catalog.validate import validate_catalog
    d, apk = _make_dir_and_apk(tmp_path)
    annotate_directory(apk, d)
    assert validate_catalog(d) == []


# ---- fail loud（写回前中止，不落盘）----

def test_annotate_apk_missing(tmp_path):
    d, _ = _make_dir_and_apk(tmp_path)
    cat_before = (d / "catalog.json").read_bytes()
    man_before = (d / "manifest.json").read_bytes()
    with pytest.raises(CatalogError, match="APK 不存在"):
        annotate_directory(tmp_path / "no.apk", d)
    assert (d / "catalog.json").read_bytes() == cat_before
    assert (d / "manifest.json").read_bytes() == man_before


def test_annotate_apk_missing_table(tmp_path):
    d, _ = _make_dir_and_apk(tmp_path)
    apk = tmp_path / "empty.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/build.tag", "18_400_7")
    # 同步 manifest 的 fingerprint 到该 APK（否则先触发 fingerprint 不匹配，测不到缺表）
    m = json.loads((d / "manifest.json").read_text())
    m["sourceFingerprint"] = sha256_file(apk)
    (d / "manifest.json").write_text(json.dumps(m))
    cat_before = (d / "catalog.json").read_bytes()
    with pytest.raises(CatalogError, match="character_items.csv"):
        annotate_directory(apk, d)
    assert (d / "catalog.json").read_bytes() == cat_before


def test_annotate_apk_missing_column(tmp_path):
    d, _ = _make_dir_and_apk(tmp_path)
    apk = _make_apk(tmp_path, CSV_TEXT.replace("RequiredBlacksmithLevel",
                                               "RequiredTownHallLevel"))
    # 同步 manifest 的 fingerprint 到该 APK（否则先触发 fingerprint 不匹配，测不到缺列）
    m = json.loads((d / "manifest.json").read_text())
    m["sourceFingerprint"] = sha256_file(apk)
    (d / "manifest.json").write_text(json.dumps(m))
    cat_before = (d / "catalog.json").read_bytes()
    with pytest.raises(CatalogError, match="RequiredBlacksmithLevel"):
        annotate_directory(apk, d)
    assert (d / "catalog.json").read_bytes() == cat_before


def test_annotate_fails_loud_on_missing_level(tmp_path):
    """目录 equipment 等级在 CSV 映射查不到 → CatalogError，不落盘
    （防 dataID 错位静默产生坏产物）。"""
    d, apk = _make_dir_and_apk(tmp_path)
    data = json.loads((d / "catalog.json").read_text())
    bp = next(i for i in data["items"] if i["dataID"] == 90_000_000)
    bp["levels"].append({
        "level": 5, "durationSeconds": None, "missingReason": "no_time_source",
        "upgradeCosts": None, "requiredTownHallLevel": None,
        "requiredLaboratoryLevel": None, "icon": None, "levelVisual": None,
    })
    bp["maxLevel"] = 5
    (d / "catalog.json").write_text(
        json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    cat_before = (d / "catalog.json").read_bytes()
    man_before = (d / "manifest.json").read_bytes()
    with pytest.raises(CatalogError, match="90000000"):
        annotate_directory(apk, d)
    assert (d / "catalog.json").read_bytes() == cat_before
    assert (d / "manifest.json").read_bytes() == man_before


# ---- P1（外部评审）：APK 版本/来源契约校验 + manifest 校验前置 + 原子写 ----

def test_annotate_apk_build_tag_mismatch_rejected(tmp_path):
    """换用不同 build 的 APK：build.tag 与 manifest.buildTag 不一致 → fail loud，
    不落盘（防用错版本 APK 写入错误门槛数据）。"""
    d, _ = _make_dir_and_apk(tmp_path)
    apk = tmp_path / "other-build.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/build.tag", "19_0_0")
        z.writestr("assets/logic/character_items.csv", _packed(CSV_TEXT))
    # fingerprint 同步到该 APK，隔离 buildTag 不匹配路径
    m = json.loads((d / "manifest.json").read_text())
    m["sourceFingerprint"] = sha256_file(apk)
    (d / "manifest.json").write_text(json.dumps(m))
    cat_before = (d / "catalog.json").read_bytes()
    man_before = (d / "manifest.json").read_bytes()
    with pytest.raises(CatalogError, match="build.tag"):
        annotate_directory(apk, d)
    assert (d / "catalog.json").read_bytes() == cat_before
    assert (d / "manifest.json").read_bytes() == man_before


def test_annotate_apk_fingerprint_mismatch_rejected(tmp_path):
    """同 build 但不同字节的 APK：SHA-256 与 manifest.sourceFingerprint 不一致
    → fail loud，不落盘（目录生成时的原 APK 溯源契约）。"""
    d, apk = _make_dir_and_apk(tmp_path)
    m = json.loads((d / "manifest.json").read_text())
    m["sourceFingerprint"] = "sha256:" + "b" * 64
    (d / "manifest.json").write_text(json.dumps(m))
    cat_before = (d / "catalog.json").read_bytes()
    man_before = (d / "manifest.json").read_bytes()
    with pytest.raises(CatalogError, match="sourceFingerprint"):
        annotate_directory(apk, d)
    assert (d / "catalog.json").read_bytes() == cat_before
    assert (d / "manifest.json").read_bytes() == man_before


def test_annotate_manifest_malformed_rejected(tmp_path):
    """畸形 manifest（非法 JSON）：在写任何文件之前拒绝，不产生半写入目录。"""
    d, apk = _make_dir_and_apk(tmp_path)
    (d / "manifest.json").write_text("{not valid json")
    cat_before = (d / "catalog.json").read_bytes()
    with pytest.raises(CatalogError, match="manifest.json 解析失败"):
        annotate_directory(apk, d)
    assert (d / "catalog.json").read_bytes() == cat_before


def test_annotate_manifest_missing_catalog_entry_rejected(tmp_path):
    """manifest 缺 generatedFiles.catalog.json 条目：无法更新哈希 → fail loud，
    不落盘（不得静默成功留下哈希过期目录）。"""
    d, apk = _make_dir_and_apk(tmp_path)
    m = json.loads((d / "manifest.json").read_text())
    m["generatedFiles"] = [e for e in m["generatedFiles"] if e.get("path") != "catalog.json"]
    (d / "manifest.json").write_text(json.dumps(m))
    cat_before = (d / "catalog.json").read_bytes()
    man_before = (d / "manifest.json").read_bytes()
    with pytest.raises(CatalogError, match="generatedFiles"):
        annotate_directory(apk, d)
    assert (d / "catalog.json").read_bytes() == cat_before
    assert (d / "manifest.json").read_bytes() == man_before


def test_annotate_manifest_missing_build_tag_rejected(tmp_path):
    """manifest 缺 buildTag（provenance 不完整）：fail loud，不落盘。"""
    d, apk = _make_dir_and_apk(tmp_path)
    m = json.loads((d / "manifest.json").read_text())
    del m["buildTag"]
    (d / "manifest.json").write_text(json.dumps(m))
    cat_before = (d / "catalog.json").read_bytes()
    with pytest.raises(CatalogError, match="buildTag"):
        annotate_directory(apk, d)
    assert (d / "catalog.json").read_bytes() == cat_before


def test_annotate_manifest_missing_fingerprint_rejected(tmp_path):
    """manifest 缺 sourceFingerprint（provenance 不完整）：fail loud，不落盘。"""
    d, apk = _make_dir_and_apk(tmp_path)
    m = json.loads((d / "manifest.json").read_text())
    del m["sourceFingerprint"]
    (d / "manifest.json").write_text(json.dumps(m))
    cat_before = (d / "catalog.json").read_bytes()
    with pytest.raises(CatalogError, match="sourceFingerprint"):
        annotate_directory(apk, d)
    assert (d / "catalog.json").read_bytes() == cat_before


def test_annotate_catalog_malformed_rejected(tmp_path):
    """畸形 catalog.json：在写任何文件之前拒绝（与 manifest 同规格的 fail-loud）。"""
    d, apk = _make_dir_and_apk(tmp_path)
    (d / "catalog.json").write_text("{broken catalog")
    man_before = (d / "manifest.json").read_bytes()
    with pytest.raises(CatalogError, match="catalog.json 解析失败"):
        annotate_directory(apk, d)
    assert (d / "manifest.json").read_bytes() == man_before


def test_annotate_catalog_missing_key_rejected_cleanly(tmp_path):
    """畸形 catalog（item 缺 section 键，from_dict 下标抛 KeyError）→ 干净
    CatalogError（不泄漏裸 traceback），且不落盘（验证 agent 发现的泄漏修复）。"""
    d, apk = _make_dir_and_apk(tmp_path)
    data = json.loads((d / "catalog.json").read_text())
    del data["items"][0]["section"]
    (d / "catalog.json").write_text(json.dumps(data))
    man_before = (d / "manifest.json").read_bytes()
    with pytest.raises(CatalogError, match="catalog.json 解析失败"):
        annotate_directory(apk, d)
    assert (d / "manifest.json").read_bytes() == man_before


def test_annotate_manifest_counts_not_dict_rejected_cleanly(tmp_path):
    """manifest counts 为非法类型（如 string）→ 干净 CatalogError，不落盘。"""
    d, apk = _make_dir_and_apk(tmp_path)
    m = json.loads((d / "manifest.json").read_text())
    m["counts"] = "not-a-dict"
    (d / "manifest.json").write_text(json.dumps(m))
    cat_before = (d / "catalog.json").read_bytes()
    with pytest.raises(CatalogError, match="counts"):
        annotate_directory(apk, d)
    assert (d / "catalog.json").read_bytes() == cat_before


def test_annotate_rolls_back_on_second_replace_failure(tmp_path, monkeypatch):
    """P2：双文件写回 all-or-nothing——第二次 os.replace（manifest）失败时
    必须回滚已写入的 catalog.json，不留「catalog 新 / manifest 旧」半状态，
    且不残留 .tmp/.rollback.tmp。"""
    d, apk = _make_dir_and_apk(tmp_path)
    calls = {"n": 0}
    real_replace = os.replace

    def flaky_replace(src, dst):
        calls["n"] += 1
        if calls["n"] == 2:  # 第二次 replace = manifest.json
            raise OSError("注入: 第二次 replace 失败")
        return real_replace(src, dst)

    monkeypatch.setattr(os, "replace", flaky_replace)
    cat_before = (d / "catalog.json").read_bytes()
    man_before = (d / "manifest.json").read_bytes()
    with pytest.raises(CatalogError, match="写入 catalog/manifest 失败"):
        annotate_directory(apk, d)
    # all-or-nothing：双文件都回到旧内容
    assert (d / "catalog.json").read_bytes() == cat_before
    assert (d / "manifest.json").read_bytes() == man_before
    # 无 tmp / rollback tmp 残留
    assert not list(d.glob("*.tmp"))
    assert not list(d.glob("*.rollback.tmp"))


def test_annotate_rolls_back_on_first_replace_failure(tmp_path, monkeypatch):
    """P2：第一次 os.replace（catalog.json）失败 → 无已写入文件可回滚，干净失败。"""
    d, apk = _make_dir_and_apk(tmp_path)
    calls = {"n": 0}
    real_replace = os.replace

    def flaky_replace(src, dst):
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError("注入: 第一次 replace 失败")
        return real_replace(src, dst)

    monkeypatch.setattr(os, "replace", flaky_replace)
    cat_before = (d / "catalog.json").read_bytes()
    man_before = (d / "manifest.json").read_bytes()
    with pytest.raises(CatalogError, match="写入 catalog/manifest 失败"):
        annotate_directory(apk, d)
    assert (d / "catalog.json").read_bytes() == cat_before
    assert (d / "manifest.json").read_bytes() == man_before
    assert not list(d.glob("*.tmp"))


def test_annotate_rollback_failure_cleans_rollback_tmp(tmp_path, monkeypatch):
    """P2 极端分支：回滚自身的 os.replace 也失败（第 2、3 次 replace 均失败）
    → 错误消息含「回滚失败」清单，且 .rollback.tmp 被清理（不残留）。"""
    d, apk = _make_dir_and_apk(tmp_path)
    calls = {"n": 0}
    real_replace = os.replace

    def flaky_replace(src, dst):
        calls["n"] += 1
        if calls["n"] in (2, 3):  # 第 2 次 = manifest replace 失败；第 3 次 = 回滚 replace 失败
            raise OSError("注入: replace 失败")
        return real_replace(src, dst)

    monkeypatch.setattr(os, "replace", flaky_replace)
    cat_before = (d / "catalog.json").read_bytes()
    man_before = (d / "manifest.json").read_bytes()
    with pytest.raises(CatalogError, match="回滚失败"):
        annotate_directory(apk, d)
    # 回滚 replace 也失败 → catalog 保持写入后的新内容（回滚未执行成功），
    # manifest 保持旧内容；.rollback.tmp 被清理不残留（fail-closed 兜底：
    # validator 哈希比对会检出 catalog 新/manifest 旧，重跑幂等修复）。
    assert (d / "catalog.json").read_bytes() != cat_before
    assert (d / "catalog.json").read_bytes() != man_before
    assert (d / "manifest.json").read_bytes() == man_before
    # 不残留任何临时文件（含 .rollback.tmp）
    assert not list(d.glob("*.tmp"))
    assert not list(d.glob("*.rollback.tmp"))
