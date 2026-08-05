"""Task 7: validate_catalog 不变量（结构 + 语义 + counts 重算）。测试是契约。"""

import json
from pathlib import Path

import pytest

from game_catalog.model import catalog_to_dict, Catalog, CatalogItem, CatalogLevel
from game_catalog.validate import validate_catalog


def _valid_dir(tmp_path: Path) -> Path:
    import hashlib

    item = CatalogItem(
        section="units", dataID=4_000_000, category="troops", base="home",
        baseMissingReason=None, name="野蛮人", maxLevel=1,
        icon=None, levelVisual=None, missingReason=None,
        levels=[CatalogLevel(
            level=1, durationSeconds=0, missingReason=None,
            upgradeResource="Elixir", upgradeCost=100,
            requiredTownHallLevel=None, requiredLaboratoryLevel=None,
            icon=None, levelVisual=None,
        )],
    )
    catalog = Catalog(schemaVersion=1, gameVersion="18.400.13", locale="zh-CN",
                      items=[item])
    d = tmp_path / "cat"
    d.mkdir()
    catalog_bytes = json.dumps(catalog_to_dict(catalog), ensure_ascii=False).encode("utf-8")
    (d / "catalog.json").write_bytes(catalog_bytes)
    (d / "icons").mkdir()
    (d / "manifest.json").write_text(json.dumps({
        "schemaVersion": 1, "gameVersion": "18.400.13", "buildTag": "18_400_7",
        "locale": "zh-CN", "sourceFingerprint": "sha256:" + "a" * 64,
        "generatedFiles": [
            {"path": "catalog.json", "sha256": "sha256:" + hashlib.sha256(catalog_bytes).hexdigest(),
             "size": len(catalog_bytes)},
            {"path": "icons/", "kind": "directory"},
        ],
        "counts": {"items": 1, "levels": 1, "missingTime": 0, "missingIcons": 0},
    }))
    return d


def _write(d: Path, *, catalog: dict | None = None, manifest: dict | None = None) -> None:
    if catalog is not None:
        (d / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False))
    if manifest is not None:
        (d / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False))


def _load_catalog(d: Path) -> dict:
    return json.loads((d / "catalog.json").read_text())


def _load_manifest(d: Path) -> dict:
    return json.loads((d / "manifest.json").read_text())

def _write_with_hash(d: Path, *, catalog: dict | None = None, manifest: dict | None = None) -> None:
    """写文件后同步更新 manifest 的 generatedFiles 哈希（篡改 catalog 的测试用）。"""
    import hashlib
    if catalog is not None:
        (d / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False))
    if manifest is not None:
        (d / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False))
    m = json.loads((d / "manifest.json").read_text())
    data = (d / "catalog.json").read_bytes()
    for entry in m.get("generatedFiles", []):
        if entry.get("path") == "catalog.json":
            entry["sha256"] = "sha256:" + hashlib.sha256(data).hexdigest()
            entry["size"] = len(data)
    (d / "manifest.json").write_text(json.dumps(m, ensure_ascii=False))



# ---- 结构存在性 / 可解析性 ----

def test_validate_ok(tmp_path):
    assert validate_catalog(_valid_dir(tmp_path)) == []


def test_validate_missing_manifest(tmp_path):
    d = _valid_dir(tmp_path)
    (d / "manifest.json").unlink()
    errors = validate_catalog(d)
    assert any("manifest" in e for e in errors)


def test_validate_missing_catalog(tmp_path):
    d = _valid_dir(tmp_path)
    (d / "catalog.json").unlink()
    errors = validate_catalog(d)
    assert any("catalog" in e for e in errors)


def test_validate_unparseable_manifest(tmp_path):
    d = _valid_dir(tmp_path)
    (d / "manifest.json").write_text("{not json")
    errors = validate_catalog(d)
    assert any("解析失败" in e for e in errors)


def test_validate_unparseable_catalog(tmp_path):
    d = _valid_dir(tmp_path)
    (d / "catalog.json").write_text("[1,2")
    errors = validate_catalog(d)
    assert any("解析失败" in e for e in errors)


