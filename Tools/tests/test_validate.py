"""Task 7: validate_catalog 不变量（结构 + 语义 + counts 重算）。测试是契约。"""

import json
from pathlib import Path

import pytest

from game_catalog.model import (
    catalog_to_dict, Catalog, CatalogItem, CatalogLevel, UpgradeCost,
)
from game_catalog.validate import validate_catalog


def _valid_dir(tmp_path: Path) -> Path:
    import hashlib

    item = CatalogItem(
        section="units", dataID=4_000_000, category="troops", base="home",
        baseMissingReason=None, name="野蛮人", maxLevel=1,
        icon=None, levelVisual=None, missingReason=None,
        levels=[CatalogLevel(
            level=1, durationSeconds=0, missingReason=None,
            upgradeCosts=[UpgradeCost(resource="Elixir", amount=100,
                                      rawResource="Elixir", rawAmount=None,
                                      parseFailed=False)],
            requiredTownHallLevel=None, requiredLaboratoryLevel=None,
            icon=None, levelVisual=None,
        )],
        # Issue #98：units:4000000 在真实声明文件中（permanent）
        lifecycle="permanent",
    )
    catalog = Catalog(schemaVersion=2, gameVersion="18.400.13", locale="zh-CN",
                      items=[item])
    d = tmp_path / "cat"
    d.mkdir()
    catalog_bytes = json.dumps(catalog_to_dict(catalog), ensure_ascii=False).encode("utf-8")
    (d / "catalog.json").write_bytes(catalog_bytes)
    (d / "icons").mkdir()
    (d / "manifest.json").write_text(json.dumps({
        "schemaVersion": 2, "gameVersion": "18.400.13", "buildTag": "18_400_7",
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
    m["schemaVersion"] = 3
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("schemaVersion" in e for e in errors)


def test_validate_schema_version_mismatch_catalog(tmp_path):
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["schemaVersion"] = 3
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
    # 同 dataID=1000008 双 item：units（非 buildings 不查分类）+ buildings（防御）
    c["items"][0]["dataID"] = 1000008
    # Issue #98：units:1000008 无声明 → 无标注不报；dup（buildings:1000008）
    # 在声明中 → 显式 permanent
    c["items"][0]["lifecycle"] = None
    dup = json.loads(json.dumps(c["items"][0]))
    dup["section"] = "buildings"
    dup["name"] = "加农炮"
    # Issue #75 工作流 C：home buildings 必须与注册表一致（defense）——全量比对锁定
    dup["displayCategory"] = "defense"
    dup["lifecycle"] = "permanent"
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
        "upgradeCosts": None,
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


# ---- upgradeCosts 不变量（Issue #73 Task 1）----


def _cost_dict(*, resource="Elixir", amount=100, raw_resource="Elixir",
               raw_amount=None, failed=False):
    return {"resource": resource, "amount": amount, "rawResource": raw_resource,
            "rawAmount": raw_amount, "parseFailed": failed}


def test_validate_upgrade_costs_ok(tmp_path):
    """合法 upgradeCosts（含 parseFailed=True 项）→ 通过。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = [
        _cost_dict(),  # parseFailed=False：amount 有值、rawAmount=None
        _cost_dict(amount=None, raw_amount="oops", failed=True),
        _cost_dict(amount=None, raw_amount="", failed=True),  # 多余资源项
    ]
    _write_with_hash(d, catalog=c)
    assert validate_catalog(d) == []


def test_validate_upgrade_costs_none_ok(tmp_path):
    """upgradeCosts=None（无费用数据）→ 通过。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = None
    _write_with_hash(d, catalog=c)
    assert validate_catalog(d) == []


def test_validate_upgrade_costs_empty_array_rejected(tmp_path):
    """不变量 2：非 None 必须非空，[] 非法。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = []
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("upgradeCosts" in e and "空" in e for e in errors)


def test_validate_upgrade_costs_failed_with_amount_rejected(tmp_path):
    """不变量 4：parseFailed=True ⟹ amount=None。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = [
        _cost_dict(amount=10, raw_amount="x", failed=True)]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("parseFailed" in e and "amount" in e for e in errors)


def test_validate_upgrade_costs_failed_missing_raw_amount_rejected(tmp_path):
    """不变量 4：parseFailed=True ⟹ rawAmount != None。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = [
        _cost_dict(amount=None, raw_amount=None, failed=True)]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("parseFailed" in e and "rawAmount" in e for e in errors)


def test_validate_upgrade_costs_ok_failed_with_raw_amount_ok(tmp_path):
    """parseFailed=True + rawAmount=''（多余资源项）→ 通过（'' 满足 != None）。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = [
        _cost_dict(amount=None, raw_amount="", failed=True)]
    _write_with_hash(d, catalog=c)
    assert validate_catalog(d) == []


def test_validate_upgrade_costs_ok_missing_amount_rejected(tmp_path):
    """不变量 3：parseFailed=False ⟹ amount != None。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = [
        _cost_dict(amount=None)]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("parseFailed" in e and "amount" in e for e in errors)


def test_validate_upgrade_costs_raw_amount_without_failed_rejected(tmp_path):
    """不变量 3：parseFailed=False ⟹ rawAmount == None。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = [
        _cost_dict(amount=100, raw_amount="100")]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("parseFailed" in e and "rawAmount" in e for e in errors)


def test_validate_upgrade_costs_negative_amount_rejected(tmp_path):
    """不变量 3：parseFailed=False ⟹ amount >= 0。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = [_cost_dict(amount=-1)]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("负" in e for e in errors)


def test_validate_upgrade_costs_amount_over_int64_rejected(tmp_path):
    """amount 超出 Int64 上界（2^63-1）→ 拒绝（Swift Int64 解码会失败，交叉审核 M-2）。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = [_cost_dict(amount=2**63)]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("Int64" in e for e in errors)


def test_validate_upgrade_costs_parse_failed_type_rejected(tmp_path):
    """parseFailed=1（非 bool，int）→ 类型非法。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = [_cost_dict(failed=1)]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("parseFailed" in e and "类型" in e for e in errors)


def test_validate_upgrade_costs_bool_amount_rejected(tmp_path):
    """amount=True（bool 是 int 子类）→ 类型非法。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = [_cost_dict(amount=True)]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("amount" in e and "类型" in e for e in errors)


def test_validate_upgrade_costs_raw_resource_empty_rejected(tmp_path):
    """不变量 5：rawResource 恒非空。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = [_cost_dict(raw_resource="")]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("rawResource" in e and "空" in e for e in errors)


def test_validate_upgrade_costs_resource_empty_rejected(tmp_path):
    """不变量 6：resource 恒非空。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = [_cost_dict(resource="")]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("resource" in e and "空" in e for e in errors)


def test_validate_upgrade_costs_wrong_type_rejected(tmp_path):
    """upgradeCosts 非 list（dict）→ 解析失败（from_dict 拒绝）。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["upgradeCosts"] = {"resource": "Elixir"}
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert errors and "解析失败" in errors[0]


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
    # Issue #98：capital_buildings:4000000 无声明 → 无标注不报
    item["lifecycle"] = None
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


# ---- requiredBlacksmithLevel 域校验（Issue #97：equipment 铁匠铺门槛）----


def _equipment_dir(tmp_path: Path) -> Path:
    """_valid_dir + 唯一 item 改为 equipment（BS 域校验基底）。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["section"] = "equipment"
    _write_with_hash(d, catalog=c)
    return d


def test_validate_equipment_blacksmith_ok(tmp_path):
    """equipment level BS=5（合法域 1...10）→ 无 BS 相关错误。"""
    d = _equipment_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["requiredBlacksmithLevel"] = 5
    _write_with_hash(d, catalog=c)
    assert validate_catalog(d) == []


def test_validate_equipment_blacksmith_missing_rejected(tmp_path):
    """equipment level 缺 requiredBlacksmithLevel 键（旧产物）→ 报错提示回填。"""
    d = _equipment_dir(tmp_path)
    c = _load_catalog(d)
    del c["items"][0]["levels"][0]["requiredBlacksmithLevel"]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("缺少 requiredBlacksmithLevel" in e for e in errors)


def test_validate_equipment_blacksmith_out_of_domain_rejected(tmp_path):
    """BS=11 超出合法域 1...10 → 报错（含具体值）。"""
    d = _equipment_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["requiredBlacksmithLevel"] = 11
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("超出合法域" in e and "11" in e for e in errors)


def test_validate_equipment_blacksmith_bool_type_rejected(tmp_path):
    """BS=true（bool 是 int 子类，JSON true）→ 类型非法。"""
    d = _equipment_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["requiredBlacksmithLevel"] = True
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("requiredBlacksmithLevel" in e and "类型非法" in e for e in errors)


def test_validate_equipment_blacksmith_str_type_rejected(tmp_path):
    """BS="5"（字符串）→ 类型非法（生成器不产生，防御手写/旧产物污染）。"""
    d = _equipment_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"][0]["requiredBlacksmithLevel"] = "5"
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("requiredBlacksmithLevel" in e and "类型非法" in e for e in errors)


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
        "upgradeCosts": None,
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


# ---- R6.2：counts.renderedIcons / counts.blockedIcons（optional 字段）----

def test_validate_counts_optional_fields_missing_ok(tmp_path):
    """旧 manifest 兼容：renderedIcons/blockedIcons 缺失不报错（optional）。"""
    d = _valid_dir(tmp_path)  # counts 仅含基础 4 字段
    assert validate_catalog(d) == []


def test_validate_rendered_icons_mismatch_detected(tmp_path):
    """renderedIcons 与 generatedFiles PNG 条目数不符 → 报错（重算断言）。"""
    d = _valid_dir(tmp_path)
    _register_png(d, "icons/ui/barbarian.png", b"\x89PNG\r\n\x1a\n" + b"r" * 16)
    m = _load_manifest(d)
    m["counts"]["renderedIcons"] = 0  # 实际 PNG 条目数 = 1
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("counts.renderedIcons" in e and "不一致" in e for e in errors)


def test_validate_rendered_icons_ok(tmp_path):
    """renderedIcons == PNG 条目数、blockedIcons 非负 → 通过。"""
    d = _valid_dir(tmp_path)
    _register_png(d, "icons/ui/barbarian.png", b"\x89PNG\r\n\x1a\n" + b"r" * 16)
    m = _load_manifest(d)
    m["counts"]["renderedIcons"] = 1
    m["counts"]["blockedIcons"] = 2
    _write(d, manifest=m)
    assert validate_catalog(d) == []


def test_validate_rendered_icons_non_int_rejected(tmp_path):
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    m["counts"]["renderedIcons"] = "4"
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("counts.renderedIcons" in e and "非法" in e for e in errors)


def test_validate_blocked_icons_non_int_rejected(tmp_path):
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    m["counts"]["blockedIcons"] = "2"
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("counts.blockedIcons" in e for e in errors)


def test_validate_blocked_icons_negative_rejected(tmp_path):
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    m["counts"]["blockedIcons"] = -1
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("counts.blockedIcons" in e for e in errors)


def test_catalog_invariants_alias(tmp_path):
    from game_catalog.validate import catalog_invariants
    assert catalog_invariants(_valid_dir(tmp_path)) == []


def test_validate_generated_files_hash_mismatch_detected(tmp_path):
    """P1-1 回归：篡改 catalog.json 后 generatedFiles 哈希不一致必须报错。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    c["items"][0]["levels"] = [{
        "level": 1, "durationSeconds": 999999, "missingReason": None,
        "upgradeCosts": None,
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


# ---- Issue #74b：counts 时长语义拆分校验 ----

_NEW_COUNTS = {
    "items": 1, "levels": 1, "missingTime": 0, "missingIcons": 0,
    "timed": 0, "instant": 1, "notApplicable": 0, "initialLevel": 0,
    "sourceMissing": 0, "parseFailed": 0,
}


def test_validate_counts_duration_buckets_consistent(tmp_path):
    """新字段与目录重算一致 → 无错误。"""
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    m["counts"] = _NEW_COUNTS
    _write(d, manifest=m)
    assert validate_catalog(d) == []


def test_validate_counts_duration_bucket_mismatch_rejected(tmp_path):
    """任一拆分桶与重算不一致 → 报错。"""
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    m["counts"] = dict(_NEW_COUNTS, instant=0)  # 重算为 1
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("counts.instant" in e for e in errors)


def test_validate_old_manifest_without_new_fields_ok(tmp_path):
    """旧 manifest 无拆分字段 → 不报错（向后兼容）。"""
    d = _valid_dir(tmp_path)  # _valid_dir 的 counts 只有 4 个旧字段
    assert validate_catalog(d) == []


def test_validate_counts_sum_invariant(tmp_path):
    """缺失类四桶之和 == missingTime 是 unknown 泄漏哨兵。

    字段级校验 + counts_for 定义保证下，纯「字段一致但不变量违反」无法构造；
    不变量校验防御 classify_duration 回归（新 reason 误映射 unknown 时，
    生成与重算共用同一坏实现，字段级同坏不可发现）。此处以手工篡改
    missingTime 验证哨兵错误信息确实会触发。
    """
    d = _valid_dir(tmp_path)
    m = _load_manifest(d)
    m["counts"] = dict(_NEW_COUNTS, missingTime=1)  # 重算 missingTime=0
    _write(d, manifest=m)
    errors = validate_catalog(d)
    assert any("不变量" in e for e in errors)


# ---- instanceCounts 宇宙（Issue #70 阶段 2）----


def _valid_dir_with_universe(tmp_path: Path) -> Path:
    """_valid_dir + 数量型 buildings 项 + 合法 instanceCounts（宇宙校验正例基底）。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    item = json.loads(json.dumps(c["items"][0]))
    item["section"] = "buildings"
    item["dataID"] = 1000008  # Cannon（数量型，不在排除列表）
    item["displayCategory"] = "defense"  # Issue #75 工作流 C：真实分类
    c["items"].append(item)
    c["instanceCounts"] = {"buildings:1000008": [1] * 18}
    _write_with_hash(d, catalog=c)
    m = _load_manifest(d)
    m["counts"] = {"items": 2, "levels": 2, "missingTime": 0, "missingIcons": 0}
    _write(d, manifest=m)
    return d


def test_validate_instance_counts_ok(tmp_path):
    """合法 instanceCounts（键在 items、长度 18、非负、非全 0）→ 通过。"""
    assert validate_catalog(_valid_dir_with_universe(tmp_path)) == []


def test_validate_instance_counts_missing_ok(tmp_path):
    """旧产物无 instanceCounts → 不报错（向后兼容）。"""
    assert validate_catalog(_valid_dir(tmp_path)) == []


def test_validate_instance_counts_wrong_length_rejected(tmp_path):
    """值长度 != 18 → 拒绝。"""
    d = _valid_dir_with_universe(tmp_path)
    c = _load_catalog(d)
    c["instanceCounts"]["buildings:1000008"] = [1] * 17
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("instanceCounts" in e and "长度" in e for e in errors)


def test_validate_instance_counts_negative_rejected(tmp_path):
    """负值 → 拒绝。"""
    d = _valid_dir_with_universe(tmp_path)
    c = _load_catalog(d)
    vals = [1] * 18
    vals[5] = -1
    c["instanceCounts"]["buildings:1000008"] = vals
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("instanceCounts" in e and "负" in e for e in errors)


def test_validate_instance_counts_key_not_in_items_rejected(tmp_path):
    """反向 join：宇宙键 (section,dataID) 不在 items → 拒绝。"""
    d = _valid_dir_with_universe(tmp_path)
    c = _load_catalog(d)
    c["instanceCounts"]["buildings:999999"] = [1] * 18
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("不在 items" in e and "999999" in e for e in errors)


def test_validate_instance_counts_all_zero_rejected(tmp_path):
    """值全 0 → 拒绝（数量型建筑不可能全 TH 都是 0）。"""
    d = _valid_dir_with_universe(tmp_path)
    c = _load_catalog(d)
    c["instanceCounts"]["buildings:1000008"] = [0] * 18
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("全 0" in e for e in errors)


def test_validate_instance_counts_unknown_section_rejected(tmp_path):
    """键 section 不在词表（buildings/traps）→ 拒绝。"""
    d = _valid_dir_with_universe(tmp_path)
    c = _load_catalog(d)
    c["instanceCounts"]["units:4000000"] = [1] * 18  # 存在但 section 非数量型
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("未知 section" in e for e in errors)


def test_validate_instance_counts_unparseable_dataid_rejected(tmp_path):
    """键 dataID 不可解析 → 拒绝。"""
    d = _valid_dir_with_universe(tmp_path)
    c = _load_catalog(d)
    c["instanceCounts"]["buildings:abc"] = [1] * 18
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("dataID" in e for e in errors)


def test_validate_instance_counts_value_type_rejected(tmp_path):
    """值非 int（str/bool）→ 拒绝。"""
    d = _valid_dir_with_universe(tmp_path)
    c = _load_catalog(d)
    c["instanceCounts"]["buildings:1000008"] = ["1"] * 18
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("值类型非法" in e for e in errors)
    c["instanceCounts"]["buildings:1000008"] = [True] + [1] * 17
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("值类型非法" in e for e in errors)


def test_validate_instance_counts_home_item_without_universe_rejected(tmp_path):
    """正向完整性：数量型 home 项必须有宇宙项。"""
    d = _valid_dir_with_universe(tmp_path)
    c = _load_catalog(d)
    del c["instanceCounts"]["buildings:1000008"]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("缺少宇宙项" in e and "1000008" in e for e in errors)


def test_validate_instance_counts_non_countable_item_ok(tmp_path):
    """排除列表项（大本营变体等非数量型）无宇宙项 → 通过。"""
    d = _valid_dir_with_universe(tmp_path)
    c = _load_catalog(d)
    item = json.loads(json.dumps(c["items"][1]))
    item["dataID"] = 1000104  # 大本营变体（非数量型排除列表）
    item["displayCategory"] = None  # Issue #75 工作流 C：兜底项不得带分类（注册表比对）
    c["items"].append(item)
    _write_with_hash(d, catalog=c)
    m = _load_manifest(d)
    m["counts"] = {"items": 3, "levels": 3, "missingTime": 0, "missingIcons": 0}
    _write(d, manifest=m)
    assert validate_catalog(d) == []


def test_validate_instance_counts_top_level_type_rejected(tmp_path):
    """顶层 instanceCounts 非 dict（list）→ 拒绝（防御分支）。"""
    d = _valid_dir_with_universe(tmp_path)
    c = _load_catalog(d)
    c["instanceCounts"] = [1, 2]
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("instanceCounts 类型非法" in e for e in errors)


def test_validate_instance_counts_key_without_colon_rejected(tmp_path):
    """键不含 ':' → 拒绝（防御分支）。"""
    d = _valid_dir_with_universe(tmp_path)
    c = _load_catalog(d)
    c["instanceCounts"]["badkey"] = [1] * 18
    _write_with_hash(d, catalog=c)
    errors = validate_catalog(d)
    assert any("键格式非法" in e and "badkey" in e for e in errors)
