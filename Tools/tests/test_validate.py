"""Task 7: validate_catalog 不变量（结构 + 语义 + counts 重算）。测试是契约。"""

import json
from pathlib import Path

from game_catalog.model import catalog_to_dict, Catalog, CatalogItem, CatalogLevel
from game_catalog.validate import validate_catalog


def _valid_dir(tmp_path: Path) -> Path:
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
    (d / "catalog.json").write_text(json.dumps(catalog_to_dict(catalog), ensure_ascii=False))
    (d / "manifest.json").write_text(json.dumps({
        "schemaVersion": 1, "gameVersion": "18.400.13", "buildTag": "18_400_7",
        "locale": "zh-CN", "sourceFingerprint": "sha256:" + "a" * 64,
        "generatedFiles": [{"path": "catalog.json", "sha256": "", "size": 0}],
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
    _write(d, catalog=c)
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
    _write(d, catalog=c)
    errors = validate_catalog(d)
    assert any("dataID" in e for e in errors)


def test_validate_duplicate_section_key(tmp_path):
    """同 dataID 不同 section 不算重复主键（(section, dataID) 复合键）。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    dup = json.loads(json.dumps(c["items"][0]))
    dup["section"] = "buildings"
    c["items"].append(dup)
    _write(d, catalog=c)
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
    _write(d, catalog=c)
    errors = validate_catalog(d)
    assert any("升序" in e for e in errors)


def test_validate_maxlevel_mismatch(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["maxLevel"] = 5
    _write(d, catalog=c)
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
    _write(d, catalog=c)
    errors = validate_catalog(d)
    assert any("missingReason" in e for e in errors)


def test_validate_duration_set_with_reason_rejected(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["missingReason"] = "time_missing"
    _write(d, catalog=c)
    errors = validate_catalog(d)
    assert any("missingReason" in e for e in errors)


def test_validate_unknown_missing_reason(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["missingReason"] = "some_future_reason"
    c["items"][0]["levels"][0]["durationSeconds"] = None
    _write(d, catalog=c)
    errors = validate_catalog(d)
    assert any("未知 missingReason" in e for e in errors)


def test_validate_negative_duration(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["durationSeconds"] = -1
    _write(d, catalog=c)
    errors = validate_catalog(d)
    assert any("负" in e for e in errors)


# ---- base ⟺ baseMissingReason（capital 表）----

def test_validate_base_null_requires_reason(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    item = c["items"][0]
    item["base"] = None
    item["baseMissingReason"] = None
    _write(d, catalog=c)
    errors = validate_catalog(d)
    assert any("baseMissingReason" in e for e in errors)


def test_validate_base_set_with_reason_rejected(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["baseMissingReason"] = "capital_has_no_base"
    _write(d, catalog=c)
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
    _write(d, catalog=c)
    assert validate_catalog(d) == []


def test_validate_unknown_base_missing_reason(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    item = c["items"][0]
    item["base"] = None
    item["baseMissingReason"] = "no_such_reason"
    _write(d, catalog=c)
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
    _write(d, catalog=c)
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