def test_validate_manifest_invalid_utf8(tmp_path):
    """I1 回归：manifest 为非法 UTF-8 时返回错误而非裸抛 UnicodeDecodeError。"""
    d = _valid_dir(tmp_path)
    (d / "manifest.json").write_bytes(b"\xff\xfe\x00{not valid utf-8}")
    errors = validate_catalog(d)
    assert any("解析失败" in e for e in errors)


def test_validate_catalog_malformed_level_type(tmp_path):
    """I2 回归：畸形但可解析（"level": "1" 字符串）→ 返回 '内容非法' 而非抛 TypeError。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["level"] = "1"
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert len(errors) == 1 and "内容非法" in errors[0]


def test_validate_catalog_icon_wrong_type(tmp_path):
    """I7 回归：icon: 5（非 dict）→ 返回 error 列表而非裸 AttributeError/TypeError。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["icon"] = 5
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert errors and "解析失败" in errors[0]
    assert not any("Traceback" in e for e in errors)


def test_validate_catalog_levelvisual_wrong_type(tmp_path):
    """I7 回归：levelVisual: "x"（非 dict）→ error 列表而非崩溃。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levelVisual"] = "x"
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert errors and "解析失败" in errors[0]


def test_validate_catalog_icon_list_type(tmp_path):
    """I7 回归：icon: [1,2]（list）→ error 列表而非崩溃。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = [1, 2]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert errors and "解析失败" in errors[0]


def test_validate_manifest_top_level_list(tmp_path):
    """I7 回归：manifest 顶层为 list → error 列表而非裸 AttributeError。"""
    d = _valid_dir(tmp_path)
    (d / "manifest.json").write_text(json.dumps([1, 2, 3]))
    errors = validate_catalog(d)
    assert errors and ("解析失败" in errors[0] or "顶层" in errors[0])


# ---- 版本一致性 ----

def test_validate_game_version_mismatch(tmp_path):
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    m["gameVersion"] = "18.400.12"
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("gameVersion" in e for e in errors)


def test_validate_locale_mismatch(tmp_path):
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    m["locale"] = "en-US"
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("locale" in e for e in errors)


def test_validate_schema_version_mismatch_manifest(tmp_path):
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    m["schemaVersion"] = 2
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("schemaVersion" in e for e in errors)


def test_validate_schema_version_mismatch_catalog(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["schemaVersion"] = 2
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("schemaVersion" in e for e in errors)


# ---- sourceFingerprint ----

def test_validate_fingerprint_wrong_prefix(tmp_path):
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    m["sourceFingerprint"] = "md5:" + "a" * 64
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("sourceFingerprint" in e for e in errors)


def test_validate_fingerprint_non_hex(tmp_path):
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    m["sourceFingerprint"] = "sha256:" + "z" * 64
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("sourceFingerprint" in e for e in errors)


def test_validate_fingerprint_short(tmp_path):
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    m["sourceFingerprint"] = "sha256:" + "a" * 63
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("sourceFingerprint" in e for e in errors)


# ---- 主键唯一性 / 等级 ----

def test_validate_duplicate_dataid(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"].append(dict(c["items"][0]))
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("dataID" in e for e in errors)


def test_validate_duplicate_section_key(tmp_path):
    """同 dataID 不同 section 不算重复主键（(section, dataID) 复合键）。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    dup = json.loads(json.dumps(c["items"][0]))
    dup["section"] = "buildings"
    c["items"].append(dup)
    _write_with_hash(d, catalog=c)
    m = _load_manifest(d)
    m["counts"] = {"items": 2, "levels": 2, "missingTime": 0, "missingIcons": 0}
    _write(d, manifest=m)
    assert validate_catalog(d) == []


def test_validate_levels_not_strictly_ascending(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    item = c["items"][0]
    lv = item["levels"][0]
    item["levels"] = [dict(lv, level=3), dict(lv, level=3)]
    item["maxLevel"] = 3
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("升序" in e for e in errors)


def test_validate_maxlevel_mismatch(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["maxLevel"] = 5
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("maxLevel" in e for e in errors)


# ---- durationSeconds ⟺ missingReason ----

def test_validate_duration_null_requires_reason(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"] = [{
        "level": 1, "durationSeconds": None, "missingReason": None,
        "upgradeResource": None, "upgradeCost": None,
        "requiredTownHallLevel": None, "requiredLaboratoryLevel": None,
        "icon": None, "levelVisual": None,
    }]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("missingReason" in e for e in errors)


def test_validate_duration_set_with_reason_rejected(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["missingReason"] = "time_missing"
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("missingReason" in e for e in errors)


def test_validate_unknown_missing_reason(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["missingReason"] = "some_future_reason"
    c["items"][0]["levels"][0]["durationSeconds"] = None
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("未知 missingReason" in e for e in errors)


# ---- missingReason 跨域污染（I3 回归）：level/base/item/asset 词表互不混用 ----

def test_validate_level_reason_cross_domain_rejected(tmp_path):
    """level 上写 base 域 reason（capital_has_no_base）→ 拒绝。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    lv = c["items"][0]["levels"][0]
    lv["durationSeconds"] = None
    lv["missingReason"] = "capital_has_no_base"
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("未知 missingReason" in e for e in errors)


def test_validate_item_reason_cross_domain_rejected(tmp_path):
    """item 上写 level 域 reason（time_missing）→ 拒绝。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["missingReason"] = "time_missing"
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("item.missingReason" in e for e in errors)


def test_validate_asset_reason_cross_domain_rejected(tmp_path):
    """AssetRef.icon 上写 level 域 reason（time_missing）→ 拒绝。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["icon"] = {
        "container": "sc/ui.sc", "exportName": "icon_x",
        "renderedPath": None, "missingReason": "time_missing",
    }
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("icon.missingReason" in e for e in errors)


def test_validate_asset_reason_asset_domain_ok(tmp_path):
    """AssetRef 用 asset 域 reason（icons_not_rendered）→ 通过。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["icon"] = {
        "container": "sc/ui.sc", "exportName": "icon_x",
        "renderedPath": None, "missingReason": "icons_not_rendered",
    }
    _write_with_hash(d, catalog=c)
    assert validate_catalog(d) == []


def test_validate_negative_duration(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["durationSeconds"] = -1
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("负" in e for e in errors)


# ---- base ⟺ baseMissingReason（capital 表）----

def test_validate_base_null_requires_reason(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    item = c["items"][0]
    item["base"] = None
    item["baseMissingReason"] = None
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("baseMissingReason" in e for e in errors)


def test_validate_base_set_with_reason_rejected(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["baseMissingReason"] = "capital_has_no_base"
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("baseMissingReason" in e for e in errors)


def test_validate_capital_item_ok(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    item = c["items"][0]
    item["section"] = "capital_buildings"
    item["category"] = "capitalBuildings"
    item["base"] = None
    item["baseMissingReason"] = "capital_has_no_base"
    _write_with_hash(d, catalog=c)
    assert validate_catalog(d) == []


def test_validate_unknown_base_missing_reason(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    item = c["items"][0]
    item["base"] = None
    item["baseMissingReason"] = "no_such_reason"
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("baseMissingReason" in e for e in errors)


# ---- counts 与内容重算一致 ----

def test_validate_counts_items_mismatch(tmp_path):
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    m["counts"]["items"] = 2
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("counts.items" in e for e in errors)


def test_validate_counts_missingtime_mismatch(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"] = [{
        "level": 1, "durationSeconds": None, "missingReason": "time_missing",
        "upgradeResource": None, "upgradeCost": None,
        "requiredTownHallLevel": None, "requiredLaboratoryLevel": None,
        "icon": None, "levelVisual": None,
    }]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("counts.missingTime" in e for e in errors)


def test_validate_counts_missing_entirely(tmp_path):
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    del m["counts"]
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("counts" in e for e in errors)


def test_catalog_invariants_alias(tmp_path):
    from game_catalog.validate import catalog_invariants
    assert catalog_invariants(_valid_dir(tmp_path)) == []


def test_validate_generated_files_hash_mismatch_detected(tmp_path):
    """P1-1 回归：篡改 catalog.json 后 generatedFiles 哈希不一致必须报错。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"] = [{
        "level": 1, "durationSeconds": 999999, "missingReason": None,
        "upgradeResource": None, "upgradeCost": None,
        "requiredTownHallLevel": None, "requiredLaboratoryLevel": None,
        "icon": None, "levelVisual": None,
    }]
    _write(d, catalog=c)  # 篡改后不更新 manifest 的 generatedFiles sha256
    errors = validate_catalog(d)
    assert any("哈希不一致" in e for e in errors)


def test_validate_generated_files_missing_file_detected(tmp_path):
    d = _valid_dir(tmp_path)
    (d / "catalog.json").unlink()
    errors = validate_catalog(d)
    assert any("catalog.json 不存在" in e for e in errors)


def test_validate_generated_files_missing_icons_dir_detected(tmp_path):
    d = _valid_dir(tmp_path)
    import shutil
    shutil.rmtree(d / "icons")
    errors = validate_catalog(d)
    assert any("icons" in e and "目录不存在" in e for e in errors)


def test_validate_generated_files_sha256_correct_passes(tmp_path):
    """未篡改时 generatedFiles 校验通过（用真实哈希写 manifest）。"""
    import hashlib
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    data = (d / "catalog.json").read_bytes()
    m["generatedFiles"] = [
        {"path": "catalog.json", "sha256": "sha256:" + hashlib.sha256(data).hexdigest(), "size": len(data)},
        {"path": "icons/", "kind": "directory"},
    ]
    _write(d, manifest=m)
    assert validate_catalog(d) == []


def test_validate_generated_files_size_missing_rejected(tmp_path):
    """P1 回归：删除 generatedFiles[].size → 必须拒绝（size 必填）。"""
    import hashlib
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    data = (d / "catalog.json").read_bytes()
    m["generatedFiles"] = [
        {"path": "catalog.json", "sha256": "sha256:" + hashlib.sha256(data).hexdigest()},
        {"path": "icons/", "kind": "directory"},
    ]
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("size 缺失或非法" in e for e in errors)


def test_validate_generated_files_size_non_int_rejected(tmp_path):
    import hashlib
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    data = (d / "catalog.json").read_bytes()
    m["generatedFiles"] = [
        {"path": "catalog.json", "sha256": "sha256:" + hashlib.sha256(data).hexdigest(),
         "size": "123"},
        {"path": "icons/", "kind": "directory"},
    ]
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("size 缺失或非法" in e for e in errors)


def test_validate_generated_files_size_negative_rejected(tmp_path):
    import hashlib
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    data = (d / "catalog.json").read_bytes()
    m["generatedFiles"] = [
        {"path": "catalog.json", "sha256": "sha256:" + hashlib.sha256(data).hexdigest(),
         "size": -1},
        {"path": "icons/", "kind": "directory"},
    ]
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("size 缺失或非法" in e for e in errors)


def test_validate_generated_files_size_wrong_rejected(tmp_path):
    import hashlib
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    data = (d / "catalog.json").read_bytes()
    m["generatedFiles"] = [
        {"path": "catalog.json", "sha256": "sha256:" + hashlib.sha256(data).hexdigest(),
         "size": len(data) + 1},
        {"path": "icons/", "kind": "directory"},
    ]
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("大小不一致" in e for e in errors)


# ---- renderedPath 负例校验（Issue #27 Task 6，契约 R1/R2/R5）----

def _ref(rendered_path=None, reason=None):
    """构造 AssetRef 字形 dict（renderedPath/missingReason 可配）。"""
    return {
        "container": "sc/ui.sc", "exportName": "icon_unit_barbarian",
        "renderedPath": rendered_path, "missingReason": reason,
    }


def _register_png(d: Path, rel_path: str, data: bytes) -> None:
    """写 PNG 文件并登记到 manifest generatedFiles（hash/size 如实）。"""
    import hashlib
    (d / rel_path).parent.mkdir(parents=True, exist_ok=True)
    (d / rel_path).write_bytes(data)
    m = _load_manifest(d)
    m["generatedFiles"].append({
        "path": rel_path,
        "sha256": "sha256:" + hashlib.sha256(data).hexdigest(),
        "size": len(data),
    })
    _write(d, manifest=m)


def test_rendered_path_file_must_exist(tmp_path):
    """R-A / R5.3 负例：renderedPath 指向不存在的文件 → error。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="icons/ui/barbarian.png")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("renderedPath 指向不存在的文件" in e and "icons/ui/barbarian.png" in e for e in errors)


def test_rendered_path_level_visual_must_exist(tmp_path):
    """R-A 覆盖 levelVisual：同样要求文件存在。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["levelVisual"] = _ref(rendered_path="icons/ui/barracks_lvl1.png")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("renderedPath 指向不存在的文件" in e and "icons/ui/barracks_lvl1.png" in e for e in errors)


def test_rendered_path_item_icon_must_exist(tmp_path):
    """R-A 覆盖 item 级 icon/levelVisual（上下文无 level）。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["icon"] = _ref(rendered_path="icons/ui/barbarian.png")
    c["items"][0]["levelVisual"] = _ref(rendered_path="icons/ui/barracks_lvl1.png")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("renderedPath 指向不存在的文件" in e and "icons/ui/barbarian.png" in e for e in errors)
    assert any("renderedPath 指向不存在的文件" in e and "icons/ui/barracks_lvl1.png" in e for e in errors)


def test_rendered_path_file_exists_passes(tmp_path):
    """R-A/R-C 正例：文件真实存在且登记（hash/size 如实）→ 通过。"""
    d = _valid_dir(tmp_path)
    png = b"\x89PNG\r\n\x1a\n" + b"x" * 64
    _register_png(d, "icons/ui/barbarian.png", png)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="icons/ui/barbarian.png")
    _write_with_hash(d, catalog=c)
    assert validate_catalog(d) == []


def test_rendered_path_file_content_not_png_rejected(tmp_path):
    """R-A 扩展（Issue #30 Task 8）：文件存在但内容非 PNG（前 8 字节非魔数）→ error。
    垃圾字节也如实登记 hash/size，保证只有 PNG 魔数错误暴露。"""
    d = _valid_dir(tmp_path)
    _register_png(d, "icons/ui/barbarian.png", b"hello world" * 6)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="icons/ui/barbarian.png")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("不是合法 PNG" in e and "icons/ui/barbarian.png" in e for e in errors)


def test_rendered_path_file_empty_rejected(tmp_path):
    """R-A 扩展：空文件（0 字节，不足 8 字节魔数）→ error。"""
    d = _valid_dir(tmp_path)
    _register_png(d, "icons/ui/barbarian.png", b"")
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="icons/ui/barbarian.png")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("不是合法 PNG" in e for e in errors)


def test_rendered_path_file_short_header_rejected(tmp_path):
    """R-A 扩展：小文件（4 字节，仅部分魔数，不足完整 8 字节）→ error。"""
    d = _valid_dir(tmp_path)
    _register_png(d, "icons/ui/barbarian.png", b"\x89PNG")
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="icons/ui/barbarian.png")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("不是合法 PNG" in e for e in errors)


def test_rendered_path_shared_between_refs_passes(tmp_path):
    """R2.4 去重：不同 ref 共享同一 renderedPath，manifest 只登记一次 → 通过。"""
    d = _valid_dir(tmp_path)
    png = b"\x89PNG\r\n\x1a\n" + b"y" * 32
    _register_png(d, "icons/ui/barbarian.png", png)
    c = _load_catalog(d)
    c["items"][0]["icon"] = _ref(rendered_path="icons/ui/barbarian.png")
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="icons/ui/barbarian.png")
    _write_with_hash(d, catalog=c)
    assert validate_catalog(d) == []


def test_rendered_path_with_missing_reason_rejected(tmp_path):
    """R-B / R5.2 负例：renderedPath 与 missingReason 互斥。"""
    d = _valid_dir(tmp_path)
    png = b"\x89PNG\r\n\x1a\n" + b"z" * 16
    _register_png(d, "icons/ui/barbarian.png", png)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(
        rendered_path="icons/ui/barbarian.png", reason="icons_not_rendered")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("renderedPath 与 missingReason 同时存在" in e and "互斥" in e for e in errors)


def test_rendered_path_without_icons_prefix_rejected(tmp_path):
    """R-D 负例：缺少 icons/ 前缀（相对版本目录 icons/ 下）→ error。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="barbarian.png")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("renderedPath" in e and "icons/" in e for e in errors)


def test_rendered_path_empty_string_rejected(tmp_path):
    """P1-2 回归：renderedPath 空串不再绕过校验（None 才是无引用；"" 是非法路径）。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("renderedPath" in e and "格式非法" in e for e in errors)


def test_asset_empty_missing_reason_rejected(tmp_path):
    """P1-2 回归：asset ref 的 missingReason 空串不绕过域校验（"" 未知 reason）。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(
        rendered_path="icons/ui/barbarian.png", reason="")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("missingReason 未知" in e for e in errors)


def test_rendered_path_non_png_rejected(tmp_path):
    """R-D 负例：非 .png 结尾 → error。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="icons/ui/barbarian.jpg")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("renderedPath" in e and ".png" in e for e in errors)


def test_rendered_path_unregistered_rejected(tmp_path):
    """R-C 负例：文件存在但未在 manifest generatedFiles 登记 → error。"""
    d = _valid_dir(tmp_path)
    (d / "icons" / "ui").mkdir(parents=True)
    (d / "icons" / "ui" / "barbarian.png").write_bytes(b"\x89PNG\r\n\x1a\n")
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="icons/ui/barbarian.png")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("未在 manifest generatedFiles 登记" in e for e in errors)


def test_rendered_path_registered_png_hash_mismatch_rejected(tmp_path):
    """R4.2 守卫：PNG 条目登记但 hash/size 与实际不符 → 走现有 generatedFiles 校验。"""
    import hashlib
    d = _valid_dir(tmp_path)
    png = b"\x89PNG\r\n\x1a\n" + b"w" * 24
    (d / "icons" / "ui").mkdir(parents=True)
    (d / "icons" / "ui" / "barbarian.png").write_bytes(png)
    m = _load_manifest(d)
    m["generatedFiles"].append({
        "path": "icons/ui/barbarian.png",
        "sha256": "sha256:" + hashlib.sha256(b"wrong").hexdigest(),
        "size": len(png) + 7,
    })
    _write(d, manifest=m)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="icons/ui/barbarian.png")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("哈希不一致" in e for e in errors)
    assert any("大小不一致" in e for e in errors)


@pytest.mark.parametrize("reason", [
    "sc_parse_failed", "movieclip_not_parsed", "texture_compressed_astc",
    "texture_external_sctx", "zstd_unavailable",
])
def test_new_asset_missing_reasons_accepted(tmp_path, reason):
    """R5 新枚举：renderedPath=null + 新 reason → 通过（域校验自动放行）。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["icon"] = _ref(rendered_path=None, reason=reason)
    _write_with_hash(d, catalog=c)
    assert validate_catalog(d) == []


def test_rendered_path_format_and_missing_reason_both_reported(tmp_path):
    """NB-1 回归：R-D 格式非法 + R-B 互斥是两条独立轴，格式非法也要报互斥。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(
        rendered_path="barbarian.png", reason="icons_not_rendered")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("renderedPath 格式非法" in e for e in errors)
    assert any("renderedPath 与 missingReason 同时存在" in e and "互斥" in e for e in errors)


def test_rendered_path_non_string_type_wrapped(tmp_path):
    """nit 4 回归：renderedPath 非 str（int）→ "catalog 内容非法" wrapper，不裸崩。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path=5)
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert errors and "内容非法" in errors[0]
    assert not any("Traceback" in e for e in errors)


def test_rendered_path_rc_skipped_when_no_generated_files(tmp_path):
    """registered=None 分支：manifest 无 generatedFiles 时 R-C 静默跳过，不虚假报"未登记"。"""
    d = _valid_dir(tmp_path)
    (d / "icons" / "ui").mkdir(parents=True)
    (d / "icons" / "ui" / "barbarian.png").write_bytes(b"\x89PNG\r\n\x1a\n")
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="icons/ui/barbarian.png")
    _write_with_hash(d, catalog=c)
    m = _load_manifest(d)
    del m["generatedFiles"]
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("缺少 generatedFiles" in e for e in errors)
    assert not any("未在 manifest generatedFiles 登记" in e for e in errors)


# ---- 交叉审核回归：R-D 严格两级结构（版本段/.. 逃逸/绝对路径）----


def test_rendered_path_version_segment_rejected_even_when_file_exists(tmp_path):
    """验收 7 缺口回归：icons/18.400.13/...（版本段）即使真实存在+登记+hash 对
    也必须拒绝——契约 R7 版本隔离要求路径内不含版本段，且 R2.1 只允许两级结构。"""
    import hashlib
    d = _valid_dir(tmp_path)
    png = b"\x89PNG\r\n\x1a\n" + b"v" * 8
    (d / "icons" / "18.400.13" / "ui").mkdir(parents=True)
    (d / "icons" / "18.400.13" / "ui" / "icon_unit_barbarian.png").write_bytes(png)
    m = _load_manifest(d)
    m["generatedFiles"].append({
        "path": "icons/18.400.13/ui/icon_unit_barbarian.png",
        "sha256": "sha256:" + hashlib.sha256(png).hexdigest(),
        "size": len(png),
    })
    _write(d, manifest=m)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(
        rendered_path="icons/18.400.13/ui/icon_unit_barbarian.png")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("格式非法" in e for e in errors)


def test_rendered_path_backslash_rejected_even_when_file_exists(tmp_path):
    """P2-1c 回归：含反斜杠的 renderedPath（未 sanitize，R2.2）即使文件真实存在+
    登记+hash 对也必须拒绝——反斜杠是 Windows 路径分隔符，跨平台逃逸风险。"""
    import hashlib
    d = _valid_dir(tmp_path)
    png = b"\x89PNG\r\n\x1a\n" + b"w" * 8
    (d / "icons" / "ui").mkdir(parents=True)
    (d / "icons" / "ui" / "a_b.png").write_bytes(png)
    m = _load_manifest(d)
    m["generatedFiles"].append({
        "path": "icons/ui/a_b.png",
        "sha256": "sha256:" + hashlib.sha256(png).hexdigest(),
        "size": len(png),
    })
    _write(d, manifest=m)
    c = _load_catalog(d)
    # renderedPath 含反斜杠（未 sanitize 形态），文件/登记都指向正常路径
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path=r"icons/ui/a\b.png")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("格式非法" in e for e in errors)


def test_rendered_path_dotdot_escape_rejected_without_probe(tmp_path):
    """NB-3 回归：icons/../../secret.png 指向 catalog 目录外的真实文件（且登记、
    hash 对）→ 必须报格式非法，不得因逃逸探测命中而放行。"""
    import hashlib
    d = _valid_dir(tmp_path)
    # 逃逸目标：catalog 目录（tmp_path/cat）之外、tmp_path 之下
    secret = tmp_path / "secret.png"
    secret.write_bytes(b"\x89PNG\r\n\x1a\n" + b"s" * 8)
    m = _load_manifest(d)
    m["generatedFiles"].append({
        "path": "icons/../../secret.png",
        "sha256": "sha256:" + hashlib.sha256(secret.read_bytes()).hexdigest(),
        "size": secret.stat().st_size,
    })
    _write(d, manifest=m)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="icons/../../secret.png")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("格式非法" in e for e in errors)
    # R-D 短路：不再报 R-A/R-C（旧实现会因探测命中而放行或报"未登记"）
    assert not any("指向不存在的文件" in e for e in errors)
    assert not any("未在 manifest generatedFiles 登记" in e for e in errors)


def test_rendered_path_dotdot_inside_catalog_rejected(tmp_path):
    """目录内逃逸：icons/../x.png 解析到 catalog 根下的文件（登记过）→ 格式非法。"""
    import hashlib
    d = _valid_dir(tmp_path)
    png = b"\x89PNG\r\n\x1a\n" + b"x" * 8
    (d / "x.png").write_bytes(png)
    m = _load_manifest(d)
    m["generatedFiles"].append({
        "path": "icons/../x.png",
        "sha256": "sha256:" + hashlib.sha256(png).hexdigest(),
        "size": len(png),
    })
    _write(d, manifest=m)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["icon"] = _ref(rendered_path="icons/../x.png")
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("格式非法" in e for e in errors)
